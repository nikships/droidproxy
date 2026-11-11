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

    static func session(headers: [(String, String)], body: [String: Any]) -> String? {
        for key in ["x-session-id", "x-claude-code-session-id"] {
            for (name, value) in headers where name.lowercased() == key {
                if let id = validSession(value.trimmingCharacters(in: CharacterSet(charactersIn: " \t"))) { return id }
            }
        }
        if let id = validSession(body["prompt_cache_key"] as? String) { return id }
        guard let metadata = body["metadata"] as? [String: Any], let user = metadata["user_id"] as? String else { return nil }
        if user.hasPrefix("{") {
            guard let object = try? JSONSerialization.jsonObject(with: Data(user.utf8)) as? [String: Any] else { return nil }
            return validSession(object["session_id"] as? String)
        }
        guard let range = user.range(of: "_session_", options: .backwards) else { return nil }
        return validSession(String(user[range.upperBound...]))
    }

    init(endpoint: String, forwardedEndpoint: String, headers: [(String, String)], body: [String: Any]) {
        self.endpoint = Self.path(endpoint)
        let forwarded = Self.path(forwardedEndpoint)
        self.forwardedEndpoint = forwarded == self.endpoint ? nil : forwarded
        let model = Self.nativeModel(self.endpoint) ?? (body["model"] as? String)
        self.model = model?.isEmpty == false ? model : nil
        self.provider = Self.provider(model: self.model, path: self.endpoint)
        self.session = Self.session(headers: headers, body: body)
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
    private struct Entry {
        let url: URL
        let fingerprint: Fingerprint
        let identity: JournalSeat
    }
    private let directory: URL
    private let lock = NSRecursiveLock()
    private var entries: [String: [Entry]] = [:]
    private var refreshed: TimeInterval = -.infinity

    init(directory: URL) { self.directory = directory }

    static func index(type: String, path: String) -> String {
        SHA256.hash(data: Data("\(type.lowercased()):\((path as NSString).standardizingPath)".utf8))
            .prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    private func fingerprint(_ url: URL) -> Fingerprint? {
        let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        return fingerprint(fd)
    }

    private func fingerprint(_ fd: Int32) -> Fingerprint? {
        var s = stat()
        guard fstat(fd, &s) == 0, s.st_mode & S_IFMT == S_IFREG, s.st_uid == getuid() else { return nil }
        return Fingerprint(size: s.st_size, seconds: s.st_mtimespec.tv_sec, nanos: s.st_mtimespec.tv_nsec, inode: s.st_ino)
    }

    private func identityData(_ url: URL) -> (Fingerprint, [String: Any])? {
        let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { return nil }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? handle.close() }
        guard let before = fingerprint(fd), let data = try? handle.readToEnd(),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              fingerprint(fd) == before, fingerprint(url) == before else { return nil }
        return (before, json)
    }

    func refresh() {
        lock.lock()
        defer { lock.unlock() }
        var next: [String: [Entry]] = [:]
        for url in (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
            where url.pathExtension == "json" {
            guard let (before, json) = identityData(url),
                  let type = json["type"] as? String, !type.isEmpty else { continue }
            let index = Self.index(type: type, path: url.standardizedFileURL.path)
            let identity = JournalSeat(
                auth_index: index, role: "served", file: url.lastPathComponent,
                email: ClaudeAuthSeatFiles.nonemptyString(json["email"]),
                org: type.lowercased() == "claude" ? ClaudeAuthSeatFiles.organizationFields(from: json).uuid : nil,
                account_id: type.lowercased() == "codex" ? ClaudeAuthSeatFiles.nonemptyString(json["account_id"]) : nil
            )
            next[index, default: []].append(Entry(url: url, fingerprint: before, identity: identity))
        }
        entries = next
        refreshed = ProcessInfo.processInfo.systemUptime
    }

    func bind(_ index: String) -> JournalSeatBinding? {
        lock.lock()
        defer { lock.unlock() }
        if let old = entries[index], old.contains(where: { fingerprint($0.url) != $0.fingerprint }) {
            refresh()
        } else if entries[index] == nil && ProcessInfo.processInfo.systemUptime - refreshed >= 1 {
            refresh()
        }
        guard let matches = entries[index], matches.count == 1, let entry = matches.first else { return nil }
        return JournalSeatBinding(identity: entry.identity, isValid: { [weak self] in
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
    private let directory: URL
    private let queue = DispatchQueue(label: "io.automaze.droidproxy.journal-writer")
    private let slots: DispatchSemaphore
    private let lock = NSLock()
    private var counts = (drops: 0, errors: 0)

    init(directory: URL, capacity: Int = 256) {
        self.directory = directory
        self.slots = DispatchSemaphore(value: capacity)
    }

    var counters: (drops: Int, errors: Int) {
        lock.lock()
        defer { lock.unlock() }
        return counts
    }

    func enqueue(_ record: JournalRecord) {
        guard slots.wait(timeout: .now()) == .success else {
            lock.lock()
            counts.drops += 1
            lock.unlock()
            NSLog("[RequestJournal] Queue full; record dropped")
            return
        }
        queue.async {
            defer { self.slots.signal() }
            do { try self.append(record) }
            catch {
                self.lock.lock()
                self.counts.errors += 1
                self.lock.unlock()
                NSLog("[RequestJournal] Append failed: %@", error.localizedDescription)
            }
        }
    }

    func flush() { queue.sync {} }

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
        while flock(fd, LOCK_EX) != 0 { if errno != EINTR { try check(false) } }
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

    func flush() { writer.flush() }

    func begin(_ request: JournalRequest) -> ResponseObservation {
        ResponseObservation(request: request, bindSeat: seats.bind, emit: writer.enqueue)
    }
}
