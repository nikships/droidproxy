import XCTest
@testable import CLIProxyMenuBar

final class BankedResetsTests: XCTestCase {
    private let now = ISO8601DateFormatter().date(from: "2026-11-06T00:00:00Z")!

    func testParseCodexResetCreditsFiltersAndSorts() {
        let data = Data("""
        {"credits":[
            {"id":"late","status":"available","reset_type":"codex_rate_limits","expires_at":"2026-12-01T00:00:00Z"},
            {"id":"soon","status":"available","reset_type":"codex_rate_limits","expires_at":"2026-11-20T00:00:00Z"},
            {"id":"spent","status":"redeemed","reset_type":"codex_rate_limits","expires_at":"2026-12-01T00:00:00Z"},
            {"id":"other","status":"available","reset_type":"something_else","expires_at":"2026-12-01T00:00:00Z"},
            {"id":"stale","status":"available","reset_type":"codex_rate_limits","expires_at":"2026-01-01T00:00:00Z"}
        ]}
        """.utf8)

        let credits = OAuthUsageTracker.parseCodexCredits(data, now: now)
        XCTAssertEqual(credits.map(\.id), ["soon", "late"])

        let display = OAuthUsageTracker.codexBankedResets(data, now: now)
        XCTAssertEqual(display?.availableCount, 2)
        XCTAssertEqual(display?.nextExpiresAt, ISO8601DateFormatter().date(from: "2026-11-20T00:00:00Z"))
    }

    func testParseClaudeResetCreditsCountsLiveGrants() {
        let data = Data("""
        {"cedar_ember":{"eligible":true,"next_grant_id":"g1","grants":[
            {"id":"g1","resets_left":2,"ends_at":"2026-12-01T00:00:00Z","paused":false,"usable_now":true},
            {"id":"g2","resets_left":1,"ends_at":"2026-12-15T00:00:00Z","paused":true,"usable_now":true},
            {"id":"g3","resets_left":1,"ends_at":"2025-01-01T00:00:00Z","usable_now":true}
        ]}}
        """.utf8)

        let state = OAuthUsageTracker.parseClaudeResetCredits(data, now: now)
        XCTAssertEqual(state?.display.availableCount, 2)
        XCTAssertEqual(state?.nextCreditID, "g1")
        XCTAssertEqual(state?.nextResetsLeft, 2)

        let ineligible = Data(#"{"cedar_ember":{"eligible":false}}"#.utf8)
        XCTAssertNil(OAuthUsageTracker.parseClaudeResetCredits(ineligible, now: now))
    }

    func testRedeemRequestIDMatchesUUIDv5Namespace() {
        // Same namespace as the Linux edition and T3 Code, so a retry from
        // either tool addresses the same provider-side redemption.
        XCTAssertEqual(OAuthUsageTracker.redeemRequestID("acct-1:c1"), "caffac06-55d9-5119-8615-1e35f9527863")
        XCTAssertEqual(OAuthUsageTracker.redeemRequestID("claude:org-1:g1:2"), "c28b4ead-7157-51c2-b7a6-f964def28499")
        XCTAssertEqual(OAuthUsageTracker.redeemRequestID("acct-1:c1"), OAuthUsageTracker.redeemRequestID("acct-1:c1"))
        XCTAssertNotEqual(OAuthUsageTracker.redeemRequestID("claude:org-1:g1:2"), OAuthUsageTracker.redeemRequestID("claude:org-1:g1:1"))
    }

    func testRedeemCodexResetConsumesSoonestCredit() async throws {
        var consumed: [String: Any]?
        let session = mockSession { request in
            switch request.url?.path {
            case "/wham/rate-limit-reset-credits":
                return (200, #"{"credits":[{"id":"c1","status":"available","reset_type":"codex_rate_limits","expires_at":"2999-01-01T00:00:00Z"}]}"#)
            case "/wham/rate-limit-reset-credits/consume":
                consumed = request.bodyJSON
                return (200, #"{"code":"reset"}"#)
            default:
                return (404, "{}")
            }
        }
        let account = try writeAccount(type: .codex, json: ["access_token": "tok", "account_id": "acct-1"])

        let result = await OAuthUsageTracker.redeemReset(
            for: account, session: session,
            codexUsageURL: URL(string: "https://example.test/wham/usage")!
        )

        XCTAssertTrue(result.ok, result.message)
        XCTAssertEqual(consumed?["credit_id"] as? String, "c1")
        XCTAssertEqual(consumed?["redeem_request_id"] as? String, OAuthUsageTracker.redeemRequestID("acct-1:c1"))
    }

    func testRedeemClaudeResetPostsGrantClaim() async throws {
        var claim: [String: Any]?
        let session = mockSession { request in
            switch request.url?.path {
            case "/api/oauth/usage":
                return (200, #"{"five_hour":{"utilization":10},"cedar_ember":{"eligible":true,"next_grant_id":"g1","grants":[{"id":"g1","resets_left":1,"ends_at":"2999-01-01T00:00:00Z","usable_now":true}]}}"#)
            case "/api/organizations/org-1/reset_rate_limits":
                claim = request.bodyJSON
                return (200, #"{"result":"reset"}"#)
            default:
                return (404, "{}")
            }
        }
        let account = try writeAccount(type: .claude, json: ["access_token": "tok", "organization_uuid": "org-1"])

        let result = await OAuthUsageTracker.redeemReset(
            for: account, session: session,
            claudeUsageURL: URL(string: "https://example.test/api/oauth/usage")!
        )

        XCTAssertTrue(result.ok, result.message)
        XCTAssertEqual(claim?["program"] as? String, "cedar_ember")
        XCTAssertEqual(claim?["grant_id"] as? String, "g1")
        XCTAssertEqual(claim?["request_id"] as? String, OAuthUsageTracker.redeemRequestID("claude:org-1:g1:1"))
    }

    func testRedeemClaudeResetUsesDistinctKeyPerRedemption() async throws {
        var left = 2
        var requestIDs: [String] = []
        let session = mockSession { request in
            switch request.url?.path {
            case "/api/oauth/usage":
                return (200, #"{"five_hour":{"utilization":100},"cedar_ember":{"eligible":true,"next_grant_id":"g1","grants":[{"id":"g1","resets_left":\#(left),"ends_at":"2999-01-01T00:00:00Z","usable_now":true}]}}"#)
            case "/api/organizations/org-1/reset_rate_limits":
                let id = request.bodyJSON?["request_id"] as? String ?? ""
                requestIDs.append(id)
                if requestIDs.filter({ $0 == id }).count > 1 {
                    return (200, #"{"result":"already_used"}"#)
                }
                left -= 1
                return (200, #"{"result":"reset"}"#)
            default:
                return (404, "{}")
            }
        }
        let account = try writeAccount(type: .claude, json: ["access_token": "tok", "organization_uuid": "org-1"])
        let usageURL = URL(string: "https://example.test/api/oauth/usage")!

        for _ in 0..<2 {
            let result = await OAuthUsageTracker.redeemReset(for: account, session: session, claudeUsageURL: usageURL)
            XCTAssertTrue(result.ok, result.message)
        }
        XCTAssertEqual(left, 0, "both resets actually spent, request ids \(requestIDs)")
        XCTAssertEqual(requestIDs.count, 2)
        XCTAssertNotEqual(requestIDs.first, requestIDs.last)
    }

    // MARK: - Helpers

    private func writeAccount(type: ServiceType, json: [String: Any]) throws -> AuthAccount {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("banked-resets-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("\(type.rawValue).json")
        try JSONSerialization.data(withJSONObject: json).write(to: file)
        return AuthAccount(
            id: file.lastPathComponent, email: "owner@example.com", login: nil, type: type,
            expired: nil, filePath: file, isDisabled: false, organizationName: nil, claudeSeatLabel: nil
        )
    }

    private func mockSession(_ handler: @escaping (URLRequest) -> (Int, String)) -> URLSession {
        BankedResetsMockProtocol.handler = handler
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [BankedResetsMockProtocol.self]
        return URLSession(configuration: configuration)
    }
}

private extension URLRequest {
    var bodyJSON: [String: Any]? {
        let data: Data?
        if let httpBody {
            data = httpBody
        } else if let stream = httpBodyStream {
            stream.open()
            defer { stream.close() }
            var collected = Data()
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let read = stream.read(&buffer, maxLength: buffer.count)
                if read > 0 { collected.append(buffer, count: read) } else { break }
            }
            data = collected
        } else {
            data = nil
        }
        guard let data else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }
}

private final class BankedResetsMockProtocol: URLProtocol {
    nonisolated(unsafe) static var handler: ((URLRequest) -> (Int, String))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let (status, body) = Self.handler?(request) ?? (500, "{}")
        let response = HTTPURLResponse(
            url: request.url!, statusCode: status, httpVersion: nil,
            headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
