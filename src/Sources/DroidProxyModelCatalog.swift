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
    case mistral
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
    /// Factory's built-in model whose reasoning levels Droid should use. Droid ignores
    /// `supportedReasoningEfforts` on custom models and instead matches `model` to a
    /// built-in by the longest id it contains, so `zai-glm-5-3` resolves to the
    /// deprecated `glm-5` (levels `[none]`) and the effort selector disappears.
    let factoryBaseModelID: String?

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
         noImageSupport: Bool = false,
         factoryBaseModelID: String? = nil) {
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
        self.factoryBaseModelID = factoryBaseModelID
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
        if let factoryBaseModelID {
            entry["baseModelId"] = factoryBaseModelID
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
    private static let minimal = DroidProxyThinkingLevel(value: "minimal", displayName: "Minimal")
    private static let low = DroidProxyThinkingLevel(value: "low", displayName: "Low")
    private static let medium = DroidProxyThinkingLevel(value: "medium", displayName: "Medium")
    private static let high = DroidProxyThinkingLevel(value: "high", displayName: "High")
    private static let xhigh = DroidProxyThinkingLevel(value: "xhigh", displayName: "xHigh")
    private static let max = DroidProxyThinkingLevel(value: "max", displayName: "Max")

    private static let claudeAdvancedLevels = [low, medium, high, xhigh, max]
    private static let codexLevels = [low, medium, high, xhigh]
    private static let gpt6Levels = [low, medium, high, xhigh, max]
    // Every reasoning-effort level `api.meta.ai` accepts for Muse Wonder
    // (verified live for both variants: `minimal` through `max` return 200;
    // `none` and `ultra` return 400, so they are not advertised).
    private static let museLevels = [minimal, low, medium, high, xhigh, max]

    /// Muse Wonder 1.0 and its cheaper/faster "contributor" companion. Completions
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

    /// Mistral's reasoning levels differ per model and are taken from its docs, not
    /// live-verified here: confirm with `GET /v1/models` and a request per level
    /// before changing them. Limits are unknown, so the context limit is left unset.
    static func mistralModel(
        baseModel: String,
        idSlug: String,
        displayName: String,
        maxOutputTokens: Int = 32_768,
        maxContextLimit: Int? = nil,
        levels: [DroidProxyThinkingLevel],
        defaultLevelValue: String,
        factoryBaseModelID: String? = nil
    ) -> DroidProxyModelDefinition {
        DroidProxyModelDefinition(
            baseModel: baseModel,
            idSlug: idSlug,
            displayName: displayName,
            maxOutputTokens: maxOutputTokens,
            maxContextLimit: maxContextLimit,
            provider: "openai",
            providerKey: "mistral",
            baseURL: "http://localhost:8317/v1",
            kind: .mistral,
            levels: levels,
            defaultLevelValue: defaultLevelValue,
            factoryBaseModelID: factoryBaseModelID
        )
    }

    /// Droid sends Responses; CLIProxyAPI's `openai-compatibility` block converts them to
    /// Chat Completions (Mistral has no Responses API). See `MistralCredentialStore.payloadFilterConfig`.
    /// Ids come from `MistralCredentialStore.modelIDs` so config and catalog agree.
    static var mistralModels: [DroidProxyModelDefinition] {
        let toggle = [none, high]
        let ids = MistralCredentialStore.modelIDs
        let specs: [(id: String, slug: String, name: String, levels: [DroidProxyThinkingLevel], factoryBase: String?)] = [
            ("mistral-large-4", "mistral-large-4", "Mistral Large 4", [low, medium, high], nil),
            ("mistral-medium-3-5", "mistral-medium-3-5", "Mistral Medium 3.5", toggle, nil),
            ("mistral-small-latest", "mistral-small-4", "Mistral Small 4", toggle, nil),
            ("zai-glm-5-3", "mistral-glm-5-3", "GLM 5.3 (Mistral)", [low, high, max], "glm-5.3"),
            ("zai-glm-5-3-flash", "mistral-glm-5-3-flash", "GLM 5.3 Flash (Mistral)", [low, high, max], "glm-5.3-flash")
        ]
        return specs.filter { ids.contains($0.id) }.map {
            mistralModel(baseModel: $0.id, idSlug: $0.slug, displayName: $0.name,
                         levels: $0.levels, defaultLevelValue: "high", factoryBaseModelID: $0.factoryBase)
        }
    }

    private static func antigravityModel(
        baseModel: String,
        idSlug: String,
        displayName: String,
        maxOutputTokens: Int = 65536,
        maxContextLimit: Int? = nil,
        levels: [DroidProxyThinkingLevel] = [high],
        defaultLevelValue: String = "high"
    ) -> DroidProxyModelDefinition {
        DroidProxyModelDefinition(
            baseModel: baseModel,
            idSlug: idSlug,
            displayName: displayName,
            maxOutputTokens: maxOutputTokens,
            maxContextLimit: maxContextLimit,
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
                baseModel: "claude-fable-5-2",
                idSlug: "fable-5-2",
                displayName: "Fable 5.2",
                maxOutputTokens: 128000,
                // Factory's limit is input-only; reserve the full output allowance.
                maxContextLimit: 872_000,
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
                baseModel: "claude-sonnet-5-5",
                idSlug: "sonnet-5-5",
                displayName: "Sonnet 5.5",
                maxOutputTokens: 128000,
                provider: "anthropic",
                providerKey: "claude",
                baseURL: "http://localhost:8317",
                kind: .claudeAdaptive,
                levels: claudeAdvancedLevels,
                defaultLevelValue: "xhigh"
            ),
            DroidProxyModelDefinition(
                baseModel: "claude-haiku-5-5",
                idSlug: "haiku-5-5",
                displayName: "Haiku 5.5",
                maxOutputTokens: 128000,
                maxContextLimit: 1_000_000,
                provider: "anthropic",
                providerKey: "claude",
                baseURL: "http://localhost:8317",
                kind: .claudeAdaptive,
                levels: claudeAdvancedLevels,
                defaultLevelValue: "xhigh"
            ),

            // Keep the conservative Codex input cap for the 6.2 upgrades until
            // CLIProxyAPI publishes their subscription-specific context limits.
            DroidProxyModelDefinition(
                baseModel: "gpt-6.2-astra",
                idSlug: "gpt-6.2-astra",
                displayName: "GPT 6.2 Astra",
                maxOutputTokens: 128000,
                maxContextLimit: 272_000,
                provider: "openai",
                providerKey: "codex",
                baseURL: "http://localhost:8317/v1",
                kind: .codex,
                levels: gpt6Levels,
                defaultLevelValue: "xhigh"
            ),
            DroidProxyModelDefinition(
                baseModel: "gpt-6.2-sol",
                idSlug: "gpt-6.2-sol",
                displayName: "GPT 6.2 Sol",
                maxOutputTokens: 128000,
                maxContextLimit: 272_000,
                provider: "openai",
                providerKey: "codex",
                baseURL: "http://localhost:8317/v1",
                kind: .codex,
                levels: gpt6Levels,
                defaultLevelValue: "xhigh"
            ),
            DroidProxyModelDefinition(
                baseModel: "gpt-6.1-terra",
                idSlug: "gpt-6.1-terra",
                displayName: "GPT 6.1 Terra",
                maxOutputTokens: 128000,
                maxContextLimit: 272_000,
                provider: "openai",
                providerKey: "codex",
                baseURL: "http://localhost:8317/v1",
                kind: .codex,
                levels: gpt6Levels,
                defaultLevelValue: "xhigh"
            ),
            DroidProxyModelDefinition(
                baseModel: "gpt-6-luna",
                idSlug: "gpt-6-luna",
                displayName: "GPT 6 Luna",
                maxOutputTokens: 128000,
                maxContextLimit: 272_000,
                provider: "openai",
                providerKey: "codex",
                baseURL: "http://localhost:8317/v1",
                kind: .codex,
                levels: gpt6Levels,
                defaultLevelValue: "xhigh"
            ),
            // Antigravity subscription models routed through the antigravity executor via
            // OpenAI-compatible chat-completions. provider="openai" + baseURL ending in
            // /v1 makes Factory's Droid CLI send POST /v1/chat/completions, which the
            // antigravity executor handles natively using the antigravity auth file.
            antigravityModel(
                baseModel: "gemini-3.8-flash-high",
                idSlug: "gemini-3.8-flash-high",
                displayName: "Gemini 3.8 Flash (High)"
            ),
            // Only the -high id is in the CLIProxyAPI registry. reasoning_effort still
            // selects low, medium, or high thinking on it (verified live 2026-10-29).
            antigravityModel(
                baseModel: "gemini-4-argon-high",
                idSlug: "gemini-4-argon-high",
                displayName: "Gemini 4 Argon",
                levels: [low, medium, high]
            ),
            // Carbon landed in fetchAvailableModels before the CLIProxyAPI
            // registry listed it; the account-gated -high id answers live
            // (verified 2026-11-09) and reasoning_effort selects the level.
            antigravityModel(
                baseModel: "gemini-4-carbon-high",
                idSlug: "gemini-4-carbon-high",
                displayName: "Gemini 4 Carbon",
                maxOutputTokens: 262144,
                levels: [low, medium, high]
            ),
            // Hydrogen is registered for Antigravity in CLIProxyAPI 8.0.68+ only
            // as the -xhigh id, which accepts low through xhigh.
            antigravityModel(
                baseModel: "gemini-4-hydrogen-xhigh",
                idSlug: "gemini-4-hydrogen-xhigh",
                displayName: "Gemini 4 Hydrogen",
                levels: [low, medium, high, xhigh],
                defaultLevelValue: "xhigh"
            ),
            // Neon is registered for Antigravity in CLIProxyAPI 8.0.78+ only
            // as the -xhigh id, which accepts low through xhigh.
            antigravityModel(
                baseModel: "gemini-4-neon-xhigh",
                idSlug: "gemini-4-neon-xhigh",
                displayName: "Gemini 4 Neon",
                levels: [low, medium, high, xhigh],
                defaultLevelValue: "xhigh"
            ),
            // Claude 5.5 is only served to directly billed (non-trial) Google AI Pro/Ultra accounts.
            // CLIProxyAPI registers an Antigravity model only when the account's
            // fetchAvailableModels returns it, so on other accounts the 5.5 entries fail with
            // `unknown provider for model`; those accounts use the 4.6 entries below.
            antigravityModel(
                baseModel: "ag-c55s-high",
                idSlug: "ag-c55s-high",
                displayName: "Claude Sonnet 5.5 (High)",
                maxOutputTokens: 128000,
                maxContextLimit: 1_000_000
            ),
            antigravityModel(
                baseModel: "ag-c55o-high",
                idSlug: "ag-c55o-high",
                displayName: "Claude Opus 5.5 (High)",
                maxOutputTokens: 128000,
                maxContextLimit: 1_000_000
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
            // CLIProxyAPI recognizes these catalog IDs and removes the `kimi-`
            // prefix, sending Kimi Code's native model ID upstream.
            DroidProxyModelDefinition(
                baseModel: "kimi-k3.1-pro",
                idSlug: "kimi-k3.1-pro",
                displayName: "Kimi K3.1 Pro",
                maxOutputTokens: 65536,
                provider: "openai",
                providerKey: "kimi",
                baseURL: "http://localhost:8317/v1",
                kind: .kimi,
                levels: [max],
                defaultLevelValue: "max"
            ),
            DroidProxyModelDefinition(
                baseModel: "kimi-k3.1-pro-highspeed",
                idSlug: "kimi-k3.1-pro-highspeed",
                displayName: "Kimi K3.1 Pro Highspeed",
                maxOutputTokens: 65536,
                provider: "openai",
                providerKey: "kimi",
                baseURL: "http://localhost:8317/v1",
                kind: .kimi,
                levels: [max],
                defaultLevelValue: "max"
            ),
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
                maxOutputTokens: 65536,
                provider: "openai",
                providerKey: "kimi",
                baseURL: "http://localhost:8317/v1",
                kind: .kimi,
                levels: [high],
                defaultLevelValue: "high"
            ),

            // Junie (JetBrains AI) subscription models. Routed through the Junie
            // executor in ThinkingProxy, which strips the `junie-` prefix and forwards
            // to the JetBrains Grazie backend over TLS using the key in junie.json. The
            // `junie-` prefix keeps these distinct from the OAuth Claude/Codex entries.
            // Opus goes out as Anthropic Messages; Sol as OpenAI Responses.
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
                baseModel: "junie-gpt-6.1-sol",
                idSlug: "junie-gpt-6.1-sol",
                displayName: "Junie Sol 6.1",
                maxOutputTokens: 128000,
                maxContextLimit: 272_000,
                provider: "openai",
                providerKey: "junie",
                baseURL: "http://localhost:8317/v1",
                kind: .junie,
                levels: gpt6Levels,
                defaultLevelValue: "xhigh"
            ),

            // Grok OAuth (SuperGrok / X Premium+) .
            // provider="openai" + /v1 → Responses API; ThinkingProxy attaches the bearer.
            // Both go to cli-chat-proxy (Grok Build billing); api.x.ai would bill as X API.
            // grok-4.7-build-fast is the same model on faster infrastructure (2x price).
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

        // Expose Muse Wonder models only with an enabled, usable key so catalog
        // eligibility matches backend configuration. Contributor Mode selects the
        // contributor variant for each Wonder model. The catalog never includes both
        // variants of the same model at once.
        if MetaMuseCredentialStore.shared.hasUsableAPIKey {
            if AppPreferences.metaContributorMode {
                list.append(museModel(
                    baseModel: "muse-wonder-1.0-contributor",
                    idSlug: "muse-wonder-1.0-contributor",
                    displayName: "Muse Wonder 1.0 Contributor"
                ))
                list.append(museModel(
                    baseModel: "muse-wonder-full-1.0-contributor",
                    idSlug: "muse-wonder-full-1.0-contributor",
                    displayName: "Muse Wonder Full 1.0 Contributor"
                ))
            } else {
                list.append(museModel(baseModel: "muse-wonder-1.0", idSlug: "muse-wonder-1.0", displayName: "Muse Wonder 1.0"))
                list.append(museModel(
                    baseModel: "muse-wonder-full-1.0",
                    idSlug: "muse-wonder-full-1.0",
                    displayName: "Muse Wonder Full 1.0"
                ))
            }
        }

        // Same eligibility rule as Meta: only with an enabled key, matching the backend config.
        if MistralCredentialStore.shared.hasUsableAPIKey {
            list.append(contentsOf: mistralModels)
        }

        return list
    }

    static func settingsModels(
        providerIsEnabled: (String) -> Bool = { _ in true },
        disabledModelSlugs: Set<String> = []
    ) -> [[String: Any]] {
        definitions.compactMap { definition in
            guard providerIsEnabled(definition.providerKey),
                  !disabledModelSlugs.contains(definition.idSlug) else { return nil }
            return definition.settingsEntry
        }
    }

    static var allSettingsIDs: Set<String> {
        Set(definitions.map(\.simpleID))
    }

}
