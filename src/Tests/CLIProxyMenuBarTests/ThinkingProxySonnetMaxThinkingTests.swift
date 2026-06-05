import XCTest
@testable import CLIProxyMenuBar

final class ThinkingProxySonnetMaxThinkingTests: XCTestCase {
    func testConvertsSonnetAdaptiveThinkingToClassicWhenEffortIsMax() {
        let request = """
        {"model":"claude-sonnet-4-6","max_tokens":8192,"thinking":{"type":"adaptive"},"output_config":{"effort":"max"},"messages":[{"role":"user","content":"hi"}]}
        """

        let rewritten = ThinkingProxy.applySonnetMaxThinking(in: request)

        // thinking becomes classic extended thinking and max_tokens is pinned so
        // the budget fits; key ordering and other fields are preserved.
        XCTAssertEqual(
            rewritten,
            """
            {"model":"claude-sonnet-4-6","max_tokens":64000,"thinking":{"type":"enabled","budget_tokens":63999},"output_config":{"effort":"max"},"messages":[{"role":"user","content":"hi"}]}
            """
        )
    }

    func testInjectsThinkingAndMaxTokensWhenAbsent() {
        let request = """
        {"model":"claude-sonnet-4-6","output_config":{"effort":"max"},"messages":[{"role":"user","content":"hi"}]}
        """

        let rewritten = ThinkingProxy.applySonnetMaxThinking(in: request)

        XCTAssertEqual(
            rewritten,
            """
            {"model":"claude-sonnet-4-6","max_tokens":64000,"thinking":{"type":"enabled","budget_tokens":63999},"output_config":{"effort":"max"},"messages":[{"role":"user","content":"hi"}]}
            """
        )
    }

    func testLeavesSonnetUnchangedForNonMaxEffort() {
        let request = """
        {"model":"claude-sonnet-4-6","thinking":{"type":"adaptive"},"output_config":{"effort":"high"}}
        """

        XCTAssertEqual(ThinkingProxy.applySonnetMaxThinking(in: request), request)
    }

    func testLeavesSonnetUnchangedWhenNoOutputConfig() {
        let request = """
        {"model":"claude-sonnet-4-6","thinking":{"type":"adaptive"}}
        """

        XCTAssertEqual(ThinkingProxy.applySonnetMaxThinking(in: request), request)
    }

    func testLeavesNonSonnetModelUnchangedEvenAtMaxEffort() {
        let request = """
        {"model":"claude-opus-4-8","thinking":{"type":"adaptive"},"output_config":{"effort":"max"}}
        """

        XCTAssertEqual(ThinkingProxy.applySonnetMaxThinking(in: request), request)
    }
}
