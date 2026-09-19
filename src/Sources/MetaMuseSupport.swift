import AppKit
import Foundation

/// Meta Model API credentials for a Muse subscription. `identityToken` is the
/// OAuth access token obtained from the device-code login; it is not sent to
/// the Model API directly but is re-used to mint fresh `apiKey` values without
/// asking the user to sign in again. `apiKey` is what actually authenticates
/// requests to `https://api.meta.ai/v1`.
struct MetaMuseCredentials: Codable, Equatable {
    var identityToken: String
    var apiKey: String
    var apiKeyExpiresAt: Date

    enum CodingKeys: String, CodingKey {
        case identityToken = "identity_token"
        case apiKey = "api_key"
        case apiKeyExpiresAt = "api_key_expires_at"
    }
}

enum MetaMuseAuthError: LocalizedError {
    case deviceAuthorizationFailed(String)
    case loginDenied
    case loginExpired
    case pollFailed(String)
    case mintFailed(String)
    case notAuthenticated

    var errorDescription: String? {
        switch self {
        case .deviceAuthorizationFailed(let detail):
            return "Could not start Meta sign-in: \(detail)"
        case .loginDenied:
            return "Meta sign-in was denied."
        case .loginExpired:
            return "Meta sign-in request expired. Please try again."
        case .pollFailed(let detail):
            return "Meta sign-in failed: \(detail)"
        case .mintFailed(let detail):
            return "Could not obtain a Meta Model API key: \(detail)"
        case .notAuthenticated:
            return "Connect your Meta Muse subscription first."
        }
    }
}

/// Lifecycle of the Meta Muse credential. Unlike Copilot, there is no local
/// gateway process to supervise — this only tracks the OAuth/mint round trip.
enum MetaMuseState: Equatable {
    case idle
    case authenticating
    case connected
    case failed(String)

    var failureDescription: String? {
        guard case .failed(let detail) = self else { return nil }
        return detail
    }
}

/// Reproduces `muse login`'s device-code flow entirely in-process (three plain
/// HTTPS calls, no child process): device authorization and token polling
/// against `auth.meta.com`, then Model API key minting against
/// `api.meta.ai/muse-code/key`. The resulting API key is what `ServerManager`
/// writes into CLIProxyAPI's `openai-compatibility` config for Completions.
/// Muse `/v1/responses` is TLS-forwarded by ThinkingProxy instead, because the
/// compatibility executor translates Responses into Chat Completions.
///
/// This contract is reverse-engineered from the installed `muse` CLI binary
/// and a working third-party client (`pi-meta-oauth`), not from official Meta
/// documentation. Errors expose status codes, not potentially sensitive bodies.
final class MetaMuseAuthManager: ObservableObject {
    private enum Endpoints {
        static let clientID = "1031625952748946"
        static let deviceAuthorizationURL = URL(string: "https://auth.meta.com/oidc/device/authorization/")!
        static let deviceTokenURL = URL(string: "https://auth.meta.com/oidc/device/token/")!
        static let mintURL = URL(string: "https://api.meta.ai/muse-code/key")!
        static let deviceCodeGrantType = "urn:ietf:params:oauth:grant-type:device_code"
    }

    private enum Timing {
        /// Minted keys are treated as valid for this long before a proactive
        /// re-mint is due (the reference client re-mints roughly daily).
        static let apiKeyValidityInterval: TimeInterval = 24 * 60 * 60
        /// Re-mint this far ahead of the recorded expiry so a request never
        /// races an about-to-expire key.
        static let refreshMargin: TimeInterval = 6 * 60 * 60
        static let defaultPollInterval: TimeInterval = 5
        static let defaultExpiresIn: TimeInterval = 15 * 60
    }

    @Published private(set) var state: MetaMuseState = .idle
    @Published private(set) var lastError: String?

    private let session: URLSession
    private let store: MetaMuseCredentialStore
    private var pollGeneration = 0
    private var activeTask: URLSessionDataTask?

    var hasCredentials: Bool {
        store.hasCredentials
    }

    init(store: MetaMuseCredentialStore = .shared, configuration: URLSessionConfiguration = .default) {
        self.store = store
        session = URLSession(configuration: configuration, delegate: nil, delegateQueue: .main)
        if hasCredentials {
            state = .connected
        }
    }

    // MARK: - Login

    func startAuthentication(
        onDeviceCode: @escaping (_ code: String, _ verificationURL: URL) -> Void,
        completion: @escaping (Result<Void, Error>) -> Void
    ) {
        guard state != .authenticating else { return }
        pollGeneration += 1
        let generation = pollGeneration
        state = .authenticating
        lastError = nil

        requestDeviceAuthorization { [weak self] result in
            guard let self, generation == self.pollGeneration else { return }
            switch result {
            case .failure(let error):
                self.finishAuthentication(.failure(error), completion: completion)
            case .success(let device):
                guard let verificationURL = URL(
                    string: device.verification_uri_complete ?? device.verification_uri
                ), verificationURL.scheme == "https",
                   let host = verificationURL.host,
                   host == "meta.com" || host.hasSuffix(".meta.com") else {
                    self.finishAuthentication(
                        .failure(MetaMuseAuthError.deviceAuthorizationFailed("invalid verification URL")),
                        completion: completion
                    )
                    return
                }
                NSWorkspace.shared.open(verificationURL)
                onDeviceCode(device.user_code, verificationURL)
                let interval = max(1, device.interval ?? Timing.defaultPollInterval)
                let expiresIn = device.expires_in ?? Timing.defaultExpiresIn
                let deadline = Date().addingTimeInterval(expiresIn)
                self.pollForToken(
                    deviceCode: device.device_code,
                    interval: interval,
                    deadline: deadline,
                    generation: generation,
                    completion: completion
                )
            }
        }
    }

    func cancelAuthentication() {
        guard state == .authenticating else { return }
        pollGeneration += 1
        activeTask?.cancel()
        activeTask = nil
        state = hasCredentials ? .connected : .idle
        lastError = nil
    }

    // MARK: - Refresh

    private var refreshingAccountIDs = Set<String>()

    /// Refresh independently so an invalid identity token cannot block other
    /// accounts. All manager state and persistence callbacks run on main.
    func refreshAPIKeyIfNeeded(force: Bool = false, completion: ((Result<Void, Error>) -> Void)? = nil) {
        let accounts = store.accounts.filter {
            !$0.disabled && !refreshingAccountIDs.contains($0.id) &&
                (force || Date() >= $0.credentials.apiKeyExpiresAt.addingTimeInterval(-Timing.refreshMargin))
        }
        guard !accounts.isEmpty else {
            completion?(.success(()))
            return
        }
        let group = DispatchGroup()
        var firstError: Error?
        for account in accounts {
            refreshingAccountIDs.insert(account.id)
            group.enter()
            mintAPIKey(identityToken: account.credentials.identityToken) { [weak self] result in
                guard let self else { group.leave(); return }
                self.refreshingAccountIDs.remove(account.id)
                switch result {
                case .success(let apiKey):
                    // A removed/re-authenticated account makes this a harmless no-op.
                    if !self.store.updateKey(
                        for: account, apiKey: apiKey,
                        expiresAt: Date().addingTimeInterval(Timing.apiKeyValidityInterval)
                    ), self.store.accounts.contains(where: {
                        $0.id == account.id && $0.credentials == account.credentials
                    }) {
                        firstError = firstError ?? MetaMuseAuthError.mintFailed("could not save the refreshed key")
                    }
                case .failure(let error):
                    firstError = firstError ?? error
                }
                group.leave()
            }
        }
        group.notify(queue: .main) { [weak self] in
            self?.lastError = firstError?.localizedDescription
            if let firstError { completion?(.failure(firstError)) }
            else { completion?(.success(())) }
        }
    }

    // MARK: - Device authorization

    private struct DeviceAuthorizationResponse: Decodable {
        let device_code: String
        let user_code: String
        let verification_uri: String
        let verification_uri_complete: String?
        let expires_in: Double?
        let interval: Double?
    }

    private func requestDeviceAuthorization(completion: @escaping (Result<DeviceAuthorizationResponse, Error>) -> Void) {
        var request = URLRequest(url: Endpoints.deviceAuthorizationURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = Self.formEncodedBody(["client_id": Endpoints.clientID])

        activeTask = session.dataTask(with: request) { data, response, error in
            if let error {
                completion(.failure(MetaMuseAuthError.deviceAuthorizationFailed(error.localizedDescription)))
                return
            }
            guard let data, let httpResponse = response as? HTTPURLResponse else {
                completion(.failure(MetaMuseAuthError.deviceAuthorizationFailed("no response")))
                return
            }
            guard (200..<300).contains(httpResponse.statusCode) else {
                completion(.failure(MetaMuseAuthError.deviceAuthorizationFailed(
                    "HTTP \(httpResponse.statusCode)"
                )))
                return
            }
            do {
                let decoded = try JSONDecoder().decode(DeviceAuthorizationResponse.self, from: data)
                completion(.success(decoded))
            } catch {
                completion(.failure(MetaMuseAuthError.deviceAuthorizationFailed("malformed response")))
            }
        }
        activeTask?.resume()
    }

    // MARK: - Token polling

    private struct DeviceTokenResponse: Decodable {
        let access_token: String?
        let error: String?
    }

    private func pollForToken(
        deviceCode: String,
        interval: TimeInterval,
        deadline: Date,
        generation: Int,
        completion: @escaping (Result<Void, Error>) -> Void
    ) {
        guard generation == pollGeneration else { return }
        guard Date() < deadline else {
            finishAuthentication(.failure(MetaMuseAuthError.loginExpired), completion: completion)
            return
        }

        var request = URLRequest(url: Endpoints.deviceTokenURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = Self.formEncodedBody([
            "grant_type": Endpoints.deviceCodeGrantType,
            "device_code": deviceCode,
            "client_id": Endpoints.clientID
        ])

        activeTask = session.dataTask(with: request) { [weak self] data, response, error in
            guard let self, generation == self.pollGeneration else { return }

            if let error {
                self.finishAuthentication(
                    .failure(MetaMuseAuthError.pollFailed(error.localizedDescription)),
                    completion: completion
                )
                return
            }
            guard let data, let httpResponse = response as? HTTPURLResponse else {
                self.finishAuthentication(.failure(MetaMuseAuthError.pollFailed("no response")), completion: completion)
                return
            }

            let decoded = try? JSONDecoder().decode(DeviceTokenResponse.self, from: data)

            if (200..<300).contains(httpResponse.statusCode), let accessToken = decoded?.access_token, !accessToken.isEmpty {
                self.mintAndPersist(identityToken: accessToken, generation: generation, completion: completion)
                return
            }

            switch decoded?.error {
            case "authorization_pending":
                self.schedulePoll(deviceCode: deviceCode, interval: interval, deadline: deadline, generation: generation, delay: interval, completion: completion)
            case "slow_down":
                self.schedulePoll(deviceCode: deviceCode, interval: interval + 5, deadline: deadline, generation: generation, delay: interval + 5, completion: completion)
            case "access_denied":
                self.finishAuthentication(.failure(MetaMuseAuthError.loginDenied), completion: completion)
            case "expired_token":
                self.finishAuthentication(.failure(MetaMuseAuthError.loginExpired), completion: completion)
            default:
                let detail = "HTTP \(httpResponse.statusCode)"
                self.finishAuthentication(.failure(MetaMuseAuthError.pollFailed(detail)), completion: completion)
            }
        }
        activeTask?.resume()
    }

    private func schedulePoll(
        deviceCode: String,
        interval: TimeInterval,
        deadline: Date,
        generation: Int,
        delay: TimeInterval,
        completion: @escaping (Result<Void, Error>) -> Void
    ) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, generation == self.pollGeneration else { return }
            self.pollForToken(deviceCode: deviceCode, interval: interval, deadline: deadline, generation: generation, completion: completion)
        }
    }

    private func mintAndPersist(identityToken: String, generation: Int, completion: @escaping (Result<Void, Error>) -> Void) {
        mintAPIKey(identityToken: identityToken) { [weak self] result in
            guard let self, generation == self.pollGeneration else { return }
            switch result {
            case .success(let apiKey):
                let credentials = MetaMuseCredentials(
                    identityToken: identityToken,
                    apiKey: apiKey,
                    apiKeyExpiresAt: Date().addingTimeInterval(Timing.apiKeyValidityInterval)
                )
                guard self.store.save(credentials) else {
                    self.finishAuthentication(
                        .failure(MetaMuseAuthError.mintFailed("could not save credentials")),
                        completion: completion
                    )
                    return
                }
                self.finishAuthentication(.success(()), completion: completion)
            case .failure(let error):
                self.finishAuthentication(.failure(error), completion: completion)
            }
        }
    }

    // MARK: - Key minting

    private struct MintResponse: Decodable {
        let api_key: String?
        let action_url: String?
    }

    private func mintAPIKey(identityToken: String, completion: @escaping (Result<String, Error>) -> Void) {
        var request = URLRequest(url: Endpoints.mintURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(identityToken)", forHTTPHeaderField: "Authorization")
        request.setValue("1.0.0", forHTTPHeaderField: "x-api-version")
        request.httpBody = Data("{}".utf8)

        session.dataTask(with: request) { data, response, error in
            if let error {
                completion(.failure(MetaMuseAuthError.mintFailed(error.localizedDescription)))
                return
            }
            guard let data, let httpResponse = response as? HTTPURLResponse else {
                completion(.failure(MetaMuseAuthError.mintFailed("no response")))
                return
            }
            let decoded = try? JSONDecoder().decode(MintResponse.self, from: data)
            guard (200..<300).contains(httpResponse.statusCode) else {
                let detail = "HTTP \(httpResponse.statusCode)"
                completion(.failure(MetaMuseAuthError.mintFailed(detail)))
                return
            }
            guard let apiKey = decoded?.api_key, !apiKey.isEmpty else {
                if let actionURL = decoded?.action_url, !actionURL.isEmpty {
                    completion(.failure(MetaMuseAuthError.mintFailed("payment method required; complete setup in Meta Muse")))
                } else {
                    completion(.failure(MetaMuseAuthError.mintFailed("no API key was issued")))
                }
                return
            }
            completion(.success(apiKey))
        }.resume()
    }

    // MARK: - Helpers

    private func finishAuthentication(_ result: Result<Void, Error>, completion: @escaping (Result<Void, Error>) -> Void) {
        activeTask = nil
        switch result {
        case .success:
            state = .connected
            lastError = nil
        case .failure(let error):
            let description = error.localizedDescription
            state = .failed(description)
            lastError = description
        }
        completion(result)
    }

    private static func formEncodedBody(_ fields: [String: String]) -> Data? {
        var components = URLComponents()
        components.queryItems = fields.map { URLQueryItem(name: $0.key, value: $0.value) }
        return components.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B").data(using: .utf8)
    }

}
