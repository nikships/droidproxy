import Foundation

enum AppPreferences {
    static let opus47ThinkingEffortKey = "opus47ThinkingEffort"
    static let opus46ThinkingEffortKey = "opus46ThinkingEffort"
    static let opus45ThinkingEffortKey = "opus45ThinkingEffort"
    static let sonnet46ThinkingEffortKey = "sonnet46ThinkingEffort"
    static let gpt53CodexReasoningEffortKey = "gpt53CodexReasoningEffort"
    static let gpt54ReasoningEffortKey = "gpt54ReasoningEffort"
    static let gpt55ReasoningEffortKey = "gpt55ReasoningEffort"
    static let gpt53CodexFastModeKey = "gpt53CodexFastMode"
    static let gpt54FastModeKey = "gpt54FastMode"
    static let gpt55FastModeKey = "gpt55FastMode"
    static let gemini31ProThinkingLevelKey = "gemini31ProThinkingLevel"
    static let gemini3FlashThinkingLevelKey = "gemini3FlashThinkingLevel"
    static let k26ReasoningEnabledKey = "k26ReasoningEnabled"
    static let claudeMaxBudgetModeKey = "claudeMaxBudgetMode"
    static let allowRemoteKey = "allowRemote"
    static let secretKeyKey = "secretKey"
    static let oledThemeKey = "oledTheme"
    static let factoryAdvancedModelsKey = "factoryAdvancedModels"
    static let backgroundOpacityKey = "backgroundOpacity"
    static let defaultOledTheme = false
    static let defaultFactoryAdvancedModels = false
    static let defaultBackgroundOpacity = 0.55
    static let defaultOpus47ThinkingEffort = "xhigh"
    static let defaultOpus46ThinkingEffort = "max"
    static let defaultOpus45ThinkingEffort = "high"
    static let defaultSonnet46ThinkingEffort = "high"
    static let defaultGpt53CodexReasoningEffort = "high"
    static let defaultGpt54ReasoningEffort = "high"
    static let defaultGpt55ReasoningEffort = "high"
    static let defaultGpt53CodexFastMode = false
    static let defaultGpt54FastMode = false
    static let defaultGpt55FastMode = false
    static let gpt52ReasoningEffortKey = "gpt52ReasoningEffort"
    static let gpt52FastModeKey = "gpt52FastMode"
    static let defaultGpt52ReasoningEffort = "high"
    static let defaultGpt52FastMode = false
    static let defaultGemini31ProThinkingLevel = "high"
    static let defaultGemini3FlashThinkingLevel = "high"
    static let defaultK26ReasoningEnabled = true
    static let defaultClaudeMaxBudgetMode = false
    static let defaultAllowRemote = false
    static let defaultSecretKey = ""
    static let showUsageInMenuBarKey = "showUsageInMenuBar"
    static let usageAutoRefreshSecondsKey = "usageAutoRefreshSeconds"
    static let defaultShowUsageInMenuBar = true
    static let defaultUsageAutoRefreshSeconds = 300

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

    static var opus47ThinkingEffort: String {
        let defaults = UserDefaults.standard
        guard defaults.object(forKey: opus47ThinkingEffortKey) != nil else {
            return defaultOpus47ThinkingEffort
        }
        return defaults.string(forKey: opus47ThinkingEffortKey) ?? defaultOpus47ThinkingEffort
    }

    static var opus46ThinkingEffort: String {
        UserDefaults.standard.string(forKey: opus46ThinkingEffortKey) ?? defaultOpus46ThinkingEffort
    }

    static var opus45ThinkingEffort: String {
        UserDefaults.standard.string(forKey: opus45ThinkingEffortKey) ?? defaultOpus45ThinkingEffort
    }

    static var sonnet46ThinkingEffort: String {
        let defaults = UserDefaults.standard
        guard defaults.object(forKey: sonnet46ThinkingEffortKey) != nil else {
            return defaultSonnet46ThinkingEffort
        }
        return defaults.string(forKey: sonnet46ThinkingEffortKey) ?? defaultSonnet46ThinkingEffort
    }

    static var gpt53CodexReasoningEffort: String {
        let defaults = UserDefaults.standard
        guard defaults.object(forKey: gpt53CodexReasoningEffortKey) != nil else {
            return defaultGpt53CodexReasoningEffort
        }
        return defaults.string(forKey: gpt53CodexReasoningEffortKey) ?? defaultGpt53CodexReasoningEffort
    }

    static var gpt54ReasoningEffort: String {
        let defaults = UserDefaults.standard
        guard defaults.object(forKey: gpt54ReasoningEffortKey) != nil else {
            return defaultGpt54ReasoningEffort
        }
        return defaults.string(forKey: gpt54ReasoningEffortKey) ?? defaultGpt54ReasoningEffort
    }

    static var gpt55ReasoningEffort: String {
        let defaults = UserDefaults.standard
        guard defaults.object(forKey: gpt55ReasoningEffortKey) != nil else {
            return defaultGpt55ReasoningEffort
        }
        return defaults.string(forKey: gpt55ReasoningEffortKey) ?? defaultGpt55ReasoningEffort
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

    static var gemini31ProThinkingLevel: String {
        let defaults = UserDefaults.standard
        guard defaults.object(forKey: gemini31ProThinkingLevelKey) != nil else {
            return defaultGemini31ProThinkingLevel
        }
        return defaults.string(forKey: gemini31ProThinkingLevelKey) ?? defaultGemini31ProThinkingLevel
    }

    static var gemini3FlashThinkingLevel: String {
        let defaults = UserDefaults.standard
        guard defaults.object(forKey: gemini3FlashThinkingLevelKey) != nil else {
            return defaultGemini3FlashThinkingLevel
        }
        return defaults.string(forKey: gemini3FlashThinkingLevelKey) ?? defaultGemini3FlashThinkingLevel
    }

    static var k26ReasoningEnabled: Bool {
        let defaults = UserDefaults.standard
        guard defaults.object(forKey: k26ReasoningEnabledKey) != nil else {
            return defaultK26ReasoningEnabled
        }
        return defaults.bool(forKey: k26ReasoningEnabledKey)
    }

    static var gpt52ReasoningEffort: String {
        let defaults = UserDefaults.standard
        guard defaults.object(forKey: gpt52ReasoningEffortKey) != nil else {
            return defaultGpt52ReasoningEffort
        }
        return defaults.string(forKey: gpt52ReasoningEffortKey) ?? defaultGpt52ReasoningEffort
    }

    static var gpt52FastMode: Bool {
        UserDefaults.standard.bool(forKey: gpt52FastModeKey)
    }

    static var backgroundOpacity: Double {
        let defaults = UserDefaults.standard
        guard defaults.object(forKey: backgroundOpacityKey) != nil else { return defaultBackgroundOpacity }
        return defaults.double(forKey: backgroundOpacityKey)
    }

    static var claudeMaxBudgetMode: Bool {
        UserDefaults.standard.bool(forKey: claudeMaxBudgetModeKey)
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
}
