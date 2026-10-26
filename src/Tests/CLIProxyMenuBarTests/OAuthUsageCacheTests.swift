import XCTest
@testable import CLIProxyMenuBar

final class OAuthUsageCacheTests: XCTestCase {
    private final class Clock {
        var date = Date(timeIntervalSince1970: 1_790_000_000)
    }

    private actor Probe {
        var calls = 0
        func fetch(_ usage: OAuthAccountUsage) async -> OAuthAccountUsage {
            calls += 1
            await Task.yield()
            return usage
        }
    }

    private func account(_ id: String = "claude.json", provider: ServiceType = .claude) -> AuthAccount {
        AuthAccount(id: id, email: "owner@example.com", login: nil, type: provider, expired: nil,
                    filePath: URL(fileURLWithPath: "/tmp/usage-cache-tests/\(id)"), isDisabled: false,
                    organizationName: nil, claudeSeatLabel: nil)
    }

    private func sample(_ account: AuthAccount, at: Date, error: String? = nil, rateLimited: Bool = false, retryAfter: Date? = nil) -> OAuthAccountUsage {
        OAuthAccountUsage(id: account.id, provider: account.type, email: account.displayName,
                          windows: error == nil ? [OAuthUsageWindow(title: "5-hour", usedPercent: 25, resetText: nil, resetDate: at.addingTimeInterval(3600))] : [],
                          error: error, updatedAt: at, rateLimited: rateLimited, retryAfter: retryAfter)
    }

    func testConcurrentConsumersAndRepeatedReadsShareOneFiveMinuteBudget() async {
        let clock = Clock()
        let cache = OAuthUsageCache(now: { clock.date }, jitter: { 0 })
        let probe = Probe()
        let account = account()
        let usage = sample(account, at: clock.date)
        await withTaskGroup(of: OAuthAccountUsage.self) { group in
            for _ in 0..<32 {
                group.addTask { await cache.usage(for: account) { await probe.fetch(usage) } }
            }
            for await value in group { XCTAssertEqual(value.updatedAt, usage.updatedAt) }
        }
        clock.date.addTimeInterval(299)
        _ = await cache.usage(for: account) { await probe.fetch(usage) }
        var calls = await probe.calls
        XCTAssertEqual(calls, 1)
        clock.date.addTimeInterval(1)
        _ = await cache.usage(for: account) { await probe.fetch(usage) }
        calls = await probe.calls
        XCTAssertEqual(calls, 2)
    }

    func testAccountsHaveIndependentBudgetsAndOtherProvidersKeepTheirCadence() async {
        let clock = Clock()
        let cache = OAuthUsageCache(now: { clock.date }, jitter: { 0 })
        let probe = Probe()
        let first = account()
        let second = account("another-seat.json")
        let codex = account("codex.json", provider: .codex)
        for account in [first, second, codex] {
            _ = await cache.usage(for: account) { await probe.fetch(self.sample(account, at: clock.date)) }
        }
        clock.date.addTimeInterval(15)
        for account in [first, second, codex] {
            _ = await cache.usage(for: account) { await probe.fetch(self.sample(account, at: clock.date)) }
        }
        let calls = await probe.calls
        XCTAssertEqual(calls, 4)
    }

    func testFailuresBackOffPreserveTheLastSampleAndHonorLongerRetryAfter() async {
        let clock = Clock()
        let cache = OAuthUsageCache(now: { clock.date }, jitter: { 0 })
        let account = account()
        let original = sample(account, at: clock.date)
        _ = await cache.usage(for: account) { original }
        clock.date.addTimeInterval(300)
        for wait in [300.0, 600, 1200, 2400, 3600, 3600] {
            let failure = sample(account, at: clock.date, error: "Claude usage API returned 429", rateLimited: true)
            let result = await cache.usage(for: account) { failure }
            XCTAssertEqual(result.windows.first?.usedPercent, 25)
            XCTAssertEqual(result.updatedAt, original.updatedAt)
            XCTAssertEqual(result.error, failure.error)
            clock.date.addTimeInterval(wait - 1)
            let stillCached = await cache.usage(for: account) {
                XCTFail("A manual refresh must not bypass the 429 cooldown")
                return original
            }
            XCTAssertEqual(stillCached.error, failure.error)
            clock.date.addTimeInterval(1)
        }
        let until = clock.date.addingTimeInterval(7200)
        let failure = sample(account, at: clock.date, error: "429", rateLimited: true, retryAfter: until)
        _ = await cache.usage(for: account) { failure }
        clock.date.addTimeInterval(7199)
        _ = await cache.usage(for: account) {
            XCTFail("Retry-After longer than the fallback cap must win")
            return original
        }
        clock.date.addTimeInterval(1)
        let recovered = await cache.usage(for: account) { self.sample(account, at: clock.date) }
        XCTAssertNil(recovered.error)
        clock.date.addTimeInterval(300)
        _ = await cache.usage(for: account) { failure }
        clock.date.addTimeInterval(300)
        // The old Retry-After is now in the past, and success reset the backoff.
        let afterReset = await cache.usage(for: account) { original }
        XCTAssertNil(afterReset.error)
    }

    func testFailedFirstReadAndCooldownSurviveRestartWithoutCredentialsInTheCache() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("usage-cache.json")
        let clock = Clock()
        let account = account()
        let failure = sample(account, at: clock.date, error: "Claude usage API returned 429", rateLimited: true)
        let cache = OAuthUsageCache(fileURL: file, now: { clock.date }, jitter: { 0 })
        _ = await cache.usage(for: account) { failure }
        let restarted = OAuthUsageCache(fileURL: file, now: { clock.date }, jitter: { 0 })
        let result = await restarted.usage(for: account) {
            XCTFail("Restarting cannot bypass a persisted cooldown")
            return failure
        }
        XCTAssertEqual(result.error, failure.error)
        let mode = try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? Int
        XCTAssertEqual(mode, 0o600)
        let saved = try String(contentsOf: file)
        XCTAssertFalse(saved.contains("access_token"))
        XCTAssertFalse(saved.contains("refresh_token"))
    }

    func testRetryAfterHandlesSecondsHTTPDatesAndMissingOrInvalidValues() {
        let now = Date(timeIntervalSince1970: 0)
        XCTAssertEqual(OAuthUsageCache.retryDate("300", now: now), now.addingTimeInterval(300))
        XCTAssertEqual(OAuthUsageCache.retryDate("0", now: now), now)
        XCTAssertEqual(OAuthUsageCache.retryDate("Thu, 01 Jan 1970 00:10:00 GMT", now: now), now.addingTimeInterval(600))
        for value in [nil, "", "-1", "NaN", "Infinity", "later"] {
            XCTAssertNil(OAuthUsageCache.retryDate(value, now: now))
        }
    }
}
