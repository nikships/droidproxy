import Foundation

enum AppPreferences {
    static let gpt53CodexFastModeKey = "gpt53CodexFastMode"
    static let gpt54FastModeKey = "gpt54FastMode"
    static let gpt55FastModeKey = "gpt55FastMode"
    static let allowRemoteKey = "allowRemote"
    static let secretKeyKey = "secretKey"
    static let bindAddressKey = "bindAddress"
    static let oledThemeKey = "oledTheme"
    static let backgroundOpacityKey = "backgroundOpacity"
    static let betaFlagKey = "BETA_FLAG"
    static let verboseLoggingKey = "verboseLogging"

    static let defaultGpt53CodexFastMode = false
    static let defaultGpt54FastMode = false
    static let defaultGpt55FastMode = false
    static let defaultAllowRemote = false
    static let defaultSecretKey = ""
    static let defaultBindAddress = "127.0.0.1"
    static let defaultOledTheme = false
    static let defaultBackgroundOpacity = 0.55
    static let defaultBetaFlag = false
    static let defaultVerboseLogging = false

    static var gpt53CodexFastMode: Bool {
        UserDefaults.standard.bool(forKey: gpt53CodexFastModeKey)
    }

    static var gpt54FastMode: Bool {
        UserDefaults.standard.bool(forKey: gpt54FastModeKey)
    }

    static var gpt55FastMode: Bool {
        UserDefaults.standard.bool(forKey: gpt55FastModeKey)
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
}

var BETA_FLAG: Bool {
    get {
        AppPreferences.betaFlag
    }
    set {
        AppPreferences.betaFlag = newValue
    }
}