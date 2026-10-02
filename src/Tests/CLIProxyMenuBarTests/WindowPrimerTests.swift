import XCTest
@testable import CLIProxyMenuBar

final class WindowPrimerTests: XCTestCase {
    private var calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()

    private func date(_ hour: Int, _ minute: Int = 0, day: Int = 2) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 10, day: day, hour: hour, minute: minute))!
    }

    private func shouldFire(now: Date, scheduled: Int = 7 * 60, lastFired: Date? = nil) -> Bool {
        WindowPrimer.shouldFire(now: now, scheduledMinutes: scheduled, lastFired: lastFired, calendar: calendar)
    }

    func testDoesNotFireBeforeScheduledTime() {
        XCTAssertFalse(shouldFire(now: date(6, 59)))
    }

    func testFiresAtScheduledTimeWhenNeverFired() {
        XCTAssertTrue(shouldFire(now: date(7, 0)))
    }

    func testFiresDuringCatchUpWindowButNotAfter() {
        XCTAssertTrue(shouldFire(now: date(8, 59)))
        XCTAssertFalse(shouldFire(now: date(9, 0)))
    }

    func testDoesNotFireTwiceInOneDay() {
        XCTAssertFalse(shouldFire(now: date(7, 5), lastFired: date(7, 0)))
    }

    func testFiresAgainTheNextDay() {
        XCTAssertTrue(shouldFire(now: date(7, 0, day: 3), lastFired: date(7, 1, day: 2)))
    }

    func testPrimerRequestsExistOnlyForProxyRoutedProviders() throws {
        let claude = try XCTUnwrap(WindowPrimer.proxyRequest(for: .claude))
        XCTAssertEqual(claude.path, "/v1/messages")
        XCTAssertTrue(claude.body.contains("claude-haiku-4-5-20251001"))
        let codex = try XCTUnwrap(WindowPrimer.proxyRequest(for: .codex))
        XCTAssertEqual(codex.path, "/v1/chat/completions")
        XCTAssertNil(WindowPrimer.proxyRequest(for: .meta))
    }
}
