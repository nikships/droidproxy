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

    func testSonnet46UsesNativeModelIDAndExposesMax() throws {
        let sonnet = try XCTUnwrap(settingsEntry(id: "custom:droidproxy:sonnet-4-6"))

        // Sonnet 4.6 ships its native Anthropic model id (no proxy alias) and
        // exposes max in Droid's selector. ThinkingProxy auto-converts a max
        // request to classic extended thinking since adaptive rejects effort:max.
        XCTAssertEqual(sonnet["model"] as? String, "claude-sonnet-4-6")
        XCTAssertEqual(sonnet["enableThinking"] as? Bool, true)
        XCTAssertEqual(sonnet["reasoningEffort"] as? String, "high")
        XCTAssertEqual(sonnet["defaultReasoningEffort"] as? String, "high")
        XCTAssertEqual(sonnet["supportedReasoningEfforts"] as? [String], ["low", "medium", "high", "max"])
    }

    func testComposer25RegisteredUnderGrokProviderInBeta() throws {
        let original = BETA_FLAG
        BETA_FLAG = true
        defer { BETA_FLAG = original }

        let grok = try XCTUnwrap(settingsEntry(id: "custom:droidproxy:grok-composer-2.5-fast"))

        // Composer 2.5 is served via the Grok CLI endpoint as a generic
        // chat-completion model. ThinkingProxy routes any "grok-" model to
        // cli-chat-proxy.grok.com, so the upstream model id must keep that prefix.
        let model = try XCTUnwrap(grok["model"] as? String)
        XCTAssertEqual(model, "grok-composer-2.5-fast")
        XCTAssertTrue(model.hasPrefix("grok-"))
        XCTAssertEqual(grok["provider"] as? String, "generic-chat-completion-api")
        XCTAssertEqual(grok["baseUrl"] as? String, "http://localhost:8317/v1")
        XCTAssertEqual(grok["displayName"] as? String, "DroidProxy: Grok CLI: Composer 2.5")
        // Composer 2.5 is non-reasoning, so no thinking metadata is emitted.
        XCTAssertNil(grok["enableThinking"])
    }

    func testGrokBuildRegisteredUnderGrokProviderInBeta() throws {
        let original = BETA_FLAG
        BETA_FLAG = true
        defer { BETA_FLAG = original }

        let grok = try XCTUnwrap(settingsEntry(id: "custom:droidproxy:grok-build"))

        // grok-build is the second model the Grok CLI endpoint serves; it routes
        // through the same "grok-" passthrough in ThinkingProxy as Composer 2.5.
        let model = try XCTUnwrap(grok["model"] as? String)
        XCTAssertEqual(model, "grok-build")
        XCTAssertTrue(model.hasPrefix("grok-"))
        XCTAssertEqual(grok["provider"] as? String, "generic-chat-completion-api")
        XCTAssertEqual(grok["baseUrl"] as? String, "http://localhost:8317/v1")
        XCTAssertEqual(grok["displayName"] as? String, "DroidProxy: Grok CLI: Grok Build")
        // The endpoint exposes no reasoning.effort for grok-build (levels: []),
        // so no thinking metadata is emitted.
        XCTAssertNil(grok["enableThinking"])
    }

    private func settingsEntry(id: String) -> [String: Any]? {
        DroidProxyModelCatalog
            .settingsModels()
            .first { ($0["id"] as? String) == id }
    }
}
