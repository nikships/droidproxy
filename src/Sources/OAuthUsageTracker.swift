import Combine
import Foundation

struct OAuthUsageWindow: Identifiable, Equatable, Codable {
    let id = UUID()
    let title: String
    let usedPercent: Double?
    let resetText: String?
    let resetDate: Date?
    /// Window length when the provider's payload states it (or the bucket
    /// implies it); nil when unknown. Drives short-window detection.
    let lengthSeconds: Int?

    init(title: String, usedPercent: Double?, resetText: String?, resetDate: Date?, lengthSeconds: Int? = nil) {
        self.title = title
        self.usedPercent = usedPercent
        self.resetText = resetText
        self.resetDate = resetDate
        self.lengthSeconds = lengthSeconds
    }

    private enum CodingKeys: String, CodingKey {
        case title, usedPercent, resetText, resetDate, lengthSeconds
    }

    var remainingPercent: Double? {
        guard let usedPercent else { return nil }
        return max(0, 100 - usedPercent)
    }
}

struct OAuthAccountUsage: Identifiable, Equatable, Codable {
    let id: String
    let provider: ServiceType
    let email: String
    var isLoading = false
    var windows: [OAuthUsageWindow] = []
    var error: String?
    var updatedAt: Date?
    var rateLimited = false
    var retryAfter: Date?
    /// Banked usage resets held by this account (Codex and Claude only).
    var bankedResets: BankedResetCredits?
    /// Full Codex credit list (soonest first) for redemption. Internal
    /// only: never persisted to the usage cache or exposed.
    var codexResetCredits: [CodexResetCredit] = []
    /// Full Claude grant state for redemption. Internal only, as above.
    var claudeResetState: ClaudeResetState?

    private enum CodingKeys: String, CodingKey {
        case id, provider, email, isLoading, windows, error, updatedAt, rateLimited, retryAfter, bankedResets
    }

    /// Bounds a "short" window: the 5-hour class, with slack.
    static let shortWindowMaxSeconds = 6 * 3600

    /// Whether this account's plan includes a short rolling window worth
    /// priming. `known` is false when the payload said nothing either way,
    /// so callers can stay permissive on unknown usage.
    func hasShortWindow() -> (has: Bool, known: Bool) {
        var has = false
        var known = false
        for window in windows {
            if let length = window.lengthSeconds, length > 0 {
                known = true
                if length <= Self.shortWindowMaxSeconds { has = true }
            } else if window.title == "5-hour" {
                has = true
                known = true
            }
        }
        return (has, known)
    }
}

enum OAuthUsageParsing {
    static let requestTimeout: TimeInterval = 15
    static let formURLEncodedAllowedCharacters: CharacterSet = {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return allowed
    }()
}

@MainActor
final class OAuthUsageTracker: ObservableObject {
    @Published private(set) var accounts: [OAuthAccountUsage] = []
    @Published private(set) var isRefreshing = false
    private var refreshTask: Task<Void, Never>?

    deinit {
        refreshTask?.cancel()
    }

    func refresh(codexAccounts: [AuthAccount], claudeAccounts: [AuthAccount], grokAccounts: [AuthAccount] = [], metaAccounts: [AuthAccount] = [], antigravityAccounts: [AuthAccount] = []) {
        refreshTask?.cancel()

        let enabledCodex = codexAccounts.filter { !$0.isDisabled && !$0.isExpired }
        let enabledClaude = claudeAccounts.filter { !$0.isDisabled && !$0.isExpired }
        let enabledGrok = Self.activeGrokAccounts(grokAccounts)
        let enabledMeta = metaAccounts.filter { !$0.isDisabled }
        let enabledAntigravity = antigravityAccounts.filter { !$0.isDisabled && !$0.isExpired }

        guard !enabledCodex.isEmpty || !enabledClaude.isEmpty || !enabledGrok.isEmpty || !enabledMeta.isEmpty || !enabledAntigravity.isEmpty else {
            accounts = []
            isRefreshing = false
            return
        }

        isRefreshing = true
        accounts = enabledCodex.map { Self.loadingPlaceholder(for: $0, provider: .codex) }
            + enabledClaude.map { Self.loadingPlaceholder(for: $0, provider: .claude) }
            + enabledGrok.map { Self.loadingPlaceholder(for: $0, provider: .grok) }
            + enabledMeta.map { Self.loadingPlaceholder(for: $0, provider: .meta) }
            + enabledAntigravity.map { Self.loadingPlaceholder(for: $0, provider: .antigravity) }

        refreshTask = Task { [enabledCodex, enabledClaude, enabledGrok, enabledMeta, enabledAntigravity] in
            let results = await Self.fetchUsage(
                codex: enabledCodex,
                claude: enabledClaude,
                grok: enabledGrok,
                meta: enabledMeta,
                antigravity: enabledAntigravity
            )

            guard !Task.isCancelled else { return }
            self.accounts = results
            self.isRefreshing = false
        }
    }

    /// Fetches usage for already-filtered accounts concurrently. Shared by the
    /// Settings dashboard and ThinkingProxy's `/droidproxy/usage` endpoint.
    nonisolated static func fetchUsage(
        codex: [AuthAccount],
        claude: [AuthAccount],
        grok: [AuthAccount],
        meta: [AuthAccount],
        antigravity: [AuthAccount] = []
    ) async -> [OAuthAccountUsage] {
        await withTaskGroup(of: OAuthAccountUsage.self) { group in
            for account in codex {
                group.addTask {
                    await OAuthUsageCache.shared.usage(for: account) { await fetchCodexUsage(for: account) }
                }
            }
            for account in claude {
                group.addTask {
                    await OAuthUsageCache.shared.usage(for: account) { await fetchClaudeUsage(for: account) }
                }
            }
            for account in grok {
                group.addTask {
                    await OAuthUsageCache.shared.usage(for: account) { await fetchGrokUsage(for: account) }
                }
            }
            for account in meta {
                group.addTask { await fetchMetaUsage(for: account) }
            }
            for account in antigravity {
                group.addTask {
                    await OAuthUsageCache.shared.usage(for: account) { await fetchAntigravityUsage(for: account) }
                }
            }

            var values: [OAuthAccountUsage] = []
            for await result in group {
                values.append(result)
            }
            return sortedAccounts(values)
        }
    }


    /// Replaces only the Meta cards from the local last-observed store. Used
    /// for live updates when ThinkingProxy sniffs a new snapshot, so a Meta
    /// response does not refetch Codex/Claude/Grok usage over the network.
    func updateMetaAccounts(_ metaAccounts: [AuthAccount]) {
        let fresh = metaAccounts.filter { !$0.isDisabled }.map { Self.storedMetaUsage(for: $0) }
        guard accounts.contains(where: { $0.provider == .meta }) || !fresh.isEmpty else { return }
        accounts = Self.sortedAccounts(accounts.filter { $0.provider != .meta } + fresh)
    }

    nonisolated private static func sortedAccounts(_ values: [OAuthAccountUsage]) -> [OAuthAccountUsage] {
        values.sorted {
            if $0.provider.rawValue == $1.provider.rawValue {
                return $0.email.localizedCaseInsensitiveCompare($1.email) == .orderedAscending
            }
            return $0.provider.rawValue < $1.provider.rawValue
        }
    }

    nonisolated private static func loadingPlaceholder(for account: AuthAccount, provider: ServiceType) -> OAuthAccountUsage {
        OAuthAccountUsage(id: account.id, provider: provider, email: account.displayName, isLoading: true)
    }

    nonisolated static func fetchCodexUsage(for account: AuthAccount, session: URLSession = .shared, usageURL: URL = defaultCodexUsageURL) async -> OAuthAccountUsage {
        guard let auth = authValues(from: account.filePath),
              let token = auth["access_token"] else {
            return failedAccount(account, "Missing access token")
        }
        if account.isAccessExpired {
            return failedAccount(account, "Access token expired; it renews on this account's next request")
        }
        var request = URLRequest(url: usageURL)
        request.httpMethod = "GET"
        request.timeoutInterval = OAuthUsageParsing.requestTimeout
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("codex-cli", forHTTPHeaderField: "User-Agent")
        if let accountId = auth["account_id"] {
            request.setValue(accountId, forHTTPHeaderField: "ChatGPT-Account-Id")
        }

        var usage = await fetchJSONUsage(account: account, request: request, session: session) { json in
            parseCodexWindows(json)
        }
        guard usage.error == nil else { return usage }
        // Banked-reset state rides along with the usage read; it is
        // best-effort and never fails the read itself.
        let credits = await fetchCodexBankedResets(account: account, auth: auth, token: token, session: session, usageURL: usageURL)
        usage.bankedResets = credits.display
        usage.codexResetCredits = credits.credits
        if credits.rateLimited {
            usage.rateLimited = true
            usage.retryAfter = max(usage.retryAfter ?? .distantPast, credits.retryAfter ?? .distantPast)
        }
        return usage
    }

    nonisolated private static var antigravityUserAgent: String {
        // Mirrors the bundled CLIProxyAPI fallback client identity. Cloud Code
        // rejects some model-list calls from older Antigravity clients.
        #if arch(arm64)
        return "antigravity/hub/2.29.0 (aidev_client; os_type=darwin; arch=arm64; cl=1013060670)"
        #else
        return "antigravity/hub/2.29.0 (aidev_client; os_type=darwin; arch=x64)"
        #endif
    }

    nonisolated private static func fetchAntigravityUsage(for account: AuthAccount) async -> OAuthAccountUsage {
        guard let auth = authValues(from: account.filePath),
              let token = auth["access_token"] else {
            return failedAccount(account, "Missing access token")
        }
        if account.isAccessExpired {
            return failedAccount(account, "Access token expired; it renews on this account's next request")
        }
        guard let project = auth["project_id"] else {
            return failedAccount(account, "Missing project ID")
        }
        guard let url = URL(string: "https://daily-cloudcode-pa.googleapis.com/v1internal:retrieveUserQuotaSummary") else {
            return failedAccount(account, "Invalid usage endpoint")
        }
        guard let body = try? JSONSerialization.data(withJSONObject: ["project": project]) else {
            return failedAccount(account, "Invalid usage request")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = OAuthUsageParsing.requestTimeout
        request.httpBody = body
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(antigravityUserAgent, forHTTPHeaderField: "User-Agent")

        return await fetchJSONUsage(account: account, request: request) { json in
            parseAntigravityQuotaSummaryWindows(json)
        }
    }

    nonisolated static func fetchClaudeUsage(for account: AuthAccount, session: URLSession = .shared, usageURL: URL = defaultClaudeUsageURL) async -> OAuthAccountUsage {
        guard let auth = authValues(from: account.filePath),
              let token = auth["access_token"] else {
            return failedAccount(account, "Missing access token")
        }

        let isExpired = auth["expired"]
            .flatMap(parseISO8601Date)
            .map { $0 <= Date() } ?? false

        let usableToken: String
        if isExpired {
            do {
                usableToken = try await refreshClaudeTokens(fileURL: account.filePath, auth: auth, session: session)
            } catch {
                return failedAccount(account, "Token refresh failed: \(error.localizedDescription)")
            }
        } else {
            usableToken = token
        }

        return await executeClaudeUsageRequest(account: account, token: usableToken, session: session, url: usageURL)
    }

    nonisolated static func refreshClaudeTokens(fileURL: URL, auth: [String: String], session: URLSession = .shared) async throws -> String {
        guard let refreshToken = auth["refresh_token"] else {
            throw NSError(domain: "ClaudeUsage", code: 2, userInfo: [NSLocalizedDescriptionKey: "No refresh token available"])
        }

        var request = URLRequest(url: URL(string: "https://platform.claude.com/v1/oauth/token")!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")

        let encodedToken = refreshToken.addingPercentEncoding(withAllowedCharacters: OAuthUsageParsing.formURLEncodedAllowedCharacters) ?? ""
        let body = "client_id=9d1c250a-e61b-44d9-88ed-5944d1962f5e&grant_type=refresh_token&refresh_token=\(encodedToken)"
        request.httpBody = body.data(using: .utf8)

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            throw NSError(domain: "ClaudeUsage", code: 3, userInfo: [NSLocalizedDescriptionKey: "Token refresh failed"])
        }

        guard let newTokens = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let newAccess = newTokens["access_token"] as? String,
              let newRefresh = newTokens["refresh_token"] as? String else {
            throw NSError(domain: "ClaudeUsage", code: 4, userInfo: [NSLocalizedDescriptionKey: "Invalid token response format"])
        }

        let expiresIn = (newTokens["expires_in"] as? Double) ?? 3600
        let isoFormatter = ISO8601DateFormatter()
        isoFormatter.formatOptions = [.withInternetDateTime]
        let newExpiresAt = isoFormatter.string(from: Date().addingTimeInterval(expiresIn))

        var existingJson = try JSONSerialization.jsonObject(with: try Data(contentsOf: fileURL)) as? [String: Any] ?? [:]
        existingJson["access_token"] = newAccess
        existingJson["refresh_token"] = newRefresh
        existingJson["expired"] = newExpiresAt
        existingJson["last_refresh"] = isoFormatter.string(from: Date())

        let newData = try JSONSerialization.data(withJSONObject: existingJson, options: [.prettyPrinted])
        try newData.write(to: fileURL, options: [.atomic])

        return newAccess
    }

    nonisolated private static func executeClaudeUsageRequest(account: AuthAccount, token: String, session: URLSession, url: URL) async -> OAuthAccountUsage {
        do {
            let (data, response) = try await session.data(for: makeClaudeUsageRequest(url: url, token: token))
            guard let http = response as? HTTPURLResponse else {
                return failedAccount(account, "No HTTP response")
            }

            if http.statusCode == 401 || http.statusCode == 403 {
                return await retryClaudeUsageAfterRefresh(account: account, url: url, session: session)
            }

            guard (200..<300).contains(http.statusCode) else {
                return failedAccount(account, "Claude usage API returned \(http.statusCode)", response: http)
            }

            let windows = parseClaudeWindows(data)
            guard !windows.isEmpty else {
                return failedAccount(account, "Usage response did not include quota windows")
            }

            return claudeSuccessAccount(account, data: data, windows: windows)
        } catch {
            return failedAccount(account, error.localizedDescription)
        }
    }

    nonisolated private static func retryClaudeUsageAfterRefresh(account: AuthAccount, url: URL, session: URLSession) async -> OAuthAccountUsage {
        do {
            guard let auth = authValues(from: account.filePath) else {
                return failedAccount(account, "Failed to read credentials for retry")
            }
            let newToken = try await refreshClaudeTokens(fileURL: account.filePath, auth: auth, session: session)
            let (data, response) = try await session.data(for: makeClaudeUsageRequest(url: url, token: newToken))
            guard let http = response as? HTTPURLResponse else {
                return failedAccount(account, "No HTTP response on retry")
            }
            guard http.statusCode == 200 else {
                return failedAccount(account, "Claude usage returned \(http.statusCode) after refresh retry", response: http)
            }
            return claudeSuccessAccount(account, data: data, windows: parseClaudeWindows(data))
        } catch {
            return failedAccount(account, "Retry token refresh failed: \(error.localizedDescription)")
        }
    }

    nonisolated static func makeClaudeUsageRequest(url: URL, token: String) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = OAuthUsageParsing.requestTimeout
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        return request
    }

    /// `GrokAuth.ensureValidAccessToken` only serves the newest enabled Grok credential file,
    /// so other Grok auth files have no token source here and are not used for requests either.
    nonisolated static func activeGrokAccounts(_ accounts: [AuthAccount]) -> [AuthAccount] {
        guard let activeFile = GrokAuth.loadActiveCredentials()?.url.lastPathComponent else {
            return []
        }
        return accounts.filter { !$0.isDisabled && !$0.isExpired && $0.id == activeFile }
    }

    nonisolated private static func fetchGrokUsage(for account: AuthAccount) async -> OAuthAccountUsage {
        guard let url = URL(string: "https://cli-chat-proxy.grok.com/v1/billing?format=credits") else {
            return failedAccount(account, "Invalid usage endpoint")
        }

        let tokenResult: Result<String, GrokAuth.GrokAuthError> = await withCheckedContinuation { continuation in
            GrokAuth.ensureValidAccessToken { result in
                continuation.resume(returning: result)
            }
        }

        let token: String
        switch tokenResult {
        case .success(let value):
            token = value
        case .failure(let error):
            return failedAccount(account, error.localizedDescription)
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = OAuthUsageParsing.requestTimeout
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("xai-grok-cli", forHTTPHeaderField: "x-xai-token-auth")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                return failedAccount(account, "No HTTP response")
            }
            // No retry on 401: ensureValidAccessToken refreshes only on local expiry,
            // so a retry would resend the same rejected token.
            if http.statusCode == 401 || http.statusCode == 403 {
                return failedAccount(account, "Grok rejected the stored credentials (HTTP \(http.statusCode)). Reconnect Grok in Settings.")
            }
            guard (200..<300).contains(http.statusCode) else {
                return failedAccount(account, "Grok usage API returned \(http.statusCode)")
            }
            let windows = parseGrokWindows(data)
            guard !windows.isEmpty else {
                return failedAccount(account, "Usage response did not include quota windows")
            }
            return successAccount(account, windows: windows)
        } catch {
            return failedAccount(account, error.localizedDescription)
        }
    }

    /// Meta has no usage endpoint: the 5-hour window and weekly percents arrive
    /// as `response.subscription_usage` SSE events, which ThinkingProxy sniffs
    /// into `MetaMuseUsageStore` and `MetaMuseUsageProbe` requests when the
    /// stored snapshot is stale. A failed probe or expired key falls back to the
    /// stored snapshot, so a stale card still shows its "as of" time.
    nonisolated private static func fetchMetaUsage(for account: AuthAccount) async -> OAuthAccountUsage {
        await MetaMuseUsageProbe.refresh(accountID: account.id)
        return storedMetaUsage(for: account)
    }

    /// The account's last observed Meta usage, without probing for a fresh one.
    nonisolated static func storedMetaUsage(for account: AuthAccount) -> OAuthAccountUsage {
        guard let snapshot = MetaMuseUsageStore.shared.snapshot(for: account.id) else {
            return failedAccount(account, "No usage observed yet — send a Meta request through DroidProxy")
        }
        let windows = parseMetaWindows(snapshot)
        guard !windows.isEmpty else {
            return failedAccount(account, "Stored Meta usage was incomplete")
        }
        var usage = successAccount(account, windows: windows)
        usage.updatedAt = snapshot.observedAt
        return usage
    }

    nonisolated static func parseMetaWindows(_ snapshot: MetaMuseUsageSnapshot) -> [OAuthUsageWindow] {
        let observed = RelativeDateTimeFormatter().localizedString(for: snapshot.observedAt, relativeTo: Date())
        return [
            OAuthUsageWindow(
                title: metaWindowTitle(minutes: snapshot.windowDurationMins),
                usedPercent: max(0.0, min(100.0, snapshot.windowUsedPercent)),
                resetText: "\(resetText(for: snapshot.windowResetsAt)) · as of \(observed)",
                resetDate: snapshot.windowResetsAt,
                lengthSeconds: snapshot.windowDurationMins > 0 ? Int(snapshot.windowDurationMins * 60) : nil
            ),
            OAuthUsageWindow(
                title: "Weekly",
                usedPercent: max(0.0, min(100.0, snapshot.weeklyUsedPercent)),
                resetText: "\(resetText(for: snapshot.weeklyResetsAt)) · as of \(observed)",
                resetDate: snapshot.weeklyResetsAt,
                lengthSeconds: 7 * 86_400
            )
        ]
    }

    nonisolated static func metaWindowTitle(minutes: Double) -> String {
        guard minutes > 0 else { return "Window" }
        if minutes.truncatingRemainder(dividingBy: 60) == 0 {
            return "\(Int(minutes / 60))-hour"
        }
        return "\(Int(minutes.rounded()))-min"
    }

    nonisolated static func parseAntigravityQuotaSummaryWindows(_ data: Data) -> [OAuthUsageWindow] {
        guard let raw = try? JSONSerialization.jsonObject(with: data) else {
            return []
        }
        return parseAntigravityQuotaSummaryWindows(raw)
    }

    nonisolated private static func parseAntigravityQuotaSummaryWindows(_ object: Any) -> [OAuthUsageWindow] {
        guard let root = object as? [String: Any],
              let groups = root["groups"] as? [[String: Any]] else {
            return []
        }

        func periodRank(_ bucket: [String: Any]) -> Int {
            let name = (bucket["displayName"] as? String ?? "").lowercased()
            if name.contains("five") || name.contains("5-hour") || name.contains("5h") { return 0 }
            if name.contains("week") { return 1 }
            return 2
        }

        func periodTitle(_ bucket: [String: Any]) -> String {
            let name = (bucket["displayName"] as? String ?? "Quota")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let lower = name.lowercased()
            if lower.contains("five") || lower.contains("5-hour") || lower.contains("5h") { return "5-hour" }
            if lower.contains("week") { return "Weekly" }
            return name.replacingOccurrences(of: " Limit Remaining", with: "")
        }

        func groupTitle(_ group: [String: Any]) -> String {
            let name = (group["displayName"] as? String ?? "Antigravity")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let lower = name.lowercased()
            if lower.contains("gemini") { return "Gemini" }
            if lower.contains("claude") && lower.contains("gpt") { return "Claude/GPT" }
            return name
                .replacingOccurrences(of: " Models", with: "")
                .replacingOccurrences(of: " models", with: "")
        }

        var windows: [OAuthUsageWindow] = []
        for group in groups {
            let buckets = (group["buckets"] as? [[String: Any]] ?? [])
                .sorted { periodRank($0) < periodRank($1) }
            for bucket in buckets {
                guard let fraction = numberValue(bucket["remainingFraction"]) else { continue }
                let remaining = max(0.0, min(1.0, fraction))
                let resetString = bucket["resetTime"] as? String
                let resetDate = resetString.flatMap(parseISO8601Date)
                windows.append(OAuthUsageWindow(
                    title: "\(groupTitle(group)) \(periodTitle(bucket))",
                    usedPercent: (1 - remaining) * 100,
                    resetText: resetDate.map(resetText(for:)) ?? resetString,
                    resetDate: resetDate,
                    lengthSeconds: periodRank(bucket) == 0 ? 5 * 3600 : (periodRank(bucket) == 1 ? 7 * 86_400 : nil)
                ))
            }
        }
        return windows
    }

    /// Regroups parsed Antigravity windows into their model pools (titles
    /// are "<pool> 5-hour" / "<pool> Weekly", shortest first within a
    /// pool) so each pool can render as one dual gauge. Returns nil when
    /// a pool has more windows than a dual gauge can show; the caller
    /// then falls back to the compact stack rather than drop a limit.
    nonisolated static func antigravityPoolGroups(_ windows: [OAuthUsageWindow]) -> [[OAuthUsageWindow]]? {
        func poolName(_ title: String) -> String {
            for suffix in [" 5-hour", " Weekly"] where title.hasSuffix(suffix) {
                return String(title.dropLast(suffix.count))
            }
            return title
        }

        var order: [String] = []
        var pools: [String: [OAuthUsageWindow]] = [:]
        for window in windows {
            let pool = poolName(window.title)
            if pools[pool] == nil { order.append(pool) }
            pools[pool, default: []].append(window)
        }
        let groups = order.compactMap { pools[$0] }
        guard groups.allSatisfy({ $0.count <= 2 }) else { return nil }
        return groups
    }

    /// SuperGrok reports one pooled credit window per billing period.
    nonisolated static func parseGrokWindows(_ data: Data) -> [OAuthUsageWindow] {
        guard let raw = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let config = raw["config"] as? [String: Any] else {
            return []
        }

        let usedPercent: Double
        if let creditPercent = numberValue(config["creditUsagePercent"]) {
            usedPercent = creditPercent
        } else if let cap = numberValue((config["onDemandCap"] as? [String: Any])?["val"]), cap > 0,
                  let used = numberValue((config["onDemandUsed"] as? [String: Any])?["val"]) {
            usedPercent = used / cap * 100
        } else {
            return []
        }

        let period = config["currentPeriod"] as? [String: Any]
        let title: String
        let lengthSeconds: Int?
        switch period?["type"] as? String {
        case "USAGE_PERIOD_TYPE_WEEKLY": title = "Weekly"; lengthSeconds = 7 * 86_400
        case "USAGE_PERIOD_TYPE_MONTHLY": title = "Monthly"; lengthSeconds = 30 * 86_400
        default: title = "Credits"; lengthSeconds = nil
        }

        let resetString = (period?["end"] as? String) ?? (config["billingPeriodEnd"] as? String)
        let resetDate = resetString.flatMap(parseISO8601Date)

        return [OAuthUsageWindow(
            title: title,
            usedPercent: max(0.0, min(100.0, usedPercent)),
            resetText: resetDate.map(resetText(for:)) ?? resetString,
            resetDate: resetDate,
            lengthSeconds: lengthSeconds
        )]
    }

    nonisolated private static func successAccount(_ account: AuthAccount, windows: [OAuthUsageWindow]) -> OAuthAccountUsage {
        OAuthAccountUsage(
            id: account.id,
            provider: account.type,
            email: account.displayName,
            windows: windows,
            updatedAt: Date()
        )
    }

    /// Claude success, with the banked-reset state read from the same
    /// usage payload (the cedar_ember block rides along with the windows).
    nonisolated private static func claudeSuccessAccount(
        _ account: AuthAccount, data: Data, windows: [OAuthUsageWindow]
    ) -> OAuthAccountUsage {
        var usage = successAccount(account, windows: windows)
        let resets = parseClaudeResetCredits(data, now: Date())
        usage.bankedResets = resets?.display
        usage.claudeResetState = resets
        return usage
    }

    nonisolated static func parseClaudeWindows(_ data: Data) -> [OAuthUsageWindow] {
        guard let raw = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return []
        }

        let knownBuckets: [(key: String, title: String, lengthSeconds: Int)] = [
            ("five_hour", "5-hour", 5 * 3600),
            ("seven_day", "Weekly", 7 * 86_400),
            ("seven_day_opus", "Weekly (Opus)", 7 * 86_400),
            ("seven_day_sonnet", "Weekly (Sonnet)", 7 * 86_400),
            ("seven_day_oauth_apps", "Weekly (OAuth Apps)", 7 * 86_400),
            ("seven_day_cowork", "Weekly (Cowork)", 7 * 86_400),
            ("seven_day_omelette", "Weekly (Omelette)", 7 * 86_400)
        ]

        var windows: [OAuthUsageWindow] = []
        for (key, title, lengthSeconds) in knownBuckets {
            guard let dict = raw[key] as? [String: Any],
                  let utilization = numberValue(dict["utilization"]) else {
                continue
            }
            // The Claude API defines 'utilization' as a percentage value in the range [0.0, 100.0]
            // where 1.0 represents 1% (not 1.0 = 100%). We clamp this value defensively.
            let usedPercent = max(0.0, min(100.0, utilization))
            let resetsAtStr = dict["resets_at"] as? String
            let resetDate = resetsAtStr.flatMap(parseISO8601Date)
            let resetText = resetDate.map(resetText(for:)) ?? resetsAtStr

            windows.append(OAuthUsageWindow(
                title: title,
                usedPercent: usedPercent,
                resetText: resetText,
                resetDate: resetDate,
                lengthSeconds: lengthSeconds
            ))
        }

        return windows
    }

    nonisolated private static func fetchJSONUsage(
        account: AuthAccount,
        request: URLRequest,
        session: URLSession = .shared,
        parse: (Any) -> [OAuthUsageWindow]
    ) async -> OAuthAccountUsage {
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                return failedAccount(account, "No HTTP response")
            }
            guard (200..<300).contains(http.statusCode) else {
                return failedAccount(account, "Usage API returned \(http.statusCode)", response: http)
            }
            let json = try JSONSerialization.jsonObject(with: data)
            let windows = parse(json)
            guard !windows.isEmpty else {
                return failedAccount(account, "Usage response did not include quota windows")
            }
            return successAccount(account, windows: windows)
        } catch {
            return failedAccount(account, error.localizedDescription)
        }
    }

    nonisolated private static func failedAccount(_ account: AuthAccount, _ message: String, response: HTTPURLResponse? = nil) -> OAuthAccountUsage {
        OAuthAccountUsage(
            id: account.id,
            provider: account.type,
            email: account.displayName,
            error: message,
            updatedAt: Date(),
            rateLimited: response?.statusCode == 429,
            retryAfter: OAuthUsageCache.retryDate(response?.value(forHTTPHeaderField: "Retry-After"), now: Date())
        )
    }

    nonisolated static func authValues(from url: URL) -> [String: String]? {
        guard let data = try? Data(contentsOf: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return json.compactMapValues { value in
            guard let string = value as? String, !string.isEmpty else { return nil }
            return string
        }
    }

    nonisolated static func parseCodexWindows(_ object: Any) -> [OAuthUsageWindow] {
        guard let root = object as? [String: Any],
              let rateLimit = root["rate_limit"] as? [String: Any] else {
            return parseGenericWindows(object)
        }

        return [
            codexWindow(fallbackTitle: "5-hour", from: rateLimit["primary_window"]),
            codexWindow(fallbackTitle: "Weekly", from: rateLimit["secondary_window"])
        ].compactMap { $0 }
    }

    /// Codex plans differ: some have 5-hour + weekly, some only weekly, some only monthly,
    /// and whichever limit exists is reported as `primary_window`. The title therefore
    /// comes from `limit_window_seconds`, with the slot position only as a fallback.
    nonisolated private static func codexWindow(fallbackTitle: String, from value: Any?) -> OAuthUsageWindow? {
        guard let window = value as? [String: Any] else { return nil }
        let resetDate = resetDate(from: window)
        let lengthSeconds = numberValue(window["limit_window_seconds"]).flatMap { $0 > 0 ? Int($0) : nil }
        return OAuthUsageWindow(
            title: codexWindowTitle(seconds: numberValue(window["limit_window_seconds"]), fallback: fallbackTitle),
            usedPercent: numberValue(window["used_percent"]),
            resetText: resetDate.map(resetText(for:)) ?? resetText(from: window),
            resetDate: resetDate,
            lengthSeconds: lengthSeconds
        )
    }

    nonisolated static func codexWindowTitle(seconds: Double?, fallback: String) -> String {
        guard let seconds, seconds > 0 else { return fallback }
        let hours = seconds / 3600
        if hours <= 24 {
            return "\(max(1, Int(hours.rounded())))-hour"
        }
        let days = seconds / 86_400
        switch days {
        case 6...8: return "Weekly"
        case 27...32: return "Monthly"
        default: return "\(Int(days.rounded()))-day"
        }
    }

    nonisolated private static func parseGenericWindows(_ object: Any) -> [OAuthUsageWindow] {
        let dictionaries = flattenDictionaries(object)
        var windows: [OAuthUsageWindow] = []

        for dictionary in dictionaries {
            guard let title = windowTitle(from: dictionary),
                  !windows.contains(where: { $0.title == title }) else {
                continue
            }
            let percent = percentValue(from: dictionary)
            let reset = resetText(from: dictionary)
            if percent != nil || reset != nil {
                windows.append(OAuthUsageWindow(title: title, usedPercent: percent, resetText: reset, resetDate: nil))
            }
        }

        return windows.sorted { windowRank($0.title) < windowRank($1.title) }
    }

    nonisolated private static func flattenDictionaries(_ value: Any) -> [[String: Any]] {
        if let dictionary = value as? [String: Any] {
            return [dictionary] + dictionary.values.flatMap(flattenDictionaries)
        }
        if let array = value as? [Any] {
            return array.flatMap(flattenDictionaries)
        }
        return []
    }

    nonisolated private static func windowTitle(from dictionary: [String: Any]) -> String? {
        let joined = dictionary.map { "\($0.key):\($0.value)" }.joined(separator: " ").lowercased()
        if joined.contains("5h") || joined.contains("5-hour") || joined.contains("five") {
            return "5-hour"
        }
        if joined.contains("weekly") || joined.contains("week") || joined.contains("7d") {
            return "Weekly"
        }
        if joined.contains("full") || joined.contains("premium") || joined.contains("paid") {
            return "Full"
        }
        if joined.contains("standard") || joined.contains("session") {
            return "Session"
        }
        return nil
    }

    nonisolated private static func percentValue(from dictionary: [String: Any]) -> Double? {
        for (key, value) in dictionary {
            let lower = key.lowercased()
            guard lower.contains("percent") || lower.contains("percentage") || lower.contains("%") else {
                continue
            }
            guard let number = numberValue(value) else { continue }
            return number <= 1 ? number * 100 : number
        }

        for (key, value) in dictionary {
            let lower = key.lowercased()
            guard lower.contains("usage") || lower.contains("used") || lower.contains("fraction") else {
                continue
            }
            guard let number = numberValue(value) else { continue }
            return number <= 1 ? number * 100 : number
        }
        return nil
    }

    nonisolated private static func resetText(from dictionary: [String: Any]) -> String? {
        if let date = resetDate(from: dictionary) {
            return resetText(for: date)
        }
        for (key, value) in dictionary where key.lowercased().contains("reset") {
            if let string = value as? String, !string.isEmpty {
                return string
            }
        }
        return nil
    }

    nonisolated private static func resetDate(from dictionary: [String: Any]) -> Date? {
        for (key, value) in dictionary where key.lowercased().contains("reset") {
            let lowerKey = key.lowercased()
            if let string = value as? String, !string.isEmpty {
                if let date = parseISO8601Date(string) {
                    return date
                }
                continue
            }
            if let number = numberValue(value) {
                if lowerKey.contains("after") {
                    return Date().addingTimeInterval(number)
                }
                return Date(timeIntervalSince1970: number > 10_000_000_000 ? number / 1000 : number)
            }
        }
        return nil
    }

    nonisolated static func parseISO8601Date(_ string: String) -> Date? {
        let withFractionalSeconds = ISO8601DateFormatter()
        withFractionalSeconds.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = withFractionalSeconds.date(from: string) {
            return date
        }

        let standard = ISO8601DateFormatter()
        standard.formatOptions = [.withInternetDateTime]
        return standard.date(from: string)
    }

    nonisolated private static func resetText(for date: Date) -> String {
        let relative = RelativeDateTimeFormatter().localizedString(for: date, relativeTo: Date())
        let absoluteFormatter = DateFormatter()
        absoluteFormatter.dateStyle = .medium
        absoluteFormatter.timeStyle = .short
        return "\(relative) (\(absoluteFormatter.string(from: date)))"
    }

    nonisolated static func numberValue(_ value: Any?) -> Double? {
        if let value = value as? Double { return value }
        if let value = value as? Int { return Double(value) }
        if let value = value as? NSNumber { return value.doubleValue }
        if let value = value as? String {
            return Double(value.replacingOccurrences(of: "%", with: ""))
        }
        return nil
    }

    nonisolated private static func windowRank(_ title: String) -> Int {
        switch title {
        case "5-hour": return 0
        case "Session": return 1
        case "Weekly": return 2
        case "Monthly": return 3
        case "Full": return 4
        default: return 9
        }
    }
}