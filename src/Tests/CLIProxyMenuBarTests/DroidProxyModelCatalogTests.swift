import XCTest
@testable import CLIProxyMenuBar

final class DroidProxyModelCatalogTests: XCTestCase {
    func testMythos5MatchesOpus48EffortLevels() throws {
        let mythos = try XCTUnwrap(settingsEntry(id: "custom:droidproxy:mythos-5"))

        XCTAssertEqual(mythos["model"] as? String, "claude-mythos-5")
        XCTAssertEqual(mythos["displayName"] as? String, "DroidProxy: Mythos 5")
        XCTAssertEqual(mythos["enableThinking"] as? Bool, true)
        XCTAssertEqual(mythos["reasoningEffort"] as? String, "xhigh")
        XCTAssertEqual(mythos["defaultReasoningEffort"] as? String, "xhigh")
        XCTAssertEqual(mythos["supportedReasoningEfforts"] as? [String], ["low", "medium", "high", "xhigh", "max"])
        XCTAssertEqual(mythos["maxOutputTokens"] as? Int, 128000)
    }

    func testMythos5RemapsToFable5Upstream() {
        let body = "{\"model\":\"claude-mythos-5\",\"max_tokens\":1000}"
        let rewritten = ThinkingProxy.rewriteUpstreamModelAlias(in: body)
        XCTAssertTrue(rewritten.contains("\"model\":\"claude-fable-5\""))
        XCTAssertFalse(rewritten.contains("claude-mythos-5"))
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

    private func settingsEntry(id: String) -> [String: Any]? {
        DroidProxyModelCatalog
            .settingsModels()
            .first { ($0["id"] as? String) == id }
    }
}
