import Foundation

@MainActor
class UsageStore: ObservableObject {
    @Published var claudeUsage: ProviderUsageSnapshot?
    @Published var codexUsage: ProviderUsageSnapshot?
    
    private var timer: Timer?
    private var refreshTask: Task<Void, Never>?
    private let claudeProbe = ClaudeUsageProbe()
    private let codexProbe = CodexUsageProbe()

    static let shared = UsageStore()

    init() {}

    func start() {
        refresh()
        scheduleTimer()
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        refreshTask?.cancel()
        refreshTask = nil
    }

    func refresh() {
        refreshTask?.cancel()
        refreshTask = Task { [weak self] in
            guard let self else { return }
            async let claude = claudeProbe.fetchUsage()
            async let codex = codexProbe.fetchUsage()

            let (cUsage, cxUsage) = await (claude, codex)
            guard !Task.isCancelled else { return }

            self.claudeUsage = cUsage
            self.codexUsage = cxUsage
            NotificationCenter.default.post(name: .usageUpdated, object: nil)
        }
    }

    func scheduleTimer() {
        timer?.invalidate()
        timer = nil
        let interval = Double(AppPreferences.usageAutoRefreshSeconds)
        guard interval > 0 else { return }
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.refresh()
            }
        }
    }
}
