import XCTest
@testable import CLIProxyMenuBar

final class ModelAvailabilityTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func account(_ id: String, usable: Bool = true) -> AvailabilityJudge.Account {
        AvailabilityJudge.Account(id: id, label: "\(id)@x.com", usable: usable)
    }

    private func window(_ title: String, used: Double?, resetsIn: TimeInterval? = 3_600) -> OAuthUsageWindow {
        OAuthUsageWindow(title: title, usedPercent: used, resetText: nil, resetDate: resetsIn.map { now.addingTimeInterval($0) })
    }

    private func usage(_ id: String, _ provider: ServiceType, _ windows: [OAuthUsageWindow], error: String? = nil) -> OAuthAccountUsage {
        OAuthAccountUsage(id: id, provider: provider, email: "\(id)@x.com", windows: windows, error: error)
    }

    private func judge(
        _ model: String = "claude-opus-5-5",
        provider: ServiceType = .claude,
        enabled: Bool = true,
        accounts: [AvailabilityJudge.Account],
        usages: [OAuthAccountUsage] = []
    ) -> ModelAvailability {
        AvailabilityJudge.judge(
            baseModel: model,
            provider: provider,
            providerEnabled: enabled,
            accounts: accounts,
            usages: Dictionary(uniqueKeysWithValues: usages.map { ($0.id, $0) }),
            now: now
        )
    }

    func testProviderSwitchedOffIsDisabled() {
        XCTAssertEqual(judge(enabled: false, accounts: [account("a")]), .disabled)
        XCTAssertEqual(judge(enabled: false, accounts: []), .disabled)
    }

    func testNoUsableAccountIsSignedOut() {
        XCTAssertEqual(judge(accounts: []), .signedOut)
        XCTAssertEqual(judge(accounts: [account("a", usable: false)]), .signedOut)
    }

    func testAccountWithQuotaLeftIsOK() {
        let result = judge(accounts: [account("a")], usages: [usage("a", .claude, [window("5-hour", used: 40), window("Weekly", used: 99.9)])])
        XCTAssertEqual(result, .ok)
    }

    func testNoUsageForAnyAccountIsUnknown() {
        XCTAssertEqual(judge(accounts: [account("a")]), .unknown)
        XCTAssertEqual(judge(accounts: [account("a")], usages: [usage("a", .claude, [], error: "Claude usage API returned 429")]), .unknown)
    }

    func testAnAccountWithoutUsageKeepsTheModelRunnable() {
        let result = judge(
            accounts: [account("a"), account("b")],
            usages: [usage("a", .claude, [window("5-hour", used: 100)]), usage("b", .claude, [], error: "timeout")]
        )
        XCTAssertEqual(result, .ok)
    }

    func testOneFreeAccountIsEnough() {
        let result = judge(
            accounts: [account("a"), account("b")],
            usages: [usage("a", .claude, [window("5-hour", used: 100)]), usage("b", .claude, [window("5-hour", used: 10)])]
        )
        XCTAssertEqual(result, .ok)
    }

    func testUnusableAccountsAreIgnored() {
        let result = judge(
            accounts: [account("a"), account("b", usable: false)],
            usages: [usage("a", .claude, [window("5-hour", used: 100)]), usage("b", .claude, [window("5-hour", used: 0)])]
        )
        XCTAssertEqual(result, .exhausted(until: now.addingTimeInterval(3_600), window: "5-hour", account: "a@x.com"))
    }

    func testExhaustedUntilTheEarliestAccountComesBack() {
        let result = judge(
            provider: .codex,
            accounts: [account("a"), account("b")],
            usages: [
                usage("a", .codex, [window("5-hour", used: 100, resetsIn: 7_200), window("Weekly", used: 30)]),
                usage("b", .codex, [window("5-hour", used: 100, resetsIn: 1_800)])
            ]
        )
        XCTAssertEqual(result, .exhausted(until: now.addingTimeInterval(1_800), window: "5-hour", account: "b@x.com"))
    }

    func testAnAccountIsBackOnlyWhenItsLastExhaustedWindowResets() {
        let result = judge(
            provider: .codex,
            accounts: [account("a"), account("b")],
            usages: [
                usage("a", .codex, [window("5-hour", used: 100, resetsIn: 600), window("Weekly", used: 100, resetsIn: 86_400)]),
                usage("b", .codex, [window("5-hour", used: 100, resetsIn: 3_600)])
            ]
        )
        XCTAssertEqual(result, .exhausted(until: now.addingTimeInterval(3_600), window: "5-hour", account: "b@x.com"))

        let single = judge(
            provider: .codex,
            accounts: [account("a")],
            usages: [usage("a", .codex, [window("5-hour", used: 100, resetsIn: 600), window("Weekly", used: 100, resetsIn: 86_400)])]
        )
        XCTAssertEqual(single, .exhausted(until: now.addingTimeInterval(86_400), window: "Weekly", account: "a@x.com"))
    }

    func testUnknownResetSortsLastAndHasNoUntil() {
        let result = judge(
            provider: .grok,
            accounts: [account("a")],
            usages: [usage("a", .grok, [window("Credits", used: 100, resetsIn: nil)])]
        )
        XCTAssertEqual(result, .exhausted(until: nil, window: "Credits", account: "a@x.com"))

        let mixed = judge(
            provider: .codex,
            accounts: [account("a"), account("b")],
            usages: [
                usage("a", .codex, [window("Monthly", used: 100, resetsIn: nil)]),
                usage("b", .codex, [window("Weekly", used: 100, resetsIn: 5_000)])
            ]
        )
        XCTAssertEqual(mixed, .exhausted(until: now.addingTimeInterval(5_000), window: "Weekly", account: "b@x.com"))
    }

    func testAWindowWhoseResetHasPassedDoesNotCount() {
        let result = judge(accounts: [account("a")], usages: [usage("a", .claude, [window("5-hour", used: 100, resetsIn: -5)])])
        XCTAssertEqual(result, .ok)
    }

    func testAWindowWithoutAPercentDoesNotCount() {
        let result = judge(accounts: [account("a")], usages: [usage("a", .claude, [window("5-hour", used: nil)])])
        XCTAssertEqual(result, .ok)
    }

    func testClaudeFamilyWindowsCoverOnlyTheirFamily() {
        let usages = [usage("a", .claude, [
            window("5-hour", used: 20),
            window("Weekly", used: 50),
            window("Weekly (Opus)", used: 100, resetsIn: 90_000),
            window("Weekly (Sonnet)", used: 10)
        ])]
        XCTAssertEqual(
            judge("claude-opus-5-5", accounts: [account("a")], usages: usages),
            .exhausted(until: now.addingTimeInterval(90_000), window: "Weekly (Opus)", account: "a@x.com")
        )
        XCTAssertEqual(judge("claude-sonnet-5-5", accounts: [account("a")], usages: usages), .ok)
        XCTAssertEqual(judge("claude-haiku-5-5", accounts: [account("a")], usages: usages), .ok)
        XCTAssertEqual(judge("claude-fable-5-1", accounts: [account("a")], usages: usages), .ok)

        let sonnetOut = [usage("a", .claude, [window("5-hour", used: 20), window("Weekly (Sonnet)", used: 100)])]
        XCTAssertEqual(judge("claude-opus-5-5", accounts: [account("a")], usages: sonnetOut), .ok)
        XCTAssertEqual(
            judge("claude-sonnet-5-5", accounts: [account("a")], usages: sonnetOut),
            .exhausted(until: now.addingTimeInterval(3_600), window: "Weekly (Sonnet)", account: "a@x.com")
        )
    }

    func testSharedWindowsCoverEveryModel() {
        let usages = [usage("a", .claude, [window("Weekly", used: 100)])]
        for model in ["claude-opus-5-5", "claude-sonnet-5-5", "claude-haiku-5-5", "claude-fable-5-1"] {
            XCTAssertEqual(
                judge(model, accounts: [account("a")], usages: usages),
                .exhausted(until: now.addingTimeInterval(3_600), window: "Weekly", account: "a@x.com"),
                model
            )
        }
    }

    func testWindowCoverage() {
        XCTAssertTrue(AvailabilityJudge.window("5-hour", covers: "gpt-6.1-sol"))
        XCTAssertTrue(AvailabilityJudge.window("Weekly", covers: "gpt-6.1-sol"))
        XCTAssertTrue(AvailabilityJudge.window("Monthly", covers: "grok-4.7"))
        XCTAssertTrue(AvailabilityJudge.window("Weekly (Opus)", covers: "claude-opus-5-5"))
        XCTAssertFalse(AvailabilityJudge.window("Weekly (Opus)", covers: "claude-sonnet-5-5"))
        XCTAssertTrue(AvailabilityJudge.window("Weekly (Sonnet)", covers: "claude-sonnet-5-5"))
        XCTAssertFalse(AvailabilityJudge.window("Weekly (Sonnet)", covers: "claude-fable-5-1"))
        XCTAssertFalse(AvailabilityJudge.window("Weekly (OAuth Apps)", covers: "claude-opus-5-5"))
        XCTAssertFalse(AvailabilityJudge.window("Weekly (Cowork)", covers: "claude-sonnet-5-5"))
        XCTAssertFalse(AvailabilityJudge.window("Weekly (Omelette)", covers: "claude-haiku-5-5"))
    }

    func testProvidersWithoutAUsageReaderAreUnknownOnceSignedIn() {
        for provider in [ServiceType.antigravity, .kimi, .junie, .copilot] {
            XCTAssertEqual(judge("some-model", provider: provider, accounts: [account("a")]), .unknown, provider.rawValue)
            XCTAssertEqual(judge("some-model", provider: provider, accounts: []), .signedOut, provider.rawValue)
            XCTAssertEqual(judge("some-model", provider: provider, enabled: false, accounts: [account("a")]), .disabled, provider.rawValue)
        }
    }

    func testMetaAndGrokUseTheirWindows() {
        XCTAssertEqual(
            judge("muse-wonder-1.0", provider: .meta, accounts: [account("m")], usages: [usage("m", .meta, [window("5-hour", used: 100, resetsIn: 60)])]),
            .exhausted(until: now.addingTimeInterval(60), window: "5-hour", account: "m@x.com")
        )
        XCTAssertEqual(
            judge("grok-4.7", provider: .grok, accounts: [account("g")], usages: [usage("g", .grok, [window("Weekly", used: 55)])]),
            .ok
        )
    }
}
