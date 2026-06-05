import Combine
import Foundation

struct OAuthUsageWindow: Identifiable, Equatable {
    let id = UUID()
    let title: String
    let usedPercent: Double?
    let resetText: String?
    let resetDate: Date?

    var remainingPercent: Double? {
        guard let usedPercent else { return nil }
        return max(0, 100 - usedPercent)
    }
}

struct OAuthAccountUsage: Identifiable, Equatable {
    let id: String
    let provider: ServiceType
    let email: String
    var isLoading = false
    var windows: [OAuthUsageWindow] = []
    var error: String?
    var updatedAt: Date?
}

private enum OAuthUsageParsing {
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

    func refresh(codexAccounts: [AuthAccount], claudeAccounts: [AuthAccount]) {
        refreshTask?.cancel()

        let enabledCodex = codexAccounts.filter { !$0.isDisabled && !$0.isExpired }
        let enabledClaude = claudeAccounts.filter { !$0.isDisabled && !$0.isExpired }

        guard !enabledCodex.isEmpty || !enabledClaude.isEmpty else {
            accounts = []
            isRefreshing = false
            return
        }

        isRefreshing = true
        accounts = enabledCodex.map { Self.loadingPlaceholder(for: $0, provider: .codex) }
            + enabledClaude.map { Self.loadingPlaceholder(for: $0, provider: .claude) }

        refreshTask = Task { [enabledCodex, enabledClaude] in
            let results = await withTaskGroup(of: OAuthAccountUsage.self) { group in
                for account in enabledCodex {
                    group.addTask { await Self.fetchCodexUsage(for: account) }
                }
                for account in enabledClaude {
                    group.addTask { await Self.fetchClaudeUsage(for: account) }
                }

                var values: [OAuthAccountUsage] = []
                for await result in group {
                    values.append(result)
                }
                return values.sorted {
                    if $0.provider.rawValue == $1.provider.rawValue {
                        return $0.email.localizedCaseInsensitiveCompare($1.email) == .orderedAscending
                    }
                    return $0.provider.rawValue < $1.provider.rawValue
                }
            }

            guard !Task.isCancelled else { return }
            self.accounts = results
            self.isRefreshing = false
        }
    }

    nonisolated private static func loadingPlaceholder(for account: AuthAccount, provider: ServiceType) -> OAuthAccountUsage {
        OAuthAccountUsage(id: account.id, provider: provider, email: account.displayName, isLoading: true)
    }

    nonisolated private static func fetchCodexUsage(for account: AuthAccount) async -> OAuthAccountUsage {
        guard let auth = authValues(from: account.filePath),
              let token = auth["access_token"] else {
            return failedAccount(account, "Missing access token")
        }
        guard let url = URL(string: "https://chatgpt.com/backend-api/wham/usage") else {
            return failedAccount(account, "Invalid usage endpoint")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = OAuthUsageParsing.requestTimeout
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("codex-cli", forHTTPHeaderField: "User-Agent")
        if let accountId = auth["account_id"] {
            request.setValue(accountId, forHTTPHeaderField: "ChatGPT-Account-Id")
        }

        return await fetchJSONUsage(account: account, request: request) { json in
            parseCodexWindows(json)
        }
    }

    nonisolated private static func fetchClaudeUsage(for account: AuthAccount) async -> OAuthAccountUsage {
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
                usableToken = try await refreshClaudeTokens(fileURL: account.filePath, auth: auth)
            } catch {
                return failedAccount(account, "Token refresh failed: \(error.localizedDescription)")
            }
        } else {
            usableToken = token
        }

        return await executeClaudeUsageRequest(account: account, token: usableToken)
    }

    nonisolated private static func refreshClaudeTokens(fileURL: URL, auth: [String: String]) async throws -> String {
        guard let refreshToken = auth["refresh_token"] else {
            throw NSError(domain: "ClaudeUsage", code: 2, userInfo: [NSLocalizedDescriptionKey: "No refresh token available"])
        }

        var request = URLRequest(url: URL(string: "https://platform.claude.com/v1/oauth/token")!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")

        let encodedToken = refreshToken.addingPercentEncoding(withAllowedCharacters: OAuthUsageParsing.formURLEncodedAllowedCharacters) ?? ""
        let body = "client_id=9d1c250a-e61b-44d9-88ed-5944d1962f5e&grant_type=refresh_token&refresh_token=\(encodedToken)"
        request.httpBody = body.data(using: .utf8)

        let (data, response) = try await URLSession.shared.data(for: request)
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

    nonisolated private static func executeClaudeUsageRequest(account: AuthAccount, token: String) async -> OAuthAccountUsage {
        guard let url = URL(string: "https://api.anthropic.com/api/oauth/usage") else {
            return failedAccount(account, "Invalid usage endpoint")
        }

        do {
            let (data, response) = try await URLSession.shared.data(for: makeClaudeUsageRequest(url: url, token: token))
            guard let http = response as? HTTPURLResponse else {
                return failedAccount(account, "No HTTP response")
            }

            if http.statusCode == 401 || http.statusCode == 403 {
                return await retryClaudeUsageAfterRefresh(account: account, url: url)
            }

            guard (200..<300).contains(http.statusCode) else {
                return failedAccount(account, "Claude usage API returned \(http.statusCode)")
            }

            let windows = parseClaudeWindows(data)
            guard !windows.isEmpty else {
                return failedAccount(account, "Usage response did not include quota windows")
            }

            return successAccount(account, windows: windows)
        } catch {
            return failedAccount(account, error.localizedDescription)
        }
    }

    nonisolated private static func retryClaudeUsageAfterRefresh(account: AuthAccount, url: URL) async -> OAuthAccountUsage {
        do {
            guard let auth = authValues(from: account.filePath) else {
                return failedAccount(account, "Failed to read credentials for retry")
            }
            let newToken = try await refreshClaudeTokens(fileURL: account.filePath, auth: auth)
            let (data, response) = try await URLSession.shared.data(for: makeClaudeUsageRequest(url: url, token: newToken))
            guard let http = response as? HTTPURLResponse else {
                return failedAccount(account, "No HTTP response on retry")
            }
            guard http.statusCode == 200 else {
                return failedAccount(account, "Claude usage returned \(http.statusCode) after refresh retry")
            }
            return successAccount(account, windows: parseClaudeWindows(data))
        } catch {
            return failedAccount(account, "Retry token refresh failed: \(error.localizedDescription)")
        }
    }

    nonisolated private static func makeClaudeUsageRequest(url: URL, token: String) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = OAuthUsageParsing.requestTimeout
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        return request
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

    nonisolated static func parseClaudeWindows(_ data: Data) -> [OAuthUsageWindow] {
        guard let raw = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return []
        }

        let knownBuckets: [(key: String, title: String)] = [
            ("five_hour", "5-hour"),
            ("seven_day", "Weekly"),
            ("seven_day_opus", "Weekly (Opus)"),
            ("seven_day_sonnet", "Weekly (Sonnet)"),
            ("seven_day_oauth_apps", "Weekly (OAuth Apps)"),
            ("seven_day_cowork", "Weekly (Cowork)"),
            ("seven_day_omelette", "Weekly (Omelette)")
        ]

        var windows: [OAuthUsageWindow] = []
        for (key, title) in knownBuckets {
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
                resetDate: resetDate
            ))
        }

        return windows
    }

    nonisolated private static func fetchJSONUsage(
        account: AuthAccount,
        request: URLRequest,
        parse: (Any) -> [OAuthUsageWindow]
    ) async -> OAuthAccountUsage {
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                return failedAccount(account, "No HTTP response")
            }
            guard (200..<300).contains(http.statusCode) else {
                return failedAccount(account, "Usage API returned \(http.statusCode)")
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

    nonisolated private static func failedAccount(_ account: AuthAccount, _ message: String) -> OAuthAccountUsage {
        OAuthAccountUsage(
            id: account.id,
            provider: account.type,
            email: account.displayName,
            error: message,
            updatedAt: Date()
        )
    }

    nonisolated private static func authValues(from url: URL) -> [String: String]? {
        guard let data = try? Data(contentsOf: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return json.compactMapValues { value in
            guard let string = value as? String, !string.isEmpty else { return nil }
            return string
        }
    }

    nonisolated private static func parseCodexWindows(_ object: Any) -> [OAuthUsageWindow] {
        guard let root = object as? [String: Any],
              let rateLimit = root["rate_limit"] as? [String: Any] else {
            return parseGenericWindows(object)
        }

        return [
            codexWindow(title: "5-hour", from: rateLimit["primary_window"]),
            codexWindow(title: "Weekly", from: rateLimit["secondary_window"])
        ].compactMap { $0 }
    }

    nonisolated private static func codexWindow(title: String, from value: Any?) -> OAuthUsageWindow? {
        guard let window = value as? [String: Any] else { return nil }
        let resetDate = resetDate(from: window)
        return OAuthUsageWindow(
            title: title,
            usedPercent: numberValue(window["used_percent"]),
            resetText: resetDate.map(resetText(for:)) ?? resetText(from: window),
            resetDate: resetDate
        )
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

    nonisolated private static func parseISO8601Date(_ string: String) -> Date? {
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

    nonisolated private static func numberValue(_ value: Any?) -> Double? {
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
        case "Full": return 3
        default: return 9
        }
    }
}