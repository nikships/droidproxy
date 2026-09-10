import Foundation

enum AppPreferences {
    static let gpt56TerraFastModeKey = "******************"
    static let gpt56SolFastModeKey = "gpt56SolFastMode"
    static let gpt56LunaFastModeKey = "gpt56LunaFastMode"
    static let gpt6AstraFastModeKey = "gpt6AstraFastMode"
    /// Grok 4.6 Fast Mode (divert grok-4.6 to Cursor CLI `cursor-grok-4.6-fast`).
    /// Default is off — same opt-in pattern as Codex GPT Fast Mode keys.
    static let grok46FastModeKey = "grok46FastMode"
    /// Cursor Fast Mode (append `-fast` to Composer 2.5 and Cursor Grok 4.6).
    static let cursorFastModeKey = "cursorFastMode"
    static let allowRemoteKey = "allowRemote"
    static let secretKeyKey = "secretKey"
    static let bindAddressKey = "bindAddress"
    static let oledThemeKey = "oledTheme"
    static let backgroundOpacityKey = "backgroundOpacity"
    static let betaFlagKey = "BETA_FLAG"
    static let verboseLoggingKey = "verboseLogging"
    static let sequentialAccountFailoverKey = "sequentialAccountFailover"

    static let defaultGpt56TerraFastMode = false
    static let defaultGpt56SolFastMode = false
    static let defaultGpt56LunaFastMode = false
    static let defaultGpt6AstraFastMode = false
    static let defaultGrok46FastMode = false
    static let defaultCursorFastMode = false
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

    static var gpt56TerraFastMode: Bool {
        UserDefaults.standard.bool(forKey: gpt56TerraFastModeKey)
    }

    static var gpt56SolFastMode: Bool {
        UserDefaults.standard.bool(forKey: gpt56SolFastModeKey)
    }

    static var gpt56LunaFastMode: Bool {
        UserDefaults.standard.bool(forKey: gpt56LunaFastModeKey)
    }

    static var gpt6AstraFastMode: Bool {
        UserDefaults.standard.bool(forKey: gpt6AstraFastModeKey)
    }

    static var grok46FastMode: Bool {
        UserDefaults.standard.bool(forKey: grok46FastModeKey)
    }

    static var cursorFastMode: Bool {
        UserDefaults.standard.bool(forKey: cursorFastModeKey)
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
