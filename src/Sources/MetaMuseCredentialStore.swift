import CryptoKit
import Foundation

struct MetaMuseAccount: Codable, Identifiable {
    let id: String
    var email: String?
    var credentials: MetaMuseCredentials
    var disabled: Bool

    var displayName: String { email ?? "Meta account \(id.prefix(8))" }
}

/// All mutations are serialized, including compare-and-swap refreshes. A late
/// network response must never restore an account removed while refreshing.
final class MetaMuseCredentialStore {
    static let shared = MetaMuseCredentialStore(directory: FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".droidproxy/meta"))

    let directory: URL
    var accountsURL: URL { directory.appendingPathComponent("accounts.json") }
    private var legacyURL: URL { directory.appendingPathComponent("credentials.json") }
    private let lock = NSRecursiveLock()
    private let decoder: JSONDecoder
    private let encoder: JSONEncoder

    init(directory: URL) {
        self.directory = directory
        decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
    }

    var accounts: [MetaMuseAccount] {
        lock.lock()
        defer { lock.unlock() }
        do { return try load() }
        catch {
            NSLog("[Meta] Could not load account store: %@", error.localizedDescription)
            return []
        }
    }

    var hasCredentials: Bool { !accounts.isEmpty }
    var hasUsableAPIKey: Bool { !Self.usableAPIKeys(accounts: accounts).isEmpty }

    private func load() throws -> [MetaMuseAccount] {
        if FileManager.default.fileExists(atPath: accountsURL.path) {
            return try decoder.decode([MetaMuseAccount].self, from: Data(contentsOf: accountsURL))
        }
        guard FileManager.default.fileExists(atPath: legacyURL.path) else { return [] }
        let credentials = try decoder.decode(MetaMuseCredentials.self, from: Data(contentsOf: legacyURL))
        let migrated = [Self.account(for: credentials)]
        try write(migrated)
        // The new store is authoritative even if legacy cleanup fails.
        try? FileManager.default.removeItem(at: legacyURL)
        return migrated
    }

    private func write(_ accounts: [MetaMuseAccount]) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                               attributes: [.posixPermissions: 0o700])
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        try encoder.encode(accounts).write(to: accountsURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: accountsURL.path)
    }

    private func mutate(_ update: (inout [MetaMuseAccount]) -> Bool) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        do {
            var accounts = try load()
            guard update(&accounts) else { return false }
            try write(accounts)
            DispatchQueue.main.async {
                NotificationCenter.default.post(name: .metaAccountsChanged, object: self)
            }
            return true
        } catch {
            NSLog("[Meta] Could not update account store: %@", error.localizedDescription)
            return false
        }
    }

    @discardableResult
    func save(_ credentials: MetaMuseCredentials) -> Bool {
        let account = Self.account(for: credentials)
        return mutate { accounts in
            if let index = accounts.firstIndex(where: { $0.id == account.id }) {
                accounts[index].credentials = credentials
                accounts[index].email = account.email ?? accounts[index].email
            } else {
                accounts.append(account)
            }
            return true
        }
    }

    @discardableResult
    func remove(id: String) -> Bool {
        mutate { accounts in
            guard accounts.contains(where: { $0.id == id }) else { return false }
            accounts.removeAll { $0.id == id }
            return true
        }
    }

    @discardableResult
    func toggleDisabled(id: String) -> Bool {
        mutate { accounts in
            guard let index = accounts.firstIndex(where: { $0.id == id }) else { return false }
            guard accounts[index].disabled || accounts.filter({ !$0.disabled }).count > 1 else { return false }
            accounts[index].disabled.toggle()
            return true
        }
    }

    @discardableResult
    func updateKey(for snapshot: MetaMuseAccount, apiKey: String, expiresAt: Date) -> Bool {
        mutate { accounts in
            guard let index = accounts.firstIndex(where: { $0.id == snapshot.id }),
                  accounts[index].credentials == snapshot.credentials else { return false }
            accounts[index].credentials.apiKey = apiKey
            accounts[index].credentials.apiKeyExpiresAt = expiresAt
            return true
        }
    }

    static func account(for credentials: MetaMuseCredentials) -> MetaMuseAccount {
        // JWT claims are display/deduplication hints only, never authorization.
        let parts = credentials.identityToken.split(separator: ".")
        var claims: [String: Any] = [:]
        if parts.count == 3 {
            var payload = String(parts[1]).replacingOccurrences(of: "-", with: "+")
                .replacingOccurrences(of: "_", with: "/")
            payload += String(repeating: "=", count: (4 - payload.count % 4) % 4)
            if let data = Data(base64Encoded: payload),
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                claims = json
            }
        }
        let subject = claims["sub"] as? String
        let identity = subject.flatMap { $0.isEmpty ? nil : "\((claims["iss"] as? String) ?? ""):\($0)" }
            ?? credentials.identityToken
        let id = SHA256.hash(data: Data(identity.utf8)).map { String(format: "%02x", $0) }.joined()
        let email = (claims["email"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        return MetaMuseAccount(id: id, email: email, credentials: credentials, disabled: false)
    }

    var authAccounts: [AuthAccount] {
        accounts.map {
            AuthAccount(id: $0.id, email: $0.email, login: $0.displayName, type: .meta,
                        expired: $0.credentials.apiKeyExpiresAt, filePath: accountsURL,
                        isDisabled: $0.disabled, organizationName: nil, claudeSeatLabel: nil)
        }
    }

    static func usableAPIKeys(accounts: [MetaMuseAccount], now: Date = Date()) -> [String] {
        accounts.filter { !$0.disabled && $0.credentials.apiKeyExpiresAt > now }
            .map(\.credentials.apiKey).filter { !$0.isEmpty }
    }

    static func compatibilityConfig(accounts: [MetaMuseAccount], enabled: Bool, now: Date = Date()) -> String {
        let keys = usableAPIKeys(accounts: accounts, now: now)
        guard enabled, !keys.isEmpty else { return "" }
        // Completions still go through this compatibility block (and its
        // account failover). Responses are TLS-forwarded by ThinkingProxy —
        // CLIProxyAPI would otherwise rewrite them into `/chat/completions`.
        // JSON strings are valid YAML scalars, including quotes/control characters.
        let entries = keys.map { key in
            let quoted = String(data: try! JSONEncoder().encode(key), encoding: .utf8)!
            return "      - api-key: \(quoted)"
        }.joined(separator: "\n")
        return """

        # Meta Muse subscription (auto-added by DroidProxy)
        openai-compatibility:
          - name: "meta"
            base-url: "https://api.meta.ai/v1"
            api-key-entries:
        \(entries)
            models:
              - name: "muse-spark-1.3"
              - name: "muse-spark-1.3-contributor"

        """
    }
}
