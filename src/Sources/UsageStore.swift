import Foundation

@MainActor
class UsageStore: ObservableObject {
    @Published var claudeUsage: ProviderUsageSnapshot?
    @Published var codexUsage: ProviderUsageSnapshot?
    
    private var timer: Timer?
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
    }
    
    func refresh() {
        Task {
            async let claude = claudeProbe.fetchUsage()
            async let codex = codexProbe.fetchUsage()
            
            let (cUsage, cxUsage) = await (claude, codex)
            
            await MainActor.run {
                self.claudeUsage = cUsage
                self.codexUsage = cxUsage
                NotificationCenter.default.post(name: .usageUpdated, object: nil)
            }
        }
    }
    
    func scheduleTimer() {
        timer?.invalidate()
        let interval = Double(AppPreferences.usageAutoRefreshSeconds)
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.refresh()
            }
        }
    }
}
