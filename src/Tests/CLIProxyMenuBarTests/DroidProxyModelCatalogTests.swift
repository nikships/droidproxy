import Foundation
import XCTest
@testable import CLIProxyMenuBar

final class DroidProxyModelCatalogTests: XCTestCase {
    func testFable5MatchesOpus48EffortLevels() throws {
        let fable = try XCTUnwrap(settingsEntry(id: "custom:droidproxy:fable-5"))

        XCTAssertEqual(fable["model"] as? String, "claude-fable-5")
        XCTAssertEqual(fable["enableThinking"] as? Bool, true)
        XCTAssertEqual(fable["reasoningEffort"] as? String, "xhigh")
        XCTAssertEqual(fable["defaultReasoningEffort"] as? String, "xhigh")
        XCTAssertEqual(fable["supportedReasoningEfforts"] as? [String], ["low", "medium", "high", "xhigh", "max"])
        XCTAssertEqual(fable["maxOutputTokens"] as? Int, 128000)
    }

    func testFable51MatchesOpus48EffortLevels() throws {
        let fable = try XCTUnwrap(settingsEntry(id: "custom:droidproxy:fable-5-1"))

        XCTAssertEqual(fable["model"] as? String, "claude-fable-5-1")
        XCTAssertEqual(fable["enableThinking"] as? Bool, true)
        XCTAssertEqual(fable["reasoningEffort"] as? String, "xhigh")
        XCTAssertEqual(fable["defaultReasoningEffort"] as? String, "xhigh")
        XCTAssertEqual(fable["supportedReasoningEfforts"] as? [String], ["low", "medium", "high", "xhigh", "max"])
        XCTAssertEqual(fable["maxOutputTokens"] as? Int, 128000)
    }

    func testApplyWritesBothOpus5AndOpus48ForClaudeProvider() throws {
        // Apply/Re-apply serializes every enabled definition via settingsModels();
        // both Opus entries are providerKey "claude", so enabling Claude writes both.
        let claudeModels = DroidProxyModelCatalog.settingsModels { $0 == "claude" }
        let ids = Set(claudeModels.compactMap { $0["id"] as? String })
        XCTAssertTrue(ids.contains("custom:droidproxy:opus-5"))
        XCTAssertTrue(ids.contains("custom:droidproxy:opus-4-8"))

        let opus5 = try XCTUnwrap(settingsEntry(id: "custom:droidproxy:opus-5"))
        XCTAssertEqual(opus5["model"] as? String, "claude-opus-5")
        XCTAssertEqual(opus5["displayName"] as? String, "DroidProxy: Opus 5")

        let opus48 = try XCTUnwrap(settingsEntry(id: "custom:droidproxy:opus-4-8"))
        XCTAssertEqual(opus48["model"] as? String, "claude-opus-4-8")
        XCTAssertEqual(opus48["displayName"] as? String, "DroidProxy: Opus 4.8")

        // Non-Junie only: the junie provider exposes Opus 5 but not Opus 4.8.
        let junieIds = Set(DroidProxyModelCatalog.settingsModels { $0 == "junie" }
            .compactMap { $0["id"] as? String })
        XCTAssertTrue(junieIds.contains("custom:droidproxy:junie-claude-opus-5"))
        XCTAssertFalse(junieIds.contains("custom:droidproxy:junie-claude-opus-4-8"))
    }

    func testSonnet5UsesNativeModelIDAndExposesFullLevels() throws {
        let sonnet = try XCTUnwrap(settingsEntry(id: "custom:droidproxy:sonnet-5"))

        XCTAssertEqual(sonnet["model"] as? String, "claude-sonnet-5")
        XCTAssertEqual(sonnet["enableThinking"] as? Bool, true)
        XCTAssertEqual(sonnet["reasoningEffort"] as? String, "xhigh")
        XCTAssertEqual(sonnet["defaultReasoningEffort"] as? String, "xhigh")
        XCTAssertEqual(sonnet["supportedReasoningEfforts"] as? [String], ["low", "medium", "high", "xhigh", "max"])
    }

    func testGpt56LunaUsesNativeModelMetadata() throws {
        let luna = try XCTUnwrap(settingsEntry(id: "custom:droidproxy:gpt-5.6-luna"))

        XCTAssertEqual(luna["model"] as? String, "gpt-5.6-luna")
        XCTAssertEqual(luna["provider"] as? String, "openai")
        XCTAssertEqual(luna["baseUrl"] as? String, "http://localhost:8317/v1")
        XCTAssertEqual(luna["displayName"] as? String, "DroidProxy: GPT 5.6 Luna")
        XCTAssertEqual(luna["maxOutputTokens"] as? Int, 128000)
        XCTAssertEqual(luna["enableThinking"] as? Bool, true)
        XCTAssertEqual(luna["reasoningEffort"] as? String, "medium")
        XCTAssertEqual(luna["defaultReasoningEffort"] as? String, "medium")
        XCTAssertEqual(luna["supportedReasoningEfforts"] as? [String], ["none", "low", "medium", "high", "xhigh", "max"])
    }

    func testGpt6AstraUsesNativeModelMetadata() throws {
        let astra = try XCTUnwrap(settingsEntry(id: "custom:droidproxy:gpt-6-astra"))

        XCTAssertEqual(astra["model"] as? String, "gpt-6-astra")
        XCTAssertEqual(astra["provider"] as? String, "openai")
        XCTAssertEqual(astra["baseUrl"] as? String, "http://localhost:8317/v1")
        XCTAssertEqual(astra["displayName"] as? String, "DroidProxy: GPT 6 Astra")
        XCTAssertEqual(astra["maxOutputTokens"] as? Int, 128000)
        XCTAssertEqual(astra["maxContextLimit"] as? Int, 1_050_000)
        XCTAssertEqual(astra["enableThinking"] as? Bool, true)
        XCTAssertEqual(astra["reasoningEffort"] as? String, "medium")
        XCTAssertEqual(astra["defaultReasoningEffort"] as? String, "medium")
        XCTAssertEqual(astra["supportedReasoningEfforts"] as? [String], ["low", "medium", "high", "xhigh", "max"])
    }

    func testKimiK3UsesMaxReasoningMetadata() throws {
        let kimiK3 = try XCTUnwrap(settingsEntry(id: "custom:droidproxy:kimi-k3"))

        XCTAssertEqual(kimiK3["model"] as? String, "kimi-k3")
        XCTAssertEqual(kimiK3["provider"] as? String, "openai")
        XCTAssertEqual(kimiK3["baseUrl"] as? String, "http://localhost:8317/v1")
        XCTAssertEqual(kimiK3["displayName"] as? String, "DroidProxy: Kimi K3")
        XCTAssertEqual(kimiK3["maxOutputTokens"] as? Int, 65536)
        XCTAssertEqual(kimiK3["enableThinking"] as? Bool, true)
        XCTAssertEqual(kimiK3["reasoningEffort"] as? String, "max")
        XCTAssertEqual(kimiK3["defaultReasoningEffort"] as? String, "max")
        XCTAssertEqual(kimiK3["supportedReasoningEfforts"] as? [String], ["max"])

        let modelsWithoutKimi = DroidProxyModelCatalog.settingsModels { $0 != "kimi" }
        XCTAssertFalse(modelsWithoutKimi.contains { ($0["id"] as? String) == "custom:droidproxy:kimi-k3" })
    }

    func testGemini38FlashHighUsesAntigravityModelMetadata() throws {
        let gemini = try XCTUnwrap(settingsEntry(id: "custom:droidproxy:gemini-3.8-flash-high"))

        XCTAssertEqual(gemini["model"] as? String, "gemini-3.8-flash-high")
        XCTAssertEqual(gemini["provider"] as? String, "openai")
        XCTAssertEqual(gemini["baseUrl"] as? String, "http://localhost:8317/v1")
        XCTAssertEqual(gemini["displayName"] as? String, "DroidProxy: Antigravity: Gemini 3.8 Flash (High)")
        XCTAssertEqual(gemini["maxOutputTokens"] as? Int, 65536)
        XCTAssertEqual(gemini["enableThinking"] as? Bool, true)
        XCTAssertEqual(gemini["reasoningEffort"] as? String, "high")
        XCTAssertEqual(gemini["defaultReasoningEffort"] as? String, "high")
        XCTAssertEqual(gemini["supportedReasoningEfforts"] as? [String], ["high"])
    }

    func testGrok46UsesOpenAIProviderAndApiXAIProxy() throws {
        let grok = try XCTUnwrap(settingsEntry(id: "custom:droidproxy:grok-4.6"))

        XCTAssertEqual(grok["model"] as? String, "grok-4.6")
        XCTAssertEqual(grok["provider"] as? String, "openai")
        XCTAssertEqual(grok["baseUrl"] as? String, "http://localhost:8317/v1")
        XCTAssertEqual(grok["displayName"] as? String, "DroidProxy: Grok 4.6")
        XCTAssertEqual(grok["supportedReasoningEfforts"] as? [String], ["low", "medium", "high", "xhigh"])
        XCTAssertEqual(grok["defaultReasoningEffort"] as? String, "high")
        XCTAssertEqual(grok["maxContextLimit"] as? Int, 500_000)
    }

    func testGrokProviderModelsAreRegistered() {
        let grokModels = DroidProxyModelCatalog.settingsModels { $0 == "grok" }
        let ids = grokModels.compactMap { $0["id"] as? String }
        XCTAssertEqual(ids, ["custom:droidproxy:grok-4.6"])
    }

    func testClineFreeModelsUseUpstreamSlugsAndGenericProvider() throws {
        let kat = try XCTUnwrap(settingsEntry(id: "custom:droidproxy:cline-kat-coder-pro"))
        XCTAssertEqual(kat["model"] as? String, "kwaipilot/kat-coder-pro")
        XCTAssertEqual(kat["provider"] as? String, "generic-chat-completion-api")
        XCTAssertEqual(kat["baseUrl"] as? String, "http://localhost:8317/v1")
        XCTAssertEqual(kat["displayName"] as? String, "DroidProxy: Cline Kat Coder Pro (Free)")
        XCTAssertEqual(kat["supportedReasoningEfforts"] as? [String], ["high"])
        XCTAssertEqual(kat["maxContextLimit"] as? Int, 256_000)
        XCTAssertEqual(kat["noImageSupport"] as? Bool, true)

        let trinity = try XCTUnwrap(settingsEntry(id: "custom:droidproxy:cline-trinity-large"))
        XCTAssertEqual(trinity["model"] as? String, "arcee-ai/trinity-large-preview:free")
        XCTAssertEqual(trinity["maxContextLimit"] as? Int, 256_000)
    }

    func testNextAvailableIndexSkipsExistingIndicesIncludingHoles() {
        // Survivors of removals keep sparse indices; count-based allocation would
        // collide. Allocation must be max(existing)+1.
        let models: [[String: Any]] = [
            ["id": "a", "index": 0],
            ["id": "b", "index": 2],
            ["id": "c", "index": 4],
        ]
        XCTAssertEqual(DroidProxyModelCatalog.nextAvailableIndex(in: models), 5)

        // Missing index fields are ignored, not treated as 0.
        let mixed: [[String: Any]] = [
            ["id": "d"],
            ["id": "e", "index": 7],
        ]
        XCTAssertEqual(DroidProxyModelCatalog.nextAvailableIndex(in: mixed), 8)

        // Empty / index-less arrays start at zero.
        XCTAssertEqual(DroidProxyModelCatalog.nextAvailableIndex(in: []), 0)
        XCTAssertEqual(DroidProxyModelCatalog.nextAvailableIndex(in: [["id": "f"]]), 0)

        // JSONSerialization numbers arrive as NSNumber and must still be seen.
        let fromJSON = (try? JSONSerialization.data(withJSONObject: [["index": 12]]))
            .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [[String: Any]] } ?? []
        XCTAssertEqual(DroidProxyModelCatalog.nextAvailableIndex(in: fromJSON), 13)
    }

    func testClineProviderModelsAreRegistered() {
        let clineModels = DroidProxyModelCatalog.settingsModels { $0 == "cline" }
        let ids = Set(clineModels.compactMap { $0["id"] as? String })
        XCTAssertEqual(
            ids,
            Set(["custom:droidproxy:cline-kat-coder-pro", "custom:droidproxy:cline-trinity-large"])
        )
    }

    func testClineModelDetectionMatchesCatalogSlugsOnly() {
        XCTAssertEqual(
            DroidProxyModelCatalog.clineBaseModels,
            Set(["kwaipilot/kat-coder-pro", "arcee-ai/trinity-large-preview:free"])
        )

        XCTAssertTrue(ThinkingProxy.isClineModel("kwaipilot/kat-coder-pro"))
        XCTAssertTrue(ThinkingProxy.isClineModel("arcee-ai/trinity-large-preview:free"))

        // A user's own namespaced custom model pointed at :8317 must not be
        // claimed as Cline traffic.
        XCTAssertFalse(ThinkingProxy.isClineModel("openai/gpt-4o"))
        XCTAssertFalse(ThinkingProxy.isClineModel("kwaipilot/kat-coder-pro-unknown"))
        XCTAssertFalse(ThinkingProxy.isClineModel("claude-opus-5"))
        XCTAssertFalse(ThinkingProxy.isClineModel(nil))
    }

    func testGrokContextLimitsMatchXAIDocs() throws {
        let grok46 = try XCTUnwrap(settingsEntry(id: "custom:droidproxy:grok-4.6"))

        XCTAssertEqual(grok46["maxContextLimit"] as? Int, 500_000)
    }

    func testCursorGrokModelsAppearWhenBetaEnabled() throws {
        let previous = BETA_FLAG
        BETA_FLAG = true
        defer { BETA_FLAG = previous }

        let standard = try XCTUnwrap(settingsEntry(id: "custom:droidproxy:cursor-grok-4.6"))
        let fast = try XCTUnwrap(settingsEntry(id: "custom:droidproxy:cursor-grok-4.6-fast"))

        XCTAssertEqual(standard["model"] as? String, "cursor-grok-4.6")
        XCTAssertEqual(standard["provider"] as? String, "generic-chat-completion-api")
        XCTAssertEqual(standard["displayName"] as? String, "DroidProxy: Cursor Grok 4.6")
        XCTAssertEqual(fast["model"] as? String, "cursor-grok-4.6-fast")
        XCTAssertEqual(fast["displayName"] as? String, "DroidProxy: Cursor Grok 4.6 Fast")
    }

    func testCopilotModelParserKeepsSelectableChatModels() throws {
        let payload: [String: Any] = [
            "data": [
                [
                    "id": "claude-opus-4-8",
                    "name": "Claude Opus 4.8",
                    "model_picker_enabled": true,
                    "supported_endpoints": ["/responses"],
                    "capabilities": [
                        "type": "chat",
                        "limits": [
                            "max_output_tokens": 32_000,
                            "max_context_window_tokens": 200_000
                        ],
                        "supports": [
                            "vision": true,
                            "reasoning_effort": ["xhigh", "low", "ultra", "high"]
                        ]
                    ]
                ],
                [
                    "id": "hidden-model",
                    "name": "Hidden Model",
                    "model_picker_enabled": false,
                    "supported_endpoints": ["/responses"],
                    "capabilities": ["type": "chat"]
                ],
                [
                    "id": "embedding-model",
                    "name": "Embedding Model",
                    "model_picker_enabled": true,
                    "supported_endpoints": ["/responses"],
                    "capabilities": ["type": "embeddings"]
                ],
                [
                    "id": "disabled-model",
                    "name": "Disabled Model",
                    "model_picker_enabled": true,
                    "policy": ["state": "disabled"],
                    "supported_endpoints": ["/responses"],
                    "capabilities": ["type": "chat"]
                ]
            ]
        ]

        let data = try JSONSerialization.data(withJSONObject: payload)
        let models = try XCTUnwrap(CopilotGatewayManager.parseModels(from: data))

        XCTAssertEqual(models.map(\.id), ["claude-opus-4-8"])
        let opus = try XCTUnwrap(models.first)
        XCTAssertEqual(opus.displayName, "Claude Opus 4.8")
        XCTAssertEqual(opus.maxOutputTokens, 32_000)
        XCTAssertEqual(opus.maxContextLimit, 200_000)
        XCTAssertTrue(opus.supportsVision)
        XCTAssertEqual(opus.reasoningEfforts, ["low", "high", "xhigh"])
    }

    func testCopilotDeviceCodeParserHandlesAnsiFormattedOutput() throws {
        let output = "\u{001B}[36mℹ\u{001B}[0m Please enter the code \"ABCD-EFGH\" in https://github.com/login/device"
        let prompt = try XCTUnwrap(DeviceCodeCapture.parsePrompt(in: output))

        XCTAssertEqual(prompt.code, "ABCD-EFGH")
        XCTAssertEqual(prompt.url.absoluteString, "https://github.com/login/device")
    }

    func testCopilotDeviceCodeParserFallsBackToCodeAndURL() throws {
        let output = "Open https://github.com/login/device, then use device code: WXYZ-1234."
        let prompt = try XCTUnwrap(DeviceCodeCapture.parsePrompt(in: output))

        XCTAssertEqual(prompt.code, "WXYZ-1234")
        XCTAssertEqual(prompt.url.absoluteString, "https://github.com/login/device")
    }

    func testCopilotSelectionIsCappedAtThreeFactoryModels() throws {
        let defaults = UserDefaults.standard
        let oldSelected = defaults.object(forKey: CopilotModelPreferences.selectedModelIDsKey)
        let oldCached = defaults.object(forKey: CopilotModelPreferences.cachedModelsKey)
        defer {
            restore(oldSelected, key: CopilotModelPreferences.selectedModelIDsKey)
            restore(oldCached, key: CopilotModelPreferences.cachedModelsKey)
        }

        let models = [
            CopilotModelDescriptor(
                id: "claude-opus-4.8",
                displayName: "Claude Opus 4.8",
                maxOutputTokens: 32_000,
                maxContextLimit: 200_000,
                supportsVision: true,
                reasoningEfforts: ["low", "high", "xhigh"]
            ),
            CopilotModelDescriptor(
                id: "gpt-5",
                displayName: "GPT-5",
                maxOutputTokens: 16_000,
                maxContextLimit: 128_000,
                supportsVision: false,
                reasoningEfforts: ["low", "medium", "high"]
            ),
            CopilotModelDescriptor(
                id: "gemini-3-pro",
                displayName: "Gemini 3 Pro",
                maxOutputTokens: 8_000,
                maxContextLimit: nil,
                supportsVision: true,
                reasoningEfforts: []
            ),
            CopilotModelDescriptor(
                id: "fourth-model",
                displayName: "Fourth",
                maxOutputTokens: 4_000,
                maxContextLimit: nil,
                supportsVision: false,
                reasoningEfforts: []
            )
        ]
        CopilotModelPreferences.saveCachedModels(models)
        CopilotModelPreferences.saveSelectedModelIDs(models.map(\.id))

        XCTAssertEqual(CopilotModelPreferences.selectedModelIDs, models.prefix(3).map(\.id))

        let entries = DroidProxyModelCatalog.settingsModels { $0 == "copilot" }
        XCTAssertEqual(entries.count, CopilotModelPreferences.maximumSelectedModels)
        XCTAssertEqual(
            entries.compactMap { $0["model"] as? String },
            models.prefix(3).map(\.id)
        )

        let opus = try XCTUnwrap(entries.first)
        XCTAssertEqual(opus["provider"] as? String, "openai")
        XCTAssertEqual(opus["baseUrl"] as? String, CopilotGatewayManager.gatewayBaseURL)
        XCTAssertEqual(opus["displayName"] as? String, "DroidProxy: GitHub Copilot: Claude Opus 4.8")
        XCTAssertEqual(opus["noImageSupport"] as? Bool, false)
        XCTAssertEqual(opus["supportedReasoningEfforts"] as? [String], ["low", "high", "xhigh"])
        XCTAssertEqual(opus["defaultReasoningEffort"] as? String, "xhigh")

        let gpt = try XCTUnwrap(entries.first { ($0["model"] as? String) == "gpt-5" })
        XCTAssertEqual(gpt["noImageSupport"] as? Bool, true)
        XCTAssertEqual(gpt["supportedReasoningEfforts"] as? [String], ["low", "medium", "high"])

        let gemini = try XCTUnwrap(entries.first { ($0["model"] as? String) == "gemini-3-pro" })
        XCTAssertNil(gemini["enableThinking"])
        XCTAssertNil(gemini["supportedReasoningEfforts"])
        XCTAssertNil(gemini["defaultReasoningEffort"])

        let maxReasoningModel = DroidProxyModelCatalog.copilotModel(
            CopilotModelDescriptor(
                id: "reasoning-max",
                displayName: "Reasoning Max",
                maxOutputTokens: 4_000,
                maxContextLimit: nil,
                supportsVision: false,
                reasoningEfforts: ["high", "max"]
            )
        ).settingsEntry
        XCTAssertEqual(maxReasoningModel["defaultReasoningEffort"] as? String, "max")
    }

    private func settingsEntry(id: String) -> [String: Any]? {
        DroidProxyModelCatalog
            .settingsModels()
            .first { ($0["id"] as? String) == id }
    }

    private func restore(_ value: Any?, key: String) {
        if let value {
            UserDefaults.standard.set(value, forKey: key)
        } else {
            UserDefaults.standard.removeObject(forKey: key)
        }
    }
}
