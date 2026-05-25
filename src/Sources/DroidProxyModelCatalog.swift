import Foundation

enum DroidProxyModelKind {
    case claudeAdaptive
    case claudeClassic
    case codex
    case gemini
    case kimi
    case antigravity
    case cursor
}

struct DroidProxyThinkingLevel: Equatable {
    let value: String
    let displayName: String
}

struct DroidProxyModelDefinition: Equatable {
    let baseModel: String
    let idSlug: String
    let displayName: String
    let maxOutputTokens: Int
    let provider: String
    let providerKey: String
    let baseURL: String
    let kind: DroidProxyModelKind
    let levels: [DroidProxyThinkingLevel]
    let defaultLevelValue: String

    var simpleID: String {
        "custom:droidproxy:\(idSlug)"
    }

    private var settingsDisplayName: String {
        switch kind {
        case .antigravity:
            return "Antigravity: \(displayName)"
        default:
            return displayName
        }
    }

    /// Settings entry that embeds Factory's native reasoning metadata so Droid's
    /// per-session reasoning selector picks up the supported levels for this model.
    var settingsEntry: [String: Any] {
        var entry: [String: Any] = [
            "model": baseModel,
            "id": simpleID,
            "baseUrl": baseURL,
            "apiKey": "dummy-not-used",
            "displayName": "DroidProxy: \(settingsDisplayName)",
            "maxOutputTokens": maxOutputTokens,
            "noImageSupport": false,
            "provider": provider
        ]
        guard !levels.isEmpty else { return entry }
        entry["enableThinking"] = true
        entry["supportedReasoningEfforts"] = levels.map(\.value)
        entry["defaultReasoningEffort"] = defaultLevelValue
        entry["reasoningEffort"] = defaultLevelValue
        return entry
    }
}

enum DroidProxyModelCatalog {
    private static let minimal = DroidProxyThinkingLevel(value: "minimal", displayName: "Minimal")
    private static let low = DroidProxyThinkingLevel(value: "low", displayName: "Low")
    private static let medium = DroidProxyThinkingLevel(value: "medium", displayName: "Medium")
    private static let high = DroidProxyThinkingLevel(value: "high", displayName: "High")
    private static let xhigh = DroidProxyThinkingLevel(value: "xhigh", displayName: "xHigh")
    private static let max = DroidProxyThinkingLevel(value: "max", displayName: "Max")

    private static let claudeAdvancedLevels = [low, medium, high, xhigh, max]
    private static let claudeClassicLevels = [low, medium, high, max]
    private static let codexLevels = [low, medium, high, xhigh]
    private static let kimiLevels = [high]
    private static let antigravityLowLevel = [low]
    private static let antigravityMediumLevel = [medium]
    private static let antigravityHighLevel = [high]
    private static let gemini35FlashAntigravityLevels = [medium, high]
    private static let geminiProLevels = [low, medium, high]
    private static let geminiFlashLevels = [minimal, low, medium, high]
    private static let cursorLevels = [high]

    private static func antigravityModel(
        baseModel: String,
        idSlug: String,
        displayName: String,
        maxOutputTokens: Int = 65536,
        levels: [DroidProxyThinkingLevel] = antigravityHighLevel,
        defaultLevelValue: String = "high"
    ) -> DroidProxyModelDefinition {
        DroidProxyModelDefinition(
            baseModel: baseModel,
            idSlug: idSlug,
            displayName: displayName,
            maxOutputTokens: maxOutputTokens,
            provider: "openai",
            providerKey: "antigravity",
            baseURL: "http://localhost:8317/v1",
            kind: .antigravity,
            levels: levels,
            defaultLevelValue: defaultLevelValue
        )
    }

    static var definitions: [DroidProxyModelDefinition] {
        var list = [
            DroidProxyModelDefinition(
                baseModel: "claude-opus-4-7",
                idSlug: "opus-4-7",
                displayName: "Opus 4.7",
                maxOutputTokens: 128000,
                provider: "anthropic",
                providerKey: "claude",
                baseURL: "http://localhost:8317",
                kind: .claudeAdaptive,
                levels: claudeAdvancedLevels,
                defaultLevelValue: "xhigh"
            ),
            DroidProxyModelDefinition(
                baseModel: "claude-opus-4-6",
                idSlug: "opus-4-6",
                displayName: "Opus 4.6",
                maxOutputTokens: 128000,
                provider: "anthropic",
                providerKey: "claude",
                baseURL: "http://localhost:8317",
                kind: .claudeAdaptive,
                levels: claudeClassicLevels,
                defaultLevelValue: "max"
            ),
            DroidProxyModelDefinition(
                baseModel: "claude-opus-4-5-20251101",
                idSlug: "opus-4-5",
                displayName: "Opus 4.5",
                maxOutputTokens: 64000,
                provider: "anthropic",
                providerKey: "claude",
                baseURL: "http://localhost:8317",
                kind: .claudeClassic,
                levels: claudeClassicLevels,
                defaultLevelValue: "high"
            ),
            DroidProxyModelDefinition(
                baseModel: "claude-sonnet-4-6",
                idSlug: "sonnet-4-6",
                displayName: "Sonnet 4.6",
                maxOutputTokens: 64000,
                provider: "anthropic",
                providerKey: "claude",
                baseURL: "http://localhost:8317",
                kind: .claudeAdaptive,
                levels: claudeClassicLevels,
                defaultLevelValue: "high"
            ),
            DroidProxyModelDefinition(
                baseModel: "gpt-5.2",
                idSlug: "gpt-5.2",
                displayName: "GPT 5.2",
                maxOutputTokens: 128000,
                provider: "openai",
                providerKey: "codex",
                baseURL: "http://localhost:8317/v1",
                kind: .codex,
                levels: codexLevels,
                defaultLevelValue: "high"
            ),
            DroidProxyModelDefinition(
                baseModel: "gpt-5.3-codex",
                idSlug: "gpt-5.3-codex",
                displayName: "GPT 5.3 Codex",
                maxOutputTokens: 128000,
                provider: "openai",
                providerKey: "codex",
                baseURL: "http://localhost:8317/v1",
                kind: .codex,
                levels: codexLevels,
                defaultLevelValue: "high"
            ),
            DroidProxyModelDefinition(
                baseModel: "gpt-5.4",
                idSlug: "gpt-5.4",
                displayName: "GPT 5.4",
                maxOutputTokens: 128000,
                provider: "openai",
                providerKey: "codex",
                baseURL: "http://localhost:8317/v1",
                kind: .codex,
                levels: codexLevels,
                defaultLevelValue: "high"
            ),
            DroidProxyModelDefinition(
                baseModel: "gpt-5.5",
                idSlug: "gpt-5.5",
                displayName: "GPT 5.5",
                maxOutputTokens: 128000,
                provider: "openai",
                providerKey: "codex",
                baseURL: "http://localhost:8317/v1",
                kind: .codex,
                levels: codexLevels,
                defaultLevelValue: "high"
            ),
            // Antigravity subscription models routed through the antigravity executor via
            // OpenAI-compatible chat-completions. provider="openai" + baseURL ending in
            // /v1 makes Factory's Droid CLI send POST /v1/chat/completions, which the
            // antigravity executor handles natively using the antigravity auth file.
            antigravityModel(
                baseModel: "gemini-pro-agent",
                idSlug: "antigravity-gemini-3.1-pro",
                displayName: "Gemini 3.1 Pro (High)"
            ),
            antigravityModel(
                baseModel: "gemini-3.1-pro-low",
                idSlug: "gemini-3.1-pro-low",
                displayName: "Gemini 3.1 Pro (Low)",
                levels: antigravityLowLevel,
                defaultLevelValue: "low"
            ),
            antigravityModel(
                baseModel: "gemini-3-flash",
                idSlug: "antigravity-gemini-3-flash",
                displayName: "Gemini 3 Flash"
            ),
            antigravityModel(
                baseModel: "gemini-3-flash-agent",
                idSlug: "gemini-3.5-flash",
                displayName: "Gemini 3.5 Flash",
                levels: gemini35FlashAntigravityLevels,
                defaultLevelValue: "high"
            ),
            antigravityModel(
                baseModel: "gemini-3.5-flash-low",
                idSlug: "gemini-3.5-flash-low",
                displayName: "Gemini 3.5 Flash (Low)",
                levels: antigravityLowLevel,
                defaultLevelValue: "low"
            ),
            antigravityModel(
                baseModel: "gemini-3.1-flash-lite",
                idSlug: "gemini-3.1-flash-lite",
                displayName: "Gemini 3.1 Flash Lite"
            ),
            antigravityModel(
                baseModel: "ag-c46s-thinking",
                idSlug: "ag-c46s-thinking",
                displayName: "Claude Sonnet 4.6 (Thinking)",
                maxOutputTokens: 64000
            ),
            antigravityModel(
                baseModel: "ag-c46o-thinking",
                idSlug: "ag-c46o-thinking",
                displayName: "Claude Opus 4.6 (Thinking)",
                maxOutputTokens: 64000
            ),
            antigravityModel(
                baseModel: "gpt-oss-120b-medium",
                idSlug: "gpt-oss-120b-medium",
                displayName: "GPT-OSS 120B (Medium)",
                maxOutputTokens: 32768,
                levels: antigravityMediumLevel,
                defaultLevelValue: "medium"
            ),
            DroidProxyModelDefinition(
                baseModel: "gemini-3.1-pro-preview",
                idSlug: "gemini-3.1-pro",
                displayName: "Gemini 3.1 Pro",
                maxOutputTokens: 65536,
                provider: "google",
                providerKey: "gemini",
                baseURL: "http://localhost:8317",
                kind: .gemini,
                levels: geminiProLevels,
                defaultLevelValue: "high"
            ),
            DroidProxyModelDefinition(
                baseModel: "gemini-3-flash-preview",
                idSlug: "gemini-3-flash",
                displayName: "Gemini 3 Flash",
                maxOutputTokens: 65536,
                provider: "google",
                providerKey: "gemini",
                baseURL: "http://localhost:8317",
                kind: .gemini,
                levels: geminiFlashLevels,
                defaultLevelValue: "high"
            ),
            DroidProxyModelDefinition(
                baseModel: "kimi-k2.6",
                idSlug: "kimi-k2.6",
                displayName: "Kimi K2.6",
                maxOutputTokens: 262144,
                provider: "openai",
                providerKey: "kimi",
                baseURL: "http://localhost:8317/v1",
                kind: .kimi,
                levels: kimiLevels,
                defaultLevelValue: "high"
            )
        ]

        if BETA_FLAG {
            list.append(contentsOf: [
                DroidProxyModelDefinition(
                    baseModel: "cursor-composer-2.5",
                    idSlug: "cursor-composer-2.5",
                    displayName: "Cursor Composer 2.5",
                    maxOutputTokens: 128000,
                    provider: "generic-chat-completion-api",
                    providerKey: "cursor",
                    baseURL: "http://localhost:8317/v1",
                    kind: .cursor,
                    levels: cursorLevels,
                    defaultLevelValue: "high"
                ),
                DroidProxyModelDefinition(
                    baseModel: "cursor-small",
                    idSlug: "cursor-small",
                    displayName: "Cursor Small",
                    maxOutputTokens: 64000,
                    provider: "generic-chat-completion-api",
                    providerKey: "cursor",
                    baseURL: "http://localhost:8317/v1",
                    kind: .cursor,
                    levels: cursorLevels,
                    defaultLevelValue: "high"
                )
            ])
        }

        return list
    }

    static func settingsModels(providerIsEnabled: (String) -> Bool = { _ in true }) -> [[String: Any]] {
        definitions.compactMap { definition in
            guard providerIsEnabled(definition.providerKey) else { return nil }
            return definition.settingsEntry
        }
    }

    static var allSettingsIDs: Set<String> {
        Set(definitions.map(\.simpleID))
    }

}
