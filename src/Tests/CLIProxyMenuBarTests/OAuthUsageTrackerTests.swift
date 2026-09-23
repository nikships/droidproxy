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

    func testParseCodexWindowsTitlesWindowsFromDuration() throws {
        let fiveHourAndWeekly: [String: Any] = ["rate_limit": [
            "primary_window": ["used_percent": 30, "limit_window_seconds": 18_000],
            "secondary_window": ["used_percent": 60, "limit_window_seconds": 604_800]
        ]]
        XCTAssertEqual(OAuthUsageTracker.parseCodexWindows(fiveHourAndWeekly).map(\.title), ["5-hour", "Weekly"])

        let weeklyOnly: [String: Any] = ["rate_limit": [
            "primary_window": ["used_percent": 40, "limit_window_seconds": 604_800]
        ]]
        XCTAssertEqual(OAuthUsageTracker.parseCodexWindows(weeklyOnly).map(\.title), ["Weekly"])

        let monthlyOnly: [String: Any] = ["rate_limit": [
            "primary_window": ["used_percent": 10, "limit_window_seconds": 2_592_000],
            "secondary_window": NSNull()
        ]]
        let monthly = OAuthUsageTracker.parseCodexWindows(monthlyOnly)
        XCTAssertEqual(monthly.map(\.title), ["Monthly"])
        XCTAssertEqual(monthly.first?.remainingPercent, 90)
    }

    func testCodexWindowTitleFallsBackToSlotName() {
        XCTAssertEqual(OAuthUsageTracker.codexWindowTitle(seconds: nil, fallback: "5-hour"), "5-hour")
        XCTAssertEqual(OAuthUsageTracker.codexWindowTitle(seconds: 0, fallback: "Weekly"), "Weekly")
        XCTAssertEqual(OAuthUsageTracker.codexWindowTitle(seconds: 3_600, fallback: "x"), "1-hour")
        XCTAssertEqual(OAuthUsageTracker.codexWindowTitle(seconds: 1_209_600, fallback: "x"), "14-day")
    }

    func testParseGrokWindowsReadsWeeklyCreditUsage() throws {
        let payload = """
        {"config":{"currentPeriod":{"type":"USAGE_PERIOD_TYPE_WEEKLY","start":"2026-09-20T05:44:46.220789+00:00","end":"2026-09-27T05:44:46.220789+00:00"},"creditUsagePercent":51.0,"onDemandCap":{"val":0},"onDemandUsed":{"val":0},"productUsage":[{"product":"GrokBuild","usagePercent":51.0}],"isUnifiedBillingUser":true,"prepaidBalance":{"val":0},"topUpMethod":"TOP_UP_METHOD_SAVED_PAYMENT_METHOD","billingPeriodStart":"2026-09-20T05:44:46.220789+00:00","billingPeriodEnd":"2026-09-27T05:44:46.220789+00:00"}}
        """

        let windows = OAuthUsageTracker.parseGrokWindows(Data(payload.utf8))

        XCTAssertEqual(windows.count, 1)
        let window = try XCTUnwrap(windows.first)
        XCTAssertEqual(window.title, "Weekly")
        XCTAssertEqual(window.usedPercent, 51)
        XCTAssertEqual(window.remainingPercent, 49)

        let resetDate = try XCTUnwrap(window.resetDate)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "UTC"))
        let expected = try XCTUnwrap(calendar.date(from: DateComponents(
            year: 2026, month: 9, day: 27, hour: 5, minute: 44, second: 46
        )))
        XCTAssertEqual(resetDate.timeIntervalSince1970, expected.timeIntervalSince1970 + 0.220789, accuracy: 0.001)
        XCTAssertNotNil(window.resetText)
    }

    func testParseGrokWindowsFallsBackToOnDemandUsage() throws {
        let payload = """
        {"config":{"onDemandCap":{"val":200},"onDemandUsed":{"val":50},"billingPeriodEnd":"2026-10-01T00:00:00+00:00"}}
        """

        let windows = OAuthUsageTracker.parseGrokWindows(Data(payload.utf8))

        let window = try XCTUnwrap(windows.first)
        XCTAssertEqual(windows.count, 1)
        XCTAssertEqual(window.title, "Credits")
        XCTAssertEqual(window.usedPercent, 25)
        XCTAssertEqual(window.remainingPercent, 75)
        XCTAssertEqual(window.resetDate, Date(timeIntervalSince1970: 1_790_812_800))
    }

    func testParseGrokWindowsLabelsMonthlyPeriod() throws {
        let payload = """
        {"config":{"currentPeriod":{"type":"USAGE_PERIOD_TYPE_MONTHLY","end":"2026-10-20T05:44:46.220789+00:00"},"creditUsagePercent":12.5,"billingPeriodEnd":"2026-09-27T05:44:46.220789+00:00"}}
        """

        let windows = OAuthUsageTracker.parseGrokWindows(Data(payload.utf8))

        let window = try XCTUnwrap(windows.first)
        XCTAssertEqual(window.title, "Monthly")
        XCTAssertEqual(window.usedPercent, 12.5)
        XCTAssertEqual(window.remainingPercent, 87.5)
        let resetDate = try XCTUnwrap(window.resetDate)
        XCTAssertEqual(resetDate.timeIntervalSince1970, 1_792_475_086.220789, accuracy: 0.001)
    }

    func testParseGrokWindowsReturnsNoWindowWithoutUsagePercent() {
        let payload = """
        {"config":{"currentPeriod":{"type":"USAGE_PERIOD_TYPE_WEEKLY","end":"2026-09-27T05:44:46.220789+00:00"},"onDemandCap":{"val":0},"onDemandUsed":{"val":0}}}
        """

        XCTAssertTrue(OAuthUsageTracker.parseGrokWindows(Data(payload.utf8)).isEmpty)
    }

    func testParseGrokWindowsHandlesMalformedJSON() {
        XCTAssertTrue(OAuthUsageTracker.parseGrokWindows(Data("{ invalid json".utf8)).isEmpty)
    }

    private func metaSnapshot() -> MetaMuseUsageSnapshot {
        MetaMuseUsageSnapshot(
            windowUsedPercent: 7,
            windowResetsAt: Date(timeIntervalSince1970: 1_790_204_220),
            windowDurationMins: 300,
            weeklyUsedPercent: 6,
            weeklyResetsAt: Date(timeIntervalSince1970: 1_790_553_600),
            tier: "27681393394859588",
            observedAt: Date()
        )
    }

    func testParseMetaWindowsTitlesFiveHourAndWeekly() throws {
        let windows = OAuthUsageTracker.parseMetaWindows(metaSnapshot())

        XCTAssertEqual(windows.map(\.title), ["5-hour", "Weekly"])
        let fiveHour = try XCTUnwrap(windows.first)
        XCTAssertEqual(fiveHour.usedPercent, 7)
        XCTAssertEqual(fiveHour.remainingPercent, 93)
        XCTAssertEqual(fiveHour.resetDate, Date(timeIntervalSince1970: 1_790_204_220))
        XCTAssertTrue(try XCTUnwrap(fiveHour.resetText).contains("as of"))
        let weekly = try XCTUnwrap(windows.last)
        XCTAssertEqual(weekly.usedPercent, 6)
        XCTAssertEqual(weekly.remainingPercent, 94)
        XCTAssertEqual(weekly.resetDate, Date(timeIntervalSince1970: 1_790_553_600))
    }

    func testMetaWindowTitleFallsBackForUnknownDurations() {
        XCTAssertEqual(OAuthUsageTracker.metaWindowTitle(minutes: 300), "5-hour")
        XCTAssertEqual(OAuthUsageTracker.metaWindowTitle(minutes: 60), "1-hour")
        XCTAssertEqual(OAuthUsageTracker.metaWindowTitle(minutes: 90), "90-min")
        XCTAssertEqual(OAuthUsageTracker.metaWindowTitle(minutes: 0), "Window")
    }
}
