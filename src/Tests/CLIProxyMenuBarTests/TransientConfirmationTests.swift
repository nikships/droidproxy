import XCTest
@testable import CLIProxyMenuBar

final class TransientConfirmationTests: XCTestCase {
    func testShowThenDismissClearsTheValue() {
        var confirmation = TransientConfirmation<String>()
        let token = confirmation.show("Copied Codex usage curl")
        XCTAssertEqual(confirmation.value, "Copied Codex usage curl")

        confirmation.dismiss(token: token)
        XCTAssertNil(confirmation.value)
    }

    func testEarlierDismissalDoesNotClearANewerShow() {
        var confirmation = TransientConfirmation<String>()
        let first = confirmation.show("Copied Codex usage curl")
        let second = confirmation.show("Copied Grok usage curl")

        confirmation.dismiss(token: first)
        XCTAssertEqual(confirmation.value, "Copied Grok usage curl")

        confirmation.dismiss(token: second)
        XCTAssertNil(confirmation.value)
    }

    func testClearHidesTheValueAndIgnoresItsPendingDismissal() {
        var confirmation = TransientConfirmation<Bool>()
        let stale = confirmation.show(true)

        confirmation.clear()
        XCTAssertNil(confirmation.value)

        let fresh = confirmation.show(true)
        confirmation.dismiss(token: stale)
        XCTAssertEqual(confirmation.value, true)

        confirmation.dismiss(token: fresh)
        XCTAssertNil(confirmation.value)
    }

    func testRepeatShowOfTheSameValueRestartsTheTimer() {
        var confirmation = TransientConfirmation<Bool>()
        let first = confirmation.show(true)
        let second = confirmation.show(true)

        confirmation.dismiss(token: first)
        XCTAssertEqual(confirmation.value, true)

        confirmation.dismiss(token: second)
        XCTAssertNil(confirmation.value)
    }
}
