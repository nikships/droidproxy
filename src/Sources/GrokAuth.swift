import Foundation
import AppKit

/// xAI Grok OAuth 2.0 Device Authorization Grant (RFC 8628), token refresh,
/// and credential storage compatible with `AuthManager`'s auth-directory scan.
///
/// Uses the public Grok CLI OAuth client (`token_endpoint_auth_method: none`)
/// so `ThinkingProxy.forwardToGrok` can call `api.x.ai` with a bearer token
/// instead of an `XAI_API_KEY`.
enum GrokAuth {

    // MARK: - Constants

    /// Public OAuth client id used by the Grok CLI.
    /// Not a secret: the device grant uses no client authentication
    /// (`token_endpoint_auth_method: none`).
    static let clientID = "b1a00492-073a-47ea-816f-4c329264a828"
    static let scope = "openid profile email offline_access grok-cli:access api:access"
    static let deviceCodeURL = URL(string: "https://auth.x.ai/oauth2/device/code")!
    static let tokenURL = URL(string: "https://auth.x.ai/oauth2/token")!
    static let deviceGrantType = "urn:ietf:params:oauth:grant-type:device_code"

    /// Public xAI API host. Serves `grok-4.7`.
    static let apiHost = "api.x.ai"

    /// Grok Build chat proxy. Serves `grok-4.7-build-fast`, which the public API does not.
    /// Routing uses `x-grok-model-override`; the JSON `model` field is the same id.
    static let buildProxyHost = "cli-chat-proxy.grok.com"
    static let fastModelID = "grok-4.7-build-fast"
    /// Build proxy rejects requests that omit this (`version (none) is outdated`).
    static let buildProxyClientVersion = "1.0.40"

    /// Auth file `type` tag + filename (scanned by AuthManager; loaded via `loadActiveCredentials`).
    static let authFileType = "grok-cli"
    static let authFileName = "grok-cli.json"

    /// Client headers dropped when building the api.x.ai request.
    static let excludedUpstreamHeaderNames: Set<String> = [
        "host", "content-length", "connection", "transfer-encoding",
        "authorization", "content-type", "anthropic-beta", "anthropic-version",
        "accept-encoding", "x-api-key", "x-xai-token-auth", "x-grok-model-override",
        "x-grok-client-version", "x-grok-client-identifier"
    ]

    /// Refresh this many ms before access-token expiry so long Droid sessions
    /// stay warm without mid-turn 401s. Kept well below typical `expires_in`
    /// (often 1h) so a fresh token is not treated as expired immediately.
    /// Applied at check time — not baked into stored `expires`.
    static let refreshSkewMs: Double = 300_000

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
        /// Absolute access-token expiry as epoch milliseconds.
        /// Skew is applied in `isAccessExpired`, not stored here.
        var expiresAtMs: Double
        var email: String?

        func isAccessExpired(now: Date = Date(), skewMs: Double = GrokAuth.refreshSkewMs) -> Bool {
            now.timeIntervalSince1970 * 1000 + skewMs >= expiresAtMs
        }
    }

    enum GrokAuthError: LocalizedError, Equatable {
        case notLoggedIn
        case reauthRequired
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
            case .reauthRequired:
                return "Grok session expired. Reconnect Grok in DroidProxy settings."
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

        /// Terminal refresh failures that should stop retrying until the user reconnects.
        var isTerminalRefreshFailure: Bool {
            switch self {
            case .reauthRequired, .accessDenied, .expiredToken:
                return true
            case .tokenError(let detail):
                let lower = detail.lowercased()
                return lower.contains("invalid_grant")
                    || lower.contains("invalid_token")
                    || lower.contains("invalid_request")
            default:
                return false
            }
        }
    }

    // MARK: - Pure parsing helpers (no I/O; unit-tested)

    /// Coerce JSON numbers that may arrive as Int or Double (JSONSerialization
    /// prefers Int for whole numbers).
    static func jsonNumber(_ value: Any?) -> Double? {
        if let d = value as? Double { return d }
        if let i = value as? Int { return Double(i) }
        if let n = value as? NSNumber { return n.doubleValue }
        return nil
    }

    static func parseDeviceAuthorization(_ data: Data) -> DeviceAuthorization? {
        guard let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let deviceCode = obj["device_code"] as? String, !deviceCode.isEmpty,
              let userCode = obj["user_code"] as? String, !userCode.isEmpty else {
            return nil
        }
        let complete = (obj["verification_uri_complete"] as? String)
            ?? (obj["verification_uri"] as? String)
            ?? ""
        let interval = jsonNumber(obj["interval"]) ?? 5
        let expiresIn = jsonNumber(obj["expires_in"]) ?? 900
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
    ///
    /// - Parameter requireRefreshToken: When `true` (device-code success), an empty
    ///   `refresh_token` is rejected so login cannot look connected then 401 later.
    ///   Refresh responses may omit a rotated refresh token; pass `false` there.
    static func parseTokenResponse(
        _ data: Data,
        statusCode: Int,
        now: Date,
        requireRefreshToken: Bool = false
    ) -> Result<Credentials, GrokAuthError> {
        let obj = ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any]) ?? [:]

        if statusCode == 200, let access = obj["access_token"] as? String, !access.isEmpty {
            let refresh = (obj["refresh_token"] as? String) ?? ""
            if requireRefreshToken && refresh.isEmpty {
                return .failure(.tokenError("Login response missing refresh_token. Try connecting Grok again."))
            }
            let expiresIn = jsonNumber(obj["expires_in"]) ?? 3600
            // Store absolute expiry; skew is applied in `isAccessExpired`.
            let expiresAtMs = now.timeIntervalSince1970 * 1000 + expiresIn * 1000
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
        case "invalid_grant", "invalid_token":
            return .failure(.reauthRequired)
        case let other?:
            return .failure(.tokenError((obj["error_description"] as? String) ?? other))
        case nil:
            if statusCode == 401 || statusCode == 403 {
                return .failure(.reauthRequired)
            }
            return .failure(.tokenError("Unexpected token response (HTTP \(statusCode))"))
        }
    }

    /// `grok-4.7` stays on `api.x.ai`. The fast variant is a separate model id
    /// on the Grok Build proxy, using the same SuperGrok OAuth bearer.
    static func upstreamHost(forModel model: String?) -> String {
        model == fastModelID ? buildProxyHost : apiHost
    }

    /// Headers the Build proxy requires to route the fast model. Empty for `api.x.ai`.
    static func upstreamAuthHeaders(forModel model: String?) -> [(String, String)] {
        guard model == fastModelID else { return [] }
        return [
            ("X-XAI-Token-Auth", "xai-grok-cli"),
            ("x-grok-model-override", fastModelID),
            ("x-grok-client-version", buildProxyClientVersion),
            ("x-grok-client-identifier", "grok-shell")
        ]
    }

    /// Normalize a client path to `/v1/...` for api.x.ai.
    /// Strips a leading `/api/v1` so Factory `/api/v1/responses` becomes `/v1/responses`.
    static func normalizeUpstreamPath(_ path: String) -> String {
        let pathOnly: String
        let query: String
        if let q = path.firstIndex(of: "?") {
            pathOnly = String(path[..<q])
            query = String(path[q...])
        } else {
            pathOnly = path
            query = ""
        }

        var normalized = pathOnly
        if normalized.hasPrefix("/api/v1/") {
            normalized = "/v1/" + String(normalized.dropFirst("/api/v1/".count))
        } else if normalized == "/api/v1" {
            normalized = "/v1"
        } else if !(normalized.hasPrefix("/v1/") || normalized == "/v1") {
            normalized = normalized.hasPrefix("/") ? "/v1" + normalized : "/v1/" + normalized
        }
        return normalized + query
    }

    /// Drop hop-by-hop / auth / Content-Type headers so the upstream request
    /// carries a single `Content-Type: application/json` (api.x.ai returns 415 otherwise).
    static func filterClientHeaders(_ headers: [(String, String)]) -> [(String, String)] {
        headers.filter { !excludedUpstreamHeaderNames.contains($0.0.lowercased()) }
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
        // Omit ISO `expired`: AuthManager treats a past `expired` as dead, but a
        // refresh token keeps the account usable past the short-lived `expires`.
        [
            "type": authFileType,
            "access": creds.access,
            "refresh": creds.refresh,
            "expires": creds.expiresAtMs,
            "disabled": false,
            "email": (creds.email.flatMap { $0.isEmpty ? nil : $0 } ?? "grok-user")
        ]
    }

    static func credentials(from json: [String: Any]) -> Credentials? {
        guard let access = json["access"] as? String, !access.isEmpty,
              let refresh = json["refresh"] as? String, !refresh.isEmpty else {
            return nil
        }
        let expiresAtMs = jsonNumber(json["expires"]) ?? 0
        return Credentials(access: access, refresh: refresh, expiresAtMs: expiresAtMs, email: json["email"] as? String)
    }

    // MARK: - Storage

    private static let ioLock = NSLock()

    /// Returns the newest enabled Grok credential file in the auth directory.
    static func loadActiveCredentials(in dir: URL = AuthPaths.authDirectory) -> (credentials: Credentials, url: URL)? {
        ioLock.lock()
        defer { ioLock.unlock() }
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: [.contentModificationDateKey]
        ) else {
            return nil
        }
        var bestCredentials: Credentials?
        var bestURL: URL?
        var bestModified = Date.distantPast
        for file in files where file.pathExtension == "json" {
            guard let data = try? Data(contentsOf: file),
                  let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  (json["type"] as? String)?.lowercased() == authFileType,
                  !(json["disabled"] as? Bool ?? false),
                  let creds = credentials(from: json) else {
                continue
            }
            let modified = (try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            if modified > bestModified {
                bestCredentials = creds
                bestURL = file
                bestModified = modified
            }
        }
        guard let bestCredentials, let bestURL else { return nil }
        return (bestCredentials, bestURL)
    }

    /// Canonical credential file location (`~/.cli-proxy-api/grok-cli.json`).
    static func credentialsURL(in dir: URL = AuthPaths.authDirectory) -> URL {
        dir.appendingPathComponent(authFileName)
    }

    /// Atomically writes credentials, preserving an existing `disabled` flag.
    /// Throws on I/O failure so login/refresh cannot report success after a failed write.
    static func persist(_ creds: Credentials, to url: URL) throws {
        ioLock.lock()
        defer { ioLock.unlock() }
        var json = credentialsJSON(creds)
        if let data = try? Data(contentsOf: url),
           let existing = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
           let disabled = existing["disabled"] as? Bool {
            json["disabled"] = disabled
        }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let out = try JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted])
        try out.write(to: url, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    /// Marks a credential file disabled so dead refresh tokens are not retried
    /// until the user reconnects (device login overwrites the file).
    static func quarantineCredentials(at url: URL) {
        ioLock.lock()
        defer { ioLock.unlock() }
        guard let data = try? Data(contentsOf: url),
              var json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            NSLog("[GrokAuth] Failed to quarantine credentials: unreadable file at %@", url.path)
            return
        }
        json["disabled"] = true
        do {
            let out = try JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted])
            try out.write(to: url, options: .atomic)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            NSLog("[GrokAuth] Quarantined Grok credentials (disabled=true) at %@", url.path)
        } catch {
            NSLog("[GrokAuth] Failed to quarantine credentials: %@", error.localizedDescription)
        }
    }

    // MARK: - Device login

    /// Cancellation handle for an in-flight device login poll loop.
    final class LoginSession {
        private let lock = NSLock()
        private var cancelledFlag = false

        func cancel() {
            lock.lock()
            cancelledFlag = true
            lock.unlock()
        }

        var isCancelled: Bool {
            lock.lock()
            defer { lock.unlock() }
            return cancelledFlag
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
        // Persist on success so ThinkingProxy / Settings see credentials immediately.
        let finish: (Result<Credentials, GrokAuthError>) -> Void = { result in
            switch result {
            case .success(let creds):
                do {
                    try persist(creds, to: credentialsURL())
                    completion(.success(creds))
                } catch {
                    completion(.failure(.tokenError("Could not save credentials: \(error.localizedDescription)")))
                }
            case .failure:
                completion(result)
            }
        }
        let request = formPOST(url: deviceCodeURL, params: [
            "client_id": clientID,
            "scope": scope
        ])

        URLSession.shared.dataTask(with: request) { data, response, error in
            if let error {
                finish(.failure(.deviceCodeFailed(error.localizedDescription)))
                return
            }
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard let data else {
                finish(.failure(.deviceCodeFailed("Empty device authorization response (HTTP \(status)).")))
                return
            }
            if !(200...299).contains(status) {
                let snippet = String(data: data, encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                let detail = snippet.isEmpty
                    ? "HTTP \(status)"
                    : "HTTP \(status): \(snippet.prefix(200))"
                finish(.failure(.deviceCodeFailed(detail)))
                return
            }
            guard let auth = parseDeviceAuthorization(data) else {
                finish(.failure(.deviceCodeFailed("Invalid device authorization response.")))
                return
            }
            if auth.verificationURIComplete.isEmpty {
                finish(.failure(.deviceCodeFailed("Device authorization response missing verification URL.")))
                return
            }
            if session.isCancelled {
                finish(.failure(.cancelled))
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
        consecutiveNetworkFailures: Int = 0,
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

        let request = formPOST(url: tokenURL, params: [
            "grant_type": deviceGrantType,
            "device_code": deviceCode,
            "client_id": clientID
        ])

        let scheduleNext: (TimeInterval, Int) -> Void = { delay, failures in
            DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + delay) {
                pollForToken(
                    deviceCode: deviceCode,
                    interval: delay,
                    deadline: deadline,
                    session: session,
                    consecutiveNetworkFailures: failures,
                    completion: completion
                )
            }
        }

        URLSession.shared.dataTask(with: request) { data, response, error in
            if session.isCancelled {
                completion(.failure(.cancelled))
                return
            }
            if let error {
                let failures = consecutiveNetworkFailures + 1
                NSLog("[GrokAuth] Token poll network error (%d): %@", failures, error.localizedDescription)
                // Bound transient retries so persistent offline doesn't look like user inaction.
                if failures >= 8 {
                    completion(.failure(.network(error.localizedDescription)))
                    return
                }
                scheduleNext(interval, failures)
                return
            }
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            switch parseTokenResponse(data ?? Data(), statusCode: status, now: Date(), requireRefreshToken: true) {
            case .success(let creds):
                completion(.success(creds))
            case .failure(.authorizationPending):
                scheduleNext(interval, 0)
            case .failure(.slowDown):
                scheduleNext(interval + 5, 0)
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
                do {
                    try persist(refreshed, to: current.url)
                    deliver(.success(refreshed.access))
                } catch {
                    NSLog("[GrokAuth] Refresh succeeded but persist failed: %@", error.localizedDescription)
                    // Still return the token for this request; next expiry will refresh again.
                    deliver(.success(refreshed.access))
                }
            case .failure(let error):
                if error.isTerminalRefreshFailure {
                    quarantineCredentials(at: current.url)
                    deliver(.failure(.reauthRequired))
                } else {
                    deliver(.failure(error))
                }
            }
        }
    }

    private static func refreshAccessToken(
        _ creds: Credentials,
        completion: @escaping (Result<Credentials, GrokAuthError>) -> Void
    ) {
        let request = formPOST(url: tokenURL, params: [
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
            switch parseTokenResponse(data ?? Data(), statusCode: status, now: Date(), requireRefreshToken: false) {
            case .success(var refreshed):
                // Refresh may omit rotated refresh_token / id_token; keep prior values.
                if refreshed.refresh.isEmpty { refreshed.refresh = creds.refresh }
                if refreshed.email == nil { refreshed.email = creds.email }
                completion(.success(refreshed))
            case .failure(let error):
                completion(.failure(error))
            }
        }.resume()
    }

    // MARK: - Helpers

    private static func formPOST(url: URL, params: [String: String]) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = formBody(params)
        return request
    }

    /// Builds an `application/x-www-form-urlencoded` body.
    ///
    /// `URLComponents.percentEncodedQuery` leaves `+` unencoded (RFC 3986), but
    /// form-urlencoded treats `+` as space — so `device_code` / `refresh_token`
    /// values containing `+` must be rewritten to `%2B`.
    static func formBody(_ params: [String: String]) -> Data {
        var components = URLComponents()
        components.queryItems = params.map { URLQueryItem(name: $0.key, value: $0.value) }
        let query = (components.percentEncodedQuery ?? "")
            .replacingOccurrences(of: "+", with: "%2B")
        return query.data(using: .utf8) ?? Data()
    }
}
