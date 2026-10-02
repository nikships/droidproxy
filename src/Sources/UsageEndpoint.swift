import Foundation

/// `GET /droidproxy/usage` on ThinkingProxy's port: answers locally (never
/// forwarded upstream) with live OAuth quota windows as JSON. The Settings
/// gauges copy a `curl` for this endpoint so an agent can poll its own quota
/// and pause before it runs dry, since Droid stops retrying failed requests
/// after roughly 30 seconds.
///
/// Query parameters (both optional):
/// - `provider`: `codex`, `claude`, `grok`, or `meta`
/// - `account`: the auth file name, email, or Settings display name
enum UsageEndpoint {
    static let path = "/droidproxy/usage"

    struct Filter: Hashable {
        var provider: String?
        var account: String?
    }

    struct Response {
        let statusCode: Int
        let body: Data
    }

    /// Returns the parsed filter when `requestPath` addresses this endpoint.
    static func filter(forRequestPath requestPath: String) -> Filter? {
        guard let components = URLComponents(string: requestPath), components.path == path else {
            return nil
        }
        let items = components.queryItems ?? []
        func value(_ name: String) -> String? {
            items.first { $0.name == name }?.value.flatMap { $0.isEmpty ? nil : $0 }
        }
        return Filter(provider: value("provider")?.lowercased(), account: value("account"))
    }

    /// The command the Settings gauges copy. Uses the configured bind address
    /// when one is set, since `localhost` would not reach a specific interface.
    static var proxyHost: String {
        let bind = AppPreferences.bindAddress
        return (bind == "0.0.0.0" || bind.isEmpty) ? "127.0.0.1" : bind
    }

    static func curlCommand(provider: ServiceType, accountID: String, proxyPort: UInt16 = 8317) -> String {
        let host = proxyHost
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "&+=#")
        let encodedAccount = accountID.addingPercentEncoding(withAllowedCharacters: allowed) ?? accountID
        return "curl -s 'http://\(host):\(proxyPort)\(path)?provider=\(provider.rawValue)&account=\(encodedAccount)'"
    }

    static func respond(to filter: Filter, now: Date = Date()) async -> Response {
        let snapshot = AuthManager().loadAccountsSnapshot()
        let enabled = enabledProviders()
        func isEnabled(_ type: ServiceType) -> Bool { enabled[type.rawValue] ?? true }

        func candidates(_ type: ServiceType) -> [AuthAccount] {
            if let provider = filter.provider, provider != type.rawValue { return [] }
            return (snapshot[type] ?? []).filter { account in
                guard let wanted = filter.account else { return true }
                return matches(account, wanted)
            }
        }

        let codex = isEnabled(.codex) ? candidates(.codex).filter { !$0.isDisabled && !$0.isExpired } : []
        let claude = isEnabled(.claude) ? candidates(.claude).filter { !$0.isDisabled && !$0.isExpired } : []
        let grok = isEnabled(.grok) ? OAuthUsageTracker.activeGrokAccounts(candidates(.grok)) : []
        let meta = isEnabled(.meta) ? candidates(.meta).filter { !$0.isDisabled } : []

        guard !(codex.isEmpty && claude.isEmpty && grok.isEmpty && meta.isEmpty) else {
            let known = [ServiceType.codex, .claude, .grok, .meta].flatMap { snapshot[$0] ?? [] }
            return Response(statusCode: 404, body: encode([
                "error": "No matching enabled OAuth account",
                "available": known.map { ["provider": $0.type.rawValue, "account": $0.displayName, "id": $0.id] }
            ]))
        }

        let usages: [OAuthAccountUsage]
        if let cached = cachedUsages(for: filter, now: now) {
            usages = cached
        } else {
            usages = await OAuthUsageTracker.fetchUsage(codex: codex, claude: claude, grok: grok, meta: meta)
            storeUsages(usages, for: filter, now: now)
        }
        return Response(statusCode: 200, body: json(for: usages, now: now))
    }

    /// Agents may poll in a loop, and the upstream usage APIs (Anthropic's in
    /// particular) rate-limit hard, so successful results are reused briefly.
    /// Reset countdowns are recomputed per response from the cached dates.
    private static let cacheTTL: TimeInterval = 15
    private static let cacheLock = NSLock()
    private static var cache: [Filter: (storedAt: Date, usages: [OAuthAccountUsage])] = [:]

    private static func cachedUsages(for filter: Filter, now: Date) -> [OAuthAccountUsage]? {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        guard let entry = cache[filter], now.timeIntervalSince(entry.storedAt) < cacheTTL else { return nil }
        return entry.usages
    }

    private static func storeUsages(_ usages: [OAuthAccountUsage], for filter: Filter, now: Date) {
        guard usages.allSatisfy({ $0.error == nil }) else { return }
        cacheLock.lock()
        defer { cacheLock.unlock() }
        cache[filter] = (now, usages)
    }

    static func json(for usages: [OAuthAccountUsage], now: Date) -> Data {
        let formatter = ISO8601DateFormatter()
        func iso(_ date: Date?) -> Any { date.map(formatter.string(from:)) ?? NSNull() }

        let accounts: [[String: Any]] = usages.map { usage in
            let windows: [[String: Any]] = usage.windows.map { window in
                [
                    "name": window.title,
                    "used_percent": window.usedPercent.map(rounded) ?? NSNull(),
                    "remaining_percent": window.remainingPercent.map(rounded) ?? NSNull(),
                    "resets_at": iso(window.resetDate),
                    "resets_in_seconds": window.resetDate.map { max(0, Int($0.timeIntervalSince(now))) } ?? NSNull()
                ]
            }
            return [
                "provider": usage.provider.rawValue,
                "account": usage.email,
                "id": usage.id,
                "windows": windows,
                "error": usage.error ?? NSNull(),
                "as_of": iso(usage.updatedAt)
            ]
        }
        return encode(["generated_at": formatter.string(from: now), "accounts": accounts])
    }

    private static func rounded(_ value: Double) -> Double {
        (value * 10).rounded() / 10
    }

    private static func matches(_ account: AuthAccount, _ wanted: String) -> Bool {
        let needle = wanted.lowercased()
        return [account.id, account.email, account.displayName]
            .compactMap { $0?.lowercased() }
            .contains(needle)
    }

    private static func enabledProviders() -> [String: Bool] {
        UserDefaults.standard.dictionary(forKey: "enabledProviders") as? [String: Bool] ?? [:]
    }

    private static func encode(_ object: [String: Any]) -> Data {
        (try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]))
            ?? Data("{\"error\":\"encoding failed\"}".utf8)
    }
}
