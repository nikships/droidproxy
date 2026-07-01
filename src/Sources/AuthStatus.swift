import Foundation

enum ServiceType: String, CaseIterable {
    case claude
    case codex
    case antigravity
    case kimi
    case cursor
    case grok

    init?(authFileType: String) {
        switch authFileType.lowercased() {
        case "claude":
            self = .claude
        case "codex":
            self = .codex
        case "antigravity", "gemini", "gemini-cli":
            self = .antigravity
        case "kimi":
            self = .kimi
        case "cursor":
            self = .cursor
        case "grok-cli", "grok":
            self = .grok
        default:
            return nil
        }
    }

    var displayName: String {
        switch self {
        case .claude: return "Claude Code"
        case .codex: return "Codex"
        case .antigravity: return "Antigravity"
        case .kimi: return "Kimi"
        case .cursor: return "Cursor"
        case .grok: return "Grok CLI"
        }
    }
}

/// Represents a single authenticated account
struct AuthAccount: Identifiable, Equatable {
    let id: String  // filename
    let email: String?
    let login: String?  // for Copilot
    let type: ServiceType
    let expired: Date?
    let filePath: URL
    let isDisabled: Bool

    var isExpired: Bool {
        guard let expired else { return false }
        return expired < Date()
    }

    var displayName: String {
        if let email, !email.isEmpty { return email }
        if let login, !login.isEmpty { return login }
        return id
    }

    static func == (lhs: AuthAccount, rhs: AuthAccount) -> Bool {
        lhs.id == rhs.id
    }
}

/// Tracks all accounts for a service type
struct ServiceAccounts {
    var type: ServiceType
    var accounts: [AuthAccount] = []

    var hasAccounts: Bool { !accounts.isEmpty }
}

class AuthManager: ObservableObject {
    @Published var serviceAccounts: [ServiceType: ServiceAccounts] = AuthManager.emptyAccounts()

    private static let dateFormatters: [ISO8601DateFormatter] = {
        let withFractional = ISO8601DateFormatter()
        withFractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let standard = ISO8601DateFormatter()
        standard.formatOptions = [.withInternetDateTime]
        return [withFractional, standard]
    }()

    func accounts(for type: ServiceType) -> [AuthAccount] {
        serviceAccounts[type]?.accounts ?? []
    }

    func hasAccounts(for type: ServiceType) -> Bool {
        serviceAccounts[type]?.hasAccounts ?? false
    }

    func checkAuthStatus() {
        let authDir = AuthPaths.authDirectory
        let files: [URL]
        do {
            files = try FileManager.default.contentsOfDirectory(at: authDir, includingPropertiesForKeys: nil)
        } catch {
            NSLog("[AuthStatus] Error checking auth status: %@", error.localizedDescription)
            let empty = Self.emptyAccounts()
            DispatchQueue.main.async { self.serviceAccounts = empty }
            return
        }

        NSLog("[AuthStatus] Scanning %d files in auth directory", files.count)
        var newAccounts = Self.emptyAccounts()
        for file in files where file.pathExtension == "json" {
            NSLog("[AuthStatus] Checking file: %@", file.lastPathComponent)
            guard let account = parseAccount(from: file) else { continue }
            newAccounts[account.type]?.accounts.append(account)
            NSLog("[AuthStatus] Found %@ auth: %@", account.type.displayName, account.displayName)
        }

        DispatchQueue.main.async {
            self.serviceAccounts = newAccounts
        }
    }

    /// Toggle the disabled state of a specific account's auth file
    func toggleAccountDisabled(_ account: AuthAccount) -> Bool {
        do {
            let data = try Data(contentsOf: account.filePath)
            guard var json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                NSLog("[AuthStatus] Failed to parse auth file as JSON: %@", account.filePath.path)
                return false
            }
            let currentlyDisabled = json["disabled"] as? Bool ?? false
            if !currentlyDisabled {
                let enabledCount = serviceAccounts[account.type]?.accounts.filter { !$0.isDisabled }.count ?? 0
                guard enabledCount > 1 else {
                    NSLog("[AuthStatus] Refusing to disable last enabled account for %@", account.type.rawValue)
                    return false
                }
            }
            json["disabled"] = !currentlyDisabled
            let updatedData = try JSONSerialization.data(withJSONObject: json, options: [.sortedKeys])
            try updatedData.write(to: account.filePath, options: .atomic)
            NSLog("[AuthStatus] Toggled disabled=%d for: %@", !currentlyDisabled, account.filePath.path)
            checkAuthStatus()
            return true
        } catch {
            NSLog("[AuthStatus] Failed to toggle disabled state: %@", error.localizedDescription)
            return false
        }
    }

    /// Delete a specific account's auth file
    func deleteAccount(_ account: AuthAccount) -> Bool {
        do {
            try FileManager.default.removeItem(at: account.filePath)
            NSLog("[AuthStatus] Deleted auth file: %@", account.filePath.path)
            checkAuthStatus()
            return true
        } catch {
            NSLog("[AuthStatus] Failed to delete auth file: %@", error.localizedDescription)
            return false
        }
    }

    private static func emptyAccounts() -> [ServiceType: ServiceAccounts] {
        Dictionary(uniqueKeysWithValues: ServiceType.allCases.map { ($0, ServiceAccounts(type: $0)) })
    }

    private func parseAccount(from file: URL) -> AuthAccount? {
        guard let data = try? Data(contentsOf: file),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let typeString = json["type"] as? String,
              let serviceType = ServiceType(authFileType: typeString) else {
            return nil
        }

        NSLog("[AuthStatus] Found type '%@' in %@", typeString, file.lastPathComponent)

        return AuthAccount(
            id: file.lastPathComponent,
            email: json["email"] as? String,
            login: json["login"] as? String,
            type: serviceType,
            expired: parseExpiry(json["expired"] as? String),
            filePath: file,
            isDisabled: json["disabled"] as? Bool ?? false
        )
    }

    private func parseExpiry(_ value: String?) -> Date? {
        guard let value else { return nil }
        for formatter in Self.dateFormatters {
            if let date = formatter.date(from: value) { return date }
        }
        return nil
    }
}
