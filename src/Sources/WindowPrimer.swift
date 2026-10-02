import Foundation

/// Providers whose subscription quota runs in rolling 5-hour windows that start
/// at the first request. Sending one tiny request before the workday starts the
/// clock early, so the window resets mid-session instead of 5 hours after the
/// first real prompt.
enum WindowPrimerProvider: String, CaseIterable, Identifiable {
    case claude
    case codex
    case meta

    var id: String { rawValue }

    var serviceType: ServiceType {
        switch self {
        case .claude: return .claude
        case .codex: return .codex
        case .meta: return .meta
        }
    }

    static let defaultMinutes = 7 * 60

    var enabledKey: String { "windowPrimerEnabled.\(rawValue)" }
    var minutesKey: String { "windowPrimerMinutes.\(rawValue)" }
    var lastFiredKey: String { "windowPrimerLastFired.\(rawValue)" }

    var isEnabled: Bool { UserDefaults.standard.bool(forKey: enabledKey) }

    /// Minutes after local midnight.
    var scheduledMinutes: Int {
        UserDefaults.standard.object(forKey: minutesKey) as? Int ?? Self.defaultMinutes
    }
}

/// Once a day, at each enabled provider's chosen time, sends one tiny request
/// per account so the 5-hour window is already running when the user starts
/// working. Nothing runs unless a provider's toggle is on.
///
/// Meta requests go straight to `api.meta.ai` with each account's own key
/// (the same request `MetaMuseUsageProbe` sends). Claude and Codex go through
/// the local proxy exactly like real traffic, so they reuse its client
/// identity handling. The proxy picks the account, so with several accounts the
/// request is repeated once per enabled account: round-robin spreads them out,
/// and in fill-first mode only the account actually serving traffic matters.
@MainActor
final class WindowPrimer {
    /// Missing the exact minute (app launching late, Mac asleep) still fires,
    /// but not hours later when starting a window would no longer help.
    nonisolated static let catchUpWindow: TimeInterval = 2 * 60 * 60
    /// A failed attempt is retried after this long, until the catch-up window ends.
    nonisolated static let retryDelay: TimeInterval = 5 * 60
    nonisolated static let tickInterval: TimeInterval = 30

    private var timer: Timer?
    private var lastAttempt: [WindowPrimerProvider: Date] = [:]
    private var inFlight: Set<WindowPrimerProvider> = []

    func start() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: Self.tickInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    /// Pure scheduling rule: fire once per day, at or after the scheduled time,
    /// within the catch-up window, and only if it has not fired since then.
    nonisolated static func shouldFire(
        now: Date,
        scheduledMinutes: Int,
        lastFired: Date?,
        calendar: Calendar = .current
    ) -> Bool {
        guard let scheduled = calendar.date(
            byAdding: .minute,
            value: scheduledMinutes,
            to: calendar.startOfDay(for: now)
        ) else { return false }
        guard now >= scheduled, now.timeIntervalSince(scheduled) < catchUpWindow else { return false }
        return lastFired.map { $0 < scheduled } ?? true
    }

    private func tick(now: Date = Date()) {
        for provider in WindowPrimerProvider.allCases where provider.isEnabled {
            let lastFired = UserDefaults.standard.object(forKey: provider.lastFiredKey) as? Date
            guard Self.shouldFire(now: now, scheduledMinutes: provider.scheduledMinutes, lastFired: lastFired),
                  !inFlight.contains(provider) else { continue }
            if let last = lastAttempt[provider], now.timeIntervalSince(last) < Self.retryDelay { continue }
            fire(provider, now: now)
        }
    }

    private func fire(_ provider: WindowPrimerProvider, now: Date) {
        lastAttempt[provider] = now
        inFlight.insert(provider)
        Task {
            let sent = await Self.sendPrimers(for: provider)
            inFlight.remove(provider)
            if sent > 0 {
                UserDefaults.standard.set(Date(), forKey: provider.lastFiredKey)
            }
            NSLog("[WindowPrimer] %@: %d request(s) started a window", provider.rawValue, sent)
        }
    }

    /// Returns how many requests succeeded. Zero also covers "no accounts".
    nonisolated static func sendPrimers(for provider: WindowPrimerProvider) async -> Int {
        let isEnabled = (UserDefaults.standard.dictionary(forKey: "enabledProviders") as? [String: Bool])?[provider.serviceType.rawValue] ?? true
        guard isEnabled else { return 0 }

        if provider == .meta {
            let ids = MetaMuseCredentialStore.shared.accounts
                .filter { !$0.disabled && $0.credentials.apiKeyExpiresAt > Date() }
                .map(\.id)
            var sent = 0
            for id in ids where await MetaMuseUsageProbe.refresh(accountID: id, force: true) {
                sent += 1
            }
            return sent
        }

        let accounts = (AuthManager().loadAccountsSnapshot()[provider.serviceType] ?? [])
            .filter { !$0.isDisabled && !$0.isExpired }
        var sent = 0
        for _ in accounts {
            if await sendThroughProxy(provider) { sent += 1 }
        }
        return sent
    }

    nonisolated static func proxyRequest(for provider: WindowPrimerProvider) -> (path: String, body: String)? {
        switch provider {
        case .claude:
            return ("/v1/messages", #"{"model":"claude-haiku-4-5-20251001","max_tokens":1,"messages":[{"role":"user","content":"hi"}]}"#)
        case .codex:
            return ("/v1/chat/completions", #"{"model":"gpt-6-luna","max_tokens":16,"messages":[{"role":"user","content":"hi"}]}"#)
        case .meta:
            return nil
        }
    }

    nonisolated private static func sendThroughProxy(_ provider: WindowPrimerProvider) async -> Bool {
        guard let spec = proxyRequest(for: provider),
              let url = URL(string: "http://\(UsageEndpoint.proxyHost):8317\(spec.path)") else { return false }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 60
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.httpBody = Data(spec.body.utf8)
        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            if !(200..<300).contains(status) {
                NSLog("[WindowPrimer] %@ request returned HTTP %d", provider.rawValue, status)
            }
            return (200..<300).contains(status)
        } catch {
            NSLog("[WindowPrimer] %@ request failed: %@", provider.rawValue, error.localizedDescription)
            return false
        }
    }
}
