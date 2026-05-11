import Foundation

class ClaudeUsageProbe {
    private let authDir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".cli-proxy-api")
    
    struct TokenInfo: Codable {
        let access_token: String
        let refresh_token: String?
        let expired: String?
    }

    private static let dateFormatters: [ISO8601DateFormatter] = {
        let withFractional = ISO8601DateFormatter()
        withFractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return [withFractional, plain]
    }()

    private static func parseDate(_ value: String?) -> Date? {
        guard let value else { return nil }
        for formatter in dateFormatters {
            if let date = formatter.date(from: value) { return date }
        }
        return nil
    }

    func fetchUsage() async -> ProviderUsageSnapshot {
        do {
            let fileURL = try findClaudeAuthFile()
            let data = try Data(contentsOf: fileURL)
            var tokenInfo = try JSONDecoder().decode(TokenInfo.self, from: data)

            if let expiresAt = Self.parseDate(tokenInfo.expired), expiresAt <= Date() {
                tokenInfo = try await refreshTokens(fileURL: fileURL, currentTokenInfo: tokenInfo)
            }

            return try await executeUsageRequest(token: tokenInfo.access_token, fileURL: fileURL, tokenInfo: tokenInfo)
        } catch {
            return ProviderUsageSnapshot(provider: "Claude", lastUpdated: Date(), windows: [], error: error.localizedDescription)
        }
    }
    
    private func findClaudeAuthFile() throws -> URL {
        let contents = try FileManager.default.contentsOfDirectory(at: authDir, includingPropertiesForKeys: nil)
        let matches = contents
            .filter { $0.lastPathComponent.hasPrefix("claude-") && $0.lastPathComponent.hasSuffix(".json") }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        if let first = matches.first { return first }
        throw NSError(domain: "ClaudeUsageProbe", code: 1, userInfo: [NSLocalizedDescriptionKey: "No claude auth file found"])
    }
    
    private func refreshTokens(fileURL: URL, currentTokenInfo: TokenInfo) async throws -> TokenInfo {
        guard let refreshToken = currentTokenInfo.refresh_token else {
            throw NSError(domain: "ClaudeUsageProbe", code: 2, userInfo: [NSLocalizedDescriptionKey: "No refresh token available"])
        }
        
        NSLog("ClaudeUsageProbe: Refreshing tokens")
        var request = URLRequest(url: URL(string: "https://platform.claude.com/v1/oauth/token")!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        
        let encodedToken = refreshToken.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        let body = "client_id=9d1c250a-e61b-44d9-88ed-5944d1962f5e&grant_type=refresh_token&refresh_token=\(encodedToken)"
        request.httpBody = body.data(using: .utf8)
        
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            throw NSError(domain: "ClaudeUsageProbe", code: 3, userInfo: [NSLocalizedDescriptionKey: "Token refresh failed"])
        }
        
        let newTokens = try JSONSerialization.jsonObject(with: data, options: []) as? [String: Any] ?? [:]
        guard let newAccess = newTokens["access_token"] as? String, let newRefresh = newTokens["refresh_token"] as? String else {
            throw NSError(domain: "ClaudeUsageProbe", code: 4, userInfo: [NSLocalizedDescriptionKey: "Invalid token response format"])
        }

        let expiresIn = (newTokens["expires_in"] as? Double) ?? 3600
        let isoFormatter = ISO8601DateFormatter()
        isoFormatter.formatOptions = [.withInternetDateTime]
        let newExpiresAt = isoFormatter.string(from: Date().addingTimeInterval(expiresIn))

        var existingJson = try JSONSerialization.jsonObject(with: try Data(contentsOf: fileURL), options: []) as? [String: Any] ?? [:]
        existingJson["access_token"] = newAccess
        existingJson["refresh_token"] = newRefresh
        existingJson["expired"] = newExpiresAt
        existingJson["last_refresh"] = isoFormatter.string(from: Date())

        let newData = try JSONSerialization.data(withJSONObject: existingJson, options: [.prettyPrinted])
        try newData.write(to: fileURL, options: [.atomic])

        return TokenInfo(access_token: newAccess, refresh_token: newRefresh, expired: newExpiresAt)
    }
    
    private func executeUsageRequest(token: String, fileURL: URL, tokenInfo: TokenInfo) async throws -> ProviderUsageSnapshot {
        var request = URLRequest(url: URL(string: "https://api.anthropic.com/api/oauth/usage")!)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw NSError(domain: "ClaudeUsageProbe", code: 5, userInfo: [NSLocalizedDescriptionKey: "Invalid response"])
        }
        
        if httpResponse.statusCode == 401 || httpResponse.statusCode == 403 {
            NSLog("ClaudeUsageProbe: Token rejected (401/403), attempting refresh")
            let newTokens = try await refreshTokens(fileURL: fileURL, currentTokenInfo: tokenInfo)
            
            var retryRequest = URLRequest(url: URL(string: "https://api.anthropic.com/api/oauth/usage")!)
            retryRequest.setValue("Bearer \(newTokens.access_token)", forHTTPHeaderField: "Authorization")
            retryRequest.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
            
            let (retryData, retryResponse) = try await URLSession.shared.data(for: retryRequest)
            guard let retryHttpResponse = retryResponse as? HTTPURLResponse, retryHttpResponse.statusCode == 200 else {
                throw NSError(domain: "ClaudeUsageProbe", code: 6, userInfo: [NSLocalizedDescriptionKey: "Usage fetch failed after refresh"])
            }
            return try parseUsage(data: retryData)
        }
        
        guard httpResponse.statusCode == 200 else {
            throw NSError(domain: "ClaudeUsageProbe", code: 7, userInfo: [NSLocalizedDescriptionKey: "HTTP Error \(httpResponse.statusCode)"])
        }
        
        return try parseUsage(data: data)
    }
    
    private func parseUsage(data: Data) throws -> ProviderUsageSnapshot {
        // Actual Anthropic response (oauth/usage):
        // { "five_hour": {"utilization": 30.0, "resets_at": "..."},
        //   "seven_day": null, "seven_day_opus": null, "seven_day_sonnet": null,
        //   "seven_day_oauth_apps": null, "seven_day_omelette": {"utilization": 0.0, "resets_at": null},
        //   "extra_usage": {...} }
        struct Bucket: Decodable {
            let utilization: Double?
            let resets_at: String?
        }

        let decoder = JSONDecoder()
        let raw = try JSONSerialization.jsonObject(with: data, options: []) as? [String: Any] ?? [:]

        let knownBuckets: [(key: String, kind: UsageWindowKind)] = [
            ("five_hour", .other),
            ("seven_day", .weekly),
            ("seven_day_opus", .weekly),
            ("seven_day_sonnet", .weekly),
            ("seven_day_oauth_apps", .weekly),
            ("seven_day_cowork", .weekly),
            ("seven_day_omelette", .weekly)
        ]

        var windows: [UsageWindow] = []
        for (key, kind) in knownBuckets {
            guard let dict = raw[key] as? [String: Any] else { continue }
            let bucketData = try JSONSerialization.data(withJSONObject: dict, options: [])
            let bucket = try decoder.decode(Bucket.self, from: bucketData)
            guard let utilization = bucket.utilization else { continue }
            windows.append(UsageWindow(
                kind: kind,
                limit: 0,
                used: 0,
                percentUsed: utilization,
                resetsAt: Self.parseDate(bucket.resets_at)
            ))
        }

        return ProviderUsageSnapshot(provider: "Claude", lastUpdated: Date(), windows: windows, error: nil)
    }
}
