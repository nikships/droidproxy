import CryptoKit
import Foundation

/// Banked usage resets (Codex reset credits, Claude cedar_ember grants)
/// are one-time credits saved on the provider account. Reading them rides
/// along with the normal usage reads; redeeming spends exactly one credit
/// and is only ever user-initiated. The endpoint shapes follow the
/// providers' own clients (Codex wham API, Anthropic OAuth usage), matching
/// the Linux edition's implementation.
/// What Settings and the cache may see: counts and expiry only. The
/// provider's credit id is derived fresh at redemption time and is never
/// stored or exposed.
struct BankedResetCredits: Equatable, Codable {
    let availableCount: Int
    let nextExpiresAt: Date?
}

struct CodexResetCredit: Equatable {
    let id: String
    let expiresAt: Date
}

struct ClaudeResetState: Equatable {
    let display: BankedResetCredits
    let nextCreditID: String
    /// How many resets the next grant itself holds; part of the redemption
    /// idempotency key so each logical redemption differs while retries of
    /// one attempt stay identical.
    let nextResetsLeft: Int
}

extension OAuthUsageTracker {
    nonisolated static let defaultCodexUsageURL = URL(string: "https://chatgpt.com/backend-api/wham/usage")!
    nonisolated static let defaultClaudeUsageURL = URL(string: "https://api.anthropic.com/api/oauth/usage")!

    /// Derives the reset-credits URL from the usage URL
    /// (.../wham/usage -> .../wham/rate-limit-reset-credits).
    nonisolated static func codexCreditsURL(fromUsage url: URL) -> URL {
        var string = url.absoluteString
        if string.hasSuffix("/usage") { string.removeLast("/usage".count) }
        return URL(string: string + "/rate-limit-reset-credits") ?? url
    }

    nonisolated static func parseCodexCredits(_ data: Data, now: Date) -> [CodexResetCredit] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let credits = root["credits"] as? [[String: Any]] else {
            return []
        }
        var out: [CodexResetCredit] = []
        for credit in credits {
            guard credit["reset_type"] as? String == "codex_rate_limits",
                  credit["status"] as? String == "available",
                  let id = credit["id"] as? String, !id.isEmpty,
                  let expiresString = credit["expires_at"] as? String,
                  let expires = parseISO8601Date(expiresString), expires > now else {
                continue
            }
            out.append(CodexResetCredit(id: id, expiresAt: expires))
        }
        return out.sorted { $0.expiresAt < $1.expiresAt }
    }

    nonisolated static func codexBankedResets(_ data: Data, now: Date) -> BankedResetCredits? {
        let credits = parseCodexCredits(data, now: now)
        guard let next = credits.first else { return nil }
        return BankedResetCredits(availableCount: credits.count, nextExpiresAt: next.expiresAt)
    }

    /// Reads the cedar_ember block of a Claude OAuth usage payload. The
    /// redeemable count is the sum of resets_left over live grants, and
    /// only counts when the payload names a next grant.
    nonisolated static func parseClaudeResetCredits(_ data: Data, now: Date) -> ClaudeResetState? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let block = root["cedar_ember"] as? [String: Any],
              block["eligible"] as? Bool == true else {
            return nil
        }
        let nextID = block["next_grant_id"] as? String
        let grants = block["grants"] as? [[String: Any]] ?? []
        var count = 0
        var next: ClaudeResetState?
        for grant in grants {
            guard let id = grant["id"] as? String, !id.isEmpty,
                  grant["paused"] as? Bool != true,
                  grant["usable_now"] as? Bool == true else {
                continue
            }
            var endsAt: Date?
            if let string = grant["ends_at"] as? String, !string.isEmpty {
                endsAt = parseISO8601Date(string)
                guard let endsAt, endsAt > now else { continue }
            }
            // Clamp defensively: Int(Double) traps outside Int range, and
            // a malformed payload runs on every Claude usage read.
            let rawLeft = numberValue(grant["resets_left"]) ?? 0
            let left = rawLeft.isFinite && rawLeft > 0 ? (Int(exactly: rawLeft.rounded(.down)) ?? Int.max) : 0
            count += left
            if id == nextID {
                next = ClaudeResetState(
                    display: BankedResetCredits(availableCount: 0, nextExpiresAt: endsAt),
                    nextCreditID: id,
                    nextResetsLeft: left
                )
            }
        }
        guard let found = next, count > 0 else { return nil }
        return ClaudeResetState(
            display: BankedResetCredits(availableCount: count, nextExpiresAt: found.display.nextExpiresAt),
            nextCreditID: found.nextCreditID,
            nextResetsLeft: found.nextResetsLeft
        )
    }

    /// UUIDv5 in T3 Code's namespace, so a retry from either tool (or the
    /// Linux edition) addresses the same provider-side redemption.
    nonisolated static func redeemRequestID(_ name: String) -> String {
        let namespace: [UInt8] = [0x6f, 0x1c, 0x2a, 0x9e, 0x2d, 0x4b, 0x4c, 0x1e, 0x9a, 0x7f, 0x3b, 0x8d, 0x5e, 0x0c, 0x1a, 0x42]
        var bytes = Array(Insecure.SHA1.hash(data: Data(namespace) + Data(name.utf8)).prefix(16))
        bytes[6] = (bytes[6] & 0x0f) | 0x50
        bytes[8] = (bytes[8] & 0x3f) | 0x80
        let hex = bytes.map { String(format: "%02x", $0) }.joined()
        let parts = [hex.prefix(8), hex.dropFirst(8).prefix(4), hex.dropFirst(12).prefix(4),
                     hex.dropFirst(16).prefix(4), hex.dropFirst(20).prefix(12)]
        return parts.joined(separator: "-")
    }

    private struct CodexResponse {
        let data: Data
        let status: Int
        let retryAfter: String?
    }

    nonisolated private static func codexRequest(
        session: URLSession, method: String, url: URL, token: String, chatGPTAccountID: String?, body: Data?
    ) async -> CodexResponse? {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = OAuthUsageParsing.requestTimeout
        request.httpBody = body
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("codex-cli", forHTTPHeaderField: "User-Agent")
        if body != nil {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        if let chatGPTAccountID, !chatGPTAccountID.isEmpty {
            request.setValue(chatGPTAccountID, forHTTPHeaderField: "ChatGPT-Account-Id")
        }
        guard let (data, response) = try? await session.data(for: request),
              let http = response as? HTTPURLResponse else {
            return nil
        }
        return CodexResponse(data: data, status: http.statusCode, retryAfter: http.value(forHTTPHeaderField: "Retry-After"))
    }

    /// Best-effort credits read riding along with a Codex usage read: a
    /// failed credits read never fails the usage read. A 429 still reports
    /// its cooldown so the sample's polling budget honors it.
    nonisolated static func fetchCodexBankedResets(
        account: AuthAccount, auth: [String: String], token: String,
        session: URLSession = .shared, usageURL: URL = defaultCodexUsageURL
    ) async -> (display: BankedResetCredits?, credits: [CodexResetCredit], rateLimited: Bool, retryAfter: Date?) {
        guard !account.isAccessExpired else { return (nil, [], false, nil) }
        guard let response = await codexRequest(
            session: session, method: "GET", url: codexCreditsURL(fromUsage: usageURL),
            token: token, chatGPTAccountID: auth["account_id"], body: nil
        ) else {
            return (nil, [], false, nil)
        }
        guard (200..<300).contains(response.status) else {
            if response.status == 429 {
                return (nil, [], true, OAuthUsageCache.retryDate(response.retryAfter, now: Date()))
            }
            return (nil, [], false, nil)
        }
        let credits = parseCodexCredits(response.data, now: Date())
        let display = credits.first.map { BankedResetCredits(availableCount: credits.count, nextExpiresAt: $0.expiresAt) }
        return (display, credits, false, nil)
    }

    /// Spends one banked reset for the account and returns a user-facing
    /// message. It never runs on its own; callers gate it behind an
    /// explicit user confirmation.
    nonisolated static func redeemReset(
        for account: AuthAccount,
        session: URLSession = .shared,
        cache: OAuthUsageCache = .shared,
        codexUsageURL: URL = defaultCodexUsageURL,
        claudeUsageURL: URL = defaultClaudeUsageURL
    ) async -> (message: String, ok: Bool) {
        let result: (message: String, ok: Bool)
        switch account.type {
        case .codex:
            result = await redeemCodexReset(for: account, session: session, cache: cache, usageURL: codexUsageURL)
        case .claude:
            result = await redeemClaudeReset(for: account, session: session, cache: cache, usageURL: claudeUsageURL)
        default:
            return ("Banked resets are only available for Codex and Claude accounts.", false)
        }
        if result.ok {
            // Quota and credit counts just changed provider-side; the next
            // read must not serve the pre-reset sample.
            await cache.invalidate(for: account)
        }
        return result
    }

    nonisolated private static func redeemCodexReset(
        for account: AuthAccount, session: URLSession, cache: OAuthUsageCache, usageURL: URL
    ) async -> (message: String, ok: Bool) {
        guard let auth = authValues(from: account.filePath), let token = auth["access_token"] else {
            return ("Missing access token.", false)
        }
        if account.isAccessExpired {
            return ("Access token expired; it renews on this account's next request.", false)
        }
        // The credit state comes through the shared usage cache, so a
        // redemption never spends polling budget outside it (AGENTS.md).
        let usage = await cache.usage(for: account) {
            await fetchCodexUsage(for: account, session: session, usageURL: usageURL)
        }
        if usage.rateLimited {
            return ("Codex is rate limiting resets. Try again soon.", false)
        }
        guard usage.error == nil else {
            return ("Could not read banked resets for this account.", false)
        }
        guard let credit = usage.codexResetCredits.first else {
            return ("No banked reset is available for this account.", false)
        }
        let creditsURL = codexCreditsURL(fromUsage: usageURL)
        let accountKey = auth["account_id"].flatMap { $0.isEmpty ? nil : $0 } ?? account.id
        guard let body = try? JSONSerialization.data(withJSONObject: [
            "redeem_request_id": redeemRequestID("\(accountKey):\(credit.id)"),
            "credit_id": credit.id
        ]) else {
            return ("Codex could not redeem the reset.", false)
        }
        guard let consume = await codexRequest(
            session: session, method: "POST",
            url: URL(string: creditsURL.absoluteString + "/consume") ?? creditsURL,
            token: token, chatGPTAccountID: auth["account_id"], body: body
        ) else {
            return ("Codex could not redeem the reset.", false)
        }
        if consume.status == 429 {
            await cache.recordRateLimit(for: account, retryAfter: OAuthUsageCache.retryDate(consume.retryAfter, now: Date()))
            return ("Codex is rate limiting resets. Try again soon.", false)
        }
        guard (200..<300).contains(consume.status) else {
            return ("Codex could not redeem the reset.", false)
        }
        guard let outcome = try? JSONSerialization.jsonObject(with: consume.data) as? [String: Any],
              let code = outcome["code"] as? String else {
            return ("Codex returned an unexpected reset response.", false)
        }
        return codexOutcome(code)
    }

    nonisolated static func codexOutcome(_ code: String) -> (message: String, ok: Bool) {
        switch code {
        case "reset":
            return ("Banked reset applied. Quota windows are refreshed.", true)
        case "already_redeemed":
            return ("That reset was already redeemed. Quota is up to date.", true)
        case "nothing_to_reset":
            return ("Nothing to reset right now; the credit was not spent.", false)
        case "no_credit":
            return ("No banked reset is available for this account.", false)
        default:
            return ("Codex returned an unexpected reset response.", false)
        }
    }

    nonisolated private static func claudeToken(for account: AuthAccount, session: URLSession) async -> String? {
        guard let auth = authValues(from: account.filePath), var token = auth["access_token"] else {
            return nil
        }
        if let expired = auth["expired"].flatMap(parseISO8601Date), expired <= Date() {
            guard let refreshed = try? await refreshClaudeTokens(fileURL: account.filePath, auth: auth, session: session) else {
                return nil
            }
            token = refreshed
        }
        return token
    }

    nonisolated private static func claudeOrganizationUUID(for account: AuthAccount) -> String? {
        guard let data = try? Data(contentsOf: account.filePath),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        let uuid = ClaudeAuthSeatFiles.organizationFields(from: json).uuid
        return (uuid?.isEmpty == false) ? uuid : nil
    }

    nonisolated private static func redeemClaudeReset(
        for account: AuthAccount, session: URLSession, cache: OAuthUsageCache, usageURL: URL
    ) async -> (message: String, ok: Bool) {
        guard let organization = claudeOrganizationUUID(for: account) else {
            return ("Sign in to Claude again to redeem resets.", false)
        }
        // The grant state comes through the shared usage cache (Claude's
        // five-minute budget included), never a side read (AGENTS.md).
        let usage = await cache.usage(for: account) {
            await fetchClaudeUsage(for: account, session: session, usageURL: usageURL)
        }
        if usage.rateLimited {
            return ("Claude is rate limiting resets. Try again soon.", false)
        }
        guard usage.error == nil else {
            return ("Could not read banked resets for this account.", false)
        }
        guard let credits = usage.claudeResetState else {
            return ("No banked reset is available for this account.", false)
        }
        guard let token = await claudeToken(for: account, session: session) else {
            return ("Sign in to Claude again to redeem resets.", false)
        }
        guard var components = URLComponents(url: usageURL, resolvingAgainstBaseURL: false) else {
            return ("Claude could not redeem the reset.", false)
        }
        components.path = "/api/organizations/\(organization)/reset_rate_limits"
        components.query = nil
        guard let claimURL = components.url,
              let body = try? JSONSerialization.data(withJSONObject: [
                  "program": "cedar_ember",
                  "grant_id": credits.nextCreditID,
                  // resets_left distinguishes logical redemptions of one
                  // multi-reset grant; a retry before the spend lands still
                  // observes the same count and reuses the key.
                  "request_id": redeemRequestID("claude:\(organization):\(credits.nextCreditID):\(credits.nextResetsLeft)")
              ]) else {
            return ("Claude could not redeem the reset.", false)
        }
        var request = URLRequest(url: claimURL)
        request.httpMethod = "POST"
        request.timeoutInterval = OAuthUsageParsing.requestTimeout
        request.httpBody = body
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        guard let (claimData, claimResponse) = try? await session.data(for: request),
              let claimHTTP = claimResponse as? HTTPURLResponse else {
            return ("Claude could not redeem the reset.", false)
        }
        if claimHTTP.statusCode == 429 {
            await cache.recordRateLimit(
                for: account,
                retryAfter: OAuthUsageCache.retryDate(claimHTTP.value(forHTTPHeaderField: "Retry-After"), now: Date())
            )
        }
        if let early = claudeStatusOutcome(claimHTTP.statusCode) {
            return early
        }
        guard let outcome = try? JSONSerialization.jsonObject(with: claimData) as? [String: Any],
              let result = outcome["result"] as? String else {
            return ("Claude returned an unexpected reset response.", false)
        }
        return claudeOutcome(result)
    }

    /// Non-2xx statuses that decide the outcome before a result body exists.
    nonisolated static func claudeStatusOutcome(_ status: Int) -> (message: String, ok: Bool)? {
        switch status {
        case 200..<300:
            return nil
        case 429:
            return ("Claude is rate limiting resets. Try again soon.", false)
        case 401, 403:
            return ("Sign in to Claude again to redeem resets.", false)
        default:
            return ("Claude could not redeem the reset.", false)
        }
    }

    nonisolated static func claudeOutcome(_ result: String) -> (message: String, ok: Bool) {
        switch result {
        case "reset":
            return ("Banked reset applied. Quota windows are refreshed.", true)
        case "already_used":
            return ("That reset was already used. Quota is up to date.", true)
        case "not_limited":
            return ("Nothing to reset right now; the credit was not spent.", false)
        case "ineligible":
            return ("No banked reset is available for this account.", false)
        case "cooldown":
            return ("Claude resets are cooling down. Try again later.", false)
        default:
            return ("Claude could not confirm the reset. If you are still limited in a moment, try again.", false)
        }
    }
}
