import Foundation

enum DroidProxyModelKind {
    case claudeAdaptive
    case claudeClassic
    case codex
    case gemini
    case kimi
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
    let levelLabel: String
    let levels: [DroidProxyThinkingLevel]

    var simpleID: String {
        "custom:droidproxy:\(idSlug)"
    }

    func advancedID(for level: DroidProxyThinkingLevel) -> String {
        "custom:droidproxy:\(idSlug)-\(level.value)"
    }

    func modelAlias(for level: DroidProxyThinkingLevel) -> String {
        "\(baseModel)(\(level.value))"
    }

    var simpleSettingsEntry: [String: Any] {
        settingsEntry(id: simpleID, model: baseModel, displayName: "DroidProxy: \(displayName)")
    }

    func advancedSettingsEntry(for level: DroidProxyThinkingLevel) -> [String: Any] {
        settingsEntry(
            id: advancedID(for: level),
            model: modelAlias(for: level),
            displayName: "DroidProxy: \(displayName) - \(level.displayName) \(levelLabel)"
        )
    }

    private func settingsEntry(id: String, model: String, displayName: String) -> [String: Any] {
        [
            "model": model,
            "id": id,
            "baseUrl": baseURL,
            "apiKey": "dummy-not-used",
            "displayName": displayName,
            "maxOutputTokens": maxOutputTokens,
            "noImageSupport": false,
            "provider": provider
        ]
    }
}

struct DroidProxyModelVariant {
    let definition: DroidProxyModelDefinition
    let level: DroidProxyThinkingLevel
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
    private static let geminiProLevels = [low, medium, high]
    private static let geminiFlashLevels = [minimal, low, medium, high]

    static let definitions: [DroidProxyModelDefinition] = [
        DroidProxyModelDefinition(
            baseModel: "claude-opus-4-7",
            idSlug: "opus-4-7",
            displayName: "Opus 4.7",
            maxOutputTokens: 128000,
            provider: "anthropic",
            providerKey: "claude",
            baseURL: "http://localhost:8317",
            kind: .claudeAdaptive,
            levelLabel: "Effort",
            levels: claudeAdvancedLevels
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
            levelLabel: "Effort",
            levels: claudeClassicLevels
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
            levelLabel: "Effort",
            levels: claudeClassicLevels
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
            levelLabel: "Effort",
            levels: claudeClassicLevels
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
            levelLabel: "Reasoning",
            levels: codexLevels
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
            levelLabel: "Reasoning",
            levels: codexLevels
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
            levelLabel: "Reasoning",
            levels: codexLevels
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
            levelLabel: "Thinking",
            levels: geminiProLevels
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
            levelLabel: "Thinking",
            levels: geminiFlashLevels
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
            levelLabel: "Reasoning",
            levels: kimiLevels
        )
    ]

    static func settingsModels(advanced: Bool) -> [[String: Any]] {
        if advanced {
            return definitions.flatMap { definition in
                definition.levels.map { definition.advancedSettingsEntry(for: $0) }
            }
        }
        return definitions.map(\.simpleSettingsEntry)
    }

    static var allSettingsIDs: Set<String> {
        Set(definitions.flatMap { definition in
            [definition.simpleID] + definition.levels.map { definition.advancedID(for: $0) }
        })
    }

    static func providerKey(forSettingsModel model: [String: Any]) -> String? {
        if let id = model["id"] as? String,
           let definition = definitions.first(where: { definition in
               id == definition.simpleID || definition.levels.contains { definition.advancedID(for: $0) == id }
           }) {
            return definition.providerKey
        }

        guard let name = model["model"] as? String else { return nil }
        if name.hasPrefix("claude") { return "claude" }
        if name.hasPrefix("gpt") { return "codex" }
        if name.hasPrefix("gemini") { return "gemini" }
        if name.hasPrefix("kimi-k2.6") { return "kimi" }
        return nil
    }

    static func advancedVariant(for model: String) -> DroidProxyModelVariant? {
        guard model.hasSuffix(")"),
              let openIndex = model.lastIndex(of: "(") else {
            return nil
        }

        let base = String(model[..<openIndex]).trimmingCharacters(in: .whitespacesAndNewlines)
        let levelStart = model.index(after: openIndex)
        let levelEnd = model.index(before: model.endIndex)
        let requestedLevel = String(model[levelStart..<levelEnd])
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()

        guard !base.isEmpty, !requestedLevel.isEmpty else { return nil }

        for definition in definitions where definition.baseModel == base {
            if let level = definition.levels.first(where: { $0.value == requestedLevel }) {
                return DroidProxyModelVariant(definition: definition, level: level)
            }
        }

        return nil
    }
}
