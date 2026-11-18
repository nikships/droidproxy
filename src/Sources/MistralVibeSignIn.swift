import CryptoKit
import Foundation

struct MistralSignInStart: Equatable {
    let processID: String
    let signInURL: URL
    let pollURL: URL
    let expiresAt: Date?
}

enum MistralSignInError: Error, Equatable, LocalizedError {
    /// HTTP 403 with `error_code` 9004: the selected workspace has no Vibe.
    case notEntitled
    case expired
    case denied
    case server(String)
    case cancelled

    var errorDescription: String? {
        switch self {
        case .notEntitled: return "This Mistral workspace doesn't include Vibe."
        case .expired: return "The sign-in link expired. Try again."
        case .denied: return "Sign-in was declined."
        case .server(let message): return message
        case .cancelled: return "Sign-in was cancelled."
        }
    }
}

/// The outcome of asking Mistral whether a key works.
enum MistralKeyCheck: Equatable {
    case valid
    case rejected
    /// Mistral could not be reached, or answered something other than yes or no.
    case unknown

    static func check(apiKey: String, session: URLSession = .shared) async -> MistralKeyCheck {
        var request = URLRequest(url: URL(string: "\(MistralCredentialStore.baseURL)/models")!)
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 20
        guard let (_, response) = try? await session.data(for: request),
              let http = response as? HTTPURLResponse else { return .unknown }
        switch http.statusCode {
        case 200..<300: return .valid
        case 401, 403: return .rejected
        default: return .unknown
        }
    }
}

/// Mistral Vibe CLI's browser sign-in. It is not OAuth: a PKCE-protected poll and
/// exchange ends with an ordinary long-lived API key. The endpoints are
/// undocumented and were taken from the Vibe CLI source, so they can change.
/// Never log the verifier, exchange token, `complete_token` URL or the key.
final class MistralVibeSignIn {
    static let authBase = URL(string: "https://console.mistral.ai/api")!
    static let pollInterval: TimeInterval = 15
    static let maxPollInterval: TimeInterval = 60
    static let fallbackLifetime: TimeInterval = 20 * 60
    static let maxConsecutiveNetworkFailures = 3

    private let session: URLSession
    private let sleep: (TimeInterval) async throws -> Void
    private let now: () -> Date
    private let pollInterval: TimeInterval
    private let store: MistralCredentialStore

    init(
        session: URLSession = .shared,
        store: MistralCredentialStore = .shared,
        pollInterval: TimeInterval = MistralVibeSignIn.pollInterval,
        now: @escaping () -> Date = Date.init,
        sleep: @escaping (TimeInterval) async throws -> Void = { seconds in
            try await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000))
        }
    ) {
        self.session = session
        self.store = store
        self.pollInterval = pollInterval
        self.now = now
        self.sleep = sleep
    }

    // MARK: PKCE

    static func makeVerifier() -> String {
        var bytes = [UInt8](repeating: 0, count: 64)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        if status != errSecSuccess {
            // Never fall back to a predictable verifier.
            bytes = (0..<64).map { _ in UInt8.random(in: .min ... .max) }
        }
        return base64URL(Data(bytes))
    }

    static func challenge(for verifier: String) -> String {
        base64URL(Data(SHA256.hash(data: Data(verifier.utf8))))
    }

    private static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    // MARK: Flow

    /// The whole sign-in. `onSignInURL` is where the caller opens the browser.
    /// Returns the saved account's id.
    @discardableResult
    func run(onSignInURL: @escaping (URL) -> Void) async throws -> String {
        let (start, verifier) = try await start()
        onSignInURL(start.signInURL)
        let key = try await waitForKey(start, verifier: verifier)
        NSLog("[Mistral] Checking the new key")
        if await MistralKeyCheck.check(apiKey: key, session: session) == .rejected {
            throw MistralSignInError.server("Mistral rejected the key it just issued. Try again.")
        }
        guard store.save(apiKey: key, label: nil, source: .browser) else {
            throw MistralSignInError.server("Couldn't save the Mistral key.")
        }
        return MistralCredentialStore.accountID(for: key)
    }

    func start() async throws -> (MistralSignInStart, verifier: String) {
        let verifier = Self.makeVerifier()
        NSLog("[Mistral] Starting sign-in")
        let (json, _) = try await postJSON(
            Self.authBase.appendingPathComponent("vibe/sign-in"),
            body: ["code_challenge": Self.challenge(for: verifier), "code_challenge_method": "S256"]
        )
        guard let processID = json["process_id"] as? String, !processID.isEmpty,
              let signInString = json["sign_in_url"] as? String,
              let signInURL = Self.httpsURL(signInString),
              let pollString = json["poll_url"] as? String,
              let pollURL = Self.httpsURL(pollString) else {
            throw MistralSignInError.server("Mistral's sign-in answer was not what DroidProxy expected.")
        }
        let expiresAt = (json["expires_at"] as? String).flatMap(Self.parseDate)
        return (MistralSignInStart(processID: processID, signInURL: signInURL, pollURL: pollURL,
                                   expiresAt: expiresAt), verifier)
    }

    func waitForKey(_ start: MistralSignInStart, verifier: String) async throws -> String {
        let deadline = start.expiresAt ?? now().addingTimeInterval(Self.fallbackLifetime)
        var wait = pollInterval
        var networkFailures = 0

        while true {
            try await pause(wait)
            if now() >= deadline { throw MistralSignInError.expired }

            let response: (Data, HTTPURLResponse)
            do {
                response = try await send(URLRequest(url: start.pollURL))
            } catch let error as MistralSignInError {
                throw error
            } catch {
                networkFailures += 1
                NSLog("[Mistral] Poll failed (%d in a row)", networkFailures)
                if networkFailures >= Self.maxConsecutiveNetworkFailures {
                    throw MistralSignInError.server("Couldn't reach Mistral to check the sign-in. Check your connection and try again.")
                }
                continue
            }
            let (data, http) = response

            switch http.statusCode {
            case 429:
                let retryAfter = http.value(forHTTPHeaderField: "Retry-After").flatMap(TimeInterval.init) ?? 0
                wait = min(Self.maxPollInterval, max(retryAfter, wait * 2))
                networkFailures = 0
                continue
            case 410:
                throw MistralSignInError.expired
            case 200..<300:
                break
            case 500..<600:
                networkFailures += 1
                if networkFailures >= Self.maxConsecutiveNetworkFailures {
                    throw MistralSignInError.server("Mistral's sign-in service isn't responding. Try again later.")
                }
                continue
            default:
                throw Self.error(for: http.statusCode, data: data)
            }

            networkFailures = 0
            wait = pollInterval
            let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
            switch json["status"] as? String {
            case "pending":
                continue
            case "completed":
                guard let token = json["exchange_token"] as? String, !token.isEmpty else {
                    throw MistralSignInError.server("Mistral finished the sign-in without a token. Try again.")
                }
                return try await exchange(start, token: token, verifier: verifier)
            case "expired":
                throw MistralSignInError.expired
            case "denied":
                throw MistralSignInError.denied
            case "error":
                throw MistralSignInError.server((json["message"] as? String).flatMap { $0.isEmpty ? nil : $0 }
                    ?? "Mistral reported a sign-in error.")
            default:
                throw MistralSignInError.server("Mistral's sign-in answer was not what DroidProxy expected.")
            }
        }
    }

    private func exchange(_ start: MistralSignInStart, token: String, verifier: String) async throws -> String {
        NSLog("[Mistral] Exchanging the sign-in")
        let allowed = CharacterSet.urlPathAllowed.subtracting(CharacterSet(charactersIn: "/"))
        let escaped = start.processID.addingPercentEncoding(withAllowedCharacters: allowed) ?? start.processID
        guard let url = URL(string: "\(Self.authBase.absoluteString)/vibe/sign-in/\(escaped)/exchange") else {
            throw MistralSignInError.server("Mistral's sign-in answer was not what DroidProxy expected.")
        }
        let (json, _) = try await postJSON(url, body: ["exchange_token": token, "code_verifier": verifier])
        guard let key = (json["api_key"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !key.isEmpty else {
            throw MistralSignInError.server("Mistral didn't return an API key. Try again.")
        }
        return key
    }

    // MARK: HTTP

    private func pause(_ seconds: TimeInterval) async throws {
        do {
            try await sleep(seconds)
            try Task.checkCancellation()
        } catch is CancellationError {
            throw MistralSignInError.cancelled
        }
    }

    private func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        var request = request
        request.timeoutInterval = 30
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
            return (data, http)
        } catch is CancellationError {
            throw MistralSignInError.cancelled
        } catch let error as URLError where error.code == .cancelled {
            throw MistralSignInError.cancelled
        }
    }

    private func postJSON(_ url: URL, body: [String: String]) async throws -> ([String: Any], HTTPURLResponse) {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
        let data: Data
        let http: HTTPURLResponse
        do {
            (data, http) = try await send(request)
        } catch let error as MistralSignInError {
            throw error
        } catch {
            throw MistralSignInError.server("Couldn't reach Mistral. Check your connection and try again.")
        }
        guard (200..<300).contains(http.statusCode) else {
            throw Self.error(for: http.statusCode, data: data)
        }
        guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw MistralSignInError.server("Mistral's sign-in answer was not what DroidProxy expected.")
        }
        return (json, http)
    }

    private static func error(for status: Int, data: Data) -> MistralSignInError {
        if status == 410 { return .expired }
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        if status == 403, errorCode(in: json) == "9004" { return .notEntitled }
        if let message = json["message"] as? String, !message.isEmpty {
            return .server("Mistral said: \(message)")
        }
        return .server("Mistral's sign-in failed (HTTP \(status)).")
    }

    private static func errorCode(in json: [String: Any]) -> String? {
        func code(_ dict: [String: Any]) -> String? {
            if let number = dict["error_code"] as? Int { return String(number) }
            return dict["error_code"] as? String
        }
        if let direct = code(json) { return direct }
        for nested in ["detail", "error"] {
            if let dict = json[nested] as? [String: Any], let found = code(dict) { return found }
        }
        return nil
    }

    private static func httpsURL(_ string: String) -> URL? {
        guard let url = URL(string: string, relativeTo: authBase)?.absoluteURL,
              url.scheme == "https", url.host != nil else { return nil }
        return url
    }

    private static func parseDate(_ string: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return fractional.date(from: string) ?? plain.date(from: string)
    }
}
