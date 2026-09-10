import XCTest
@testable import CLIProxyMenuBar

final class CopilotProcessTranscriptTests: XCTestCase {
    func testReportsLastMeaningfulLineWithExitCode() {
        let transcript = ProcessTranscript()
        transcript.append("ℹ Logging in with GitHub Copilot\n")
        transcript.append("env: node: No such file or directory\n\n")

        XCTAssertEqual(
            transcript.failureDetail(exitCode: 127),
            "env: node: No such file or directory (exit code 127)"
        )
    }

    func testStripsANSIEscapeSequences() {
        let transcript = ProcessTranscript()
        transcript.append("\u{001B}[31m✖\u{001B}[39m Failed to fetch Copilot token\n")

        XCTAssertEqual(
            transcript.failureDetail(exitCode: 1),
            "✖ Failed to fetch Copilot token (exit code 1)"
        )
    }

    func testFallsBackToExitCodeWhenNoOutputWasCaptured() {
        let transcript = ProcessTranscript()

        XCTAssertEqual(
            transcript.failureDetail(exitCode: 143),
            "the sign-in helper exited with code 143."
        )
    }

    func testSnapshotReturnsCapturedOutput() {
        let transcript = ProcessTranscript()
        transcript.append("hello\n")
        transcript.append("world")
        XCTAssertEqual(transcript.snapshot(), "hello\nworld")
    }

    func testLastMeaningfulLineIgnoresTrailingBlankLines() {
        let transcript = ProcessTranscript()
        transcript.append("➜ Listening on: http://127.0.0.1:8319/\n")
        transcript.append("   \n\n")

        XCTAssertEqual(transcript.lastMeaningfulLine(), "➜ Listening on: http://127.0.0.1:8319/")
    }

    func testLastMeaningfulLineIsNilWithoutOutput() {
        XCTAssertNil(ProcessTranscript().lastMeaningfulLine())
    }

    func testNeverBecameReadyErrorIncludesDetail() {
        let withDetail = CopilotGatewayError.neverBecameReady("env: node: not found (exit code 127)")
        XCTAssertEqual(
            withDetail.localizedDescription,
            "The local Copilot gateway never started serving requests on port 8319: env: node: not found (exit code 127)"
        )

        let withoutDetail = CopilotGatewayError.neverBecameReady(nil)
        XCTAssertEqual(
            withoutDetail.localizedDescription,
            "The local Copilot gateway never started serving requests on port 8319."
        )
    }

    func testStoppedUnexpectedlyErrorIncludesDetail() {
        XCTAssertEqual(
            CopilotGatewayError.stoppedUnexpectedly("env: node: not found (exit code 127)").localizedDescription,
            "The local Copilot gateway stopped unexpectedly: env: node: not found (exit code 127)"
        )
    }

    func testGatewayStateExposesFailureDetailOnlyWhenFailed() {
        XCTAssertEqual(CopilotGatewayState.failed("boom").failureDescription, "boom")
        XCTAssertNil(CopilotGatewayState.idle.failureDescription)
        XCTAssertNil(CopilotGatewayState.starting.failureDescription)
        XCTAssertNil(CopilotGatewayState.running.failureDescription)
    }

    @MainActor
    func testGatewayReportsFailureWhenCredentialsAreMissing() throws {
        try XCTSkipIf(
            CopilotGatewayManager.hasCredentials,
            "Requires a machine without Copilot credentials; the manager would launch a real gateway."
        )

        let manager = CopilotGatewayManager()
        XCTAssertEqual(manager.state, .idle)
        XCTAssertFalse(manager.isRunning)

        let started = expectation(description: "start completes")
        manager.start { success in
            XCTAssertFalse(success)
            started.fulfill()
        }
        wait(for: [started], timeout: 5)

        XCTAssertFalse(manager.isRunning)
        XCTAssertEqual(
            manager.state,
            .failed(CopilotGatewayError.notAuthenticated.localizedDescription)
        )
        XCTAssertEqual(manager.state.failureDescription, manager.lastError)
    }

    func testAuthenticationFailedErrorIncludesDetail() {
        let withDetail = CopilotGatewayError.authenticationFailed("env: node: not found (exit code 127)")
        XCTAssertEqual(
            withDetail.localizedDescription,
            "GitHub Copilot authentication did not complete: env: node: not found (exit code 127)"
        )

        let withoutDetail = CopilotGatewayError.authenticationFailed(nil)
        XCTAssertEqual(
            withoutDetail.localizedDescription,
            "GitHub Copilot authentication did not complete. Please try again."
        )
    }
}
