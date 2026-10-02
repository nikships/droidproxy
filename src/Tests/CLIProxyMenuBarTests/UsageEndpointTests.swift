import XCTest
@testable import CLIProxyMenuBar

final class UsageEndpointTests: XCTestCase {
    func testFilterParsesProviderAndAccount() {
        let filter = UsageEndpoint.filter(forRequestPath: "/droidproxy/usage?provider=Codex&account=a%2Bb%40x.com")
        XCTAssertEqual(filter, UsageEndpoint.Filter(provider: "codex", account: "a+b@x.com"))
    }

    func testFilterMatchesBarePathAndRejectsOthers() {
        XCTAssertEqual(UsageEndpoint.filter(forRequestPath: "/droidproxy/usage"), UsageEndpoint.Filter())
        XCTAssertNil(UsageEndpoint.filter(forRequestPath: "/v1/models"))
        XCTAssertNil(UsageEndpoint.filter(forRequestPath: "/droidproxy/usage/extra"))
    }

    func testCurlCommandEncodesAccountAndTargetsProxyPort() {
        let command = UsageEndpoint.curlCommand(provider: .codex, accountID: "codex-a+b@x.com.json")
        XCTAssertTrue(command.hasPrefix("curl -s 'http://"))
        XCTAssertTrue(command.contains(":8317/droidproxy/usage?provider=codex&account=codex-a%2Bb@x.com.json'"))
    }

    func testJSONReportsRemainingPercentAndSecondsUntilReset() throws {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let reset = now.addingTimeInterval(7_200)
        let usage = OAuthAccountUsage(
            id: "codex-a.json",
            provider: .codex,
            email: "a@x.com",
            windows: [OAuthUsageWindow(title: "5-hour", usedPercent: 97.46, resetText: nil, resetDate: reset)]
        )

        let data = UsageEndpoint.json(for: [usage], now: now)
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let accounts = try XCTUnwrap(root["accounts"] as? [[String: Any]])
        let window = try XCTUnwrap((accounts.first?["windows"] as? [[String: Any]])?.first)

        XCTAssertEqual(accounts.first?["provider"] as? String, "codex")
        XCTAssertEqual(window["name"] as? String, "5-hour")
        XCTAssertEqual(window["remaining_percent"] as? Double, 2.5)
        XCTAssertEqual(window["resets_in_seconds"] as? Int, 7_200)
    }
}
