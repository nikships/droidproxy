import Foundation

/// Whether a DroidProxy model can run right now, for `GET /droidproxy/control/models`.
enum ModelAvailability: Equatable {
    case ok
    /// Every usable account is out of quota in a window that covers the model;
    /// `until` is when the first of them comes back, nil when nobody says.
    case exhausted(until: Date?, window: String, account: String?)
    case signedOut
    case disabled
    case unknown
}

enum AvailabilityJudge {
    struct Account: Equatable {
        let id: String
        /// The email (or login) to name in an `exhausted` answer.
        let label: String?
        /// Not expired, not disabled, and one the proxy really sends requests with.
        let usable: Bool
    }

    /// Providers DroidProxy reads quota for (`OAuthUsageTracker`).
    static let providersWithUsage: Set<ServiceType> = [.claude, .codex, .grok, .meta]

    /// Model families a usage window can be named for, as in Claude's
    /// "Weekly (Opus)" and "Weekly (Sonnet)".
    static let modelFamilies: Set<String> = ["opus", "sonnet", "haiku", "fable"]

    /// Claude's per-product weekly buckets ("Weekly (OAuth Apps)", "Weekly (Cowork)",
    /// "Weekly (Omelette)") meter other Anthropic products, not the Claude Code
    /// seat DroidProxy signs in as, so they gate none of its models.
    static let otherProducts: Set<String> = ["oauth apps", "cowork", "omelette"]

    /// A window covers a model unless it is named for another model family or another product.
    static func window(_ title: String, covers baseModel: String) -> Bool {
        guard let open = title.lastIndex(of: "("), let close = title.lastIndex(of: ")"), open < close else {
            return true
        }
        let qualifier = title[title.index(after: open)..<close].trimmingCharacters(in: .whitespaces).lowercased()
        if modelFamilies.contains(qualifier) {
            return baseModel.lowercased().contains(qualifier)
        }
        return !otherProducts.contains(qualifier)
    }

    /// Out of quota and not reset yet. A cached reading can be a few seconds
    /// old, so a window whose reset time has passed no longer counts.
    static func isExhausted(_ window: OAuthUsageWindow, now: Date) -> Bool {
        guard let remaining = window.remainingPercent, remaining <= 0 else { return false }
        if let reset = window.resetDate, reset <= now { return false }
        return true
    }

    /// `usages` are this provider's, by account id.
    static func judge(
        baseModel: String,
        provider: ServiceType,
        providerEnabled: Bool,
        accounts: [Account],
        usages: [String: OAuthAccountUsage],
        now: Date
    ) -> ModelAvailability {
        guard providerEnabled else { return .disabled }
        let usable = accounts.filter(\.usable)
        guard !usable.isEmpty else { return .signedOut }
        guard providersWithUsage.contains(provider) else { return .unknown }

        var anyUsage = false
        var anyFree = false
        var blocked: [(until: Date?, window: String, account: String?)] = []

        for account in usable {
            guard let usage = usages[account.id], usage.error == nil, !usage.windows.isEmpty else {
                anyFree = true
                continue
            }
            anyUsage = true
            let blocking = usage.windows.filter { window($0.title, covers: baseModel) && isExhausted($0, now: now) }
            guard !blocking.isEmpty else {
                anyFree = true
                continue
            }
            // The account is back once the last of its exhausted windows resets.
            if let unknownReset = blocking.first(where: { $0.resetDate == nil }) {
                blocked.append((nil, unknownReset.title, account.label))
            } else if let latest = blocking.max(by: { $0.resetDate! < $1.resetDate! }) {
                blocked.append((latest.resetDate, latest.title, account.label))
            }
        }

        guard anyUsage else { return .unknown }
        if anyFree { return .ok }

        let first = blocked.min { lhs, rhs in
            switch (lhs.until, rhs.until) {
            case let (l?, r?): return l < r
            case (.some, nil): return true
            default: return false
            }
        }
        guard let first else { return .ok }
        return .exhausted(until: first.until, window: first.window, account: first.account)
    }
}
