import XCTest
@testable import CLIProxyMenuBar

final class OpenAICompatibilityConfigTests: XCTestCase {
    private func meta(_ keys: [String]) -> OpenAICompatibilityConfig.Entry {
        OpenAICompatibilityConfig.Entry(
            comment: "Meta Muse subscription",
            name: "meta",
            baseURL: "https://api.meta.ai/v1",
            apiKeys: keys,
            models: ["muse-wonder-1.0", "muse-wonder-1.0-contributor", "muse-wonder-full-1.0", "muse-wonder-full-1.0-contributor"]
        )
    }

    private func mistral(_ keys: [String]) -> OpenAICompatibilityConfig.Entry {
        OpenAICompatibilityConfig.Entry(
            comment: "Mistral", name: "mistral", baseURL: "https://api.mistral.ai/v1",
            apiKeys: keys, models: ["mistral-large-4"]
        )
    }

    func testMetaAloneKeepsTheExistingBytes() {
        let expected = """

        # Meta Muse subscription (auto-added by DroidProxy)
        openai-compatibility:
          - name: "meta"
            base-url: "https://api.meta.ai/v1"
            api-key-entries:
              - api-key: "k1"
              - api-key: "k2"
            models:
              - name: "muse-wonder-1.0"
              - name: "muse-wonder-1.0-contributor"
              - name: "muse-wonder-full-1.0"
              - name: "muse-wonder-full-1.0-contributor"

        """
        XCTAssertEqual(OpenAICompatibilityConfig.render([meta(["k1", "k2"])]), expected)
    }

    func testMetaAndMistralShareOneTopLevelKey() {
        let config = OpenAICompatibilityConfig.render([meta(["m"]), mistral(["a", "b"])])
        XCTAssertEqual(config.components(separatedBy: "openai-compatibility:").count - 1, 1)
        XCTAssertEqual(config.components(separatedBy: "\n  - name:").count - 1, 2)
        XCTAssertTrue(config.contains("# Meta Muse subscription (auto-added by DroidProxy)"))
        XCTAssertTrue(config.contains("# Mistral (auto-added by DroidProxy)"))
        XCTAssertTrue(config.contains("  - name: \"mistral\"\n    base-url: \"https://api.mistral.ai/v1\""))
        XCTAssertEqual(config.components(separatedBy: "- api-key:").count - 1, 3)
    }

    func testMistralAloneOmitsMeta() {
        let config = OpenAICompatibilityConfig.render([meta([]), mistral(["a"])])
        XCTAssertFalse(config.contains("meta"))
        XCTAssertTrue(config.contains("\"mistral\""))
    }

    func testQuotesBackslashesAndNewlinesAreEscaped() {
        let config = OpenAICompatibilityConfig.render([mistral(["quote\"\\\nkey"])])
        XCTAssertTrue(config.contains("- api-key: \"quote\\\"\\\\\\nkey\""))
        XCTAssertEqual(config.components(separatedBy: "\n").count, OpenAICompatibilityConfig.render([mistral(["quotekey"])]).components(separatedBy: "\n").count)
    }

    func testNoEntriesOrNoKeysRenderNothing() {
        XCTAssertEqual(OpenAICompatibilityConfig.render([]), "")
        XCTAssertEqual(OpenAICompatibilityConfig.render([meta([]), mistral([])]), "")
    }
}
