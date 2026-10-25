import AppKit
import Combine
import Foundation

/// How a provider's sign-in works: a browser OAuth on this Mac, a device code,
/// or only in DroidProxy's own window (Junie's API key).
enum ConnectKind: String {
    case browser
    case device
    case app
}

extension ServiceType {
    var connectKind: ConnectKind {
        switch self {
        case .claude, .codex, .antigravity, .kimi: return .browser
        case .grok, .copilot, .meta: return .device
        case .junie: return .app
        }
    }

    var authCommand: AuthCommand? {
        switch self {
        case .claude: return .claudeLogin
        case .codex: return .codexLogin
        case .antigravity: return .antigravityLogin
        case .kimi: return .kimiLogin
        case .junie, .grok, .copilot, .meta: return nil
        }
    }
}

/// A sign-in in flight, or the last one that failed (`error` set), for one provider.
struct ProviderConnect: Equatable {
    var startedAt: Date
    var userCode: String?
    var verificationURI: String?
    var error: String?

    var isRunning: Bool { error == nil }
}

enum ConnectOutcome: Equatable {
    case started(ProviderConnect)
    case alreadyRunning
    case needsApp
}

/// Connect, cancel, remove account, the provider switch and Droid's models:
/// the business logic the Settings window and the control API share, so the
/// two never disagree. Main thread only.
@MainActor
final class ProviderController: ObservableObject {
    let serverManager: ServerManager
    let copilotGateway: CopilotGatewayManager
    let metaMuseAuth: MetaMuseAuthManager
    let authManager: AuthManager

    @Published private(set) var connects: [ServiceType: ProviderConnect] = [:]
    /// The Settings rows' spinner: a browser login until its browser step has
    /// started, a Grok login until it finishes.
    @Published private(set) var launching: Set<ServiceType> = []
    @Published private(set) var factoryStatus = FactoryModels.Status(installed: 0, available: 0, stale: false)

    var openSettingsWindow: (() -> Void)?

    static let browserConnectTimeout: TimeInterval = 15 * 60
    private static let serverRestartDelay: TimeInterval = 0.3

    private var generations: [ServiceType: Int] = [:]
    private var authProcesses: [ServiceType: Process] = [:]
    private var grokSession: GrokAuth.LoginSession?
    private var observers: [NSObjectProtocol] = []

    init(
        serverManager: ServerManager,
        copilotGateway: CopilotGatewayManager,
        metaMuseAuth: MetaMuseAuthManager,
        authManager: AuthManager = AuthManager()
    ) {
        self.serverManager = serverManager
        self.copilotGateway = copilotGateway
        self.metaMuseAuth = metaMuseAuth
        self.authManager = authManager
        authManager.checkAuthStatus()
        refreshFactoryStatus()

        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: .authDirectoryChanged, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.authManager.checkAuthStatus() }
        })
        observers.append(center.addObserver(forName: .metaAccountsChanged, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.authManager.checkAuthStatus()
                self?.refreshFactoryStatus()
            }
        })
    }

    deinit {
        observers.forEach(NotificationCenter.default.removeObserver)
    }

    // MARK: - Connect

    func isAuthenticating(_ type: ServiceType) -> Bool {
        switch type {
        case .meta: return metaMuseAuth.state == .authenticating
        case .copilot: return copilotGateway.isAuthenticating
        default: return launching.contains(type)
        }
    }

    /// Whether a sign-in for `type` is running now, whoever started it.
    func isConnecting(_ type: ServiceType) -> Bool {
        switch type {
        case .meta: return metaMuseAuth.state == .authenticating
        case .copilot: return copilotGateway.isAuthenticating
        default: return connects[type]?.isRunning == true
        }
    }

    /// Starts `type`'s sign-in. With `replacing`, a sign-in already running is
    /// cancelled first (the Settings window's Add Account); without it, it is
    /// left alone (`.alreadyRunning`). `onMessage` gets the words the Settings
    /// window shows in its alert.
    @discardableResult
    func connect(_ type: ServiceType, replacing: Bool, onMessage: ((String) -> Void)? = nil) -> ConnectOutcome {
        guard type.connectKind != .app else { return .needsApp }
        if isConnecting(type) {
            guard replacing else { return .alreadyRunning }
            cancelConnect(type)
        }

        let generation = (generations[type] ?? 0) + 1
        generations[type] = generation
        connects[type] = ProviderConnect(startedAt: Date())

        switch type {
        case .grok:
            startGrok(generation: generation, onMessage: onMessage)
        case .copilot:
            startCopilot(generation: generation, onMessage: onMessage)
        case .meta:
            startMeta(generation: generation, onMessage: onMessage)
        default:
            startBrowser(type, generation: generation, onMessage: onMessage)
        }
        return .started(connects[type] ?? ProviderConnect(startedAt: Date()))
    }

    func cancelConnect(_ type: ServiceType) {
        generations[type] = (generations[type] ?? 0) + 1
        switch type {
        case .grok:
            grokSession?.cancel()
            grokSession = nil
        case .copilot:
            copilotGateway.cancelAuthentication()
        case .meta:
            metaMuseAuth.cancelAuthentication()
        default:
            if let process = authProcesses.removeValue(forKey: type), process.isRunning {
                process.terminate()
            }
        }
        launching.remove(type)
        connects[type] = nil
    }

    private func isCurrent(_ type: ServiceType, _ generation: Int) -> Bool {
        generations[type] == generation
    }

    private func finishConnect(_ type: ServiceType, _ generation: Int) {
        guard isCurrent(type, generation) else { return }
        launching.remove(type)
        connects[type] = nil
    }

    private func failConnect(_ type: ServiceType, _ generation: Int, _ error: String) {
        guard isCurrent(type, generation) else { return }
        launching.remove(type)
        guard var connect = connects[type], connect.isRunning else { return }
        connect.error = error
        connect.userCode = nil
        connect.verificationURI = nil
        connects[type] = connect
    }

    private func showCode(_ type: ServiceType, _ generation: Int, code: String, uri: String) {
        guard isCurrent(type, generation), var connect = connects[type], connect.isRunning else { return }
        connect.userCode = code
        connect.verificationURI = uri
        connects[type] = connect
    }

    private func startBrowser(_ type: ServiceType, generation: Int, onMessage: ((String) -> Void)?) {
        guard let command = type.authCommand else { return }
        launching.insert(type)
        NSLog("[ProviderController] Starting %@ authentication", type.displayName)

        let process = serverManager.runAuthCommand(command, onExit: { [weak self] status in
            DispatchQueue.main.async {
                guard let self, self.isCurrent(type, generation) else { return }
                self.authProcesses[type] = nil
                if status == 0 {
                    self.finishConnect(type, generation)
                } else {
                    self.failConnect(type, generation, "The \(type.displayName) sign-in ended before it finished. Try again.")
                }
            }
        }) { [weak self] success, output in
            NSLog("[ProviderController] Auth completed - success: %d, output: %@", success, output)
            DispatchQueue.main.async {
                guard let self, self.isCurrent(type, generation) else { return }
                self.launching.remove(type)
                if success {
                    onMessage?(Self.browserStartedMessage(for: type))
                } else {
                    let details = output.isEmpty ? "No output from authentication process" : output
                    onMessage?("Authentication failed. Please check if the browser opened and try again.\n\nDetails: \(details)")
                    let firstLine = details.split(whereSeparator: \.isNewline).first.map(String.init) ?? details
                    self.failConnect(type, generation, "The \(type.displayName) sign-in didn't start: \(firstLine)")
                }
            }
        }
        if let process {
            authProcesses[type] = process
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + Self.browserConnectTimeout) { [weak self] in
            guard let self, self.isCurrent(type, generation), self.connects[type]?.isRunning == true else { return }
            if let process = self.authProcesses.removeValue(forKey: type), process.isRunning {
                process.terminate()
            }
            self.failConnect(type, generation, "The \(type.displayName) sign-in timed out. Try again.")
        }
    }

    private static func browserStartedMessage(for type: ServiceType) -> String {
        switch type {
        case .claude:
            return "🌐 Browser opened for Claude Code authentication.\n\nPlease complete the login in your browser.\n\nThe app will automatically detect your credentials."
        case .codex:
            return "🌐 Browser opened for Codex authentication.\n\nPlease complete the login in your browser.\n\nThe app will automatically detect your credentials."
        case .antigravity:
            return "🌐 Browser opened for Antigravity authentication.\n\nYou must have Google Antigravity installed before adding an Antigravity account.\n\nPlease complete the login in your browser.\n\nThe app will automatically detect your credentials.\n\nIf having issues, run in terminal:\n/Applications/DroidProxy.app/Contents/Resources/cli-proxy-api --config ~/.cli-proxy-api/merged-config.yaml -antigravity-login"
        case .kimi:
            return "🌐 Browser opened for Kimi authentication.\n\nPlease complete the login in your browser.\n\nThe app will automatically detect your credentials."
        case .junie:
            return "✓ Successfully saved Junie API Key."
        case .grok:
            return "🌐 Browser opened for Grok (xAI) authentication.\n\nApprove access for SuperGrok / X Premium+, then DroidProxy will save credentials automatically."
        case .copilot:
            return "🌐 GitHub Copilot sign-in started."
        case .meta:
            return "🌐 Meta Muse sign-in started."
        }
    }

    private func startGrok(generation: Int, onMessage: ((String) -> Void)?) {
        grokSession?.cancel()
        grokSession = nil
        launching.insert(.grok)
        NSLog("[ProviderController] Starting Grok xAI OAuth device login")

        grokSession = GrokAuth.startDeviceLogin(
            onPrompt: { [weak self] auth in
                DispatchQueue.main.async {
                    guard let self, self.isCurrent(.grok, generation) else { return }
                    self.showCode(.grok, generation, code: auth.userCode, uri: auth.verificationURIComplete)
                    onMessage?("🌐 Browser opened for Grok login.\n\nIf prompted, enter code: \(auth.userCode)\n\nWaiting for approval…")
                }
            },
            completion: { [weak self] result in
                DispatchQueue.main.async {
                    guard let self, self.isCurrent(.grok, generation) else { return }
                    switch result {
                    case .success(let creds):
                        self.grokSession = nil
                        self.finishConnect(.grok, generation)
                        self.authManager.checkAuthStatus()
                        let who = creds.email ?? "grok-user"
                        onMessage?("✓ Grok OAuth connected as \(who).\n\nSelect DroidProxy: Grok 4.7 or DroidProxy: Grok 4.7 Fast in Droid with `/model`.")
                    case .failure(.cancelled):
                        break
                    case .failure(.reauthRequired):
                        self.grokSession = nil
                        let message = "Grok session expired. Reconnect Grok in Settings."
                        self.failConnect(.grok, generation, message)
                        onMessage?(message)
                    case .failure(let error):
                        self.grokSession = nil
                        let message = "Grok login failed: \(error.localizedDescription)"
                        self.failConnect(.grok, generation, message)
                        onMessage?(message)
                    }
                }
            }
        )
    }

    private func startCopilot(generation: Int, onMessage: ((String) -> Void)?) {
        copilotGateway.startAuthentication(
            onDeviceCode: { [weak self] code, verificationURL in
                DispatchQueue.main.async {
                    self?.showCode(.copilot, generation, code: code, uri: verificationURL.absoluteString)
                }
            },
            completion: { [weak self] result in
                DispatchQueue.main.async {
                    guard let self, self.isCurrent(.copilot, generation) else { return }
                    switch result {
                    case .success:
                        self.finishConnect(.copilot, generation)
                        self.copilotGateway.start()
                        onMessage?("GitHub Copilot connected.\n\nThe local gateway is starting. Select Refresh Models, choose up to three models, then Re-apply Factory custom models.")
                    case .failure(let error):
                        self.failConnect(.copilot, generation, "GitHub Copilot sign-in failed: \(error.localizedDescription)")
                        onMessage?("GitHub Copilot authentication failed: \(error.localizedDescription)")
                    }
                }
            }
        )
    }

    private func startMeta(generation: Int, onMessage: ((String) -> Void)?) {
        metaMuseAuth.startAuthentication(
            onDeviceCode: { [weak self] code, verificationURL in
                DispatchQueue.main.async {
                    self?.showCode(.meta, generation, code: code, uri: verificationURL.absoluteString)
                }
            },
            completion: { [weak self] result in
                DispatchQueue.main.async {
                    guard let self, self.isCurrent(.meta, generation) else { return }
                    switch result {
                    case .success:
                        self.finishConnect(.meta, generation)
                        onMessage?("Meta Muse connected.\n\nMuse Wonder 1.0 and Muse Wonder 1.0 Contributor are now available. Re-apply Factory custom models to pick them up.")
                    case .failure(let error):
                        self.failConnect(.meta, generation, "Meta Muse sign-in failed: \(error.localizedDescription)")
                        onMessage?("Meta Muse authentication failed: \(error.localizedDescription)")
                    }
                    self.refreshFactoryStatus()
                }
            }
        )
    }

    /// Junie connects with an API key typed into the Settings window.
    func saveJunieAPIKey(_ apiKey: String) -> String? {
        guard !apiKey.isEmpty else { return nil }

        let fileURL = AuthPaths.authDirectory.appendingPathComponent("junie.json")
        let json: [String: Any] = [
            "type": "junie",
            "email": "junie-user",
            "apiKey": apiKey,
            "disabled": false
        ]

        do {
            try FileManager.default.createDirectory(at: AuthPaths.authDirectory, withIntermediateDirectories: true)
            let data = try JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted])
            try data.write(to: fileURL)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
            NSLog("[ProviderController] Saved Junie API Key with secure permissions to \(fileURL.path)")
            authManager.checkAuthStatus()
            return "✓ Successfully added Junie API Key."
        } catch {
            NSLog("[ProviderController] Failed to save Junie API Key: \(error.localizedDescription)")
            return "Failed to save Junie API Key: \(error.localizedDescription)"
        }
    }

    // MARK: - Accounts

    /// Forgets an account. Removing a backend account restarts a running
    /// backend around the file deletion, as the Settings window always has.
    func removeAccount(_ account: AuthAccount, completion: @escaping (Bool) -> Void) {
        if account.type == .meta {
            let removed = authManager.deleteAccount(account)
            refreshFactoryStatus()
            completion(removed)
            return
        }
        let wasRunning = serverManager.isRunning
        let cleanup = { [weak self] in
            guard let self else { return }
            let removed = self.authManager.deleteAccount(account)
            completion(removed)
            if wasRunning {
                DispatchQueue.main.asyncAfter(deadline: .now() + Self.serverRestartDelay) {
                    self.serverManager.start { _ in }
                }
            }
        }
        if wasRunning {
            serverManager.stop {
                MainActor.assumeIsolated { cleanup() }
            }
        } else {
            cleanup()
        }
    }

    /// Copilot's single sign-in lives in its gateway's token file, not in `~/.cli-proxy-api`.
    @discardableResult
    func disconnectCopilot() -> Bool {
        guard copilotGateway.disconnect() else { return false }
        CopilotModelPreferences.saveSelectedModelIDs([])
        cancelConnect(.copilot)
        refreshFactoryStatus()
        return true
    }

    // MARK: - Provider switch

    func setProviderEnabled(_ type: ServiceType, enabled: Bool) {
        serverManager.setProviderEnabled(type, enabled: enabled)
        switch type {
        case .copilot:
            if enabled, copilotGateway.hasCredentials {
                copilotGateway.start()
            } else if !enabled {
                copilotGateway.stop()
                cancelConnect(.copilot)
            }
        case .meta:
            if enabled {
                metaMuseAuth.refreshAPIKeyIfNeeded()
            } else {
                cancelConnect(.meta)
            }
        default:
            break
        }
        refreshFactoryStatus()
    }

    // MARK: - Droid's models

    func enabledFactorySettingsModels() -> [[String: Any]] {
        DroidProxyModelCatalog.settingsModels { [serverManager] providerKey in
            guard let serviceType = ServiceType(authFileType: providerKey) else { return true }
            return serverManager.isProviderEnabled(serviceType)
        }
    }

    func refreshFactoryStatus() {
        let status = FactoryModels.status(
            settingsAt: FactoryModels.settingsURL,
            expected: enabledFactorySettingsModels(),
            catalogIDs: DroidProxyModelCatalog.allSettingsIDs
        )
        if status != factoryStatus {
            factoryStatus = status
        }
    }

    func applyFactoryModels() -> Result<FactoryModels.ApplyResult, Error> {
        let result = Result(catching: {
            try FactoryModels.apply(
                settingsAt: FactoryModels.settingsURL,
                models: enabledFactorySettingsModels(),
                catalogIDs: DroidProxyModelCatalog.allSettingsIDs
            )
        })
        if case .failure(let error) = result {
            NSLog("[ProviderController] Failed to apply Factory custom models: %@", error.localizedDescription)
        }
        refreshFactoryStatus()
        return result
    }
}
