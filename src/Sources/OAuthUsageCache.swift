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
    private var inFlight: [String: (generation: Int, task: Task<OAuthAccountUsage, Never>)] = [:]
    /// Bumped by `invalidate`: a fetch started before the bump must not
    /// satisfy later readers or repopulate the dropped sample.
    private var generations: [String: Int] = [:]

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

    private func key(for account: AuthAccount) -> String {
        "\(account.type.rawValue):\(account.filePath.standardizedFileURL.path)"
    }

    /// The last stored sample for an account, without fetching. Callers
    /// that only need the shape of the quota (e.g. window lengths) must
    /// not spend polling budget to learn it.
    func cachedUsage(for account: AuthAccount) -> OAuthAccountUsage? {
        entries[key(for: account)]?.usage
    }

    func usage(for account: AuthAccount, fetch: @escaping () async -> OAuthAccountUsage) async -> OAuthAccountUsage {
        let key = key(for: account)
        let generation = generations[key] ?? 0
        if let running = inFlight[key], running.generation == generation { return await running.task.value }
        if let entry = entries[key], now() < entry.nextAttemptAt { return entry.usage }

        let interval: TimeInterval
        switch account.type {
        case .claude: interval = 300
        case .antigravity: interval = 60
        default: interval = 15
        }
        // Persist the request reservation before starting: a restart cannot immediately retry it.
        let placeholder = OAuthAccountUsage(id: account.id, provider: account.type, email: account.displayName, error: "Usage refresh pending")
        var entry = entries[key] ?? Entry(usage: placeholder, nextAttemptAt: now(), rateLimitFailures: 0)
        entry.nextAttemptAt = now().addingTimeInterval(interval)
        entries[key] = entry
        persist()

        let task = Task {
            let result = await fetch()
            return finish(result, key: key, interval: interval, generation: generation)
        }
        inFlight[key] = (generation: generation, task: task)
        return await task.value
    }

    private func finish(_ result: OAuthAccountUsage, key: String, interval: TimeInterval, generation: Int) -> OAuthAccountUsage {
        var usage = result
        let previous = entries[key]
        if result.error != nil, let cached = previous?.usage, !cached.windows.isEmpty {
            usage.windows = cached.windows
            usage.updatedAt = cached.updatedAt
            usage.bankedResets = cached.bankedResets
            usage.codexResetCredits = cached.codexResetCredits
            usage.claudeResetState = cached.claudeResetState
        }
        // A fetch that started before an invalidation still answers its own
        // awaiters, but its pre-invalidation sample must not come back.
        guard generation == (generations[key] ?? 0) else { return usage }
        let failures = result.rateLimited ? min(5, (previous?.rateLimitFailures ?? 0) + 1) : (result.error == nil ? 0 : previous?.rateLimitFailures ?? 0)
        entries[key] = Entry(
            usage: usage,
            nextAttemptAt: rateLimitedNextAttempt(failures: failures, rateLimited: result.rateLimited, interval: interval, provider: usage.provider, retryAfter: result.retryAfter),
            rateLimitFailures: failures
        )
        if inFlight[key]?.generation == generation { inFlight[key] = nil }
        persist()
        return usage
    }

    private func rateLimitedNextAttempt(failures: Int, rateLimited: Bool, interval: TimeInterval, provider: ServiceType, retryAfter: Date?) -> Date {
        let backoff = rateLimited ? min(3600, 300 * pow(2, Double(max(0, failures - 1)))) : interval
        let next = now().addingTimeInterval(backoff + (provider == .claude ? jitter() : 0))
        return max(next, retryAfter ?? next)
    }

    /// Records a 429 from a quota-adjacent call that is not itself a quota
    /// fetch (a banked-reset redemption), so the shared budget backs off
    /// instead of letting retries hammer the provider.
    func recordRateLimit(for account: AuthAccount, retryAfter: Date?) {
        let key = key(for: account)
        let interval: TimeInterval = account.type == .claude ? 300 : 15
        let failures = min(5, (entries[key]?.rateLimitFailures ?? 0) + 1)
        let placeholder = OAuthAccountUsage(id: account.id, provider: account.type, email: account.displayName, error: "Usage refresh pending")
        var entry = entries[key] ?? Entry(usage: placeholder, nextAttemptAt: now(), rateLimitFailures: 0)
        entry.rateLimitFailures = failures
        entry.usage.rateLimited = true
        entry.nextAttemptAt = rateLimitedNextAttempt(failures: failures, rateLimited: true, interval: interval, provider: account.type, retryAfter: retryAfter)
        entries[key] = entry
        persist()
    }

    /// Drops the stored sample so the next read refetches even inside the
    /// polling budget (e.g. right after a banked reset changed the quota).
    /// Generation-aware: a fetch already in flight from before the
    /// invalidation cannot satisfy later readers or write its older
    /// sample back when it lands.
    func invalidate(for account: AuthAccount) {
        let key = key(for: account)
        entries[key] = nil
        generations[key] = (generations[key] ?? 0) + 1
        inFlight[key] = nil
        persist()
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
