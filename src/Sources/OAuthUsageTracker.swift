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
}

@MainActor
final class OAuthUsageTracker: ObservableObject {
    @Published private(set) var accounts: [OAuthAccountUsage] = []
    @Published private(set) var isRefreshing = false
    private var refreshTask: Task<Void, Never>?

    deinit {
        refreshTask?.cancel()
    }

    func refresh(codexAccounts authAccounts: [AuthAccount]) {
        refreshTask?.cancel()

        let enabledAccounts = authAccounts.filter { !$0.isDisabled && !$0.isExpired && $0.type == .codex }
        guard !enabledAccounts.isEmpty else {
            accounts = []
            isRefreshing = false
            return
        }

        isRefreshing = true
        accounts = enabledAccounts.map {
            OAuthAccountUsage(id: $0.id, provider: $0.type, email: $0.displayName, isLoading: true)
        }

        refreshTask = Task { [enabledAccounts] in
            let results = await withTaskGroup(of: OAuthAccountUsage.self) { group in
                for account in enabledAccounts {
                    group.addTask {
                        await Self.fetchCodexUsage(for: account)
                    }
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
            return OAuthAccountUsage(
                id: account.id,
                provider: account.type,
                email: account.displayName,
                windows: windows,
                updatedAt: Date()
            )
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
            guard lower.contains("percent") || lower.contains("usage") || lower.contains("used") || lower.contains("fraction") else {
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
