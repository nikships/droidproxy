import XCTest
@testable import CLIProxyMenuBar

final class MistralUsageTests: XCTestCase {
    private var session: URLSession!
    private let account = AuthAccount(
        id: "acct-1", email: nil, login: "Mistral ••••abcd", type: .mistral, expired: nil,
        filePath: URL(fileURLWithPath: "/tmp/mistral-usage-tests/accounts.json"), isDisabled: false,
        organizationName: nil, claudeSeatLabel: nil
    )

    /// The live `GET /v1/billing/budget` shape (Vibe CLI's budget read), values redacted.
    private let livePayload = """
    {"vibe_budget":{"usage_percentage":0.0501,"initial_budget":300.0,"currency":"USD","reset_at":"2026-12-01T00:00:00Z","payg_enabled":false},
     "api_budget":{"usage_percentage":0.0,"initial_budget":30.0,"currency":"USD","reset_at":"2026-12-01T00:00:00Z","payg_enabled":false},
     "usage_percentage":0.0,"initial_budget":30.0,"currency":"USD","reset_at":"2026-12-01T00:00:00Z"}
    """

    override func setUp() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MistralStubProtocol.self]
        session = URLSession(configuration: configuration)
    }

    override func tearDown() {
        MistralStubProtocol.handler = nil
    }

    private func windows(_ json: String) throws -> [OAuthUsageWindow] {
        OAuthUsageTracker.parseMistralWindows(try JSONSerialization.jsonObject(with: Data(json.utf8)))
    }

    func testParsesVibeAndAPIBudgetsAsMonthlyWindows() throws {
        let parsed = try windows(livePayload)
        XCTAssertEqual(parsed.map(\.title), ["Monthly (Vibe)", "Monthly (API)"])
        XCTAssertEqual(parsed[0].usedPercent ?? -1, 0.0501, accuracy: 0.000_001)
        XCTAssertEqual(parsed[1].remainingPercent, 100)
        XCTAssertEqual(parsed[0].resetDate, OAuthUsageTracker.parseISO8601Date("2026-12-01T00:00:00Z"))
        XCTAssertEqual(parsed[0].lengthSeconds, 30 * 86_400)
        XCTAssertNil(parsed[0].overageBilled)
        // A monthly budget is never a short window worth priming.
        let usage = OAuthAccountUsage(id: "a", provider: .mistral, email: "m", windows: parsed)
        XCTAssertFalse(usage.hasShortWindow().has)
    }

    func testSkipsBudgetsWithoutAnAllowanceAndFallsBackToTopLevelFields() throws {
        let noVibe = #"{"vibe_budget":{"usage_percentage":10,"initial_budget":0},"api_budget":{"usage_percentage":20,"initial_budget":30}}"#
        XCTAssertEqual(try windows(noVibe).map(\.title), ["Monthly (API)"])
        let flat = #"{"usage_percentage":42.5,"initial_budget":30,"reset_at":"2026-12-01T00:00:00Z"}"#
        XCTAssertEqual(try windows(flat).map(\.title), ["Monthly"])
        XCTAssertEqual(try windows(flat).first?.usedPercent, 42.5)
        XCTAssertTrue(try windows(#"{"vibe_budget":{"initial_budget":0}}"#).isEmpty)
    }

    func testPayAsYouGoClampsTheRingAndNeverBlocks() throws {
        let payg = #"{"vibe_budget":{"usage_percentage":130,"initial_budget":300,"reset_at":"2026-12-01T00:00:00Z","payg_enabled":true}}"#
        let window = try XCTUnwrap(try windows(payg).first)
        XCTAssertEqual(window.usedPercent, 100)
        XCTAssertEqual(window.overageBilled, true)
        XCTAssertTrue(window.resetText?.contains("pay-as-you-go") ?? false)
        XCTAssertFalse(AvailabilityJudge.isExhausted(window, now: Date(timeIntervalSince1970: 0)))
    }

    func testFetchSendsTheKeyAndReadsTheBudget() async {
        MistralStubProtocol.handler = { request, _ in
            XCTAssertEqual(request.url?.absoluteString, "https://api.mistral.ai/v1/billing/budget")
            XCTAssertEqual(request.httpMethod, "GET")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer secret-key")
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, Data(self.livePayload.utf8))
        }
        let usage = await OAuthUsageTracker.fetchMistralUsage(for: account, session: session, apiKey: "secret-key")
        XCTAssertNil(usage.error)
        XCTAssertEqual(usage.provider, .mistral)
        XCTAssertEqual(usage.windows.count, 2)
    }

    func testFetchExplainsRejectedAndForbiddenKeys() async {
        for (status, phrase) in [(401, "Reconnect Mistral"), (403, "cannot read"), (404, "cannot read"), (500, "returned 500")] {
            MistralStubProtocol.handler = { request, _ in
                (HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!, Data())
            }
            let usage = await OAuthUsageTracker.fetchMistralUsage(for: account, session: session, apiKey: "k")
            XCTAssertTrue(usage.windows.isEmpty, "\(status)")
            XCTAssertTrue(usage.error?.contains(phrase) ?? false, "\(status): \(usage.error ?? "nil")")
        }
        let missing = await OAuthUsageTracker.fetchMistralUsage(for: account, session: session, apiKey: "")
        XCTAssertEqual(missing.error, "Missing Mistral API key")
    }

    func testAccountsSharingTheStoreFileHaveSeparateFiveMinuteBudgets() async {
        var date = Date(timeIntervalSince1970: 1_790_000_000)
        let cache = OAuthUsageCache(now: { date }, jitter: { 0 })
        let second = AuthAccount(id: "acct-2", email: nil, login: "Mistral ••••efgh", type: .mistral, expired: nil,
                                 filePath: account.filePath, isDisabled: false, organizationName: nil, claudeSeatLabel: nil)
        func sample(_ id: String) -> OAuthAccountUsage {
            OAuthAccountUsage(id: id, provider: .mistral, email: id,
                              windows: [OAuthUsageWindow(title: "Monthly (Vibe)", usedPercent: 1, resetText: nil, resetDate: nil)],
                              updatedAt: date)
        }
        let first = await cache.usage(for: account) { sample("acct-1") }
        let other = await cache.usage(for: second) { sample("acct-2") }
        XCTAssertEqual(first.id, "acct-1")
        XCTAssertEqual(other.id, "acct-2")

        var fetched = false
        date.addTimeInterval(299)
        _ = await cache.usage(for: account) { fetched = true; return sample("acct-1") }
        XCTAssertFalse(fetched)
        date.addTimeInterval(1)
        _ = await cache.usage(for: account) { fetched = true; return sample("acct-1") }
        XCTAssertTrue(fetched)
    }

    private func judge(_ windows: [OAuthUsageWindow]) -> ModelAvailability {
        AvailabilityJudge.judge(
            baseModel: "mistral-large-4",
            provider: .mistral,
            providerEnabled: true,
            accounts: [AvailabilityJudge.Account(id: "m", label: "Mistral ••••abcd", usable: true)],
            usages: ["m": OAuthAccountUsage(id: "m", provider: .mistral, email: "m", windows: windows)],
            now: Date(timeIntervalSince1970: 1_800_000_000)
        )
    }

    func testMistralIsExhaustedOnlyWhenEveryBudgetIsOut() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        func window(_ title: String, used: Double, resetsIn: TimeInterval) -> OAuthUsageWindow {
            OAuthUsageWindow(title: title, usedPercent: used, resetText: nil, resetDate: now.addingTimeInterval(resetsIn))
        }
        XCTAssertEqual(judge([window("Monthly (Vibe)", used: 10, resetsIn: 900), window("Monthly (API)", used: 100, resetsIn: 600)]), .ok)
        XCTAssertEqual(
            judge([window("Monthly (Vibe)", used: 100, resetsIn: 900), window("Monthly (API)", used: 100, resetsIn: 600)]),
            .exhausted(until: now.addingTimeInterval(600), window: "Monthly (API)", account: "Mistral ••••abcd")
        )
        XCTAssertEqual(judge([]), .unknown)
    }
}
