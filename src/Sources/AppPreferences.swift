import Foundation

enum AppPreferences {
    static let gpt52FastModeKey = "gpt52FastMode"
    static let gpt53CodexFastModeKey = "gpt53CodexFastMode"
    static let gpt54FastModeKey = "gpt54FastMode"
    static let gpt55FastModeKey = "gpt55FastMode"
    static let factoryNativeReasoningKey = "factoryNativeReasoning"
    static let codexUsageVisibleKey = "codexUsageVisible"
    static let allowRemoteKey = "allowRemote"
    static let secretKeyKey = "secretKey"
    static let oledThemeKey = "oledTheme"
    static let backgroundOpacityKey = "backgroundOpacity"
    static let showUsageInMenuBarKey = "showUsageInMenuBar"
    static let usageAutoRefreshSecondsKey = "usageAutoRefreshSeconds"

    static let defaultGpt52FastMode = false
    static let defaultGpt53CodexFastMode = false
    static let defaultGpt54FastMode = false
    static let defaultGpt55FastMode = false
    static let defaultFactoryNativeReasoning = false
    static let defaultCodexUsageVisible = false
    static let defaultAllowRemote = false
    static let defaultSecretKey = ""
    static let defaultOledTheme = false
    static let defaultBackgroundOpacity = 0.55
    static let defaultShowUsageInMenuBar = true
    static let defaultUsageAutoRefreshSeconds = 300

    static var gpt52FastMode: Bool {
        UserDefaults.standard.bool(forKey: gpt52FastModeKey)
    }

    static var gpt53CodexFastMode: Bool {
        UserDefaults.standard.bool(forKey: gpt53CodexFastModeKey)
    }

    static var gpt54FastMode: Bool {
        UserDefaults.standard.bool(forKey: gpt54FastModeKey)
    }

    static var gpt55FastMode: Bool {
        UserDefaults.standard.bool(forKey: gpt55FastModeKey)
    }

    static var factoryNativeReasoning: Bool {
        UserDefaults.standard.bool(forKey: factoryNativeReasoningKey)
    }

    static var allowRemote: Bool {
        UserDefaults.standard.bool(forKey: allowRemoteKey)
    }

    static var secretKey: String {
        let defaults = UserDefaults.standard
        guard defaults.object(forKey: secretKeyKey) != nil else {
            return defaultSecretKey
        }
        return defaults.string(forKey: secretKeyKey) ?? defaultSecretKey
    }

    static var backgroundOpacity: Double {
        let defaults = UserDefaults.standard
        guard defaults.object(forKey: backgroundOpacityKey) != nil else { return defaultBackgroundOpacity }
        return defaults.double(forKey: backgroundOpacityKey)
    }

    static var showUsageInMenuBar: Bool {
        let defaults = UserDefaults.standard
        guard defaults.object(forKey: showUsageInMenuBarKey) != nil else { return defaultShowUsageInMenuBar }
        return defaults.bool(forKey: showUsageInMenuBarKey)
    }

    static var usageAutoRefreshSeconds: Int {
        let defaults = UserDefaults.standard
        guard defaults.object(forKey: usageAutoRefreshSecondsKey) != nil else { return defaultUsageAutoRefreshSeconds }
        return defaults.integer(forKey: usageAutoRefreshSecondsKey)
    }
}
