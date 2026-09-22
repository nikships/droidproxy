import Foundation

enum DroidProxyModelKind {
    case claudeAdaptive
    case codex
    case kimi
    case antigravity
    case junie
    case grok
    case copilot
    case meta
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
        case .meta:
            return "Meta: \(displayName)"
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
    // Full reasoning-effort range the `muse` CLI itself exposes for Muse Spark
    // (`--reasoning-effort none|minimal|low|medium|high|xhigh|max|ultra`), minus
    // `none`/`minimal`/`ultra` which aren't meaningful defaults for a coding model.
    private static let museLevels = [low, medium, high, xhigh, max]

    /// Muse Spark 1.3 and its cheaper/faster "contributor" companion. Completions
    /// go through CLIProxyAPI's `openai-compatibility` passthrough; Responses are
    /// TLS-forwarded by ThinkingProxy to `https://api.meta.ai/v1` so encrypted
    /// reasoning can persist across turns.
    static func museModel(baseModel: String, idSlug: String, displayName: String) -> DroidProxyModelDefinition {
        DroidProxyModelDefinition(
            baseModel: baseModel,
            idSlug: idSlug,
            displayName: displayName,
            maxOutputTokens: 256_000,
            maxContextLimit: 1_048_576,
            provider: "openai",
            providerKey: "meta",
            baseURL: "http://localhost:8317/v1",
            kind: .meta,
            levels: museLevels,
            defaultLevelValue: "max"
        )
    }

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
                baseModel: "claude-opus-5-5",
                idSlug: "opus-5-5",
                displayName: "Opus 5.5",
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
                baseModel: "junie-claude-opus-5-5",
                idSlug: "junie-claude-opus-5-5",
                displayName: "Junie Opus 5.5",
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

            // Grok OAuth (SuperGrok / X Premium+) .
            // provider="openai" + /v1 → Responses API; ThinkingProxy attaches the bearer.
            // grok-4.7 goes to api.x.ai. grok-4.7-build-fast is the same model on
            // faster infrastructure (2x price) and is served only by cli-chat-proxy.
            // Context window from docs.x.ai: grok-4.7=500k.
            DroidProxyModelDefinition(
                baseModel: "grok-4.7",
                idSlug: "grok-4.7",
                displayName: "Grok 4.7",
                maxOutputTokens: 128000,
                maxContextLimit: 500_000,
                provider: "openai",
                providerKey: "grok",
                baseURL: "http://localhost:8317/v1",
                kind: .grok,
                levels: codexLevels,
                defaultLevelValue: "xhigh"
            ),
            DroidProxyModelDefinition(
                baseModel: GrokAuth.fastModelID,
                idSlug: GrokAuth.fastModelID,
                displayName: "Grok 4.7 Fast",
                maxOutputTokens: 128000,
                maxContextLimit: 500_000,
                provider: "openai",
                providerKey: "grok",
                baseURL: "http://localhost:8317/v1",
                kind: .grok,
                levels: codexLevels,
                defaultLevelValue: "xhigh"
            )
        ]

        // Copilot's model catalog is account-specific and changes independently
        // of DroidProxy. Only the three models the user selected in Settings are
        // written into Factory's customModels configuration.
        list.append(contentsOf: CopilotModelPreferences.selectedModels.map(copilotModel))

        // Only expose Muse Spark with an enabled, usable key, matching backend
        // configuration eligibility. Contributor Mode picks exactly one of the two variants;
        // they are never both applied at once.
        if MetaMuseCredentialStore.shared.hasUsableAPIKey {
            if AppPreferences.metaContributorMode {
                list.append(museModel(
                    baseModel: "muse-spark-1.3-contributor",
                    idSlug: "muse-spark-1.3-contributor",
                    displayName: "Muse Spark 1.3 Contributor"
                ))
            } else {
                list.append(museModel(baseModel: "muse-spark-1.3", idSlug: "muse-spark-1.3", displayName: "Muse Spark 1.3"))
            }
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
