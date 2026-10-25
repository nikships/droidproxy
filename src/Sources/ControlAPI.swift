import Foundation
import Network
import Security

/// DroidProxy's control API, version 1: how Droid Office drives DroidProxy.
/// ThinkingProxy serves it on its own port under `/droidproxy/control/`.
/// Everything here is pure (request parsing, authorization, routing, JSON) so
/// it can be tested without a listener; `ControlEndpoint` runs it.
enum ControlAPI {
    static let version = 1
    static let pathPrefix = "/droidproxy/control"
    static let maxBodyBytes = 64 * 1024

    struct Request {
        let method: String
        /// The path without its query.
        let path: String
        /// Header values by lowercased name.
        let headers: [String: String]
        let body: Data

        var contentLength: Int? {
            headers["content-length"].flatMap { Int($0.trimmingCharacters(in: .whitespaces)) }
        }
    }

    struct Response: Equatable {
        let status: Int
        let body: Data

        static func json(_ status: Int, _ object: Any) -> Response {
            Response(status: status, body: encode(object))
        }

        static func error(_ status: Int, _ message: String) -> Response {
            json(status, ["error": message])
        }
    }

    enum Route: Equatable {
        case status
        case connect
        case cancelConnect
        case removeAccount
        case providers
        case factoryModels
        case models
        case open
    }

    enum RouteMatch: Equatable {
        case route(Route)
        case notFound
        case methodNotAllowed
    }

    private static let routes: [String: (method: String, route: Route)] = [
        "/status": ("GET", .status),
        "/connect": ("POST", .connect),
        "/connect/cancel": ("POST", .cancelConnect),
        "/accounts/remove": ("POST", .removeAccount),
        "/providers": ("POST", .providers),
        "/factory-models": ("POST", .factoryModels),
        "/models": ("GET", .models),
        "/open": ("POST", .open)
    ]

    // MARK: - Recognizing and parsing

    static func isControlPath(_ path: String) -> Bool {
        let bare = path.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? path
        return bare == pathPrefix || bare.hasPrefix(pathPrefix + "/")
    }

    /// Reads only the request line, so ThinkingProxy can pick control requests
    /// out cheaply before it reads a large body.
    static func looksLikeControlRequest(_ data: Data) -> Bool {
        let head = data.prefix(512)
        guard let lineEnd = head.range(of: Data([13, 10])) else { return false }
        guard let line = String(data: head[head.startIndex..<lineEnd.lowerBound], encoding: .utf8) else { return false }
        let parts = line.split(separator: " ")
        return parts.count >= 2 && isControlPath(String(parts[1]))
    }

    static func parseRequest(_ data: Data) -> Request? {
        let separator = Data([13, 10, 13, 10])
        let headerEnd = data.range(of: separator)
        let headerData = headerEnd.map { data[data.startIndex..<$0.lowerBound] } ?? data[...]
        guard let headerText = String(data: headerData, encoding: .utf8) else { return nil }
        let lines = headerText.components(separatedBy: "\r\n")
        let requestLine = lines.first?.split(separator: " ") ?? []
        guard requestLine.count >= 3 else { return nil }

        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            headers[name] = value
        }

        let target = String(requestLine[1])
        let path = target.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? target
        let body = headerEnd.map { Data(data[$0.upperBound...]) } ?? Data()
        return Request(method: String(requestLine[0]).uppercased(), path: path, headers: headers, body: body)
    }

    static func match(method: String, path: String) -> RouteMatch {
        guard path.hasPrefix(pathPrefix + "/"),
              let entry = routes[String(path.dropFirst(pathPrefix.count))] else {
            return .notFound
        }
        return entry.method == method ? .route(entry.route) : .methodNotAllowed
    }

    // MARK: - Authorization

    static func isLoopback(_ endpoint: NWEndpoint?) -> Bool {
        guard case .hostPort(let host, _)? = endpoint else { return false }
        return isLoopback(host: host)
    }

    static func isLoopback(host: NWEndpoint.Host) -> Bool {
        switch host {
        case .ipv4(let address):
            // Network's isLoopback is only 127.0.0.1; the whole 127/8 block is loopback.
            return address.rawValue.first == 127
        case .ipv6(let address):
            return address.isLoopback || isMappedIPv4Loopback(address.rawValue)
        case .name:
            return false
        @unknown default:
            return false
        }
    }

    /// `::ffff:127.x.y.z`, how a dual-stack listener can see an IPv4 loopback peer.
    static func isMappedIPv4Loopback(_ bytes: Data) -> Bool {
        let raw = [UInt8](bytes)
        guard raw.count == 16 else { return false }
        return raw[0..<10].allSatisfy { $0 == 0 } && raw[10] == 0xff && raw[11] == 0xff && raw[12] == 127
    }

    /// The checks every request passes before it is routed: a loopback peer,
    /// no `Origin` (no web page may call this), a `Host` naming this port on
    /// loopback, the launch's bearer token, and a body within the limit.
    /// Returns the refusal, or nil when the request may go on.
    static func authorize(_ request: Request, peerIsLoopback: Bool, token: String, port: UInt16) -> Response? {
        guard peerIsLoopback else {
            return .error(403, "DroidProxy's control API only answers this Mac.")
        }
        guard request.headers["origin"] == nil else {
            return .error(403, "DroidProxy's control API doesn't answer web pages.")
        }
        let allowedHosts = ["127.0.0.1:\(port)", "localhost:\(port)"]
        guard let host = request.headers["host"]?.lowercased(), allowedHosts.contains(host) else {
            return .error(403, "DroidProxy's control API only answers 127.0.0.1:\(port) or localhost:\(port).")
        }
        let prefix = "bearer "
        guard let authorization = request.headers["authorization"],
              authorization.lowercased().hasPrefix(prefix),
              constantTimeEquals(String(authorization.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces), token) else {
            return .error(401, "Missing or wrong control token. Read ~/.droidproxy/control.json again.")
        }
        if (request.contentLength ?? 0) > maxBodyBytes || request.body.count > maxBodyBytes {
            return .error(413, "The request body is over 64 KiB.")
        }
        return nil
    }

    static func constantTimeEquals(_ lhs: String, _ rhs: String) -> Bool {
        let a = Array(lhs.utf8)
        let b = Array(rhs.utf8)
        var difference = UInt8(a.count == b.count ? 0 : 1)
        for index in 0..<max(a.count, b.count) {
            let x = index < a.count ? a[index] : 0
            let y = index < b.count ? b[index] : 0
            difference |= x ^ y
        }
        return difference == 0
    }

    static func isJSONContentType(_ value: String?) -> Bool {
        guard let value else { return false }
        let mediaType = value.split(separator: ";").first?.trimmingCharacters(in: .whitespaces).lowercased()
        return mediaType == "application/json"
    }

    /// The body of a POST as a JSON object; an empty body is `{}`.
    static func jsonObject(_ body: Data) -> [String: Any]? {
        let trimmed = String(data: body, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if trimmed.isEmpty { return [:] }
        return (try? JSONSerialization.jsonObject(with: body)) as? [String: Any]
    }

    // MARK: - JSON

    static func encode(_ object: Any) -> Data {
        (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]))
            ?? Data("{\"error\":\"encoding failed\"}".utf8)
    }

    private static let isoFormatter = ISO8601DateFormatter()

    static func iso(_ date: Date?) -> Any {
        date.map(isoFormatter.string(from:)) ?? NSNull()
    }

    static func connectingObject(_ connect: ProviderConnect?) -> Any {
        guard let connect else { return NSNull() }
        return [
            "started_at": iso(connect.startedAt),
            "user_code": connect.userCode ?? NSNull(),
            "verification_uri": connect.verificationURI ?? NSNull(),
            "error": connect.error ?? NSNull()
        ] as [String: Any]
    }

    static func statusObject(_ status: ControlStatus) -> [String: Any] {
        [
            "api": version,
            "version": status.version,
            "backend": ["running": status.backendRunning],
            "providers": status.providers.map { provider -> [String: Any] in
                [
                    "key": provider.key.rawValue,
                    "name": provider.name,
                    "enabled": provider.enabled,
                    "connect": provider.key.connectKind.rawValue,
                    "accounts": provider.accounts.map { account -> [String: Any] in
                        [
                            "id": account.id,
                            "label": account.label,
                            "expired": account.expired,
                            "disabled": account.disabled
                        ]
                    },
                    "connecting": connectingObject(provider.connecting)
                ]
            },
            "factory": [
                "installed": status.factory.installed,
                "available": status.factory.available,
                "stale": status.factory.stale
            ]
        ]
    }

    static func availabilityObject(_ availability: ModelAvailability) -> [String: Any] {
        switch availability {
        case .ok:
            return ["state": "ok"]
        case .exhausted(let until, let window, let account):
            return ["state": "exhausted", "until": iso(until), "window": window, "account": account ?? NSNull()]
        case .signedOut:
            return ["state": "signed-out"]
        case .disabled:
            return ["state": "disabled"]
        case .unknown:
            return ["state": "unknown"]
        }
    }

    static func modelsObject(_ models: [ControlModel], now: Date) -> [String: Any] {
        [
            "generated_at": iso(now),
            "models": models.map { model -> [String: Any] in
                [
                    "id": model.id,
                    "name": model.name,
                    "provider": model.provider,
                    "availability": availabilityObject(model.availability)
                ]
            }
        ]
    }

    // MARK: - Handling

    /// Runs one control request end to end against `backend`.
    static func handle(
        _ request: Request,
        peerIsLoopback: Bool,
        token: String,
        port: UInt16,
        backend: ControlBackend,
        now: Date = Date()
    ) async -> Response {
        if let refusal = authorize(request, peerIsLoopback: peerIsLoopback, token: token, port: port) {
            return refusal
        }

        let route: Route
        switch match(method: request.method, path: request.path) {
        case .route(let matched): route = matched
        case .notFound: return .error(404, "DroidProxy has no control call \(request.method) \(request.path).")
        case .methodNotAllowed: return .error(405, "\(request.path) doesn't take \(request.method).")
        }

        var body: [String: Any] = [:]
        if request.method == "POST" {
            guard isJSONContentType(request.headers["content-type"]) else {
                return .error(415, "Send the body as application/json.")
            }
            guard let object = jsonObject(request.body) else {
                return .error(400, "The body isn't a JSON object.")
            }
            body = object
        }

        func provider() -> Result<ServiceType, ResponseError> {
            guard let key = body["provider"] as? String else {
                return .failure(ResponseError(.error(400, "Say which provider.")))
            }
            guard let type = ServiceType(rawValue: key) else {
                return .failure(ResponseError(.error(400, "DroidProxy has no provider \"\(key)\".")))
            }
            return .success(type)
        }

        switch route {
        case .status:
            return .json(200, statusObject(await backend.controlStatus()))

        case .connect:
            switch provider() {
            case .failure(let error): return error.response
            case .success(let type):
                switch await backend.controlConnect(type) {
                case .started(let connect):
                    return .json(202, ["connecting": connectingObject(connect)])
                case .alreadyRunning:
                    return .error(409, "A \(type.controlName) sign-in is already running.")
                case .needsApp:
                    return .error(400, "\(type.controlName) connects in DroidProxy's own window.")
                }
            }

        case .cancelConnect:
            switch provider() {
            case .failure(let error): return error.response
            case .success(let type):
                await backend.controlCancelConnect(type)
                return .json(200, [String: Any]())
            }

        case .removeAccount:
            switch provider() {
            case .failure(let error): return error.response
            case .success(let type):
                guard let account = body["account"] as? String, !account.isEmpty else {
                    return .error(400, "Say which account.")
                }
                if let failure = await backend.controlRemoveAccount(type, account: account) {
                    return failure
                }
                return .json(200, statusObject(await backend.controlStatus()))
            }

        case .providers:
            switch provider() {
            case .failure(let error): return error.response
            case .success(let type):
                guard let enabled = body["enabled"] as? Bool else {
                    return .error(400, "Say whether the provider is enabled (true or false).")
                }
                await backend.controlSetProviderEnabled(type, enabled: enabled)
                return .json(200, statusObject(await backend.controlStatus()))
            }

        case .factoryModels:
            switch await backend.controlApplyFactoryModels() {
            case .success(let result):
                return .json(200, ["installed": result.installed, "backup": result.backup?.path ?? NSNull()] as [String: Any])
            case .failure(let error):
                return .error(500, "Couldn't write Droid's settings: \(error.localizedDescription)")
            }

        case .models:
            return .json(200, modelsObject(await backend.controlModels(now: now), now: now))

        case .open:
            await backend.controlOpenSettings()
            return .json(200, [String: Any]())
        }
    }

    struct ResponseError: Error {
        let response: Response
        init(_ response: Response) { self.response = response }
    }
}

extension ServiceType {
    /// The provider's name in the control API.
    var controlName: String {
        switch self {
        case .claude: return "Claude"
        case .codex: return "Codex"
        case .antigravity: return "Antigravity"
        case .kimi: return "Kimi"
        case .junie: return "Junie"
        case .grok: return "Grok"
        case .copilot: return "GitHub Copilot"
        case .meta: return "Meta Muse"
        }
    }
}

struct ControlAccount: Equatable {
    let id: String
    let label: String
    let expired: Bool
    let disabled: Bool
}

struct ControlProvider: Equatable {
    let key: ServiceType
    let name: String
    let enabled: Bool
    let accounts: [ControlAccount]
    let connecting: ProviderConnect?
}

struct ControlStatus: Equatable {
    let version: String
    let backendRunning: Bool
    let providers: [ControlProvider]
    let factory: FactoryModels.Status
}

struct ControlModel: Equatable {
    let id: String
    let name: String
    let provider: String
    let availability: ModelAvailability
}

/// What the control API asks of the app. `ProviderController` is the real one.
@MainActor
protocol ControlBackend: AnyObject {
    func controlStatus() -> ControlStatus
    func controlConnect(_ provider: ServiceType) -> ConnectOutcome
    func controlCancelConnect(_ provider: ServiceType)
    /// Nil when the account is gone; otherwise the refusal to send.
    func controlRemoveAccount(_ provider: ServiceType, account: String) async -> ControlAPI.Response?
    func controlSetProviderEnabled(_ provider: ServiceType, enabled: Bool)
    func controlApplyFactoryModels() -> Result<FactoryModels.ApplyResult, Error>
    func controlModels(now: Date) async -> [ControlModel]
    func controlOpenSettings()
}

/// `~/.droidproxy/control.json`: how the office finds the control API and its
/// token, which is new at every launch.
enum ControlDiscovery {
    static let fileName = "control.json"

    static var defaultDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".droidproxy")
    }

    /// 32 random bytes as 64 hex characters, or nil when the system has no randomness to give.
    static func makeToken() -> String? {
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else { return nil }
        return bytes.map { String(format: "%02x", $0) }.joined()
    }

    static func contents(port: UInt16, token: String, version: String, pid: Int32) -> Data {
        ControlAPI.encode([
            "api": ControlAPI.version,
            "port": Int(port),
            "token": token,
            "version": version,
            "pid": Int(pid)
        ] as [String: Any])
    }

    enum WriteError: LocalizedError {
        case posix(String, Int32)

        var errorDescription: String? {
            switch self {
            case .posix(let step, let code): return "\(step) failed: \(String(cString: strerror(code)))"
            }
        }
    }

    /// Writes the file through a 0600 temp file in the same folder and a
    /// rename, so a reader never sees a partial file or a moment when it is
    /// readable by anyone else.
    @discardableResult
    static func write(
        directory: URL = defaultDirectory,
        port: UInt16,
        token: String,
        version: String,
        pid: Int32 = ProcessInfo.processInfo.processIdentifier
    ) throws -> URL {
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)

        let target = directory.appendingPathComponent(fileName)
        let temp = directory.appendingPathComponent(".\(fileName).\(UUID().uuidString).tmp")
        let data = contents(port: port, token: token, version: version, pid: pid)

        let fd = open(temp.path, O_WRONLY | O_CREAT | O_EXCL, 0o600)
        guard fd >= 0 else { throw WriteError.posix("open", errno) }
        let written = data.withUnsafeBytes { buffer in
            Darwin.write(fd, buffer.baseAddress, buffer.count)
        }
        let writeErrno = errno
        fchmod(fd, 0o600)
        fsync(fd)
        close(fd)
        guard written == data.count else {
            unlink(temp.path)
            throw WriteError.posix("write", writeErrno)
        }
        guard rename(temp.path, target.path) == 0 else {
            let renameErrno = errno
            unlink(temp.path)
            throw WriteError.posix("rename", renameErrno)
        }
        return target
    }

    /// Removes the file when it is still this process's.
    static func remove(directory: URL = defaultDirectory, pid: Int32 = ProcessInfo.processInfo.processIdentifier) {
        let target = directory.appendingPathComponent(fileName)
        guard let data = try? Data(contentsOf: target),
              let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              (json["pid"] as? Int) == Int(pid) else { return }
        try? FileManager.default.removeItem(at: target)
    }
}

/// ThinkingProxy's handle on the control API for this launch.
final class ControlEndpoint {
    let token: String
    let port: UInt16
    let backend: ControlBackend

    init(token: String, port: UInt16, backend: ControlBackend) {
        self.token = token
        self.port = port
        self.backend = backend
    }

    func handle(_ request: ControlAPI.Request, peer: NWEndpoint?) async -> ControlAPI.Response {
        await ControlAPI.handle(request, peerIsLoopback: ControlAPI.isLoopback(peer), token: token, port: port, backend: backend)
    }
}
