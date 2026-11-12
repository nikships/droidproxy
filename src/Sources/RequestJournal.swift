import Foundation
import CryptoKit
import Darwin
import os

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
    struct Fields {
        let model: String?
        let provider: String
        let session: String?
    }

    let endpoint: String
    let forwardedEndpoint: String?
    let origin: String
    private let headers: [(String, String)]
    private let body: String

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

    /// The contract's `$` means end of input; `\z` keeps that on runtimes where `range(of:)` uses ICU, whose `$` also
    /// matches before a final line terminator.
    static func validSession(_ value: String?) -> String? {
        guard let value, value.range(of: #"^[A-Za-z0-9_.:-]{8,128}\z"#, options: .regularExpression) != nil else { return nil }
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
            return validSession(JournalJSON.parse(user)?["session_id"]?.string)
        }
        guard let range = user.range(of: "_session_", options: .backwards) else { return nil }
        return validSession(String(user[range.upperBound...]))
    }

    /// Stores the body unparsed so the forwarding path never pays for JSON parsing.
    init(endpoint: String, forwardedEndpoint: String, headers: [(String, String)], body: String) {
        self.endpoint = Self.path(endpoint)
        let forwarded = Self.path(forwardedEndpoint)
        self.forwardedEndpoint = forwarded == self.endpoint ? nil : forwarded
        self.headers = headers
        self.body = body
        self.origin = headers.contains { $0.0.lowercased() == "x-droidproxy-origin" && $0.1 == "window-primer" } ? "primer" : "client"
    }

    private static let bodyMembers = JournalJSON.Selection(members: [
        "model": .all, "prompt_cache_key": .all, "metadata": JournalJSON.Selection(members: ["user_id": .all])
    ])

    /// Parses the body on every call; an observation calls it once, on a background queue, when the request begins.
    var fields: Fields {
        let json = JournalJSON.parse(body, select: Self.bodyMembers)
        let named = Self.nativeModel(endpoint) ?? json?["model"]?.string
        let model = named?.isEmpty == false ? named : nil
        return Fields(model: model, provider: Self.provider(model: model, path: endpoint), session: Self.session(headers: headers, body: json))
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

    private static let identityLimit = 1 << 20

    private static func fingerprint(_ s: stat) -> Fingerprint {
        Fingerprint(size: s.st_size, seconds: s.st_mtimespec.tv_sec, nanos: s.st_mtimespec.tv_nsec, inode: s.st_ino)
    }

    /// True for an owned regular file, false for a symlink to a regular file or a file owned by someone else,
    /// nil for anything else (those are never opened).
    private static func bindability(_ url: URL) -> Bool? {
        var s = stat()
        guard lstat(url.path, &s) == 0 else { return nil }
        switch s.st_mode & S_IFMT {
        case S_IFREG: return s.st_uid == getuid()
        case S_IFLNK: return stat(url.path, &s) == 0 && s.st_mode & S_IFMT == S_IFREG ? false : nil
        default: return nil
        }
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
        return Self.fingerprint(s)
    }

    /// Whether the path still holds what `entry` was built from: the same bindability and fingerprint.
    private func unchanged(_ entry: Entry) -> Bool {
        guard let bindable = Self.bindability(entry.url), bindable == (entry.identity != nil) else { return false }
        if bindable { return fingerprint(entry.url) == entry.fingerprint }
        var s = stat()
        return stat(entry.url.path, &s) == 0 && Self.fingerprint(s) == entry.fingerprint
    }

    private func identityData(_ url: URL, bindable: Bool) -> (Fingerprint, JournalJSON)? {
        let fd = open(url.path, O_RDONLY | O_NONBLOCK | O_CLOEXEC | (bindable ? O_NOFOLLOW : 0))
        guard fd >= 0 else { return nil }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? handle.close() }
        guard let before = fingerprint(fd, owned: bindable), before.size <= Self.identityLimit,
              let data = try? handle.read(upToCount: Self.identityLimit + 1), data.count <= Self.identityLimit,
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
            guard let bindable = Self.bindability(url), let (before, json) = identityData(url, bindable: bindable),
                  let type = Self.nonempty(json["type"]) else { continue }
            let index = Self.index(type: type, path: url.standardizedFileURL.path)
            let kind = type.lowercased()
            let identity = !bindable ? nil : JournalSeat(
                auth_index: index, role: "served",
                file: name.range(of: #"^[^/\\]+\.json\z"#, options: .regularExpression) == nil ? nil : name,
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
        if let old = entries[index], !old.allSatisfy(unchanged) {
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
            return self.unchanged(entry)
        })
    }
}

final class JournalWriter {
    private struct LockTimeout: Error {}
    private struct Abandoned: Error {}
    private struct State {
        var drops = 0
        var errors = 0
        var lastError: String?
        var reportScheduled = false
        /// Accepted records whose writer-queue work has not ended; at most `capacity`.
        var queued = 0
        /// Accepted records not yet claimed for writing, whether queued or in flight.
        var unsettled = 0
        var closed = false

        /// True when the caller must schedule the next report.
        mutating func count(drops: Int = 0, errors: Int = 0, error: String? = nil) -> Bool {
            self.drops += drops
            self.errors += errors
            if let error { lastError = error }
            let schedule = !reportScheduled
            reportScheduled = true
            return schedule
        }
    }
    private static let diagnostics = DispatchQueue(label: "io.automaze.droidproxy.journal-diagnostics")
    private static let lockWait: TimeInterval = 1
    private let directory: URL
    private let queue = DispatchQueue(label: "io.automaze.droidproxy.journal-writer")
    /// Counts drops that found the writer state busy. It never runs the log sink, so `flush` can wait for it.
    private let busyDrops = DispatchQueue(label: "io.automaze.droidproxy.journal-busy-drops")
    private let capacity: Int
    private let state = OSAllocatedUnfairLock(initialState: State())
    private let log: (String) -> Void

    init(directory: URL, capacity: Int = 256, log: @escaping (String) -> Void = { NSLog("%@", $0) }) {
        self.directory = directory
        self.capacity = capacity
        self.log = log
    }

    var counters: (drops: Int, errors: Int) {
        state.withLock { (drops: $0.drops, errors: $0.errors) }
    }

    /// Never waits: a full queue, a closed writer, or writer state another thread holds at that instant drops the
    /// record and counts it. `build` runs on the writer queue, so work it does or waits for stays off the caller's thread.
    func enqueue(_ build: @escaping () -> JournalRecord) {
        let capacity = capacity
        let admission = state.withLockIfAvailable { s -> (accepted: Bool, report: Bool) in
            guard !s.closed, s.queued < capacity else { return (false, s.count(drops: 1)) }
            s.queued += 1
            s.unsettled += 1
            return (true, false)
        }
        guard let admission else {
            // DispatchQueue.async only enqueues the block, so the caller never waits to count this drop.
            return busyDrops.async { self.note(drops: 1) }
        }
        guard admission.accepted else {
            if admission.report { scheduleReport() }
            return
        }
        queue.async {
            defer { self.state.withLock { $0.queued -= 1 } }
            var claimed = false
            do {
                guard !self.isClosed else { throw Abandoned() }
                let record = build()
                guard !self.isClosed else { throw Abandoned() }
                try self.append(record) {
                    claimed = self.claim()
                    return claimed
                }
            } catch {
                self.failed(error, claimed: claimed)
            }
        }
    }

    /// Waits at most `timeout` for accepted records and busy-lock drop counts. Every record not yet claimed for writing
    /// then, queued or in flight, is counted as dropped and never written; the report is logged on the diagnostics queue
    /// so a stalled log sink cannot hold the caller.
    func flush(timeout: TimeInterval = 2) {
        let done = DispatchGroup()
        for queue in [queue, busyDrops] {
            done.enter()
            queue.async { done.leave() }
        }
        guard done.wait(timeout: .now() + timeout) == .timedOut else { return }
        state.withLock { s in
            s.closed = true
            s.drops += s.unsettled
            s.unsettled = 0
        }
        Self.diagnostics.async { self.report() }
    }

    private var isClosed: Bool {
        state.withLock { $0.closed }
    }

    /// Takes the record out of the shutdown count just before its bytes are written; false once flush has counted it.
    private func claim() -> Bool {
        state.withLock { s in
            guard !s.closed else { return false }
            s.unsettled -= 1
            return true
        }
    }

    /// An unclaimed record after the flush deadline was already counted as dropped there.
    private func failed(_ error: Error, claimed: Bool) {
        let counted = state.withLock { s -> Bool in
            if !claimed && !s.closed { s.unsettled -= 1 }
            return !claimed && s.closed
        }
        guard !counted else { return }
        if error is LockTimeout { note(drops: 1) } else { note(errors: 1, error: error.localizedDescription) }
    }

    /// Counts are updated at once; the log line is emitted later on another queue, at most once per interval.
    private func note(drops: Int = 0, errors: Int = 0, error: String? = nil) {
        if state.withLock({ $0.count(drops: drops, errors: errors, error: error) }) { scheduleReport() }
    }

    private func scheduleReport() {
        Self.diagnostics.asyncAfter(deadline: .now() + 5) { [weak self] in self?.report() }
    }

    private func report() {
        let (drops, errors, error) = state.withLock { s in
            s.reportScheduled = false
            return (s.drops, s.errors, s.lastError)
        }
        log("[RequestJournal] \(drops) records dropped, \(errors) write errors" + (error.map { "; last error: \($0)" } ?? ""))
    }

    private func lockExclusive(_ fd: Int32) throws {
        let deadline = Date().addingTimeInterval(Self.lockWait)
        while flock(fd, LOCK_EX | LOCK_NB) != 0 {
            guard errno == EWOULDBLOCK || errno == EINTR else { return try check(false) }
            guard !isClosed else { throw Abandoned() }
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

    /// `claim` is asked once the file lock is held; when it returns false nothing is written.
    func append(_ record: JournalRecord, claim: () -> Bool = { true }) throws {
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
        guard claim() else { throw Abandoned() }
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
        let encoder = JSONEncoder()
        encoder.outputFormatting = .withoutEscapingSlashes
        var data = try encoder.encode(record)
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
    private let refreshes = DispatchQueue(label: "io.automaze.droidproxy.journal-seat-refresh", qos: .utility)
    private var watcher: NSObjectProtocol?

    init(directory: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".droidproxy/journal"),
         authDirectory: URL = AuthPaths.authDirectory) {
        seats = JournalSeatIndex(directory: authDirectory)
        writer = JournalWriter(directory: directory)
        watcher = NotificationCenter.default.addObserver(forName: .authDirectoryChanged, object: nil, queue: nil) { [weak self] _ in
            self?.refreshes.async { self?.seats.refresh() }
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
