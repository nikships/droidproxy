import Foundation

/// Last-observed subscription quota for one Meta Muse account.
///
/// Meta exposes no usage endpoint (the muse CLI notes its Meta provider
/// "carries no subscription-usage probe"): the 5-hour window and weekly
/// percents arrive as a `response.subscription_usage` SSE event on the
/// `/v1/responses` stream, and `muse /usage` renders the last-observed values
/// "as of" their arrival. ThinkingProxy sniffs that event while relaying Meta
/// Responses traffic and records it here so Settings shows the same numbers.
struct MetaMuseUsageSnapshot: Codable, Equatable {
    var windowUsedPercent: Double
    var windowResetsAt: Date
    var windowDurationMins: Double
    var weeklyUsedPercent: Double
    var weeklyResetsAt: Date
    var tier: String?
    var observedAt: Date
}

/// Parses `response.subscription_usage` SSE data lines. Observed shape:
/// `data: {"subscription":{"tier":"...","weekly":{"resets_at":N,"used_percent":N},
/// "window":{"resets_at":N,"used_percent":N,"window_duration_mins":300}},
/// "type":"response.subscription_usage"}`. Non-streaming `/v1/responses`
/// responses carry no `subscription` object, so only the stream is sniffed.
enum MetaMuseUsageEvent {
    private struct Payload: Decodable {
        struct Window: Decodable {
            let resets_at: Double
            let used_percent: Double
            let window_duration_mins: Double?
        }
        struct Weekly: Decodable {
            let resets_at: Double
            let used_percent: Double
        }
        struct Subscription: Decodable {
            let tier: String?
            let weekly: Weekly
            let window: Window
        }
        let type: String
        let subscription: Subscription?
    }

    /// The 5-hour window all subscription accounts report.
    static let defaultWindowDurationMins = 300.0

    static func parse(dataLine: String, observedAt: Date) -> MetaMuseUsageSnapshot? {
        var jsonText = dataLine
        if jsonText.hasPrefix("data:") {
            jsonText = String(jsonText.dropFirst("data:".count))
        }
        guard let jsonData = jsonText.trimmingCharacters(in: .whitespaces).data(using: .utf8),
              let payload = try? JSONDecoder().decode(Payload.self, from: jsonData),
              payload.type == "response.subscription_usage",
              let subscription = payload.subscription else {
            return nil
        }
        return MetaMuseUsageSnapshot(
            windowUsedPercent: min(100, max(0, subscription.window.used_percent)),
            windowResetsAt: Date(timeIntervalSince1970: subscription.window.resets_at),
            windowDurationMins: subscription.window.window_duration_mins ?? defaultWindowDurationMins,
            weeklyUsedPercent: min(100, max(0, subscription.weekly.used_percent)),
            weeklyResetsAt: Date(timeIntervalSince1970: subscription.weekly.resets_at),
            tier: subscription.tier,
            observedAt: observedAt
        )
    }
}

/// Splits relayed Meta response bytes into SSE lines and pulls out usage
/// snapshots. Pure: callers record the returned snapshots. Relayed bytes are
/// never modified — the proxy forwards them unchanged.
enum MetaMuseUsageSniffer {
    /// Incomplete trailing line carried across chunks is capped so a
    /// non-SSE body cannot grow the buffer without bound.
    static let maxPendingCount = 16 * 1024

    static func scan(chunk: Data, pending: String) -> (pending: String, snapshots: [MetaMuseUsageSnapshot]) {
        scan(chunk: chunk, pending: pending, observedAt: Date())
    }

    static func scan(chunk: Data, pending: String, observedAt: Date) -> (pending: String, snapshots: [MetaMuseUsageSnapshot]) {
        var buffer = pending + String(decoding: chunk, as: UTF8.self)
        var snapshots: [MetaMuseUsageSnapshot] = []
        while let newline = buffer.firstIndex(of: "\n") {
            let rawLine = String(buffer[..<newline])
            buffer = String(buffer[buffer.index(after: newline)...])
            let line = rawLine.hasSuffix("\r") ? String(rawLine.dropLast()) : rawLine
            guard line.hasPrefix("data:"), line.contains("response.subscription_usage"),
                  let snapshot = MetaMuseUsageEvent.parse(dataLine: line, observedAt: observedAt) else {
                continue
            }
            snapshots.append(snapshot)
        }
        if buffer.count > maxPendingCount {
            buffer = String(buffer.suffix(maxPendingCount))
        }
        return (buffer, snapshots)
    }
}

/// Persists last-observed Meta usage per account id next to the credential
/// store. Thread-safe: ThinkingProxy records from its relay queues while
/// Settings reads on main.
final class MetaMuseUsageStore {
    static let shared = MetaMuseUsageStore(directory: FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".droidproxy/meta"))

    let directory: URL
    var usageURL: URL { directory.appendingPathComponent("usage.json") }
    private let lock = NSRecursiveLock()
    private let decoder: JSONDecoder
    private let encoder: JSONEncoder

    init(directory: URL) {
        self.directory = directory
        decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        encoder.outputFormatting = [.sortedKeys]
    }

    func snapshot(for accountID: String) -> MetaMuseUsageSnapshot? {
        lock.lock()
        defer { lock.unlock() }
        return (try? load())?[accountID]
    }

    func record(accountID: String, snapshot: MetaMuseUsageSnapshot) {
        lock.lock()
        do {
            var snapshots = (try? load()) ?? [:]
            snapshots[accountID] = snapshot
            try write(snapshots)
        } catch {
            NSLog("[Meta] Could not record usage snapshot: %@", error.localizedDescription)
            lock.unlock()
            return
        }
        lock.unlock()
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: .metaUsageChanged, object: self)
        }
    }

    func remove(accountID: String) {
        lock.lock()
        defer { lock.unlock() }
        do {
            var snapshots = (try? load()) ?? [:]
            guard snapshots.removeValue(forKey: accountID) != nil else { return }
            try write(snapshots)
        } catch {
            NSLog("[Meta] Could not remove usage snapshot: %@", error.localizedDescription)
        }
    }

    private func load() throws -> [String: MetaMuseUsageSnapshot] {
        guard FileManager.default.fileExists(atPath: usageURL.path) else { return [:] }
        return try decoder.decode([String: MetaMuseUsageSnapshot].self, from: Data(contentsOf: usageURL))
    }

    private func write(_ snapshots: [String: MetaMuseUsageSnapshot]) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        try encoder.encode(snapshots).write(to: usageURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: usageURL.path)
    }
}
