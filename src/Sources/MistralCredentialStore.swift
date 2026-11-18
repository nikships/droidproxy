import CryptoKit
import Foundation

struct MistralAccount: Codable, Identifiable, Equatable {
    enum Source: String, Codable {
        case browser
        case pasted
    }

    /// SHA-256 hex of `apiKey`, so saving the same key twice is one account.
    let id: String
    var label: String?
    var apiKey: String
    var source: Source
    var addedAt: Date
    var disabled: Bool

    var displayName: String {
        if let label, !label.isEmpty { return label }
        return "Mistral ••••\(apiKey.suffix(4))"
    }
}

/// Mistral keys are long-lived API keys (from the Vibe browser sign-in or pasted), so
/// there is no expiry and no refresh. They live outside `~/.cli-proxy-api`; the
/// backend only sees them through the `openai-compatibility` block.
final class MistralCredentialStore {
    static let shared = MistralCredentialStore(directory: FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".droidproxy/mistral"))

    static let baseURL = "https://api.mistral.ai/v1"

    /// The one list the backend config and the Factory catalog both read.
    static let modelIDs = [
        "mistral-large-4",
        "mistral-medium-3-5",
        "mistral-small-latest",
        "zai-glm-5-3",
        "zai-glm-5-3-flash"
    ]

    let directory: URL
    var accountsURL: URL { directory.appendingPathComponent("accounts.json") }
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

    var accounts: [MistralAccount] {
        lock.lock()
        defer { lock.unlock() }
        do { return try load() }
        catch {
            NSLog("[Mistral] Could not load account store: %@", error.localizedDescription)
            return []
        }
    }

    var hasUsableAPIKey: Bool { !Self.usableAPIKeys(accounts: accounts).isEmpty }

    private func load() throws -> [MistralAccount] {
        guard FileManager.default.fileExists(atPath: accountsURL.path) else { return [] }
        return try decoder.decode([MistralAccount].self, from: Data(contentsOf: accountsURL))
    }

    private func write(_ accounts: [MistralAccount]) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                               attributes: [.posixPermissions: 0o700])
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        try encoder.encode(accounts).write(to: accountsURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: accountsURL.path)
    }

    /// A corrupt file is never overwritten: `load` throws and the change is dropped.
    private func mutate(_ update: (inout [MistralAccount]) -> Bool) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        do {
            var accounts = try load()
            guard update(&accounts) else { return false }
            try write(accounts)
            DispatchQueue.main.async {
                NotificationCenter.default.post(name: .mistralAccountsChanged, object: self)
            }
            return true
        } catch {
            NSLog("[Mistral] Could not update account store: %@", error.localizedDescription)
            return false
        }
    }

    static func accountID(for apiKey: String) -> String {
        SHA256.hash(data: Data(apiKey.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    @discardableResult
    func save(apiKey: String, label: String?, source: MistralAccount.Source, now: Date = Date()) -> Bool {
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return false }
        let trimmedLabel = label?.trimmingCharacters(in: .whitespacesAndNewlines)
        let newLabel = (trimmedLabel?.isEmpty ?? true) ? nil : trimmedLabel
        let id = Self.accountID(for: key)
        return mutate { accounts in
            if let index = accounts.firstIndex(where: { $0.id == id }) {
                if let newLabel { accounts[index].label = newLabel }
                accounts[index].source = source
            } else {
                accounts.append(MistralAccount(id: id, label: newLabel, apiKey: key, source: source,
                                               addedAt: now, disabled: false))
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

    /// `expired` is nil: a Mistral key has no expiry, so it is never shown as expired.
    var authAccounts: [AuthAccount] {
        accounts.map {
            AuthAccount(id: $0.id, email: nil, login: $0.displayName, type: .mistral,
                        expired: nil, filePath: accountsURL, isDisabled: $0.disabled,
                        organizationName: nil, claudeSeatLabel: nil)
        }
    }

    static func usableAPIKeys(accounts: [MistralAccount]) -> [String] {
        accounts.filter { !$0.disabled }.map(\.apiKey).filter { !$0.isEmpty }
    }

    func compatibilityEntry(enabled: Bool) -> OpenAICompatibilityConfig.Entry? {
        Self.compatibilityEntry(accounts: accounts, enabled: enabled)
    }

    /// CLIProxyAPI's Responses-to-Chat translation adds `reasoning_content` to every
    /// assistant tool-call message whenever reasoning is on (`"[reasoning unavailable]"`
    /// without real text), for DeepSeek-style APIs. Mistral rejects unknown message
    /// fields (422 `extra_forbidden`), so the backend's payload filter strips it from
    /// the final upstream body. A plain `#` path deletes nothing; it needs a `#(...)#` query.
    static func payloadFilterConfig(accounts: [MistralAccount], enabled: Bool) -> String {
        guard compatibilityEntry(accounts: accounts, enabled: enabled) != nil else { return "" }
        var lines = ["", "# Mistral message filter (auto-added by DroidProxy)", "payload:", "  filter:", "    - models:"]
        lines += modelIDs.map { "        - name: \"\($0)\"\n          protocol: \"openai\"" }
        lines += ["      params:", "        - 'messages.#(reasoning_content)#.reasoning_content'"]
        return lines.joined(separator: "\n") + "\n"
    }

    static func compatibilityEntry(accounts: [MistralAccount], enabled: Bool) -> OpenAICompatibilityConfig.Entry? {
        let keys = usableAPIKeys(accounts: accounts)
        guard enabled, !keys.isEmpty else { return nil }
        return OpenAICompatibilityConfig.Entry(
            comment: "Mistral",
            name: "mistral",
            baseURL: baseURL,
            apiKeys: keys,
            models: modelIDs
        )
    }
}
