import XCTest
@testable import CLIProxyMenuBar

final class ThinkingProxyModelAliasTests: XCTestCase {
    func testRewritesDroidProxySonnet46AliasWithoutReserializingJSON() {
        let request = """
        {"messages":[{"role":"user","content":"hi"}],"model":"droidproxy-claude-sonnet-4-6","thinking":{"type":"adaptive"},"output_config":{"effort":"max"}}
        """

        let rewritten = ThinkingProxy.rewriteDroidProxyModelAlias(in: request)

        XCTAssertEqual(
            rewritten,
            """
            {"messages":[{"role":"user","content":"hi"}],"model":"claude-sonnet-4-6","thinking":{"type":"adaptive"},"output_config":{"effort":"max"}}
            """
        )
    }
}
