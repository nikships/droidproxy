import Foundation

enum UsageWindowKind: String, Codable {
    case hourly
    case daily
    case weekly
    case monthly
    case other
}

struct UsageWindow: Codable {
    let kind: UsageWindowKind
    let limit: Int
    let used: Int
    let percentUsed: Double // 0-100
    let resetsAt: Date?
}

struct ProviderUsageSnapshot: Codable {
    let provider: String // "Claude" or "Codex"
    let lastUpdated: Date
    let windows: [UsageWindow]
    let error: String?
}
