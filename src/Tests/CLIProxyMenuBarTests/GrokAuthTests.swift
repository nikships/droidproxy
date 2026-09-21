import XCTest
@testable import CLIProxyMenuBar

final class GrokAuthTests: XCTestCase {
    func testParseDeviceAuthorizationAcceptsIntegerExpiresIn() throws {
        let json = """
        {"device_code":"dc","user_code":"ABCD-EFGH","verification_uri_complete":"https://auth.x.ai/device","interval":5,"expires_in":900}
        """.data(using: .utf8)!

        let auth = try XCTUnwrap(GrokAuth.parseDeviceAuthorization(json))
        XCTAssertEqual(auth.deviceCode, "dc")
        XCTAssertEqual(auth.userCode, "ABCD-EFGH")
        XCTAssertEqual(auth.interval, 5)
        XCTAssertEqual(auth.expiresIn, 900)
    }

    func testParseDeviceAuthorizationFallsBackToVerificationURIAndDefaults() throws {
        let json = """
        {"device_code":"dc","user_code":"CODE","verification_uri":"https://auth.x.ai/device"}
        """.data(using: .utf8)!

        let auth = try XCTUnwrap(GrokAuth.parseDeviceAuthorization(json))
        XCTAssertEqual(auth.verificationURIComplete, "https://auth.x.ai/device")
        XCTAssertEqual(auth.interval, 5)
        XCTAssertEqual(auth.expiresIn, 900)
    }

    func testParseTokenResponseStoresAbsoluteExpiryWithoutSkew() throws {
        let json = """
        {"access_token":"access","refresh_token":"refresh","expires_in":7200,"id_token":"hdr.eyJlbWFpbCI6InVAeC5haSJ9.sig"}
        """.data(using: .utf8)!
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let result = GrokAuth.parseTokenResponse(json, statusCode: 200, now: now)
        guard case .success(let creds) = result else {
            return XCTFail("expected success")
        }
        XCTAssertEqual(creds.access, "access")
        XCTAssertEqual(creds.refresh, "refresh")
        XCTAssertEqual(creds.email, "u@x.ai")
        XCTAssertEqual(creds.expiresAtMs, now.timeIntervalSince1970 * 1000 + 7200 * 1000)
    }

    func testIsAccessExpiredAppliesSkewAtCheckTime() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let creds = GrokAuth.Credentials(
            access: "a",
            refresh: "r",
            expiresAtMs: now.timeIntervalSince1970 * 1000 + 7200 * 1000,
            email: nil
        )

        XCTAssertFalse(creds.isAccessExpired(now: now))
        // Exactly at the 5m skew threshold → expired (>=).
        XCTAssertTrue(creds.isAccessExpired(now: now.addingTimeInterval(7200 - 300)))
        // One ms before the skew threshold → still valid.
        XCTAssertFalse(creds.isAccessExpired(now: now.addingTimeInterval(7200 - 300 - 0.001)))
        // Absolute expiry boundary with skew disabled.
        XCTAssertTrue(creds.isAccessExpired(now: now.addingTimeInterval(7200), skewMs: 0))
        XCTAssertFalse(creds.isAccessExpired(now: now.addingTimeInterval(7200 - 0.001), skewMs: 0))
    }

    func testShortLivedTokenIsExpiredImmediatelyUnderDefaultSkew() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        // Lifetime shorter than refreshSkewMs (5m) → expired as soon as issued.
        let creds = GrokAuth.Credentials(
            access: "a",
            refresh: "r",
            expiresAtMs: now.timeIntervalSince1970 * 1000 + 240 * 1000,
            email: nil
        )
        XCTAssertTrue(creds.isAccessExpired(now: now))
    }

    func testParseTokenResponseRequiresRefreshTokenWhenRequested() {
        let json = #"{"access_token":"access","expires_in":3600}"#.data(using: .utf8)!
        let result = GrokAuth.parseTokenResponse(json, statusCode: 200, now: Date(), requireRefreshToken: true)
        guard case .failure(.tokenError(let detail)) = result else {
            return XCTFail("expected tokenError for missing refresh")
        }
        XCTAssertTrue(detail.lowercased().contains("refresh_token"))
    }

    func testParseTokenResponseAllowsEmptyRefreshWhenNotRequired() throws {
        let json = #"{"access_token":"access","expires_in":3600}"#.data(using: .utf8)!
        let result = GrokAuth.parseTokenResponse(json, statusCode: 200, now: Date(), requireRefreshToken: false)
        let creds = try XCTUnwrap(result.get())
        XCTAssertEqual(creds.refresh, "")
    }

    func testParseTokenResponseErrorMatrix() {
        let cases: [(String, Int, GrokAuth.GrokAuthError)] = [
            (#"{"error":"authorization_pending"}"#, 400, .authorizationPending),
            (#"{"error":"slow_down"}"#, 400, .slowDown),
            (#"{"error":"access_denied"}"#, 400, .accessDenied),
            (#"{"error":"expired_token"}"#, 400, .expiredToken),
            (#"{"error":"invalid_grant"}"#, 400, .reauthRequired),
            (#"{"error":"invalid_token"}"#, 401, .reauthRequired),
        ]
        for (body, status, expected) in cases {
            let result = GrokAuth.parseTokenResponse(body.data(using: .utf8)!, statusCode: status, now: Date())
            guard case .failure(let error) = result else {
                return XCTFail("expected failure for \(body)")
            }
            XCTAssertEqual(error, expected, body)
        }

        let described = GrokAuth.parseTokenResponse(
            #"{"error":"server_error","error_description":"boom"}"#.data(using: .utf8)!,
            statusCode: 500,
            now: Date()
        )
        guard case .failure(.tokenError("boom")) = described else {
            return XCTFail("expected tokenError with description")
        }

        let unauthorized = GrokAuth.parseTokenResponse(Data(), statusCode: 401, now: Date())
        guard case .failure(.reauthRequired) = unauthorized else {
            return XCTFail("expected reauthRequired for bare 401")
        }
    }

    func testCredentialsRoundTrip() throws {
        let creds = GrokAuth.Credentials(access: "a", refresh: "r", expiresAtMs: 123, email: "u@x.ai")
        let json = GrokAuth.credentialsJSON(creds)
        XCTAssertEqual(json["type"] as? String, "grok-cli")
        XCTAssertNil(json["expired"])
        let parsed = try XCTUnwrap(GrokAuth.credentials(from: json))
        XCTAssertEqual(parsed.access, "a")
        XCTAssertEqual(parsed.refresh, "r")
        XCTAssertEqual(parsed.expiresAtMs, 123)
        XCTAssertEqual(parsed.email, "u@x.ai")
    }

    func testCredentialsFromRejectsEmptyRefresh() {
        XCTAssertNil(GrokAuth.credentials(from: [
            "access": "a",
            "refresh": "",
            "expires": 1
        ]))
    }

    func testLoadActiveCredentialsSkipsDisabledAndPrefersNewest() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("grok-auth-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let older = dir.appendingPathComponent("older.json")
        let newer = dir.appendingPathComponent("newer.json")
        let disabled = dir.appendingPathComponent("disabled.json")

        try writeCreds(
            GrokAuth.Credentials(access: "old", refresh: "r1", expiresAtMs: 1, email: "old@x.ai"),
            to: older,
            disabled: false
        )
        // Ensure distinct mtimes.
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: 1_000)],
            ofItemAtPath: older.path
        )
        try writeCreds(
            GrokAuth.Credentials(access: "new", refresh: "r2", expiresAtMs: 2, email: "new@x.ai"),
            to: newer,
            disabled: false
        )
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: 2_000)],
            ofItemAtPath: newer.path
        )
        try writeCreds(
            GrokAuth.Credentials(access: "off", refresh: "r3", expiresAtMs: 3, email: "off@x.ai"),
            to: disabled,
            disabled: true
        )
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: 3_000)],
            ofItemAtPath: disabled.path
        )

        let loaded = try XCTUnwrap(GrokAuth.loadActiveCredentials(in: dir))
        XCTAssertEqual(loaded.credentials.access, "new")
        XCTAssertEqual(loaded.url.lastPathComponent, "newer.json")
    }

    func testQuarantineCredentialsSetsDisabled() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("grok-quarantine-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let url = dir.appendingPathComponent("grok-cli.json")
        try writeCreds(
            GrokAuth.Credentials(access: "a", refresh: "r", expiresAtMs: 1, email: "u@x.ai"),
            to: url,
            disabled: false
        )
        GrokAuth.quarantineCredentials(at: url)

        let data = try Data(contentsOf: url)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(json["disabled"] as? Bool, true)
        XCTAssertNil(GrokAuth.loadActiveCredentials(in: dir))
    }

    func testNormalizeUpstreamPath() {
        XCTAssertEqual(GrokAuth.normalizeUpstreamPath("/v1/responses"), "/v1/responses")
        XCTAssertEqual(GrokAuth.normalizeUpstreamPath("/v1"), "/v1")
        XCTAssertEqual(GrokAuth.normalizeUpstreamPath("/api/v1/responses"), "/v1/responses")
        XCTAssertEqual(GrokAuth.normalizeUpstreamPath("/api/v1"), "/v1")
        XCTAssertEqual(GrokAuth.normalizeUpstreamPath("/responses"), "/v1/responses")
        XCTAssertEqual(GrokAuth.normalizeUpstreamPath("responses"), "/v1/responses")
        XCTAssertEqual(GrokAuth.normalizeUpstreamPath("/v1/chat/completions"), "/v1/chat/completions")
        XCTAssertEqual(GrokAuth.normalizeUpstreamPath("/api/v1/responses?foo=1"), "/v1/responses?foo=1")
    }

    func testFilterClientHeadersDropsContentTypeAndAuth() {
        let filtered = GrokAuth.filterClientHeaders([
            ("Content-Type", "application/json"),
            ("content-type", "text/plain"),
            ("Authorization", "Bearer client"),
            ("Host", "localhost"),
            ("X-Request-Id", "abc"),
            ("User-Agent", "Droid")
        ])
        let names = Set(filtered.map { $0.0.lowercased() })
        XCTAssertFalse(names.contains("content-type"))
        XCTAssertFalse(names.contains("authorization"))
        XCTAssertFalse(names.contains("host"))
        XCTAssertEqual(Set(filtered.map(\.0)), ["X-Request-Id", "User-Agent"])
    }

    func testApiHostIsPublicXAI() {
        XCTAssertEqual(GrokAuth.apiHost, "api.x.ai")
    }

    func testFastModelRoutesToBuildProxy() {
        XCTAssertEqual(GrokAuth.upstreamHost(forModel: "grok-4.7"), "api.x.ai")
        XCTAssertEqual(GrokAuth.upstreamHost(forModel: nil), "api.x.ai")
        XCTAssertEqual(GrokAuth.upstreamHost(forModel: "grok-4.7-build-fast"), "cli-chat-proxy.grok.com")
        XCTAssertTrue(GrokAuth.upstreamAuthHeaders(forModel: "grok-4.7").isEmpty)
        XCTAssertEqual(
            GrokAuth.upstreamAuthHeaders(forModel: "grok-4.7-build-fast").map(\.0),
            ["X-XAI-Token-Auth", "x-grok-model-override", "x-grok-client-version", "x-grok-client-identifier"]
        )
        XCTAssertEqual(
            GrokAuth.upstreamAuthHeaders(forModel: "grok-4.7-build-fast").map(\.1),
            ["xai-grok-cli", "grok-4.7-build-fast", "1.0.40", "grok-shell"]
        )
    }

    func testFormBodyPercentEncodesPlusAsFormUrlEncoded() {
        let body = String(data: GrokAuth.formBody([
            "refresh_token": "abc+def/ghi=",
            "grant_type": "refresh_token"
        ]), encoding: .utf8)!
        // `+` must become %2B (form-urlencoded space trap); `=` may be %3D.
        XCTAssertTrue(body.contains("refresh_token=abc%2Bdef"), body)
        XCTAssertTrue(body.contains("%2B"), body)
        XCTAssertFalse(body.contains("abc+def"), body)
        XCTAssertTrue(body.contains("grant_type=refresh_token"), body)
    }

    func testOneHourTokenIsNotExpiredImmediatelyUnderDefaultSkew() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let creds = GrokAuth.Credentials(
            access: "a",
            refresh: "r",
            expiresAtMs: now.timeIntervalSince1970 * 1000 + 3600 * 1000,
            email: nil
        )
        XCTAssertFalse(creds.isAccessExpired(now: now))
        XCTAssertTrue(creds.isAccessExpired(now: now.addingTimeInterval(3600 - 300)))
    }

    func testTerminalRefreshFailureDetection() {
        XCTAssertTrue(GrokAuth.GrokAuthError.reauthRequired.isTerminalRefreshFailure)
        XCTAssertTrue(GrokAuth.GrokAuthError.tokenError("invalid_grant").isTerminalRefreshFailure)
        XCTAssertFalse(GrokAuth.GrokAuthError.network("timeout").isTerminalRefreshFailure)
        XCTAssertFalse(GrokAuth.GrokAuthError.notLoggedIn.isTerminalRefreshFailure)
    }

    private func writeCreds(_ creds: GrokAuth.Credentials, to url: URL, disabled: Bool) throws {
        var json = GrokAuth.credentialsJSON(creds)
        json["disabled"] = disabled
        let data = try JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted])
        try data.write(to: url, options: .atomic)
    }
}
