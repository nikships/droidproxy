import Foundation

class ClaudeUsageProbe {
    private let authDir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".cli-proxy-api")
    
    struct TokenInfo: Codable {
        let access_token: String
        let refresh_token: String?
        let expired: Bool?
    }
    
    func fetchUsage() async -> ProviderUsageSnapshot {
        do {
            let fileURL = try findClaudeAuthFile()
            let data = try Data(contentsOf: fileURL)
            var tokenInfo = try JSONDecoder().decode(TokenInfo.self, from: data)
            
            if tokenInfo.expired == true {
                tokenInfo = try await refreshTokens(fileURL: fileURL, currentTokenInfo: tokenInfo)
            }
            
            return try await executeUsageRequest(token: tokenInfo.access_token, fileURL: fileURL, tokenInfo: tokenInfo)
        } catch {
            return ProviderUsageSnapshot(provider: "Claude", lastUpdated: Date(), windows: [], error: error.localizedDescription)
        }
    }
    
    private func findClaudeAuthFile() throws -> URL {
        let contents = try FileManager.default.contentsOfDirectory(at: authDir, includingPropertiesForKeys: nil)
        for url in contents {
            if url.lastPathComponent.hasPrefix("claude-") && url.lastPathComponent.hasSuffix(".json") {
                return url
            }
        }
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
        
        let body = "client_id=9d1c250a-e61b-44d9-88ed-5944d1962f5e&grant_type=refresh_token&refresh_token=\(refreshToken)"
        request.httpBody = body.data(using: .utf8)
        
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            throw NSError(domain: "ClaudeUsageProbe", code: 3, userInfo: [NSLocalizedDescriptionKey: "Token refresh failed"])
        }
        
        let newTokens = try JSONSerialization.jsonObject(with: data, options: []) as? [String: Any] ?? [:]
        guard let newAccess = newTokens["access_token"] as? String, let newRefresh = newTokens["refresh_token"] as? String else {
            throw NSError(domain: "ClaudeUsageProbe", code: 4, userInfo: [NSLocalizedDescriptionKey: "Invalid token response format"])
        }
        
        // Read existing JSON to preserve structure, just update fields
        var existingJson = try JSONSerialization.jsonObject(with: try Data(contentsOf: fileURL), options: []) as? [String: Any] ?? [:]
        existingJson["access_token"] = newAccess
        existingJson["refresh_token"] = newRefresh
        existingJson["expired"] = false
        
        let newData = try JSONSerialization.data(withJSONObject: existingJson, options: [.prettyPrinted])
        try newData.write(to: fileURL)
        
        return TokenInfo(access_token: newAccess, refresh_token: newRefresh, expired: false)
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
        // Expected Anthropic structure:
        // { "rate_limits": [ { "window": "5h", "limit": 1000, "used": 120, "resets_at": "2026-05-07T..." }, { "window": "weekly", ... } ] }
        struct AnthropicUsage: Codable {
            struct Limit: Codable {
                let window: String
                let limit: Int
                let used: Int
                let resets_at: String?
            }
            let rate_limits: [Limit]
        }
        
        let apiResponse = try JSONDecoder().decode(AnthropicUsage.self, from: data)
        let dateFormatter = ISO8601DateFormatter()
        dateFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let fallbackFormatter = ISO8601DateFormatter()
        
        let windows: [UsageWindow] = apiResponse.rate_limits.map { limit in
            let kind: UsageWindowKind
            if limit.window == "5h" { kind = .other } // Map 5h to other for now, handled by UI
            else if limit.window.lowercased().contains("week") { kind = .weekly }
            else if limit.window.lowercased().contains("hour") { kind = .hourly }
            else { kind = .other }
            
            let percent = limit.limit > 0 ? (Double(limit.used) / Double(limit.limit)) * 100.0 : 0.0
            
            var resetsAt: Date? = nil
            if let resetsStr = limit.resets_at {
                resetsAt = dateFormatter.date(from: resetsStr) ?? fallbackFormatter.date(from: resetsStr)
            }
            
            return UsageWindow(kind: kind, limit: limit.limit, used: limit.used, percentUsed: percent, resetsAt: resetsAt)
        }
        
        return ProviderUsageSnapshot(provider: "Claude", lastUpdated: Date(), windows: windows, error: nil)
    }
}
