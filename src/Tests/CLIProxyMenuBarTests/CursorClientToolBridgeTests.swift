import XCTest
@testable import CLIProxyMenuBar

final class CursorClientToolBridgeTests: XCTestCase {
    func testInjectsSystemPromptReminderAndPinsAskMode() throws {
        let body = """
        {"model":"cursor-grok-4.6","messages":[{"role":"user","content":"write a file"}],"tools":[{"type":"function","name":"Write"}]}
        """
        let injected = try XCTUnwrap(CursorClientToolBridge.inject(into: body))
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(injected.utf8)) as? [String: Any])
        XCTAssertEqual(root["mode"] as? String, "ask")
        let messages = try XCTUnwrap(root["messages"] as? [[String: Any]])
        XCTAssertEqual(messages.count, 2)
        XCTAssertEqual(messages[0]["role"] as? String, "system")
        XCTAssertTrue((messages[0]["content"] as? String)?.contains(CursorClientToolBridge.marker) == true)
        XCTAssertEqual(messages[1]["role"] as? String, "user")
        XCTAssertTrue((messages[1]["content"] as? String)?.contains(CursorClientToolBridge.marker) == true)
        XCTAssertEqual((root["tools"] as? [Any])?.count, 1)
    }

    func testDoesNotDuplicateWhenFullyInjected() throws {
        let original: [String: Any] = [
            "mode": "ask",
            "messages": [
                ["role": "system", "content": CursorClientToolBridge.systemPrompt],
                ["role": "user", "content": "hi" + CursorClientToolBridge.userReminder]
            ]
        ]
        let data = try JSONSerialization.data(withJSONObject: original)
        let body = try XCTUnwrap(String(data: data, encoding: .utf8))
        XCTAssertNil(CursorClientToolBridge.inject(into: body))
    }

    func testPinsAskModeEvenWhenBridgePromptExists() throws {
        let original: [String: Any] = [
            "mode": "agent",
            "messages": [
                ["role": "system", "content": CursorClientToolBridge.systemPrompt],
                ["role": "user", "content": "hi" + CursorClientToolBridge.userReminder]
            ]
        ]
        let data = try JSONSerialization.data(withJSONObject: original)
        let body = try XCTUnwrap(String(data: data, encoding: .utf8))
        let injected = try XCTUnwrap(CursorClientToolBridge.inject(into: body))
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(injected.utf8)) as? [String: Any])
        XCTAssertEqual(root["mode"] as? String, "ask")
        let messages = try XCTUnwrap(root["messages"] as? [[String: Any]])
        XCTAssertEqual(messages.count, 2)
    }
}
