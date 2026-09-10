import Foundation
import AppKit
import Network
import Security

/// Cline account OAuth (WorkOS AuthKit), token refresh, and credential storage
/// compatible with `AuthManager`'s auth-directory scan.
///
/// Cline's free models are only served to extension/CLI *account* tokens — an
/// API key from app.cline.bot cannot use them. DroidProxy therefore runs the
/// same browser OAuth flow as the official VS Code extension: open
/// `/auth/authorize`, capture the localhost callback code on port 31234,
/// exchange it at `/auth/token`, and refresh via `/auth/refresh` when needed.
///
/// Upstream requires the bearer value to keep the `workos:` prefix used by the
/// extension client; a bare access token gets a 401.
enum ClineAuth {

    // MARK: - Constants

    static let apiHost = "api.cline.bot"

    /// Auth file `type` tag + filename (scanned by AuthManager; loaded via
    /// `loadActiveCredentials`). Provider toggles key off `"cline"` too.
    static let authFileType = "cline"
    static let authFileName = "cline.json"

    /// Local redirect target the upstream authorize call embeds in its state;
    /// the browser callback lands here after SSO.
    static let callbackURL = "http://127.0.0.1:31234/auth"

    /// Refresh this many ms before expiry so long sessions stay warm.
    static let refreshSkewMs: Double = 300_000

    /// Identity headers sent with every completion request so the gateway sees
    /// a current-version VS Code extension client (matches what the official
    /// extension emits; the API rejects unknown/very old clients occasionally).
    static let clientVersion = "3.63.0"
    private static let identityHeaders: [(String, String)] = [
        ("X-Platform", "Visual Studio Code"),
        ("X-Platform-Version", "1.109.3"),
        ("X-Client-Type", "VSCode Extension"),
        ("X-Client-Version", clientVersion),
        ("X-Core-Version", clientVersion)
    ]

    /// Header names dropped from the client request before forwarding to
    /// api.cline.bot (Droid/Factory auth and Anthropic-specific headers).
    static let excludedUpstreamHeaderNames: Set<String> = [
        "host", "content-length", "connection", "transfer-encoding",
        "authorization", "content-type", "anthropic-beta", "anthropic-version",
        "accept-encoding", "x-api-key", "x-api-version", "x-stainless-lang",
        "x-stainless-package-version", "x-stainless-os", "x-stainless-arch",
        "x-stainless-runtime", "x-stainless-runtime-version", "x-stainless-retry-count",
        "http-referer", "x-title", "x-task-id"
    ]

    // MARK: - Models

    struct Credentials: Equatable {
        /// Raw WorkOS access token WITHOUT the `workos:` prefix (stored).
        var access: String
        var refresh: String
        /// Absolute access-token expiry as epoch milliseconds.
        var expiresAtMs: Double
        var email: String?

        func isAccessExpired(now: Date = Date(), skewMs: Double = ClineAuth.refreshSkewMs) -> Bool {
            now.timeIntervalSince1970 * 1000 + skewMs >= expiresAtMs
        }

        /// Full bearer header value for upstream requests (`workos:` prefix required).
        var bearerValue: String { "workos:\(access)" }
    }

    enum ClineAuthError: LocalizedError, Equatable {
        case notLoggedIn
        case reauthRequired(String)
        case loginFailed(String)
        case network(String)
        case cancelled

        var errorDescription: String? {
            switch self {
            case .notLoggedIn:
                return "Not logged in to Cline. Connect Cline in DroidProxy settings."
            case .reauthRequired(let detail):
                return detail.isEmpty
                    ? "Cline session expired. Reconnect Cline in DroidProxy settings."
                    : detail
            case .loginFailed(let detail):
                return "Cline login failed: \(detail)"
            case .network(let detail):
                return "Network error: \(detail)"
            case .cancelled:
                return "Login cancelled."
            }
        }

        /// Terminal refresh failures that should stop retrying until the user reconnects.
        var isTerminalRefreshFailure: Bool {
            switch self {
            case .notLoggedIn:
                return true
            case .reauthRequired:
                return true
            default:
                return false
            }
        }
    }

    // MARK: - Parsing helpers (pure, no I/O)

    /// Coerce JSON numbers that may arrive as Int or Double.
    static func jsonNumber(_ value: Any?) -> Double? {
        if let d = value as? Double { return d }
        if let i = value as? Int { return Double(i) }
        if let n = value as? NSNumber { return n.doubleValue }
        return nil
    }

    private static let isoDateFormatters: [ISO8601DateFormatter] = {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let standard = ISO8601DateFormatter()
        standard.formatOptions = [.withInternetDateTime]
        return [fractional, standard]
    }()

    /// Accepts epoch milliseconds or an ISO 8601 string (`expiresAt` may be either).
    static func parseExpiresMs(_ value: Any?, now: Date) -> Double? {
        if let ms = jsonNumber(value) {
            // Epoch milliseconds are ~13 digits; seconds ~10.
            return ms < 100_000_000_000 ? ms * 1000 : ms
        }
        guard let raw = value as? String else { return nil }
        for formatter in isoDateFormatters {
            if let date = formatter.date(from: raw) {
                return date.timeIntervalSince1970 * 1000
            }
        }
        return nil
    }

    struct TokenPayload {
        let accessToken: String
        var refreshToken: String
        let expiresAtMs: Double
    }

    /// Parses `{success, data:{accessToken, refreshToken, expiresAt}}`.
    /// Refresh responses may omit the rotated refresh token; callers keep the old one.
    static func parseTokenResponse(
        _ data: Data,
        statusCode: Int,
        now: Date
    ) -> Result<TokenPayload, ClineAuthError> {
        let obj = ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any]) ?? [:]
        let payload = obj["data"] as? [String: Any]

        guard statusCode == 200, obj["success"] as? Bool == true || payload != nil,
              let payloadData = payload,
              let access = payloadData["accessToken"] as? String, !access.isEmpty else {
            if statusCode == 401 || statusCode == 403 {
                let message = (obj["error"] as? String) ?? ""
                return .failure(.reauthRequired(message))
            }
            let rawBody = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let message = (obj["error"] as? String)
                ?? (rawBody.isEmpty ? nil : String(rawBody.prefix(160)))
                ?? "HTTP \(statusCode)"
            return .failure(.loginFailed("HTTP \(statusCode): \(message)"))
        }

        let expiresAtMs = parseExpiresMs(payloadData["expiresAt"], now: now)
            ?? now.timeIntervalSince1970 * 1000 + 3600_000
        return .success(TokenPayload(
            accessToken: access,
            refreshToken: payloadData["refreshToken"] as? String ?? "",
            expiresAtMs: expiresAtMs
        ))
    }

    // MARK: - Storage

    private static let ioLock = NSLock()

    /// Returns the newest enabled Cline credential file in the auth directory.
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

    static func credentials(from json: [String: Any]) -> Credentials? {
        guard let access = json["access"] as? String, !access.isEmpty else { return nil }
        guard let refresh = json["refresh"] as? String, !refresh.isEmpty else { return nil }
        let now = Date()
        let expiresAtMs = parseExpiresMs(json["expires"], now: now) ?? 0
        return Credentials(access: access, refresh: refresh, expiresAtMs: expiresAtMs, email: json["email"] as? String)
    }

    static func credentialsJSON(_ creds: Credentials) -> [String: Any] {
        [
            "type": authFileType,
            "access": creds.access,
            "refresh": creds.refresh,
            "expires": creds.expiresAtMs,
            "disabled": false,
            "email": (creds.email.flatMap { $0.isEmpty ? nil : $0 } ?? "cline-user")
        ]
    }

    /// Canonical credential file location (`~/.cli-proxy-api/cline.json`).
    static func credentialsURL(in dir: URL = AuthPaths.authDirectory) -> URL {
        dir.appendingPathComponent(authFileName)
    }

    /// Atomically writes credentials, preserving an existing `disabled` flag.
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
    /// until the user reconnects.
    static func quarantineCredentials(at url: URL) {
        ioLock.lock()
        defer { ioLock.unlock() }
        guard let data = try? Data(contentsOf: url),
              var json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            NSLog("[ClineAuth] Failed to quarantine credentials: unreadable file at %@", url.path)
            return
        }
        json["disabled"] = true
        do {
            let out = try JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted])
            try out.write(to: url, options: .atomic)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            NSLog("[ClineAuth] Quarantined Cline credentials (disabled=true) at %@", url.path)
        } catch {
            NSLog("[ClineAuth] Failed to quarantine credentials: %@", error.localizedDescription)
        }
    }

    // MARK: - Browser login (authorize + localhost callback + exchange)

    /// Cancellation handle for an in-flight browser login.
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

    /// Runs the full browser login flow: fetches the authorize URL (following
    /// the service's redirect/json indirection), opens it, waits for the local
    /// callback on port 31234, then exchanges the code. Persists credentials on
    /// success. Callbacks run on background queues.
    @discardableResult
    static func startBrowserLogin(
        onAuthURL: @escaping (_ url: URL) -> Void,
        completion: @escaping (Result<Credentials, ClineAuthError>) -> Void
    ) -> LoginSession {
        let session = LoginSession()

        fetchAuthorizeURL(session: session) { authorizeResult in
            guard !session.isCancelled else {
                completion(.failure(.cancelled))
                return
            }
            switch authorizeResult {
            case .failure(let error):
                completion(.failure(error))
            case .success(let url):
                DispatchQueue.main.async { onAuthURL(url) }
                DispatchQueue.main.async {
                    NSWorkspace.shared.open(url)
                }
                awaitCallbackCode(session: session) { codeResult in
                    guard !session.isCancelled else {
                        completion(.failure(.cancelled))
                        return
                    }
                    switch codeResult {
                    case .failure(let error):
                        completion(.failure(error))
                    case .success(let code):
                        exchangeAndPersist(code: code, session: session, completion: completion)
                    }
                }
            }
        }
        return session
    }

    /// GET `/auth/authorize` and resolve the real sign-in URL. The endpoint may
    /// answer with a 3xx Location or `{"redirect_url": ...}`.
    private static func fetchAuthorizeURL(
        session: LoginSession,
        completion: @escaping (Result<URL, ClineAuthError>) -> Void
    ) {
        var components = URLComponents(string: "https://\(apiHost)/api/v1/auth/authorize")!
        components.queryItems = [
            URLQueryItem(name: "client_type", value: "extension"),
            URLQueryItem(name: "callback_url", value: callbackURL),
            URLQueryItem(name: "redirect_uri", value: callbackURL)
        ]

        var request = URLRequest(url: components.url!)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        applyIdentityHeaders(to: &request)

        URLSession.shared.dataTask(with: request) { data, response, error in
            if session.isCancelled {
                completion(.failure(.cancelled))
                return
            }
            if let error {
                completion(.failure(.network(error.localizedDescription)))
                return
            }
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            // Redirect: prefer the Location header directly.
            if let location = (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Location"),
               let url = URL(string: location), status >= 300 && status < 400 {
                completion(.success(url))
                return
            }
            // JSON body: {"redirect_url": "..."} or already-started HTML page.
            if let data,
               let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
               let redirect = obj["redirect_url"] as? String,
               let url = URL(string: redirect) {
                completion(.success(url))
                return
            }
            if status == 200, let url = response?.url {
                completion(.success(url))
                return
            }
            completion(.failure(.loginFailed("Authorize request returned HTTP \(status)")))
        }.resume()
    }

    /// Local HTTP listener that captures the browser's `GET /auth?code=...`
    /// callback. One-shot: the listener stops itself after the first valid hit.
    private static func awaitCallbackCode(
        session: LoginSession,
        completion: @escaping (Result<String, ClineAuthError>) -> Void
    ) {
        let deliverOnce = OnceCompletion(completion)

        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = false
        // Loopback-only: without this the listener accepts the one-shot callback
        // from any host that can reach this machine, letting a code from an
        // account the user did not choose be exchanged and persisted. The port
        // must stay `.any` here — NWListener rejects a required endpoint that
        // also pins a port with EINVAL ("Local endpoint has port set, cannot
        // override"), since the port comes from the `on:` argument below.
        parameters.requiredLocalEndpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: .any)

        var listener: NWListener?
        do {
            listener = try NWListener(using: parameters, on: NWEndpoint.Port(integerLiteral: 31234))
        } catch {
            deliverOnce(.failure(.loginFailed(
                "Could not listen on port 31234 (\(error.localizedDescription)). If another Cline login is running, cancel it first."
            )))
            return
        }
        guard let listener else {
            deliverOnce(.failure(.loginFailed("Could not create the callback listener.")))
            return
        }

        listener.stateUpdateHandler = { state in
            switch state {
            case .failed(let error):
                deliverOnce(.failure(.loginFailed("Callback listener failed: \(error.localizedDescription)")))
            default:
                break
            }
        }

        listener.newConnectionHandler = { connection in
            receiveCallback(connection) { queryItems in
                // Browsers fire parallel requests (favicons, prefetches); ignore
                // any that do not carry the authorization code.
                guard let code = queryItems.first(where: { $0.name == "code" })?.value, !code.isEmpty else {
                    sendCallbackNotFoundPage(to: connection)
                    return
                }
                guard !session.isCancelled else {
                    connection.cancel()
                    listener.cancel()
                    deliverOnce(.failure(.cancelled))
                    return
                }
                listener.cancel()
                sendCallbackSuccessPage(to: connection)
                deliverOnce(.success(code))
            }
        }

        listener.start(queue: .global(qos: .userInitiated))

        // Hard timeout: give up so a stuck flow cannot linger silently forever.
        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 600) {
            if session.isCancelled {
                listener.cancel()
                deliverOnce(.failure(.cancelled))
            } else {
                listener.cancel()
                deliverOnce(.failure(.loginFailed("Timed out waiting for the browser callback (10 minutes). Try connecting again.")))
            }
        }
    }

    /// Accumulates the first HTTP request line of the callback and parses its
    /// query items, then invokes `handler`. Errors cancel silently; the 10-minute
    /// timeout in the caller is the backstop.
    private static func receiveCallback(
        _ connection: NWConnection,
        handler: @escaping ([URLQueryItem]) -> Void
    ) {
        connection.start(queue: .global(qos: .userInitiated))
        var accumulated = Data()

        func recv() {
            connection.receive(minimumIncompleteLength: 1, maximumLength: 16384) { data, _, isComplete, _ in
                if let data, !data.isEmpty {
                    accumulated.append(data)
                }
                if let text = String(data: accumulated, encoding: .utf8),
                   text.contains("\r\n\r\n") || text.contains("\n\n"),
                   let requestLine = text.split(separator: "\r\n").first ?? text.split(separator: "\n").first {
                    let parts = requestLine.split(separator: " ")
                    let target = parts.count >= 2 ? String(parts[1]) : ""
                    if let components = URLComponents(string: "http://127.0.0.1\(target)") {
                        handler(components.queryItems ?? [])
                        return
                    }
                    handler([])
                    return
                }
                if isComplete {
                    handler([])
                    return
                }
                if accumulated.count > 65536 {
                    handler([])
                    return
                }
                recv()
            }
        }
        recv()
    }

    private static func sendCallbackNotFoundPage(to connection: NWConnection) {
        let body = "HTTP/1.1 404 Not Found\r\nContent-Type: text/plain\r\nConnection: close\r\nContent-Length: 0\r\n\r\n"
        connection.send(content: body.data(using: .utf8), completion: .contentProcessed({ _ in
            connection.send(content: nil, isComplete: true, completion: .contentProcessed({ _ in
                connection.cancel()
            }))
        }))
    }

    private static func sendCallbackSuccessPage(to connection: NWConnection) {
        let html = "<!DOCTYPE html><html><body style=\"font-family:-apple-system;display:flex;align-items:center;" +
            "justify-content:center;height:95vh\"><div style=\"text-align:center\"><h1>&#10003; Authenticated</h1>" +
            "<p>You can close this window.</p></div></body></html>"
        let body = """
        HTTP/1.1 200 OK\r\nContent-Type: text/html\r\nConnection: close\r\n\
        Content-Length: \(html.utf8.count)\r\n\r\n\(html)
        """
        connection.send(content: body.data(using: .utf8), completion: .contentProcessed({ _ in
            connection.send(content: nil, isComplete: true, completion: .contentProcessed({ _ in
                connection.cancel()
            }))
        }))
    }

    /// Exchanges the authorization code for tokens and persists them. Tries the
    /// callback's provider hint first, then each SSO flavor like the official client.
    private static func exchangeAndPersist(
        code: String,
        session: LoginSession,
        completion: @escaping (Result<Credentials, ClineAuthError>) -> Void
    ) {
        var request = URLRequest(url: URL(string: "https://\(apiHost)/api/v1/auth/token")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        applyIdentityHeaders(to: &request)
        request.httpBody = try? JSONSerialization.data(withJSONObject: [
            "grant_type": "authorization_code",
            "code": code,
            "client_type": "extension",
            "redirect_uri": callbackURL
        ])

        URLSession.shared.dataTask(with: request) { data, response, error in
            guard !session.isCancelled else {
                completion(.failure(.cancelled))
                return
            }
            if let error {
                completion(.failure(.network(error.localizedDescription)))
                return
            }
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            switch parseTokenResponse(data ?? Data(), statusCode: status, now: Date()) {
            case .success(let payload):
                guard !payload.refreshToken.isEmpty else {
                    completion(.failure(.loginFailed("Token response missing refresh token. Try connecting again.")))
                    return
                }
                let creds = Credentials(
                    access: payload.accessToken,
                    refresh: payload.refreshToken,
                    expiresAtMs: payload.expiresAtMs,
                    email: emailFromIDToken(payload.accessToken)
                )
                do {
                    try persist(creds, to: credentialsURL())
                    completion(.success(creds))
                } catch {
                    completion(.failure(.loginFailed("Could not save credentials: \(error.localizedDescription)")))
                }
            case .failure(let error):
                completion(.failure(error))
            }
        }.resume()
    }

    /// Best-effort extraction of the `email` claim from a JWT-ish access token.
    static func emailFromIDToken(_ token: String?) -> String? {
        guard let token else { return nil }
        let parts = token.split(separator: ".")
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

    // MARK: - Token access for request forwarding

    private static let refreshLock = NSLock()
    private static var refreshInFlight = false
    private static var refreshWaiters: [(Result<String, ClineAuthError>) -> Void] = []

    /// Loads stored credentials and returns a valid bearer header value,
    /// refreshing (and persisting) it first when the current token has expired.
    ///
    /// Refreshes are single-flighted: concurrent requests collapse onto one
    /// network refresh because upstream ROTATES the refresh token — two racing
    /// refreshes would invalidate one of them mid-flight.
    static func ensureValidAccessToken(completion: @escaping (Result<String, ClineAuthError>) -> Void) {
        guard let (creds, url) = loadActiveCredentials() else {
            completion(.failure(.notLoggedIn))
            return
        }
        if !creds.isAccessExpired() {
            completion(.success(creds.bearerValue))
            return
        }

        refreshLock.lock()
        if refreshInFlight {
            refreshWaiters.append(completion)
            refreshLock.unlock()
            return
        }
        refreshInFlight = true
        refreshLock.unlock()

        let deliver: (Result<String, ClineAuthError>) -> Void = { result in
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
            deliver(.success(current.credentials.bearerValue))
            return
        }

        refreshAccessToken(current.credentials) { result in
            switch result {
            case .success(let refreshed):
                do {
                    try persist(refreshed, to: current.url)
                    deliver(.success(refreshed.bearerValue))
                } catch {
                    NSLog("[ClineAuth] Refresh succeeded but persist failed: %@", error.localizedDescription)
                    deliver(.success(refreshed.bearerValue))
                }
            case .failure(let error):
                if error.isTerminalRefreshFailure {
                    quarantineCredentials(at: current.url)
                    deliver(.failure(.reauthRequired(error.localizedDescription)))
                } else {
                    deliver(.failure(error))
                }
            }
        }
    }

    private static func refreshAccessToken(
        _ creds: Credentials,
        completion: @escaping (Result<Credentials, ClineAuthError>) -> Void
    ) {
        var request = URLRequest(url: URL(string: "https://\(apiHost)/api/v1/auth/refresh")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        applyIdentityHeaders(to: &request)
        request.httpBody = try? JSONSerialization.data(withJSONObject: [
            "refreshToken": creds.refresh,
            "grantType": "refresh_token"
        ])

        URLSession.shared.dataTask(with: request) { data, response, error in
            if let error {
                completion(.failure(.network(error.localizedDescription)))
                return
            }
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            switch parseTokenResponse(data ?? Data(), statusCode: status, now: Date()) {
            case .success(var refreshed):
                // Refresh may omit the rotated refresh token; keep the prior value.
                if refreshed.refreshToken.isEmpty { refreshed.refreshToken = creds.refresh }
                let email = creds.email
                completion(.success(Credentials(
                    access: refreshed.accessToken,
                    refresh: refreshed.refreshToken,
                    expiresAtMs: refreshed.expiresAtMs,
                    email: email
                )))
            case .failure(let error):
                completion(.failure(error))
            }
        }.resume()
    }

    // MARK: - Request header helpers

    /// Builds the full set of headers ThinkingProxy adds when forwarding to
    /// api.cline.bot: identity headers plus OpenRouter-style tracking headers.
    static func completionHeaders(taskID: String) -> [(String, String)] {
        [
            ("HTTP-Referer", "https://cline.bot"),
            ("X-Title", "Cline"),
            ("X-Task-ID", taskID),
            ("X-Is-Multiroot", "false")
        ] + identityHeaders
    }

    private static func applyIdentityHeaders(to request: inout URLRequest) {
        for (name, value) in identityHeaders {
            request.setValue(value, forHTTPHeaderField: name)
        }
    }

    // MARK: - Misc

    /// Generates a ULID-style `X-Task-ID` (48-bit timestamp + 80-bit random,
    /// Crockford Base32) matching what the official extension sends.
    enum ClineTaskID {
        private static let chars = Array("0123456789ABCDEFGHJKMNPQRSTVWXYZ")

        static func generate(date: Date = Date()) -> String {
            var value = ""
            var ts = UInt64(date.timeIntervalSince1970 * 1000)
            for _ in 0..<10 {
                value.insert(chars[Int(ts % 32)], at: value.startIndex)
                ts /= 32
            }
            var bytes = [UInt8](repeating: 0, count: 16)
            let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
            if status != errSecSuccess {
                for i in 0..<bytes.count { bytes[i] = UInt8.random(in: 0...255) }
            }
            for b in bytes {
                value.append(chars[Int(b) % 32])
            }
            return value
        }
    }

    private final class OnceCompletion {
        private let lock = NSLock()
        private var done = false
        private let original: (Result<String, ClineAuthError>) -> Void

        init(_ original: @escaping (Result<String, ClineAuthError>) -> Void) {
            self.original = original
        }

        func callAsFunction(_ result: Result<String, ClineAuthError>) {
            lock.lock()
            defer { lock.unlock() }
            guard !done else { return }
            done = true
            original(result)
        }
    }
}
