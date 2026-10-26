import Foundation

/// One budget per credential file, shared by Settings, /usage (all filters), and /models.
/// An actor keeps concurrent readers on the same task, including across token rotation.
actor OAuthUsageCache {
    static let shared = OAuthUsageCache(
        fileURL: FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".droidproxy/usage-cache.json")
    )

    private struct Entry: Codable {
        var usage: OAuthAccountUsage
        var nextAttemptAt: Date
        var rateLimitFailures: Int
    }

    private let fileURL: URL?
    private let now: () -> Date
    private let jitter: () -> TimeInterval
    private var entries: [String: Entry]
    private var inFlight: [String: Task<OAuthAccountUsage, Never>] = [:]

    init(fileURL: URL? = nil, now: @escaping () -> Date = Date.init, jitter: @escaping () -> TimeInterval = { Double.random(in: 0...30) }) {
        self.fileURL = fileURL
        self.now = now
        self.jitter = jitter
        if let fileURL, let data = try? Data(contentsOf: fileURL),
           let saved = try? JSONDecoder().decode([String: Entry].self, from: data) {
            entries = saved
        } else {
            entries = [:]
        }
    }

    func usage(for account: AuthAccount, fetch: @escaping () async -> OAuthAccountUsage) async -> OAuthAccountUsage {
        let key = "\(account.type.rawValue):\(account.filePath.standardizedFileURL.path)"
        if let task = inFlight[key] { return await task.value }
        if let entry = entries[key], now() < entry.nextAttemptAt { return entry.usage }

        let interval: TimeInterval = account.type == .claude ? 300 : 15
        // Persist the request reservation before starting: a restart cannot immediately retry it.
        let placeholder = OAuthAccountUsage(id: account.id, provider: account.type, email: account.displayName, error: "Usage refresh pending")
        var entry = entries[key] ?? Entry(usage: placeholder, nextAttemptAt: now(), rateLimitFailures: 0)
        entry.nextAttemptAt = now().addingTimeInterval(interval)
        entries[key] = entry
        persist()

        let task = Task {
            let result = await fetch()
            return finish(result, key: key, interval: interval)
        }
        inFlight[key] = task
        return await task.value
    }

    private func finish(_ result: OAuthAccountUsage, key: String, interval: TimeInterval) -> OAuthAccountUsage {
        var usage = result
        let previous = entries[key]
        if result.error != nil, let cached = previous?.usage, !cached.windows.isEmpty {
            usage.windows = cached.windows
            usage.updatedAt = cached.updatedAt
        }
        let failures = result.rateLimited ? min(5, (previous?.rateLimitFailures ?? 0) + 1) : (result.error == nil ? 0 : previous?.rateLimitFailures ?? 0)
        let backoff = result.rateLimited ? min(3600, 300 * pow(2, Double(max(0, failures - 1)))) : interval
        let next = now().addingTimeInterval(backoff + (usage.provider == .claude ? jitter() : 0))
        entries[key] = Entry(usage: usage, nextAttemptAt: max(next, result.retryAfter ?? next), rateLimitFailures: failures)
        inFlight[key] = nil
        persist()
        return usage
    }

    private func persist() {
        guard let fileURL else { return }
        do {
            let manager = FileManager.default
            try manager.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let data = try JSONEncoder().encode(entries)
            let temporary = fileURL.deletingLastPathComponent().appendingPathComponent(".usage-cache-\(UUID().uuidString).tmp")
            defer { try? manager.removeItem(at: temporary) }
            guard manager.createFile(atPath: temporary.path, contents: data, attributes: [.posixPermissions: 0o600]),
                  rename(temporary.path, fileURL.path) == 0 else {
                throw CocoaError(.fileWriteUnknown)
            }
        } catch {
            NSLog("[Usage] Could not save the quota polling cache.")
        }
    }

    nonisolated static func retryDate(_ value: String?, now: Date) -> Date? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if let seconds = Double(trimmed), seconds.isFinite, seconds >= 0 {
            return now.addingTimeInterval(seconds)
        }
        let format = DateFormatter()
        format.locale = Locale(identifier: "en_US_POSIX")
        format.timeZone = TimeZone(secondsFromGMT: 0)
        format.dateFormat = "EEE, dd MMM yyyy HH:mm:ss z"
        return format.date(from: trimmed)
    }
}
