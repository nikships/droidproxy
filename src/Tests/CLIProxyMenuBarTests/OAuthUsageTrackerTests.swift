import XCTest
@testable import CLIProxyMenuBar

final class OAuthUsageTrackerTests: XCTestCase {
    func testParseClaudeWindowsTreatsUtilizationAsPercentForSonnetBucket() throws {
        let payload = """
        {
          "five_hour": {
            "utilization": 7.0,
            "resets_at": "2026-06-05T13:00:00.885429+00:00"
          },
          "seven_day": {
            "utilization": 11.0,
            "resets_at": "2026-06-10T15:59:59.885452+00:00"
          },
          "seven_day_sonnet": {
            "utilization": 1.0,
            "resets_at": "2026-06-10T16:00:00.885459+00:00"
          }
        }
        """

        let windows = OAuthUsageTracker.parseClaudeWindows(Data(payload.utf8))

        XCTAssertEqual(windows.first(where: { $0.title == "5-hour" })?.usedPercent, 7)
        XCTAssertEqual(windows.first(where: { $0.title == "Weekly" })?.usedPercent, 11)

        let sonnetWindow = try XCTUnwrap(windows.first(where: { $0.title == "Weekly (Sonnet)" }))
        XCTAssertEqual(sonnetWindow.usedPercent, 1)
        XCTAssertEqual(sonnetWindow.remainingPercent, 99)
    }

    func testParseClaudeWindowsHandlesEdgeCases() throws {
        let payload = """
        {
          "five_hour": {
            "utilization": 0.0,
            "resets_at": "2026-06-05T13:00:00.885429+00:00"
          },
          "seven_day": {
            "utilization": 100.0,
            "resets_at": "2026-06-10T15:59:59.885452+00:00"
          },
          "seven_day_sonnet": {
            "utilization": -5.0,
            "resets_at": "2026-06-10T16:00:00.885459+00:00"
          },
          "seven_day_opus": {
            "utilization": 120.0,
            "resets_at": "2026-06-10T16:00:00.885459+00:00"
          }
        }
        """

        let windows = OAuthUsageTracker.parseClaudeWindows(Data(payload.utf8))

        let fiveHour = try XCTUnwrap(windows.first(where: { $0.title == "5-hour" }))
        XCTAssertEqual(fiveHour.usedPercent, 0.0)
        XCTAssertEqual(fiveHour.remainingPercent, 100.0)

        let weekly = try XCTUnwrap(windows.first(where: { $0.title == "Weekly" }))
        XCTAssertEqual(weekly.usedPercent, 100.0)
        XCTAssertEqual(weekly.remainingPercent, 0.0)

        // Clamping edge cases
        let sonnet = try XCTUnwrap(windows.first(where: { $0.title == "Weekly (Sonnet)" }))
        XCTAssertEqual(sonnet.usedPercent, 0.0)
        XCTAssertEqual(sonnet.remainingPercent, 100.0)

        let opus = try XCTUnwrap(windows.first(where: { $0.title == "Weekly (Opus)" }))
        XCTAssertEqual(opus.usedPercent, 100.0)
        XCTAssertEqual(opus.remainingPercent, 0.0)
    }

    func testParseClaudeWindowsHandlesMalformedJSON() throws {
        let malformedPayload = "{ invalid json"
        let windows = OAuthUsageTracker.parseClaudeWindows(Data(malformedPayload.utf8))
        XCTAssertTrue(windows.isEmpty)
    }
}
