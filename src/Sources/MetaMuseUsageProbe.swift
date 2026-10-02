import Foundation

/// Meta has no usage endpoint, and the quota only rides along on streamed
/// `/v1/responses` traffic, so a snapshot sniffed from real requests goes stale
/// whenever Meta is idle. The probe asks for a 16-token streamed completion per
/// account (about 2.5s) and records the `response.subscription_usage` event,
/// the same data the proxy would have sniffed. The stream is dropped as soon as
/// the event arrives.
enum MetaMuseUsageProbe {
    /// Real traffic or an earlier probe this recent already counts as fresh,
    /// which also keeps polling agents from burning quota on probes.
    static let minimumInterval: TimeInterval = 60
    static let requestTimeout: TimeInterval = 20

    static func isFresh(_ snapshot: MetaMuseUsageSnapshot?, now: Date = Date()) -> Bool {
        guard let snapshot else { return false }
        return now.timeIntervalSince(snapshot.observedAt) < minimumInterval
    }

    /// Records a fresh snapshot for the account when its stored one is older than
    /// `minimumInterval` (or always, with `force`). Silently keeps the stored
    /// snapshot on any failure so the card falls back to its "as of" value.
    /// Returns whether a request completed and recorded a snapshot.
    @discardableResult
    static func refresh(accountID: String, force: Bool = false, store: MetaMuseUsageStore = .shared) async -> Bool {
        guard force || !isFresh(store.snapshot(for: accountID)) else { return false }
        guard let account = MetaMuseCredentialStore.shared.accounts.first(where: {
            $0.id == accountID && !$0.disabled && !$0.credentials.apiKey.isEmpty
                && $0.credentials.apiKeyExpiresAt > Date()
        }) else { return false }

        var request = URLRequest(url: URL(string: "https://\(MetaMuseUpstream.apiHost)/v1/responses")!)
        request.httpMethod = "POST"
        request.timeoutInterval = requestTimeout
        request.setValue("Bearer \(account.credentials.apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        request.setValue("muse-build/1.3.0", forHTTPHeaderField: "User-Agent")
        request.httpBody = Data(#"{"model":"muse-spark-1.3","input":"hi","max_output_tokens":16,"stream":true}"#.utf8)

        do {
            let (bytes, response) = try await URLSession.shared.bytes(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else {
                NSLog("[Meta] Usage probe got HTTP %d", (response as? HTTPURLResponse)?.statusCode ?? -1)
                return false
            }
            for try await line in bytes.lines where line.hasPrefix("data:") && line.contains("response.subscription_usage") {
                guard let snapshot = MetaMuseUsageEvent.parse(dataLine: line, observedAt: Date()) else { return false }
                store.record(accountID: accountID, snapshot: snapshot)
                return true
            }
        } catch {
            NSLog("[Meta] Usage probe failed: %@", error.localizedDescription)
        }
        return false
    }
}
