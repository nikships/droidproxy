import Foundation

/// The usage `GET /droidproxy/control/models` judges by: the same 15-second
/// cache `/droidproxy/usage` keeps when it is fresh, else one fetch of the
/// same accounts, kept for 15 seconds even when an account failed, so the
/// office's polling never hammers the upstream usage APIs. Meta is read from
/// its stored snapshot without a probe, because a probe spends quota.
enum ControlUsage {
    private static let ttl: TimeInterval = 15
    private static let lock = NSLock()
    private static var cache: (storedAt: Date, usages: [OAuthAccountUsage])?

    static func usages(
        codex: [AuthAccount],
        claude: [AuthAccount],
        grok: [AuthAccount],
        meta: [AuthAccount],
        now: Date
    ) async -> [OAuthAccountUsage] {
        if let shared = UsageEndpoint.cachedUsages(for: UsageEndpoint.Filter(), now: now) {
            return shared
        }
        if let own = cached(now: now) {
            return own
        }
        var usages = await OAuthUsageTracker.fetchUsage(codex: codex, claude: claude, grok: grok, meta: [])
        usages += meta.map(OAuthUsageTracker.storedMetaUsage(for:))
        store(usages, now: now)
        return usages
    }

    private static func cached(now: Date) -> [OAuthAccountUsage]? {
        lock.lock()
        defer { lock.unlock() }
        guard let cache, now.timeIntervalSince(cache.storedAt) < ttl else { return nil }
        return cache.usages
    }

    private static func store(_ usages: [OAuthAccountUsage], now: Date) {
        lock.lock()
        defer { lock.unlock() }
        cache = (now, usages)
    }
}

extension ProviderController: ControlBackend {
    private static let copilotAccountID = "github_token"

    private var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
    }

    private func controlAccounts(_ type: ServiceType) -> [AuthAccount] {
        authManager.accounts(for: type)
    }

    func controlStatus() -> ControlStatus {
        refreshFactoryStatus()
        let providers = ServiceType.allCases.map { type -> ControlProvider in
            let accounts: [ControlAccount]
            if type == .copilot {
                accounts = copilotGateway.hasCredentials
                    ? [ControlAccount(id: Self.copilotAccountID, label: type.displayName, expired: false, disabled: false)]
                    : []
            } else {
                accounts = controlAccounts(type).map {
                    ControlAccount(id: $0.id, label: $0.displayName, expired: $0.isExpired, disabled: $0.isDisabled)
                }
            }
            return ControlProvider(
                key: type,
                name: type.controlName,
                enabled: serverManager.isProviderEnabled(type),
                accounts: accounts,
                connecting: connects[type]
            )
        }
        return ControlStatus(
            version: appVersion,
            backendRunning: serverManager.isRunning,
            providers: providers,
            factory: factoryStatus
        )
    }

    func controlConnect(_ provider: ServiceType) -> ConnectOutcome {
        connect(provider, replacing: false)
    }

    func controlCancelConnect(_ provider: ServiceType) {
        cancelConnect(provider)
    }

    func controlRemoveAccount(_ provider: ServiceType, account wanted: String) async -> ControlAPI.Response? {
        if provider == .copilot {
            guard wanted == Self.copilotAccountID, copilotGateway.hasCredentials else {
                return .error(404, "GitHub Copilot has no account \"\(wanted)\".")
            }
            return disconnectCopilot() ? nil : .error(500, "Couldn't remove the GitHub Copilot sign-in.")
        }
        let matches = Self.controlAccounts(named: wanted, in: controlAccounts(provider))
        guard let account = matches.first else {
            return .error(404, "\(provider.controlName) has no account \"\(wanted)\".")
        }
        guard matches.count == 1 else {
            return .error(409, "\(provider.controlName) has several accounts for \"\(wanted)\". Name one by its id.")
        }
        let removed = await withCheckedContinuation { continuation in
            removeAccount(account) { continuation.resume(returning: $0) }
        }
        return removed ? nil : .error(500, "Couldn't remove \(account.displayName).")
    }

    /// The accounts `wanted` names: the one with that id, else every one with that email. A Claude
    /// email can hold a seat in several organizations, so an email alone may name more than one.
    nonisolated static func controlAccounts(named wanted: String, in accounts: [AuthAccount]) -> [AuthAccount] {
        if let byID = accounts.first(where: { $0.id == wanted }) { return [byID] }
        let needle = wanted.lowercased()
        return accounts.filter { $0.email?.lowercased() == needle }
    }

    func controlSetProviderEnabled(_ provider: ServiceType, enabled: Bool) {
        setProviderEnabled(provider, enabled: enabled)
    }

    func controlApplyFactoryModels() -> Result<FactoryModels.ApplyResult, Error> {
        applyFactoryModels()
    }

    func controlOpenSettings() {
        openSettingsWindow?()
    }

    func controlModels(now: Date) async -> [ControlModel] {
        var accounts: [ServiceType: [AuthAccount]] = [:]
        var enabled: [ServiceType: Bool] = [:]
        for type in ServiceType.allCases {
            accounts[type] = controlAccounts(type)
            enabled[type] = serverManager.isProviderEnabled(type)
        }
        let activeGrok = OAuthUsageTracker.activeGrokAccounts(accounts[.grok] ?? [])
        let activeGrokIDs = Set(activeGrok.map(\.id))
        let hasCopilot = copilotGateway.hasCredentials
        let definitions = DroidProxyModelCatalog.definitions

        func live(_ type: ServiceType) -> [AuthAccount] {
            guard enabled[type] ?? true else { return [] }
            return (accounts[type] ?? []).filter { !$0.isDisabled && !$0.isExpired }
        }
        let usages = await ControlUsage.usages(
            codex: live(.codex),
            claude: live(.claude),
            grok: (enabled[.grok] ?? true) ? activeGrok : [],
            meta: (enabled[.meta] ?? true) ? (accounts[.meta] ?? []).filter { !$0.isDisabled } : [],
            now: now
        )

        func judgeAccounts(_ type: ServiceType) -> [AvailabilityJudge.Account] {
            if type == .copilot {
                return hasCopilot ? [AvailabilityJudge.Account(id: Self.copilotAccountID, label: nil, usable: true)] : []
            }
            return (accounts[type] ?? []).map { account in
                let usable = type == .grok
                    ? activeGrokIDs.contains(account.id)
                    : !account.isDisabled && !account.isExpired
                return AvailabilityJudge.Account(id: account.id, label: account.email ?? account.login, usable: usable)
            }
        }

        return definitions.map { definition in
            let availability: ModelAvailability
            if let type = ServiceType(authFileType: definition.providerKey) {
                let providerUsages = Dictionary(
                    usages.filter { $0.provider == type }.map { ($0.id, $0) },
                    uniquingKeysWith: { first, _ in first }
                )
                availability = AvailabilityJudge.judge(
                    baseModel: definition.baseModel,
                    provider: type,
                    providerEnabled: enabled[type] ?? true,
                    accounts: judgeAccounts(type),
                    usages: providerUsages,
                    now: now
                )
            } else {
                availability = .unknown
            }
            return ControlModel(
                id: definition.simpleID,
                name: definition.displayName,
                provider: definition.providerKey,
                availability: availability
            )
        }
    }
}
