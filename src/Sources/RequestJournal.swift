import Foundation
import CryptoKit
import Darwin

struct JournalTokens: Codable, Equatable {
    var input_uncached: Int64
    var cache_read: Int64
    var cache_creation: Int64?
    var output: Int64
    var reasoning: Int64?

    enum CodingKeys: String, CodingKey {
        case input_uncached, cache_read, cache_creation, output, reasoning
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(input_uncached, forKey: .input_uncached)
        try c.encode(cache_read, forKey: .cache_read)
        try c.encode(cache_creation, forKey: .cache_creation)
        try c.encode(output, forKey: .output)
        try c.encode(reasoning, forKey: .reasoning)
    }
}

struct JournalSeat: Codable, Equatable {
    var auth_index: String
    var role: String
    var file: String?
    var email: String?
    var org: String?
    var account_id: String?
}

struct JournalRecord: Codable, Equatable {
    var v = 1
    var execution_id: String
    var trace_id: String?
    var started_at: String
    var ended_at: String
    var latency_ms: Int
    var ttft_ms: Int?
    var origin: String
    var endpoint: String
    var forwarded_endpoint: String?
    var provider: String
    var requested_model: String?
    var response_model: String?
    var status: Int?
    var outcome: String
    var seat: JournalSeat?
    var client_session: String?
    var tokens: JournalTokens?

    enum CodingKeys: String, CodingKey {
        case v, execution_id, trace_id, started_at, ended_at, latency_ms, ttft_ms
        case origin, endpoint, forwarded_endpoint, provider, requested_model
        case response_model, status, outcome, seat, client_session, tokens
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(v, forKey: .v)
        try c.encode(execution_id, forKey: .execution_id)
        try c.encode(trace_id, forKey: .trace_id)
        try c.encode(started_at, forKey: .started_at)
        try c.encode(ended_at, forKey: .ended_at)
        try c.encode(latency_ms, forKey: .latency_ms)
        try c.encode(ttft_ms, forKey: .ttft_ms)
        try c.encode(origin, forKey: .origin)
        try c.encode(endpoint, forKey: .endpoint)
        try c.encode(forwarded_endpoint, forKey: .forwarded_endpoint)
        try c.encode(provider, forKey: .provider)
        try c.encode(requested_model, forKey: .requested_model)
        try c.encode(response_model, forKey: .response_model)
        try c.encode(status, forKey: .status)
        try c.encode(outcome, forKey: .outcome)
        try c.encode(seat, forKey: .seat)
        try c.encode(client_session, forKey: .client_session)
        try c.encode(tokens, forKey: .tokens)
    }
}

struct JournalRequest {
    let endpoint: String
    let forwardedEndpoint: String?
    let model: String?
    let provider: String
    let session: String?
    let origin: String

    static func path(_ raw: String) -> String { String(raw.prefix { $0 != "?" }) }

    static func nativeModel(_ path: String) -> String? {
        let prefix = "/v1beta/models/"
        guard path.hasPrefix(prefix) else { return nil }
        let suffix = path.dropFirst(prefix.count)
        guard let colon = suffix.lastIndex(of: ":"),
              ["generateContent", "streamGenerateContent"].contains(String(suffix[suffix.index(after: colon)...])) else { return nil }
        let model = String(suffix[..<colon])
        return model.isEmpty || model.contains("/") || model.contains(":") ? nil : model
    }

    static let paths: Set<String> = [
        "/v1/messages", "/v1/chat/completions", "/v1/completions",
        "/v1/responses", "/backend-api/codex/responses",
        "/v1/responses/compact", "/backend-api/codex/responses/compact",
        "/v1/alpha/search", "/backend-api/codex/alpha/search",
        "/v1/images/generations", "/v1/images/edits",
        "/v1/videos", "/v1/videos/generations", "/v1/videos/edits",
        "/v1/videos/extensions", "/openai/v1/videos", "/v1/audio/speech", "/v1/tts",
        "/v1/live", "/v1/realtime", "/v1/realtime/calls", "/v1/realtime/translations",
        "/v1beta/interactions"
    ]

    static func admitted(method: String, path: String) -> Bool {
        method == "POST" && (paths.contains(Self.path(path)) || nativeModel(Self.path(path)) != nil)
    }

    static func provider(model: String?, path: String) -> String {
        let m = model ?? ""
        if m.hasPrefix("claude-") || m.hasPrefix("gemini-claude-")
            || ["ag-c55s-high", "ag-c55o-high", "ag-c46s-thinking", "ag-c46o-thinking"].contains(m) { return "claude" }
        if m.hasPrefix("gemini-") || path.hasPrefix("/v1beta/") { return "gemini" }
        if m.hasPrefix("gpt-") || m.hasPrefix("codex-")
            || path.hasPrefix("/backend-api/codex/") || path == "/v1/alpha/search" { return "codex" }
        if path == "/v1/messages" { return "claude" }
        if path.hasPrefix("/v1/") || path.hasPrefix("/openai/v1/") { return "openai" }
        return "unknown"
    }

    static func validSession(_ value: String?) -> String? {
        guard let value, value.range(of: "^[A-Za-z0-9_.:-]{8,128}$", options: .regularExpression) != nil else { return nil }
        return value
    }

    /// `body` is the request body parsed as strict JSON, or nil when it is not strict JSON.
    static func session(headers: [(String, String)], body: JournalJSON?) -> String? {
        for key in ["x-session-id", "x-claude-code-session-id"] {
            for (name, value) in headers where name.lowercased() == key {
                if let id = validSession(value.trimmingCharacters(in: CharacterSet(charactersIn: " \t"))) { return id }
            }
        }
        guard let body = body?.object else { return nil }
        if let id = validSession(body["prompt_cache_key"]?.string) { return id }
        guard let user = body["metadata"]?["user_id"]?.string else { return nil }
        if user.hasPrefix("{") {
            return validSession(JournalJSON.parse(Data(user.utf8))?["session_id"]?.string)
        }
        guard let range = user.range(of: "_session_", options: .backwards) else { return nil }
        return validSession(String(user[range.upperBound...]))
    }

    init(endpoint: String, forwardedEndpoint: String, headers: [(String, String)], body: Data) {
        self.endpoint = Self.path(endpoint)
        let forwarded = Self.path(forwardedEndpoint)
        self.forwardedEndpoint = forwarded == self.endpoint ? nil : forwarded
        let json = JournalJSON.parse(body)
        let model = Self.nativeModel(self.endpoint) ?? json?["model"]?.string
        self.model = model?.isEmpty == false ? model : nil
        self.provider = Self.provider(model: self.model, path: self.endpoint)
        self.session = Self.session(headers: headers, body: json)
        self.origin = headers.contains { $0.0.lowercased() == "x-droidproxy-origin" && $0.1 == "window-primer" } ? "primer" : "client"
    }
}

struct JournalSeatBinding {
    let identity: JournalSeat
    let isValid: () -> Bool
}

final class JournalSeatIndex {
    private struct Fingerprint: Equatable {
        let size: off_t
        let seconds: Int
        let nanos: Int
        let inode: ino_t
    }
    /// Entries that are not owned regular files keep a nil identity: they hold their index but are never bound.
    private struct Entry {
        let url: URL
        let fingerprint: Fingerprint
        let identity: JournalSeat?
    }
    private static let identityMembers = JournalJSON.Selection(members: [
        "type": .all, "email": .all, "organization_uuid": .all, "account_id": .all,
        "organization": JournalJSON.Selection(members: ["uuid": .all])
    ])
    private let directory: URL
    private let lock = NSRecursiveLock()
    private var entries: [String: [Entry]] = [:]
    private var refreshed: TimeInterval = -.infinity

    init(directory: URL) { self.directory = directory }

    static func index(type: String, path: String) -> String {
        SHA256.hash(data: Data("\(type.lowercased()):\((path as NSString).standardizingPath)".utf8))
            .prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    /// Fingerprint of an owned regular file at `url`, opened without following a symlink; nil if unreadable.
    private func fingerprint(_ url: URL) -> Fingerprint? {
        let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        return fingerprint(fd, owned: true)
    }

    private func fingerprint(_ fd: Int32, owned: Bool) -> Fingerprint? {
        var s = stat()
        guard fstat(fd, &s) == 0, s.st_mode & S_IFMT == S_IFREG, !owned || s.st_uid == getuid() else { return nil }
        return Fingerprint(size: s.st_size, seconds: s.st_mtimespec.tv_sec, nanos: s.st_mtimespec.tv_nsec, inode: s.st_ino)
    }

    private func identityData(_ url: URL, bindable: Bool) -> (Fingerprint, JournalJSON)? {
        let fd = open(url.path, O_RDONLY | O_NONBLOCK | O_CLOEXEC | (bindable ? O_NOFOLLOW : 0))
        guard fd >= 0 else { return nil }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? handle.close() }
        guard let before = fingerprint(fd, owned: bindable), let data = try? handle.readToEnd(),
              let json = JournalJSON.parse(data, select: Self.identityMembers),
              fingerprint(fd, owned: bindable) == before, !bindable || fingerprint(url) == before else { return nil }
        return (before, json)
    }

    private static func nonempty(_ value: JournalJSON?) -> String? {
        guard let string = value?.string, !string.isEmpty else { return nil }
        return string
    }

    func refresh() {
        lock.lock()
        defer { lock.unlock() }
        var next: [String: [Entry]] = [:]
        for name in (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? [] where name.hasSuffix(".json") {
            let url = directory.appendingPathComponent(name)
            var s = stat()
            guard lstat(url.path, &s) == 0 else { continue }
            let bindable = s.st_mode & S_IFMT == S_IFREG && s.st_uid == getuid()
            guard let (before, json) = identityData(url, bindable: bindable), let type = Self.nonempty(json["type"]) else { continue }
            let index = Self.index(type: type, path: url.standardizedFileURL.path)
            let kind = type.lowercased()
            let identity = !bindable ? nil : JournalSeat(
                auth_index: index, role: "served",
                file: name.range(of: #"^[^/\\]+\.json$"#, options: .regularExpression) == nil ? nil : name,
                email: Self.nonempty(json["email"]),
                org: kind == "claude" ? Self.nonempty(json["organization_uuid"]) ?? Self.nonempty(json["organization"]?["uuid"]) : nil,
                account_id: kind == "codex" ? Self.nonempty(json["account_id"]) : nil
            )
            next[index, default: []].append(Entry(url: url, fingerprint: before, identity: identity))
        }
        entries = next
        refreshed = ProcessInfo.processInfo.systemUptime
    }

    func bind(_ index: String) -> JournalSeatBinding? {
        lock.lock()
        defer { lock.unlock() }
        if let old = entries[index], old.contains(where: { $0.identity != nil && fingerprint($0.url) != $0.fingerprint }) {
            refresh()
        } else if entries[index] == nil && ProcessInfo.processInfo.systemUptime - refreshed >= 1 {
            refresh()
        }
        guard let matches = entries[index], matches.count == 1, let entry = matches.first, let identity = entry.identity else { return nil }
        return JournalSeatBinding(identity: identity, isValid: { [weak self] in
            guard let self else { return false }
            self.lock.lock()
            defer { self.lock.unlock() }
            guard let current = self.entries[index], current.count == 1,
                  current[0].url == entry.url, current[0].fingerprint == entry.fingerprint else { return false }
            return self.fingerprint(entry.url) == entry.fingerprint
        })
    }
}

final class JournalWriter {
    private struct LockTimeout: Error {}
    private static let diagnostics = DispatchQueue(label: "io.automaze.droidproxy.journal-diagnostics")
    private static let lockWait: TimeInterval = 1
    private let directory: URL
    private let queue = DispatchQueue(label: "io.automaze.droidproxy.journal-writer")
    private let slots: DispatchSemaphore
    private let lock = NSLock()
    private var counts = (drops: 0, errors: 0)
    private var lastError: String?
    private var reportScheduled = false
    private var pending = 0
    private var closed = false

    init(directory: URL, capacity: Int = 256) {
        self.directory = directory
        self.slots = DispatchSemaphore(value: capacity)
    }

    var counters: (drops: Int, errors: Int) {
        lock.lock()
        defer { lock.unlock() }
        return counts
    }

    /// Never blocks the caller: a full queue or a closed writer counts the record as dropped.
    func enqueue(_ record: JournalRecord) {
        guard slots.wait(timeout: .now()) == .success else { return note(drops: 1) }
        lock.lock()
        let accepted = !closed
        if accepted { pending += 1 }
        lock.unlock()
        guard accepted else {
            slots.signal()
            return note(drops: 1)
        }
        queue.async {
            defer { self.slots.signal() }
            self.lock.lock()
            let skip = self.closed
            if !skip { self.pending -= 1 }
            self.lock.unlock()
            guard !skip else { return }
            do { try self.append(record) }
            catch is LockTimeout { self.note(drops: 1) }
            catch { self.note(errors: 1, error: error.localizedDescription) }
        }
    }

    /// Waits at most `timeout` for queued records. Records still queued then are counted as dropped and never written.
    func flush(timeout: TimeInterval = 2) {
        let done = DispatchSemaphore(value: 0)
        queue.async { done.signal() }
        guard done.wait(timeout: .now() + timeout) == .timedOut else { return }
        lock.lock()
        closed = true
        counts.drops += pending
        pending = 0
        lock.unlock()
        report()
    }

    /// Counts are updated at once; the log line is emitted later on another queue, at most once per interval.
    private func note(drops: Int = 0, errors: Int = 0, error: String? = nil) {
        lock.lock()
        counts.drops += drops
        counts.errors += errors
        if let error { lastError = error }
        let schedule = !reportScheduled
        reportScheduled = true
        lock.unlock()
        if schedule { Self.diagnostics.asyncAfter(deadline: .now() + 5) { [weak self] in self?.report() } }
    }

    private func report() {
        lock.lock()
        let (current, error) = (counts, lastError)
        reportScheduled = false
        lock.unlock()
        NSLog("[RequestJournal] %d records dropped, %d write errors%@", current.drops, current.errors, error.map { "; last error: \($0)" } ?? "")
    }

    private func lockExclusive(_ fd: Int32) throws {
        let deadline = Date().addingTimeInterval(Self.lockWait)
        while flock(fd, LOCK_EX | LOCK_NB) != 0 {
            guard errno == EWOULDBLOCK || errno == EINTR else { return try check(false) }
            guard Date() < deadline else { throw LockTimeout() }
            usleep(10_000)
        }
    }

    private func check(_ success: Bool) throws {
        if !success { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    }

    private func verify(_ fd: Int32, kind: mode_t, mode: mode_t) throws {
        var s = stat()
        try check(fstat(fd, &s) == 0)
        guard s.st_uid == getuid(), s.st_mode & S_IFMT == kind else { throw POSIXError(.EPERM) }
        try check(fchmod(fd, mode) == 0)
    }

    func append(_ record: JournalRecord) throws {
        // Open the private parent separately so a journal-directory symlink cannot redirect writes.
        let parent = directory.deletingLastPathComponent()
        if mkdir(parent.path, 0o700) != 0 && errno != EEXIST { try check(false) }
        let pfd = open(parent.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        try check(pfd >= 0)
        defer { close(pfd) }
        try verify(pfd, kind: mode_t(S_IFDIR), mode: 0o700)
        if mkdirat(pfd, directory.lastPathComponent, 0o700) != 0 && errno != EEXIST { try check(false) }
        let dfd = openat(pfd, directory.lastPathComponent, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        try check(dfd >= 0)
        defer { close(dfd) }
        try verify(dfd, kind: mode_t(S_IFDIR), mode: 0o700)
        let name = "requests-\(record.started_at.prefix(7)).jsonl"
        var created = true
        var fd = openat(dfd, name, O_RDWR | O_APPEND | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        if fd < 0 && errno == EEXIST {
            created = false
            fd = openat(dfd, name, O_RDWR | O_APPEND | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        }
        try check(fd >= 0)
        defer { close(fd) }
        try verify(fd, kind: mode_t(S_IFREG), mode: 0o600)
        try lockExclusive(fd)
        defer { flock(fd, LOCK_UN) }
        var end = lseek(fd, 0, SEEK_END)
        try check(end >= 0)
        var buffer = [UInt8](repeating: 0, count: 4096)
        var repaired = end
        while end > 0 {
            let count = Int(min(end, off_t(buffer.count)))
            let start = end - off_t(count)
            let n = pread(fd, &buffer, count, start)
            if n < 0 && errno == EINTR { continue }
            try check(n == count)
            if let last = buffer[..<count].lastIndex(of: 10) {
                repaired = start + off_t(last) + 1
                break
            }
            end = start
            repaired = end
        }
        try check(ftruncate(fd, repaired) == 0)
        var data = try JSONEncoder().encode(record)
        data.append(10)
        try data.withUnsafeBytes { raw in
            var offset = 0
            while offset < raw.count {
                let n = write(fd, raw.baseAddress!.advanced(by: offset), raw.count - offset)
                if n < 0 && errno == EINTR { continue }
                try check(n > 0)
                offset += n
            }
        }
        try check(fsync(fd) == 0)
        if created { try check(fsync(dfd) == 0) }
    }
}

final class RequestJournal {
    static let shared = RequestJournal()
    private let seats: JournalSeatIndex
    private let writer: JournalWriter
    private var watcher: NSObjectProtocol?

    init(directory: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".droidproxy/journal"),
         authDirectory: URL = AuthPaths.authDirectory) {
        seats = JournalSeatIndex(directory: authDirectory)
        writer = JournalWriter(directory: directory)
        watcher = NotificationCenter.default.addObserver(forName: .authDirectoryChanged, object: nil, queue: nil) { [weak self] _ in
            self?.seats.refresh()
        }
    }

    deinit {
        if let watcher { NotificationCenter.default.removeObserver(watcher) }
    }

    func flush(timeout: TimeInterval = 2) { writer.flush(timeout: timeout) }

    func begin(_ request: JournalRequest) -> ResponseObservation {
        ResponseObservation(request: request, bindSeat: seats.bind, emit: writer.enqueue)
    }
}
