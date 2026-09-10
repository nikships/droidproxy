import XCTest
@testable import CLIProxyMenuBar

final class CursorModelRewriterTests: XCTestCase {
    func testAliasesMapCatalogIdsToCursorAgentCLIModels() {
        XCTAssertEqual(
            CursorModelRewriter.resolveUpstreamModel("cursor-composer-2.5", fastMode: false),
            "composer-2.5"
        )
        XCTAssertEqual(
            CursorModelRewriter.resolveUpstreamModel("cursor-grok-4.6", fastMode: false),
            "cursor-grok-4.6"
        )
        XCTAssertEqual(
            CursorModelRewriter.resolveUpstreamModel("cursor-grok-4.6-fast", fastMode: false),
            "cursor-grok-4.6-fast"
        )
        XCTAssertEqual(
            CursorModelRewriter.resolveUpstreamModel("grok-4.6", fastMode: false),
            "cursor-grok-4.6"
        )
    }

    func testFastModeAppendsFastSuffix() {
        XCTAssertEqual(
            CursorModelRewriter.resolveUpstreamModel("cursor-composer-2.5", fastMode: true),
            "composer-2.5-fast"
        )
        XCTAssertEqual(
            CursorModelRewriter.resolveUpstreamModel("cursor-grok-4.6", fastMode: true),
            "cursor-grok-4.6-fast"
        )
        XCTAssertEqual(
            CursorModelRewriter.resolveUpstreamModel("grok-4.6", fastMode: true),
            "cursor-grok-4.6-fast"
        )
        XCTAssertEqual(
            CursorModelRewriter.resolveUpstreamModel("cursor-grok-4.6-fast", fastMode: true),
            "cursor-grok-4.6-fast"
        )
    }

    func testGrokOAuthFastDivertPredicate() {
        XCTAssertTrue(
            CursorModelRewriter.shouldDivertGrokOAuthToCursorFast(model: "grok-4.6", grok46FastMode: true)
        )
        XCTAssertFalse(
            CursorModelRewriter.shouldDivertGrokOAuthToCursorFast(model: "grok-4.6", grok46FastMode: false)
        )
        XCTAssertFalse(
            CursorModelRewriter.shouldDivertGrokOAuthToCursorFast(model: "gpt-5.6-sol", grok46FastMode: true)
        )
    }

    func testCursorFastPathRequiresBetaCursorAndAgentLogin() {
        XCTAssertEqual(
            CursorModelRewriter.cursorFastPathBlocker(
                betaEnabled: false, cursorEnabled: true, agentLoggedIn: true
            ),
            .betaDisabled
        )
        XCTAssertEqual(
            CursorModelRewriter.cursorFastPathBlocker(
                betaEnabled: true, cursorEnabled: false, agentLoggedIn: true
            ),
            .cursorDisabled
        )
        XCTAssertEqual(
            CursorModelRewriter.cursorFastPathBlocker(
                betaEnabled: true, cursorEnabled: true, agentLoggedIn: false
            ),
            .agentNotLoggedIn
        )
        XCTAssertNil(
            CursorModelRewriter.cursorFastPathBlocker(
                betaEnabled: true, cursorEnabled: true, agentLoggedIn: true
            )
        )
    }

    func testComposerIgnoresReasoningEffort() {
        XCTAssertTrue(CursorModelRewriter.ignoresReasoningEffort("cursor-composer-2.5"))
        XCTAssertTrue(CursorModelRewriter.ignoresReasoningEffort("composer-2.5"))
        XCTAssertTrue(CursorModelRewriter.ignoresReasoningEffort("composer-2.5-fast"))
        XCTAssertFalse(CursorModelRewriter.ignoresReasoningEffort("cursor-grok-4.6"))
        XCTAssertFalse(CursorModelRewriter.ignoresReasoningEffort("cursor-grok-4.6-fast"))
    }

    func testUnknownCursorIdsPassThrough() {
        XCTAssertEqual(
            CursorModelRewriter.resolveUpstreamModel("cursor-composer-3", fastMode: false),
            "cursor-composer-3"
        )
    }

    func testProxyListensOnLocalhostSidecarPort() {
        XCTAssertEqual(CursorModelRewriter.host, "127.0.0.1")
        XCTAssertEqual(CursorModelRewriter.port, 8320)
    }
}
