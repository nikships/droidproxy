import Foundation

enum AppPreferences {
    static let gpt6AstraFastModeKey = "gpt6AstraFastMode"
    static let gpt6SolFastModeKey = "gpt6SolFastMode"
    static let gpt6LunaFastModeKey = "gpt6LunaFastMode"
    /// Meta Muse Contributor Mode: apply `muse-spark-1.3-contributor` instead of
    /// `muse-spark-1.3` when Factory custom models are applied. Exactly one of
    /// the two variants is ever active - never both.
    static let metaContributorModeKey = "metaContributorMode"
    static let allowRemoteKey = "allowRemote"
    static let secretKeyKey = "secretKey"
    static let bindAddressKey = "bindAddress"
    static let oledThemeKey = "oledTheme"
    static let backgroundOpacityKey = "backgroundOpacity"
    static let betaFlagKey = "BETA_FLAG"
    static let verboseLoggingKey = "verboseLogging"
    static let sequentialAccountFailoverKey = "sequentialAccountFailover"

    static let defaultGpt6AstraFastMode = false
    static let defaultGpt6SolFastMode = false
    static let defaultGpt6LunaFastMode = false
    static let defaultMetaContributorMode = false
    static let defaultAllowRemote = false
    static let defaultSecretKey = ""
    static let defaultBindAddress = "127.0.0.1"
    static let defaultOledTheme = false
    static let defaultBackgroundOpacity = 0.55
    static let defaultBetaFlag = false
    static let defaultVerboseLogging = false
    /// Opt-in. Off preserves the historical round-robin routing and globally
    /// disabled cooldowns, so existing single-account users see no change.
    static let defaultSequentialAccountFailover = false

    static var gpt6AstraFastMode: Bool {
        UserDefaults.standard.bool(forKey: gpt6AstraFastModeKey)
    }

    static var gpt6SolFastMode: Bool {
        UserDefaults.standard.bool(forKey: gpt6SolFastModeKey)
    }

    static var gpt6LunaFastMode: Bool {
        UserDefaults.standard.bool(forKey: gpt6LunaFastModeKey)
    }

    static var metaContributorMode: Bool {
        UserDefaults.standard.bool(forKey: metaContributorModeKey)
    }

    static var allowRemote: Bool {
        UserDefaults.standard.bool(forKey: allowRemoteKey)
    }

    static var secretKey: String {
        UserDefaults.standard.string(forKey: secretKeyKey) ?? defaultSecretKey
    }

    static var bindAddress: String {
        guard betaFlag else { return defaultBindAddress }
        let raw = UserDefaults.standard.string(forKey: bindAddressKey) ?? defaultBindAddress
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        // Reject empty or multi-line values that would produce an invalid
        // NWEndpoint host or inject extra lines into the generated YAML config.
        guard !trimmed.isEmpty, !trimmed.contains(where: { $0.isNewline }) else {
            return defaultBindAddress
        }
        return trimmed
    }

    static var backgroundOpacity: Double {
        let defaults = UserDefaults.standard
        guard defaults.object(forKey: backgroundOpacityKey) != nil else { return defaultBackgroundOpacity }
        return defaults.double(forKey: backgroundOpacityKey)
    }

    static var betaFlag: Bool {
        get {
            UserDefaults.standard.bool(forKey: betaFlagKey)
        }
        set {
            UserDefaults.standard.set(newValue, forKey: betaFlagKey)
        }
    }

    static var verboseLogging: Bool {
        UserDefaults.standard.bool(forKey: verboseLoggingKey)
    }

    static var sequentialAccountFailover: Bool {
        UserDefaults.standard.bool(forKey: sequentialAccountFailoverKey)
    }
}

var BETA_FLAG: Bool {
    get {
        AppPreferences.betaFlag
    }
    set {
        AppPreferences.betaFlag = newValue
    }
}
