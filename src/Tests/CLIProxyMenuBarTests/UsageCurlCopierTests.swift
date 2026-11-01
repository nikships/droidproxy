import XCTest
@testable import CLIProxyMenuBar

final class UsageCurlCopierTests: XCTestCase {
    func testRejectedWriteSkipsTheConfirmation() {
        var confirmed = false
        let copied = UsageCurlCopier.copy("curl -s 'http://127.0.0.1:8317/droidproxy/usage'", write: { _ in false }) {
            confirmed = true
        }
        XCTAssertFalse(copied)
        XCTAssertFalse(confirmed)
    }

    func testSuccessfulWriteConfirmsWithTheCommand() {
        let command = "curl -s 'http://127.0.0.1:8317/droidproxy/usage?provider=codex'"
        var written: String?
        var confirmed = false
        let copied = UsageCurlCopier.copy(command, write: { written = $0; return true }) {
            confirmed = true
        }
        XCTAssertTrue(copied)
        XCTAssertTrue(confirmed)
        XCTAssertEqual(written, command)
    }
}
