import XCTest
@testable import CLIProxyMenuBar

final class ClaudeThinkingBlockSanitizerTests: XCTestCase {
    func testPreservesThinkingForTrailingToolResults() {
        let request = """
        {"model":"claude-sonnet-4-6","messages":[{"role":"assistant","content":[{"type":"thinking","signature":"sig","thinking":"keep me"},{"type":"tool_use","id":"toolu_1","name":"Bash","input":{"cmd":"pwd"}},{"type":"tool_use","id":"toolu_2","name":"Read","input":{"file":"a"}}]},{"role":"user","content":[{"type":"tool_result","tool_use_id":"toolu_1","content":"ok"},{"type":"tool_result","tool_use_id":"toolu_2","content":"ok"}]}]}
        """

        let sanitized = ClaudeThinkingBlockSanitizer.sanitize(request)

        XCTAssertEqual(sanitized, request)
    }

    func testPreservesRedactedThinkingForTrailingToolResults() {
        let request = """
        {"model":"claude-sonnet-4-6","messages":[{"role":"assistant","content":[{"type":"redacted_thinking","data":"keep me"},{"type":"tool_use","id":"toolu_1","name":"Bash","input":{"cmd":"pwd"}}]},{"role":"user","content":[{"type":"tool_result","tool_use_id":"toolu_1","content":"ok"}]}]}
        """

        let sanitized = ClaudeThinkingBlockSanitizer.sanitize(request)

        XCTAssertEqual(sanitized, request)
    }

    func testStripsThinkingAfterNormalUserContent() {
        let request = """
        {"model":"claude-sonnet-4-6","messages":[{"role":"assistant","content":[{"type":"thinking","signature":"sig","thinking":"strip me"},{"type":"tool_use","id":"toolu_1","name":"Bash","input":{"cmd":"pwd"}}]},{"role":"user","content":[{"type":"tool_result","tool_use_id":"toolu_1","content":"ok"}]},{"role":"user","content":[{"type":"text","text":"continue"}]}]}
        """

        let sanitized = ClaudeThinkingBlockSanitizer.sanitize(request)

        XCTAssertFalse(sanitized.contains("\"type\":\"thinking\""))
        XCTAssertTrue(sanitized.contains("\"type\":\"tool_use\",\"id\":\"toolu_1\""))
        XCTAssertTrue(sanitized.contains("\"type\":\"tool_result\",\"tool_use_id\":\"toolu_1\""))
        XCTAssertTrue(sanitized.contains("\"type\":\"text\",\"text\":\"continue\""))
    }

    func testStripsRedactedThinkingAfterNormalUserContent() {
        let request = """
        {"model":"claude-sonnet-4-6","messages":[{"role":"assistant","content":[{"type":"redacted_thinking","data":"strip me"},{"type":"tool_use","id":"toolu_1","name":"Bash","input":{"cmd":"pwd"}}]},{"role":"user","content":[{"type":"tool_result","tool_use_id":"toolu_1","content":"ok"}]},{"role":"user","content":[{"type":"text","text":"continue"}]}]}
        """

        let sanitized = ClaudeThinkingBlockSanitizer.sanitize(request)

        XCTAssertFalse(sanitized.contains("\"type\":\"redacted_thinking\""))
        XCTAssertTrue(sanitized.contains("\"type\":\"tool_use\",\"id\":\"toolu_1\""))
        XCTAssertTrue(sanitized.contains("\"type\":\"tool_result\",\"tool_use_id\":\"toolu_1\""))
    }

    func testStripsEarlierAssistantThinkingWhenLatestToolResultCycleIsPreserved() {
        let request = """
        {"model":"claude-sonnet-4-6","messages":[{"role":"assistant","content":[{"type":"thinking","signature":"old","thinking":"strip old"},{"type":"tool_use","id":"toolu_old","name":"Bash","input":{"cmd":"pwd"}}]},{"role":"user","content":[{"type":"tool_result","tool_use_id":"toolu_old","content":"ok"}]},{"role":"user","content":[{"type":"text","text":"next task"}]},{"role":"assistant","content":[{"type":"thinking","signature":"new","thinking":"keep new"},{"type":"tool_use","id":"toolu_new","name":"Bash","input":{"cmd":"ls"}}]},{"role":"user","content":[{"type":"tool_result","tool_use_id":"toolu_new","content":"ok"}]}]}
        """

        let sanitized = ClaudeThinkingBlockSanitizer.sanitize(request)

        XCTAssertFalse(sanitized.contains("\"signature\":\"old\""))
        XCTAssertTrue(sanitized.contains("\"signature\":\"new\""))
        XCTAssertTrue(sanitized.contains("\"tool_use_id\":\"toolu_old\""))
        XCTAssertTrue(sanitized.contains("\"tool_use_id\":\"toolu_new\""))
    }

    // The trailing user turn carries a tool_result plus a text block. The preceding
    // assistant is still the active tool-use turn, so its thinking must be preserved.
    func testPreservesThinkingWhenTrailingToolResultIncludesText() {
        let request = """
        {"model":"claude-sonnet-4-6","messages":[{"role":"assistant","content":[{"type":"thinking","signature":"sig","thinking":"keep me"},{"type":"tool_use","id":"toolu_1","name":"Bash","input":{"cmd":"pwd"}}]},{"role":"user","content":[{"type":"tool_result","tool_use_id":"toolu_1","content":"ok"},{"type":"text","text":"also do this"}]}]}
        """

        let sanitized = ClaudeThinkingBlockSanitizer.sanitize(request)

        XCTAssertEqual(sanitized, request)
        XCTAssertTrue(sanitized.contains("\"thinking\":\"keep me\""))
    }

    // A stale assistant message whose only block is thinking must not become
    // `"content":[]` (which Anthropic rejects). Its content is replaced with a
    // placeholder so the assistant turn — and role alternation — is preserved.
    func testReplacesEmptiedAssistantContentWithPlaceholder() {
        let request = """
        {"model":"claude-sonnet-4-6","messages":[{"role":"user","content":[{"type":"text","text":"hello"}]},{"role":"assistant","content":[{"type":"thinking","signature":"s","thinking":"x"}]},{"role":"user","content":[{"type":"text","text":"go"}]}]}
        """

        let sanitized = ClaudeThinkingBlockSanitizer.sanitize(request)

        XCTAssertFalse(sanitized.contains("\"content\":[]"))
        XCTAssertFalse(sanitized.contains("\"type\":\"thinking\""))
        // Assistant turn is preserved (placeholder text), so roles still alternate.
        XCTAssertTrue(sanitized.contains("\"role\":\"assistant\""))
        XCTAssertTrue(sanitized.contains("\"type\":\"text\",\"text\":\"go\""))
        XCTAssertNotNil(try? JSONSerialization.jsonObject(with: Data(sanitized.utf8)))

        // Roles must still alternate: user, assistant, user.
        let roles = roleSequence(sanitized)
        XCTAssertEqual(roles, ["user", "assistant", "user"])
    }

    // Droid sometimes merges several reasoning/tool steps into one assistant message, leaving
    // every thinking block clustered before every tool_use block. That turn is itself malformed,
    // so even though it is the latest assistant turn before a tool_result-only user turn it must
    // NOT be preserved — its thinking has to be stripped. The tool_use blocks (and the matching
    // tool_result ids) must survive so the request stays valid.
    func testStripsClusteredThinkingInLatestAssistantTurn() {
        let request = """
        {"model":"claude-sonnet-4-6","messages":[{"role":"assistant","content":[{"type":"thinking","signature":"sigA","thinking":"first"},{"type":"thinking","signature":"sigB","thinking":"second"},{"type":"tool_use","id":"toolu_1","name":"Bash","input":{"cmd":"pwd"}},{"type":"tool_use","id":"toolu_2","name":"Read","input":{"file":"a"}}]},{"role":"user","content":[{"type":"tool_result","tool_use_id":"toolu_1","content":"ok"},{"type":"tool_result","tool_use_id":"toolu_2","content":"ok"}]}]}
        """

        let sanitized = ClaudeThinkingBlockSanitizer.sanitize(request)

        XCTAssertFalse(sanitized.contains("\"type\":\"thinking\""))
        XCTAssertFalse(sanitized.contains("\"signature\":\"sigA\""))
        XCTAssertFalse(sanitized.contains("\"signature\":\"sigB\""))
        // tool_use blocks and their tool_result references are untouched.
        XCTAssertTrue(sanitized.contains("\"type\":\"tool_use\",\"id\":\"toolu_1\""))
        XCTAssertTrue(sanitized.contains("\"type\":\"tool_use\",\"id\":\"toolu_2\""))
        XCTAssertTrue(sanitized.contains("\"type\":\"tool_result\",\"tool_use_id\":\"toolu_1\""))
        XCTAssertTrue(sanitized.contains("\"type\":\"tool_result\",\"tool_use_id\":\"toolu_2\""))
        XCTAssertNotNil(try? JSONSerialization.jsonObject(with: Data(sanitized.utf8)))
        XCTAssertEqual(roleSequence(sanitized), ["assistant", "user"])
    }

    // Same clustered shape, but with a text block sitting between the clustered thinking blocks
    // and the tool_use blocks — mirrors the real failing layout (e.g. [thinking, thinking, text,
    // tool_use, …]). The interposed text must not stop the clustered turn from being stripped.
    func testStripsClusteredThinkingWithInterposedTextBlock() {
        let request = """
        {"model":"claude-sonnet-4-6","messages":[{"role":"assistant","content":[{"type":"thinking","signature":"sigA","thinking":"first"},{"type":"thinking","signature":"sigB","thinking":"second"},{"type":"text","text":"working on it"},{"type":"tool_use","id":"toolu_1","name":"Bash","input":{"cmd":"pwd"}}]},{"role":"user","content":[{"type":"tool_result","tool_use_id":"toolu_1","content":"ok"}]}]}
        """

        let sanitized = ClaudeThinkingBlockSanitizer.sanitize(request)

        XCTAssertFalse(sanitized.contains("\"type\":\"thinking\""))
        XCTAssertTrue(sanitized.contains("\"type\":\"text\",\"text\":\"working on it\""))
        XCTAssertTrue(sanitized.contains("\"type\":\"tool_use\",\"id\":\"toolu_1\""))
        XCTAssertTrue(sanitized.contains("\"type\":\"tool_result\",\"tool_use_id\":\"toolu_1\""))
        XCTAssertNotNil(try? JSONSerialization.jsonObject(with: Data(sanitized.utf8)))
    }

    // redacted_thinking clusters the same way and must also be stripped.
    func testStripsClusteredRedactedThinkingInLatestAssistantTurn() {
        let request = """
        {"model":"claude-sonnet-4-6","messages":[{"role":"assistant","content":[{"type":"redacted_thinking","data":"first"},{"type":"redacted_thinking","data":"second"},{"type":"tool_use","id":"toolu_1","name":"Bash","input":{"cmd":"pwd"}},{"type":"tool_use","id":"toolu_2","name":"Read","input":{"file":"a"}}]},{"role":"user","content":[{"type":"tool_result","tool_use_id":"toolu_1","content":"ok"},{"type":"tool_result","tool_use_id":"toolu_2","content":"ok"}]}]}
        """

        let sanitized = ClaudeThinkingBlockSanitizer.sanitize(request)

        XCTAssertFalse(sanitized.contains("\"type\":\"redacted_thinking\""))
        XCTAssertTrue(sanitized.contains("\"type\":\"tool_use\",\"id\":\"toolu_1\""))
        XCTAssertTrue(sanitized.contains("\"type\":\"tool_use\",\"id\":\"toolu_2\""))
        XCTAssertTrue(sanitized.contains("\"type\":\"tool_result\",\"tool_use_id\":\"toolu_2\""))
        XCTAssertNotNil(try? JSONSerialization.jsonObject(with: Data(sanitized.utf8)))
    }

    // The 200 case from the report: two thinking blocks that are correctly interleaved with
    // their tool_use blocks (thinking -> tool_use -> thinking -> tool_use). This is a valid
    // signed sequence and must be preserved untouched even though it has >= 2 thinking blocks.
    func testPreservesInterleavedThinkingInLatestAssistantTurn() {
        let request = """
        {"model":"claude-sonnet-4-6","messages":[{"role":"assistant","content":[{"type":"thinking","signature":"sigA","thinking":"first"},{"type":"tool_use","id":"toolu_1","name":"Bash","input":{"cmd":"pwd"}},{"type":"thinking","signature":"sigB","thinking":"second"},{"type":"tool_use","id":"toolu_2","name":"Read","input":{"file":"a"}}]},{"role":"user","content":[{"type":"tool_result","tool_use_id":"toolu_1","content":"ok"},{"type":"tool_result","tool_use_id":"toolu_2","content":"ok"}]}]}
        """

        let sanitized = ClaudeThinkingBlockSanitizer.sanitize(request)

        XCTAssertEqual(sanitized, request)
    }

    // A single leading thinking block followed by parallel tool_use blocks is a normal, valid
    // shape. The `>= 2` thinking guard means it must stay preserved (not mistaken for a cluster).
    func testPreservesSingleLeadingThinkingBeforeParallelToolUse() {
        let request = """
        {"model":"claude-sonnet-4-6","messages":[{"role":"assistant","content":[{"type":"thinking","signature":"sig","thinking":"plan"},{"type":"tool_use","id":"toolu_1","name":"Bash","input":{"cmd":"pwd"}},{"type":"tool_use","id":"toolu_2","name":"Read","input":{"file":"a"}},{"type":"tool_use","id":"toolu_3","name":"Read","input":{"file":"b"}}]},{"role":"user","content":[{"type":"tool_result","tool_use_id":"toolu_1","content":"ok"},{"type":"tool_result","tool_use_id":"toolu_2","content":"ok"},{"type":"tool_result","tool_use_id":"toolu_3","content":"ok"}]}]}
        """

        let sanitized = ClaudeThinkingBlockSanitizer.sanitize(request)

        XCTAssertEqual(sanitized, request)
        XCTAssertTrue(sanitized.contains("\"thinking\":\"plan\""))
    }

    private func roleSequence(_ json: String) -> [String] {
        guard let data = json.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let messages = object["messages"] as? [[String: Any]] else {
            return []
        }
        return messages.compactMap { $0["role"] as? String }
    }
}
