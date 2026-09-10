import Foundation

enum DroidProxyModelKind {
    case claudeAdaptive
    case codex
    case kimi
    case antigravity
    case cursor
    case junie
    case grok
    case copilot
    case cline
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
    /// Optional Factory `maxContextLimit` accepted by the customModels schema.
    let maxContextLimit: Int?
    let provider: String
    let providerKey: String
    let baseURL: String
    let kind: DroidProxyModelKind
    let levels: [DroidProxyThinkingLevel]
    let defaultLevelValue: String
    let noImageSupport: Bool

    init(baseModel: String,
         idSlug: String,
         displayName: String,
         maxOutputTokens: Int,
         maxContextLimit: Int? = nil,
         provider: String,
         providerKey: String,
         baseURL: String,
         kind: DroidProxyModelKind,
         levels: [DroidProxyThinkingLevel],
         defaultLevelValue: String,
         noImageSupport: Bool = false) {
        self.baseModel = baseModel
        self.idSlug = idSlug
        self.displayName = displayName
        self.maxOutputTokens = maxOutputTokens
        self.maxContextLimit = maxContextLimit
        self.provider = provider
        self.providerKey = providerKey
        self.baseURL = baseURL
        self.kind = kind
        self.levels = levels
        self.defaultLevelValue = defaultLevelValue
        self.noImageSupport = noImageSupport
    }

    var simpleID: String {
        "custom:droidproxy:\(idSlug)"
    }

    private var settingsDisplayName: String {
        switch kind {
        case .antigravity:
            return "Antigravity: \(displayName)"
        case .copilot:
            return "GitHub Copilot: \(displayName)"
        default:
            return displayName
        }
    }

    /// Settings entry for Factory's custom model schema.
    ///
    /// Keep all reasoning metadata explicit so Droid/Factory does not need to
    /// infer supported effort levels from built-in model defaults.
    var settingsEntry: [String: Any] {
        var entry: [String: Any] = [
            "model": baseModel,
            "id": simpleID,
            "baseUrl": baseURL,
            "apiKey": "dummy-not-used",
            "displayName": "DroidProxy: \(settingsDisplayName)",
            "maxOutputTokens": maxOutputTokens,
            "noImageSupport": noImageSupport,
            "provider": provider
        ]
        if let maxContextLimit {
            entry["maxContextLimit"] = maxContextLimit
        }
        guard !levels.isEmpty else { return entry }
        entry["enableThinking"] = true
        entry["supportedReasoningEfforts"] = levels.map(\.value)
        entry["defaultReasoningEffort"] = defaultLevelValue
        entry["reasoningEffort"] = levels.count == 1 ? levels[0].value : defaultLevelValue
        return entry
    }
}

enum DroidProxyModelCatalog {
    private static let none = DroidProxyThinkingLevel(value: "none", displayName: "None")
    private static let dynamic = DroidProxyThinkingLevel(value: "dynamic", displayName: "Dynamic")
    private static let low = DroidProxyThinkingLevel(value: "low", displayName: "Low")
    private static let medium = DroidProxyThinkingLevel(value: "medium", displayName: "Medium")
    private static let high = DroidProxyThinkingLevel(value: "high", displayName: "High")
    private static let xhigh = DroidProxyThinkingLevel(value: "xhigh", displayName: "xHigh")
    private static let max = DroidProxyThinkingLevel(value: "max", displayName: "Max")

    private static let claudeAdvancedLevels = [low, medium, high, xhigh, max]
    private static let codexLevels = [low, medium, high, xhigh]
    private static let gpt56Levels = [none, low, medium, high, xhigh, max]
    private static let gpt56SolLevels = [dynamic, low, medium, high, xhigh, max]
    private static let gpt6AstraLevels = [low, medium, high, xhigh, max]

    private static func antigravityModel(
        baseModel: String,
        idSlug: String,
        displayName: String,
        maxOutputTokens: Int = 65536,
        levels: [DroidProxyThinkingLevel] = [high],
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

    static func copilotModel(_ descriptor: CopilotModelDescriptor) -> DroidProxyModelDefinition {
        let levels = descriptor.reasoningEfforts.map {
            DroidProxyThinkingLevel(value: $0, displayName: $0.capitalized)
        }
        let defaultLevelValue = ["max", "xhigh", "high", "medium", "low", "minimal", "none"]
            .first(where: { descriptor.reasoningEfforts.contains($0) })
            ?? descriptor.reasoningEfforts.first
            ?? "high"

        return DroidProxyModelDefinition(
            baseModel: descriptor.id,
            idSlug: "copilot-\(descriptor.identifierSlug)",
            displayName: descriptor.displayName,
            maxOutputTokens: descriptor.maxOutputTokens,
            maxContextLimit: descriptor.maxContextLimit,
            // Route every selected Copilot model through the gateway's
            // Responses endpoint. It resolves client-facing Claude aliases
            // (for example `claude-opus-4-8`) back to Copilot's upstream ID
            // and translates Responses for models that expose Messages or Chat
            // Completions only.
            provider: "openai",
            providerKey: "copilot",
            baseURL: CopilotGatewayManager.gatewayBaseURL,
            kind: .copilot,
            levels: levels,
            defaultLevelValue: defaultLevelValue,
            noImageSupport: !descriptor.supportsVision
        )
    }

    static var definitions: [DroidProxyModelDefinition] {
        var list = [
            DroidProxyModelDefinition(
                baseModel: "claude-fable-5-1",
                idSlug: "fable-5-1",
                displayName: "Fable 5.1",
                maxOutputTokens: 128000,
                provider: "anthropic",
                providerKey: "claude",
                baseURL: "http://localhost:8317",
                kind: .claudeAdaptive,
                levels: claudeAdvancedLevels,
                defaultLevelValue: "xhigh"
            ),
            DroidProxyModelDefinition(
                baseModel: "claude-fable-5",
                idSlug: "fable-5",
                displayName: "Fable 5",
                maxOutputTokens: 128000,
                provider: "anthropic",
                providerKey: "claude",
                baseURL: "http://localhost:8317",
                kind: .claudeAdaptive,
                levels: claudeAdvancedLevels,
                defaultLevelValue: "xhigh"
            ),
            DroidProxyModelDefinition(
                baseModel: "claude-opus-5",
                idSlug: "opus-5",
                displayName: "Opus 5",
                maxOutputTokens: 128000,
                provider: "anthropic",
                providerKey: "claude",
                baseURL: "http://localhost:8317",
                kind: .claudeAdaptive,
                levels: claudeAdvancedLevels,
                defaultLevelValue: "xhigh"
            ),
            DroidProxyModelDefinition(
                baseModel: "claude-opus-4-8",
                idSlug: "opus-4-8",
                displayName: "Opus 4.8",
                maxOutputTokens: 128000,
                provider: "anthropic",
                providerKey: "claude",
                baseURL: "http://localhost:8317",
                kind: .claudeAdaptive,
                levels: claudeAdvancedLevels,
                defaultLevelValue: "xhigh"
            ),
            DroidProxyModelDefinition(
                baseModel: "claude-sonnet-5",
                idSlug: "sonnet-5",
                displayName: "Sonnet 5",
                maxOutputTokens: 128000,
                provider: "anthropic",
                providerKey: "claude",
                baseURL: "http://localhost:8317",
                kind: .claudeAdaptive,
                levels: claudeAdvancedLevels,
                defaultLevelValue: "xhigh"
            ),

            DroidProxyModelDefinition(
                baseModel: "gpt-5.6-terra",
                idSlug: "gpt-5.6-terra",
                displayName: "GPT 5.6 Terra",
                maxOutputTokens: 128000,
                provider: "openai",
                providerKey: "codex",
                baseURL: "http://localhost:8317/v1",
                kind: .codex,
                levels: gpt56Levels,
                defaultLevelValue: "medium"
            ),
            DroidProxyModelDefinition(
                baseModel: "gpt-5.6-luna",
                idSlug: "gpt-5.6-luna",
                displayName: "GPT 5.6 Luna",
                maxOutputTokens: 128000,
                provider: "openai",
                providerKey: "codex",
                baseURL: "http://localhost:8317/v1",
                kind: .codex,
                levels: gpt56Levels,
                defaultLevelValue: "medium"
            ),
            DroidProxyModelDefinition(
                baseModel: "gpt-5.6-sol",
                idSlug: "gpt-5.6-sol",
                displayName: "GPT 5.6 Sol",
                maxOutputTokens: 128000,
                provider: "openai",
                providerKey: "codex",
                baseURL: "http://localhost:8317/v1",
                kind: .codex,
                levels: gpt56SolLevels,
                defaultLevelValue: "medium"
            ),
            DroidProxyModelDefinition(
                baseModel: "gpt-6-astra",
                idSlug: "gpt-6-astra",
                displayName: "GPT 6 Astra",
                maxOutputTokens: 128000,
                maxContextLimit: 1_050_000,
                provider: "openai",
                providerKey: "codex",
                baseURL: "http://localhost:8317/v1",
                kind: .codex,
                levels: gpt6AstraLevels,
                defaultLevelValue: "medium"
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
                levels: [low],
                defaultLevelValue: "low"
            ),
            antigravityModel(
                baseModel: "gemini-3.8-flash-high",
                idSlug: "gemini-3.8-flash-high",
                displayName: "Gemini 3.8 Flash (High)"
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
                levels: [medium],
                defaultLevelValue: "medium"
            ),
            // CLIProxyAPI recognizes this catalog ID and removes the `kimi-` prefix,
            // sending Kimi Code's native `k3` model ID upstream.
            DroidProxyModelDefinition(
                baseModel: "kimi-k3",
                idSlug: "kimi-k3",
                displayName: "Kimi K3",
                maxOutputTokens: 65536,
                provider: "openai",
                providerKey: "kimi",
                baseURL: "http://localhost:8317/v1",
                kind: .kimi,
                levels: [max],
                defaultLevelValue: "max"
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
                levels: [high],
                defaultLevelValue: "high"
            ),

            // Junie (JetBrains AI) subscription models. Routed through the antigravity-style
            // Junie executor in ThinkingProxy, which strips the `junie-` prefix and forwards
            // to the JetBrains Grazie backend over TLS using the key in junie.json. The
            // `junie-` prefix keeps these distinct from the OAuth Claude entries above.
            DroidProxyModelDefinition(
                baseModel: "junie-claude-sonnet-5",
                idSlug: "junie-claude-sonnet-5",
                displayName: "Junie Sonnet 5",
                maxOutputTokens: 128000,
                provider: "anthropic",
                providerKey: "junie",
                baseURL: "http://localhost:8317",
                kind: .junie,
                levels: claudeAdvancedLevels,
                defaultLevelValue: "xhigh"
            ),
            DroidProxyModelDefinition(
                baseModel: "junie-claude-opus-5",
                idSlug: "junie-claude-opus-5",
                displayName: "Junie Opus 5",
                maxOutputTokens: 128000,
                provider: "anthropic",
                providerKey: "junie",
                baseURL: "http://localhost:8317",
                kind: .junie,
                levels: claudeAdvancedLevels,
                defaultLevelValue: "xhigh"
            ),
            DroidProxyModelDefinition(
                baseModel: "junie-claude-fable-5-1",
                idSlug: "junie-claude-fable-5-1",
                displayName: "Junie Fable 5.1",
                maxOutputTokens: 128000,
                provider: "anthropic",
                providerKey: "junie",
                baseURL: "http://localhost:8317",
                kind: .junie,
                levels: claudeAdvancedLevels,
                defaultLevelValue: "xhigh"
            ),
            DroidProxyModelDefinition(
                baseModel: "junie-claude-fable-5",
                idSlug: "junie-claude-fable-5",
                displayName: "Junie Fable 5",
                maxOutputTokens: 128000,
                provider: "anthropic",
                providerKey: "junie",
                baseURL: "http://localhost:8317",
                kind: .junie,
                levels: claudeAdvancedLevels,
                defaultLevelValue: "xhigh"
            ),

            // Grok OAuth (SuperGrok / X Premium+) via api.x.ai.
            // provider="openai" + /v1 → Responses API; ThinkingProxy attaches the bearer.
            // Context window from docs.x.ai: grok-4.6=500k.
            DroidProxyModelDefinition(
                baseModel: "grok-4.6",
                idSlug: "grok-4.6",
                displayName: "Grok 4.6",
                maxOutputTokens: 128000,
                maxContextLimit: 500_000,
                provider: "openai",
                providerKey: "grok",
                baseURL: "http://localhost:8317/v1",
                kind: .grok,
                levels: codexLevels,
                defaultLevelValue: "high"
            ),

            // Cline free-model promos (api.cline.bot), gated on Cline account OAuth.
            // The free list rotates; these entries mirror Cline's own current
            // fallback list. baseModel is the OpenRouter-style upstream slug, and
            // ThinkingProxy matches these slugs exactly to detect Cline traffic.
            DroidProxyModelDefinition(
                baseModel: "kwaipilot/kat-coder-pro",
                idSlug: "cline-kat-coder-pro",
                displayName: "Cline Kat Coder Pro (Free)",
                maxOutputTokens: 65536,
                maxContextLimit: 256_000,
                provider: "generic-chat-completion-api",
                providerKey: "cline",
                baseURL: "http://localhost:8317/v1",
                kind: .cline,
                levels: [high],
                defaultLevelValue: "high",
                noImageSupport: true
            ),
            DroidProxyModelDefinition(
                baseModel: "arcee-ai/trinity-large-preview:free",
                idSlug: "cline-trinity-large",
                displayName: "Cline Trinity Large (Free)",
                maxOutputTokens: 65536,
                maxContextLimit: 256_000,
                provider: "generic-chat-completion-api",
                providerKey: "cline",
                baseURL: "http://localhost:8317/v1",
                kind: .cline,
                levels: [high],
                defaultLevelValue: "high",
                noImageSupport: true
            )
        ]

        // Copilot's model catalog is account-specific and changes independently
        // of DroidProxy. Only the three models the user selected in Settings are
        // written into Factory's customModels configuration.
        list.append(contentsOf: CopilotModelPreferences.selectedModels.map(copilotModel))

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
                    levels: [high],
                    defaultLevelValue: "high"
                ),
                DroidProxyModelDefinition(
                    baseModel: "cursor-grok-4.6",
                    idSlug: "cursor-grok-4.6",
                    displayName: "Cursor Grok 4.6",
                    maxOutputTokens: 128000,
                    provider: "generic-chat-completion-api",
                    providerKey: "cursor",
                    baseURL: "http://localhost:8317/v1",
                    kind: .cursor,
                    levels: [high],
                    defaultLevelValue: "high"
                ),
                DroidProxyModelDefinition(
                    baseModel: "cursor-grok-4.6-fast",
                    idSlug: "cursor-grok-4.6-fast",
                    displayName: "Cursor Grok 4.6 Fast",
                    maxOutputTokens: 128000,
                    provider: "generic-chat-completion-api",
                    providerKey: "cursor",
                    baseURL: "http://localhost:8317/v1",
                    kind: .cursor,
                    levels: [high],
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
                    levels: [high],
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

    /// Upstream slugs of the Cline free models, used by ThinkingProxy to claim
    /// Cline traffic. Matching the catalog exactly keeps unrelated namespaced
    /// custom models (e.g. a user's own `openai/gpt-4o` entry pointed at
    /// `localhost:8317`) from being misrouted to api.cline.bot.
    static var clineBaseModels: Set<String> {
        Set(definitions.filter { $0.kind == .cline }.map(\.baseModel))
    }

    /// Smallest safe starting `index` for appending new entries to Factory's
    /// `customModels` array. Factory treats `index` as a required unique int, so
    /// the start must be strictly greater than every existing index — including
    /// holes left by removed third-party models, which makes `models.count`
    /// unsafe (survivors {0,2,4} after removals have count 3 but max index 4).
    static func nextAvailableIndex(in models: [[String: Any]]) -> Int {
        let existing = models.compactMap { entry -> Int? in
            if let n = entry["index"] as? Int { return n }
            if let n = (entry["index"] as? NSNumber)?.intValue { return n }
            return nil
        }
        return (existing.max() ?? -1) + 1
    }

}
