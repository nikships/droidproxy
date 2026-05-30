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

    private func roleSequence(_ json: String) -> [String] {
        guard let data = json.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let messages = object["messages"] as? [[String: Any]] else {
            return []
        }
        return messages.compactMap { $0["role"] as? String }
    }
}
