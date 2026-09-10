import XCTest
@testable import CLIProxyMenuBar

final class ClineAuthTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_780_000_000)

    func testParseTokenResponseAcceptsISOTimestampAndWorkOSPrefix() throws {
        // `expiresAt` arrives as an ISO 8601 string from api.cline.bot.
        let json = """
        {"success":true,"data":{"accessToken":"at","refreshToken":"rt","expiresAt":"2026-08-26T22:01:05Z"}}
        """.data(using: .utf8)!

        let result = ClineAuth.parseTokenResponse(json, statusCode: 200, now: now)
        guard case .success(let payload) = result else {
            return XCTFail("expected success")
        }
        XCTAssertEqual(payload.accessToken, "at")
        XCTAssertEqual(payload.refreshToken, "rt")

        let expected = ISO8601DateFormatter().date(from: "2026-08-26T22:01:05Z")!
        XCTAssertEqual(payload.expiresAtMs, expected.timeIntervalSince1970 * 1000)
    }

    func testParseTokenResponseAcceptsEpochMilliseconds() throws {
        let json = """
        {"success":true,"data":{"accessToken":"at","refreshToken":"rt","expiresAt":1787999999000}}
        """.data(using: .utf8)!

        guard case .success(let payload) = ClineAuth.parseTokenResponse(json, statusCode: 200, now: now) else {
            return XCTFail("expected success")
        }
        XCTAssertEqual(payload.expiresAtMs, 1_787_999_999_000)
    }

    func testParseTokenResponseMaps401ToReauthRequired() throws {
        let json = """
        {"error":"Unauthorized: Please make sure you're using the latest version of Cline and re-authenticate your Cline account."}
        """.data(using: .utf8)!

        let result = ClineAuth.parseTokenResponse(json, statusCode: 401, now: now)
        guard case .failure(.reauthRequired) = result else {
            return XCTFail("expected reauthRequired")
        }
    }

    func testParseTokenResponseFailsWhenAccessTokenMissing() throws {
        let json = """
        {"success":true,"data":{"refreshToken":"rt"}}
        """.data(using: .utf8)!

        guard case .failure(.loginFailed) = ClineAuth.parseTokenResponse(json, statusCode: 200, now: now) else {
            return XCTFail("expected loginFailed")
        }
    }

    func testBearerValueKeepsWorkOSPrefix() {
        let creds = ClineAuth.Credentials(
            access: "token123",
            refresh: "r",
            expiresAtMs: now.timeIntervalSince1970 * 1000 + 3600_000,
            email: nil
        )
        XCTAssertEqual(creds.bearerValue, "workos:token123")
    }

    func testCredentialsRoundTripRequiresRefreshToken() throws {
        var json = ClineAuth.credentialsJSON(ClineAuth.Credentials(
            access: "a", refresh: "r", expiresAtMs: 1_788_000_000_000, email: "u@x.com"
        ))
        json.removeValue(forKey: "expires")
        XCTAssertNotNil(ClineAuth.credentials(from: json))

        json["access"] = ""
        XCTAssertNil(ClineAuth.credentials(from: json), "missing access must reject")
    }

    func testClineUpstreamPathVariants() {
        XCTAssertEqual(ThinkingProxy.clineUpstreamPath("/v1/chat/completions"), "/api/v1/chat/completions")
        XCTAssertEqual(ThinkingProxy.clineUpstreamPath("/api/v1/chat/completions"), "/api/v1/chat/completions")
        XCTAssertEqual(ThinkingProxy.clineUpstreamPath("/chat/completions"), "/api/v1/chat/completions")
        XCTAssertEqual(ThinkingProxy.clineUpstreamPath("/v1/responses"), "/api/v1/responses")
        // Query strings survive the rewrite.
        XCTAssertEqual(
            ThinkingProxy.clineUpstreamPath("/v1/chat/completions?a=1"),
            "/api/v1/chat/completions?a=1"
        )
    }

    func testReplaceContentLengthRewritesExistingHeader() {
        let head = "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: 42\r\nX-Foo: bar"
        let replaced = ThinkingProxy.replaceContentLength(in: head, value: 100)

        XCTAssertTrue(replaced.contains("Content-Length: 100"))
        XCTAssertFalse(replaced.contains("42"))
        XCTAssertTrue(replaced.hasPrefix("HTTP/1.1 200 OK\r\n"))
        XCTAssertTrue(replaced.contains("X-Foo: bar"))
    }

    func testReplaceContentLengthAppendsWhenMissing() {
        let head = "HTTP/1.1 200 OK\r\nContent-Type: application/json"
        let replaced = ThinkingProxy.replaceContentLength(in: head, value: 7)
        XCTAssertTrue(replaced.contains("Content-Length: 7"))
    }

    func testTaskIDIsULIDShaped() {
        let id = ClineAuth.ClineTaskID.generate()
        XCTAssertEqual(id.count, 26)
        // Characters must come from the Crockford Base32 alphabet (uppercase).
        let alphabet = Set("0123456789ABCDEFGHJKMNPQRSTVWXYZ")
        XCTAssertTrue(id.allSatisfy { alphabet.contains($0) })
    }

    func testExcludedHeadersCoverClientAuthAndIdentity() {
        for name in ["authorization", "content-type", "host", "content-length",
                     "anthropic-beta", "http-referer", "x-task-id"] {
            XCTAssertTrue(ClineAuth.excludedUpstreamHeaderNames.contains(name), "\(name) should be excluded")
        }
    }
}
