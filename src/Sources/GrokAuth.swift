import Foundation
import AppKit

/// xAI Grok CLI OAuth 2.0 Device Authorization Grant (RFC 8628), token refresh,
/// and credential storage compatible with `AuthManager`'s auth-directory scan.
///
/// Composer 2.5 (`grok-composer-2.5-fast`) and the other Grok CLI models are
/// served from `cli-chat-proxy.grok.com`, which is gated behind an xAI
/// subscription (SuperGrok / X Premium+). The public `api.x.ai` API does not
/// expose them, so DroidProxy authenticates as the Grok CLI public client and
/// `ThinkingProxy.forwardToGrok` attaches the resulting OAuth access token (plus
/// the `x-xai-token-auth` / `x-grok-*` headers the endpoint requires) to the
/// forwarded chat-completions request.
enum GrokAuth {

    // MARK: - Constants

    /// Public OAuth client id used by the Grok CLI. Not a secret: the device
    /// grant uses no client authentication (`token_endpoint_auth_method: none`).
    static let clientID = "b1a00492-073a-47ea-816f-4c329264a828"
    static let scope = "openid profile email offline_access grok-cli:access api:access"
    static let deviceCodeURL = URL(string: "https://auth.x.ai/oauth2/device/code")!
    static let tokenURL = URL(string: "https://auth.x.ai/oauth2/token")!
    static let deviceGrantType = "urn:ietf:params:oauth:grant-type:device_code"

    /// API host that serves Grok CLI models (including Composer 2.5).
    static let apiHost = "cli-chat-proxy.grok.com"

    /// Headers cli-chat-proxy expects for client identification (see pi-grok-cli).
    static let tokenAuthHeader = "xai-grok-cli"   // x-xai-token-auth
    static let clientIdentifier = "droidproxy"     // x-grok-client-identifier
    static let clientVersion = "0.2.16"            // x-grok-client-version

    /// Auth file `type` tag + filename (scanned by AuthManager and ThinkingProxy).
    static let authFileType = "grok-cli"
    static let authFileName = "grok-cli.json"

    /// Refresh the access token this many milliseconds before it actually expires.
    static let refreshSkewMs: Double = 120_000

    // MARK: - Models

    struct DeviceAuthorization: Equatable {
        let deviceCode: String
        let userCode: String
        let verificationURIComplete: String
        let interval: TimeInterval
        let expiresIn: TimeInterval
    }

    struct Credentials: Equatable {
        var access: String
        var refresh: String
        /// Access-token expiry as epoch milliseconds (skew already subtracted).
        var expiresAtMs: Double
        var email: String?

        func isAccessExpired(now: Date = Date()) -> Bool {
            now.timeIntervalSince1970 * 1000 >= expiresAtMs
        }
    }

    enum GrokAuthError: LocalizedError, Equatable {
        case notLoggedIn
        case deviceCodeFailed(String)
        case authorizationPending
        case slowDown
        case accessDenied
        case expiredToken
        case tokenError(String)
        case network(String)
        case cancelled

        var errorDescription: String? {
            switch self {
            case .notLoggedIn:
                return "Not logged in to Grok."
            case .deviceCodeFailed(let detail):
                return "Could not start Grok login: \(detail)"
            case .authorizationPending:
                return "Authorization pending."
            case .slowDown:
                return "Polling too fast."
            case .accessDenied:
                return "Authorization was denied."
            case .expiredToken:
                return "The login request expired. Please try again."
            case .tokenError(let detail):
                return detail
            case .network(let detail):
                return "Network error: \(detail)"
            case .cancelled:
                return "Login cancelled."
            }
        }
    }

    // MARK: - Pure parsing helpers (no I/O; unit-tested)

    static func parseDeviceAuthorization(_ data: Data) -> DeviceAuthorization? {
        guard let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let deviceCode = obj["device_code"] as? String, !deviceCode.isEmpty,
              let userCode = obj["user_code"] as? String, !userCode.isEmpty else {
            return nil
        }
        let complete = (obj["verification_uri_complete"] as? String)
            ?? (obj["verification_uri"] as? String)
            ?? ""
        let interval = (obj["interval"] as? Double) ?? 5
        let expiresIn = (obj["expires_in"] as? Double) ?? 900
        return DeviceAuthorization(
            deviceCode: deviceCode,
            userCode: userCode,
            verificationURIComplete: complete,
            interval: interval,
            expiresIn: expiresIn
        )
    }

    /// Parse an RFC 8628 token poll / refresh response. Standard polling
    /// outcomes (`authorization_pending`, `slow_down`, `access_denied`,
    /// `expired_token`) map to typed errors so callers can drive the poll loop.
    static func parseTokenResponse(_ data: Data, statusCode: Int, now: Date) -> Result<Credentials, GrokAuthError> {
        let obj = ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any]) ?? [:]

        if statusCode == 200, let access = obj["access_token"] as? String, !access.isEmpty {
            let refresh = (obj["refresh_token"] as? String) ?? ""
            let expiresIn = (obj["expires_in"] as? Double) ?? 3600
            let expiresAtMs = now.timeIntervalSince1970 * 1000 + expiresIn * 1000 - refreshSkewMs
            let email = emailFromIDToken(obj["id_token"] as? String)
            return .success(Credentials(access: access, refresh: refresh, expiresAtMs: expiresAtMs, email: email))
        }

        switch obj["error"] as? String {
        case "authorization_pending":
            return .failure(.authorizationPending)
        case "slow_down":
            return .failure(.slowDown)
        case "access_denied":
            return .failure(.accessDenied)
        case "expired_token":
            return .failure(.expiredToken)
        case let other?:
            return .failure(.tokenError((obj["error_description"] as? String) ?? other))
        case nil:
            return .failure(.tokenError("Unexpected token response (HTTP \(statusCode))"))
        }
    }

    /// Best-effort extraction of the `email` claim from an OIDC id_token JWT.
    static func emailFromIDToken(_ idToken: String?) -> String? {
        guard let idToken, !idToken.isEmpty else { return nil }
        let parts = idToken.split(separator: ".")
        guard parts.count >= 2 else { return nil }
        var b64 = String(parts[1])
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while b64.count % 4 != 0 { b64 += "=" }
        guard let data = Data(base64Encoded: b64),
              let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return nil
        }
        return obj["email"] as? String
    }

    static func credentialsJSON(_ creds: Credentials) -> [String: Any] {
        var json: [String: Any] = [
            "type": authFileType,
            "access": creds.access,
            "refresh": creds.refresh,
            "expires": creds.expiresAtMs,
            "disabled": false,
            "email": (creds.email?.isEmpty == false ? creds.email! : "grok-user")
        ]
        // No ISO `expired` field: AuthManager only flags accounts whose `expired`
        // timestamp is in the past, and a refresh token keeps the account live
        // well past the short-lived access-token expiry stored in `expires`.
        json["expired"] = nil
        return json
    }

    static func credentials(from json: [String: Any]) -> Credentials? {
        guard let access = json["access"] as? String, !access.isEmpty,
              let refresh = json["refresh"] as? String, !refresh.isEmpty else {
            return nil
        }
        let expiresAtMs = (json["expires"] as? Double) ?? 0
        return Credentials(access: access, refresh: refresh, expiresAtMs: expiresAtMs, email: json["email"] as? String)
    }

    // MARK: - Storage

    private static let ioLock = NSLock()

    /// Returns the newest enabled Grok credential file in the auth directory.
    static func loadActiveCredentials(in dir: URL = AuthPaths.authDirectory) -> (credentials: Credentials, url: URL)? {
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: [.contentModificationDateKey]
        ) else {
            return nil
        }
        var best: (Credentials, URL, Date)?
        for file in files where file.pathExtension == "json" {
            guard let data = try? Data(contentsOf: file),
                  let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  (json["type"] as? String)?.lowercased() == authFileType,
                  !(json["disabled"] as? Bool ?? false),
                  let creds = credentials(from: json) else {
                continue
            }
            let modified = (try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            if best == nil || modified > best!.2 {
                best = (creds, file, modified)
            }
        }
        guard let best else { return nil }
        return (best.0, best.1)
    }

    /// Canonical credential file location (`~/.cli-proxy-api/grok-cli.json`).
    static func credentialsURL(in dir: URL = AuthPaths.authDirectory) -> URL {
        dir.appendingPathComponent(authFileName)
    }

    /// Atomically writes credentials, preserving an existing `disabled` flag.
    static func persist(_ creds: Credentials, to url: URL) {
        ioLock.lock()
        defer { ioLock.unlock() }
        var json = credentialsJSON(creds)
        if let data = try? Data(contentsOf: url),
           let existing = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
           let disabled = existing["disabled"] as? Bool {
            json["disabled"] = disabled
        }
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let out = try JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted])
            try out.write(to: url, options: .atomic)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        } catch {
            NSLog("[GrokAuth] Failed to persist credentials: %@", error.localizedDescription)
        }
    }

    // MARK: - Device login

    /// Cancellation handle for an in-flight device login poll loop.
    final class LoginSession {
        private let lock = NSLock()
        private var cancelledFlag = false
        func cancel() {
            lock.lock(); cancelledFlag = true; lock.unlock()
        }
        var isCancelled: Bool {
            lock.lock(); defer { lock.unlock() }; return cancelledFlag
        }
    }

    /// Starts the device authorization flow: requests a device/user code, opens
    /// the verification URL in the browser, surfaces the user code via
    /// `onPrompt`, then polls until the user approves (or the request fails /
    /// is cancelled / expires). All callbacks are invoked on a background queue.
    @discardableResult
    static func startDeviceLogin(
        onPrompt: @escaping (DeviceAuthorization) -> Void,
        completion: @escaping (Result<Credentials, GrokAuthError>) -> Void
    ) -> LoginSession {
        let session = LoginSession()
        // Persist on success so ThinkingProxy (and the Settings account list) can
        // find the credentials immediately after the browser approval completes.
        let finish: (Result<Credentials, GrokAuthError>) -> Void = { result in
            if case .success(let creds) = result {
                persist(creds, to: credentialsURL())
            }
            completion(result)
        }
        var request = URLRequest(url: deviceCodeURL)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = formBody(["client_id": clientID, "scope": scope])

        URLSession.shared.dataTask(with: request) { data, _, error in
            if let error {
                finish(.failure(.deviceCodeFailed(error.localizedDescription)))
                return
            }
            guard let data, let auth = parseDeviceAuthorization(data) else {
                finish(.failure(.deviceCodeFailed("Invalid device authorization response.")))
                return
            }
            if let url = URL(string: auth.verificationURIComplete) {
                DispatchQueue.main.async { NSWorkspace.shared.open(url) }
            }
            onPrompt(auth)
            pollForToken(
                deviceCode: auth.deviceCode,
                interval: max(auth.interval, 1),
                deadline: Date().addingTimeInterval(auth.expiresIn),
                session: session,
                completion: finish
            )
        }.resume()

        return session
    }

    private static func pollForToken(
        deviceCode: String,
        interval: TimeInterval,
        deadline: Date,
        session: LoginSession,
        completion: @escaping (Result<Credentials, GrokAuthError>) -> Void
    ) {
        if session.isCancelled {
            completion(.failure(.cancelled))
            return
        }
        if Date() >= deadline {
            completion(.failure(.expiredToken))
            return
        }

        var request = URLRequest(url: tokenURL)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = formBody([
            "grant_type": deviceGrantType,
            "device_code": deviceCode,
            "client_id": clientID
        ])

        let scheduleNext: (TimeInterval) -> Void = { delay in
            DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + delay) {
                pollForToken(deviceCode: deviceCode, interval: delay, deadline: deadline, session: session, completion: completion)
            }
        }

        URLSession.shared.dataTask(with: request) { data, response, error in
            if session.isCancelled {
                completion(.failure(.cancelled))
                return
            }
            if error != nil {
                // Transient network blip: keep polling until the deadline.
                scheduleNext(interval)
                return
            }
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            switch parseTokenResponse(data ?? Data(), statusCode: status, now: Date()) {
            case .success(let creds):
                completion(.success(creds))
            case .failure(.authorizationPending):
                scheduleNext(interval)
            case .failure(.slowDown):
                scheduleNext(interval + 5)
            case .failure(let other):
                completion(.failure(other))
            }
        }.resume()
    }

    // MARK: - Token access for request forwarding

    private static let refreshLock = NSLock()
    private static var refreshInFlight = false
    private static var refreshWaiters: [(Result<String, GrokAuthError>) -> Void] = []

    /// Loads stored credentials and returns a valid bearer access token,
    /// refreshing (and persisting) it first when the current token has expired.
    ///
    /// Refreshes are single-flighted: concurrent requests that arrive while the
    /// token is expired collapse onto one network refresh instead of each POSTing
    /// the same refresh token (xAI rotates it, so a second concurrent refresh
    /// would fail with `invalid_grant` and surface a spurious 401).
    static func ensureValidAccessToken(completion: @escaping (Result<String, GrokAuthError>) -> Void) {
        guard let (creds, url) = loadActiveCredentials() else {
            completion(.failure(.notLoggedIn))
            return
        }
        if !creds.isAccessExpired() {
            completion(.success(creds.access))
            return
        }

        // Join an in-flight refresh rather than starting a competing one.
        refreshLock.lock()
        if refreshInFlight {
            refreshWaiters.append(completion)
            refreshLock.unlock()
            return
        }
        refreshInFlight = true
        refreshLock.unlock()

        // Fan the single refresh result out to this caller plus anyone who queued
        // while it was in flight, clearing the in-flight state atomically.
        let deliver: (Result<String, GrokAuthError>) -> Void = { result in
            refreshLock.lock()
            let waiters = refreshWaiters
            refreshWaiters.removeAll()
            refreshInFlight = false
            refreshLock.unlock()
            completion(result)
            for waiter in waiters { waiter(result) }
        }

        // A previous refresh may have persisted a fresh token between our expiry
        // check and winning the in-flight slot; re-read before hitting the network.
        let current = loadActiveCredentials() ?? (credentials: creds, url: url)
        if !current.credentials.isAccessExpired() {
            deliver(.success(current.credentials.access))
            return
        }

        refreshAccessToken(current.credentials) { result in
            switch result {
            case .success(let refreshed):
                persist(refreshed, to: current.url)
                deliver(.success(refreshed.access))
            case .failure(let error):
                deliver(.failure(error))
            }
        }
    }

    private static func refreshAccessToken(
        _ creds: Credentials,
        completion: @escaping (Result<Credentials, GrokAuthError>) -> Void
    ) {
        var request = URLRequest(url: tokenURL)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = formBody([
            "grant_type": "refresh_token",
            "client_id": clientID,
            "refresh_token": creds.refresh
        ])

        URLSession.shared.dataTask(with: request) { data, response, error in
            if let error {
                completion(.failure(.network(error.localizedDescription)))
                return
            }
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            switch parseTokenResponse(data ?? Data(), statusCode: status, now: Date()) {
            case .success(var refreshed):
                // A refresh response may omit a rotated refresh token / id_token;
                // carry the previous values forward so the account stays usable.
                if refreshed.refresh.isEmpty { refreshed.refresh = creds.refresh }
                if refreshed.email == nil { refreshed.email = creds.email }
                completion(.success(refreshed))
            case .failure(let error):
                completion(.failure(error))
            }
        }.resume()
    }

    // MARK: - Helpers

    private static func formBody(_ params: [String: String]) -> Data {
        var components = URLComponents()
        components.queryItems = params.map { URLQueryItem(name: $0.key, value: $0.value) }
        // URLComponents encodes spaces as %20 (not "+"), which the token endpoint
        // accepts for the space-delimited `scope` value.
        return (components.percentEncodedQuery ?? "").data(using: .utf8) ?? Data()
    }
}
