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

    func testSonnet5UsesNativeModelIDAndExposesFullLevels() throws {
        let sonnet = try XCTUnwrap(settingsEntry(id: "custom:droidproxy:sonnet-5"))

        XCTAssertEqual(sonnet["model"] as? String, "claude-sonnet-5")
        XCTAssertEqual(sonnet["enableThinking"] as? Bool, true)
        XCTAssertEqual(sonnet["reasoningEffort"] as? String, "xhigh")
        XCTAssertEqual(sonnet["defaultReasoningEffort"] as? String, "xhigh")
        XCTAssertEqual(sonnet["supportedReasoningEfforts"] as? [String], ["low", "medium", "high", "xhigh", "max"])
    }

    private func settingsEntry(id: String) -> [String: Any]? {
        DroidProxyModelCatalog
            .settingsModels()
            .first { ($0["id"] as? String) == id }
    }
}
