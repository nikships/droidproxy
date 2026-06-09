import XCTest
@testable import CLIProxyMenuBar

final class ThinkingProxyGrokConvIDTests: XCTestCase {
    /// The cache-affinity id must be identical on turn 1 and later turns of the
    /// same conversation (history is replayed verbatim), or cli-chat-proxy routes
    /// follow-ups to a different server and the prompt cache never hits.
    func testConvIDStableAcrossTurns() {
        let turn1 = #"{"model":"grok-composer-2.5-fast","messages":[{"role":"system","content":"You are helpful."},{"role":"user","content":"First task"}]}"#
        let turn2 = #"{"model":"grok-composer-2.5-fast","messages":[{"role":"system","content":"You are helpful."},{"role":"user","content":"First task"},{"role":"assistant","content":"done"},{"role":"user","content":"Second task"}]}"#

        let id1 = ThinkingProxy.grokConversationID(forBody: turn1)
        let id2 = ThinkingProxy.grokConversationID(forBody: turn2)
        XCTAssertNotNil(id1)
        XCTAssertEqual(id1, id2)
    }

    func testConvIDDiffersByFirstUserMessage() {
        let a = #"{"messages":[{"role":"system","content":"You are helpful."},{"role":"user","content":"Task A"}]}"#
        let b = #"{"messages":[{"role":"system","content":"You are helpful."},{"role":"user","content":"Task B"}]}"#
        XCTAssertNotEqual(ThinkingProxy.grokConversationID(forBody: a), ThinkingProxy.grokConversationID(forBody: b))
    }

    /// A conversation with no system message still anchors on its first (user)
    /// message, which is replayed across turns.
    func testConvIDStableForSystemlessConversation() {
        let turn1 = #"{"messages":[{"role":"user","content":"Only user"}]}"#
        let turn2 = #"{"messages":[{"role":"user","content":"Only user"},{"role":"assistant","content":"ok"},{"role":"user","content":"next"}]}"#
        let id1 = ThinkingProxy.grokConversationID(forBody: turn1)
        XCTAssertNotNil(id1)
        XCTAssertEqual(id1, ThinkingProxy.grokConversationID(forBody: turn2))
    }

    /// Factory/Droid may send `content` as an array of text parts.
    func testConvIDHandlesArrayContent() {
        let body = #"{"messages":[{"role":"system","content":[{"type":"text","text":"sys"}]},{"role":"user","content":[{"type":"text","text":"hi"}]}]}"#
        XCTAssertNotNil(ThinkingProxy.grokConversationID(forBody: body))
    }

    func testConvIDNilWhenNoMessages() {
        XCTAssertNil(ThinkingProxy.grokConversationID(forBody: #"{"model":"grok-composer-2.5-fast"}"#))
        XCTAssertNil(ThinkingProxy.grokConversationID(forBody: "not json"))
    }
}
