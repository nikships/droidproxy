import XCTest
@testable import CLIProxyMenuBar

final class DroidProxyModelCatalogTests: XCTestCase {
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
