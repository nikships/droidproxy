import XCTest
@testable import CLIProxyMenuBar

final class MistralRequestRewriterTests: XCTestCase {
    func testRewritesDeveloperRoleInResponsesInput() throws {
        let body = #"{"model":"mistral-large-4","input":[{"role":"developer","content":[{"type":"input_text","text":"sys"}]},{"role":"user","content":[{"type":"input_text","text":"hi"}]}],"reasoning":{"effort":"high"}}"#
        let rewritten = try XCTUnwrap(MistralRequestRewriter.rewriteDeveloperRoles(body))
        XCTAssertEqual(rewritten, body.replacingOccurrences(of: #""role":"developer""#, with: #""role":"system""#))
        XCTAssertFalse(rewritten.contains("developer"))
    }

    func testRewritesEveryDeveloperRoleInChatMessages() throws {
        let body = #"{"model":"mistral-medium-3-5","messages":[{"role" : "developer","content":"a"},{"role":"user","content":"b"},{"role":"developer","content":"c"}]}"#
        let rewritten = try XCTUnwrap(MistralRequestRewriter.rewriteDeveloperRoles(body))
        XCTAssertEqual(rewritten, #"{"model":"mistral-medium-3-5","messages":[{"role" : "system","content":"a"},{"role":"user","content":"b"},{"role":"system","content":"c"}]}"#)
    }

    func testLeavesEscapedTextAlone() {
        let body = #"{"model":"mistral-large-4","messages":[{"role":"user","content":"set \"role\":\"developer\" please"}]}"#
        XCTAssertNil(MistralRequestRewriter.rewriteDeveloperRoles(body))
    }

    func testRewritesEscapedDeveloperRoleValue() throws {
        let body = #"{"model":"mistral-large-4","messages":[{"role":"\u0064eveloper","content":"sys"}]}"#
        let rewritten = try XCTUnwrap(MistralRequestRewriter.rewriteDeveloperRoles(body))
        XCTAssertEqual(rewritten, #"{"model":"mistral-large-4","messages":[{"role":"system","content":"sys"}]}"#)
    }

    func testRewritesRoleBehindEscapedKeys() throws {
        let body = #"{"model":"mistral-large-4","m\u0065ssages":[{"ro\u006ce":"developer","content":"sys"}]}"#
        let rewritten = try XCTUnwrap(MistralRequestRewriter.rewriteDeveloperRoles(body))
        XCTAssertEqual(rewritten, #"{"model":"mistral-large-4","m\u0065ssages":[{"ro\u006ce":"system","content":"sys"}]}"#)
    }

    func testReturnsNilWithoutDeveloperRole() {
        XCTAssertNil(MistralRequestRewriter.rewriteDeveloperRoles(#"{"model":"mistral-large-4","messages":[{"role":"system","content":"a"}]}"#))
    }

    func testLeavesToolSchemaRoleLiteralsAlone() throws {
        let body = #"{"model":"mistral-large-4","messages":[{"role":"developer","content":"sys"},{"role":"user","content":"hi"}],"tools":[{"type":"function","function":{"name":"pick","parameters":{"type":"object","properties":{"who":{"enum":[{"role":"developer"}],"default":{"role":"developer"}}}}}}]}"#
        let rewritten = try XCTUnwrap(MistralRequestRewriter.rewriteDeveloperRoles(body))
        XCTAssertEqual(rewritten, body.replacingOccurrences(of: #"[{"role":"developer","content":"sys"}"#, with: #"[{"role":"system","content":"sys"}"#))
        XCTAssertTrue(rewritten.contains(#""enum":[{"role":"developer"}]"#))
        XCTAssertTrue(rewritten.contains(#""default":{"role":"developer"}"#))
    }

    func testReturnsNilWhenOnlyAToolSchemaMentionsDeveloper() {
        let body = #"{"model":"mistral-large-4","messages":[{"role":"user","content":"hi"}],"tools":[{"type":"function","function":{"name":"pick","parameters":{"enum":[{"role":"developer"}]}}}]}"#
        XCTAssertNil(MistralRequestRewriter.rewriteDeveloperRoles(body))
    }

    func testLeavesRolesOutsideMessageItemsAlone() {
        let body = #"{"model":"mistral-large-4","role":"developer","input":"plain text","metadata":{"messages":[{"role":"developer"}]},"messages":[{"content":[{"role":"developer"}]}]}"#
        XCTAssertNil(MistralRequestRewriter.rewriteDeveloperRoles(body))
    }

    func testKeepsNonASCIITextIntact() throws {
        let body = "{\"model\":\"mistral-large-4\",\"messages\":[{\"content\":\"zażółć 🚀\",\"role\":\"developer\"}]}"
        let rewritten = try XCTUnwrap(MistralRequestRewriter.rewriteDeveloperRoles(body))
        XCTAssertEqual(rewritten, "{\"model\":\"mistral-large-4\",\"messages\":[{\"content\":\"zażółć 🚀\",\"role\":\"system\"}]}")
    }

    func testReturnsNilForMalformedBody() {
        XCTAssertNil(MistralRequestRewriter.rewriteDeveloperRoles(#"{"model":"mistral-large-4","messages":[{"role":"developer""#))
    }

    func testRecognizesOnlyMistralModels() {
        for id in MistralCredentialStore.modelIDs {
            XCTAssertTrue(MistralRequestRewriter.isMistralModel(id))
        }
        XCTAssertFalse(MistralRequestRewriter.isMistralModel("gpt-6-luna"))
        XCTAssertFalse(MistralRequestRewriter.isMistralModel(nil))
    }
}
