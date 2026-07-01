import XCTest
@testable import CLIProxyMenuBar

final class GrokAuthTests: XCTestCase {

    // MARK: - Device authorization parsing

    func testParseDeviceAuthorizationUsesCompleteVerificationURI() throws {
        let json = """
        {"device_code":"DEV","user_code":"BDBW-ZSH6","verification_uri":"https://accounts.x.ai/oauth2/device","verification_uri_complete":"https://accounts.x.ai/oauth2/device?user_code=BDBW-ZSH6","expires_in":900,"interval":5}
        """.data(using: .utf8)!

        let auth = try XCTUnwrap(GrokAuth.parseDeviceAuthorization(json))
        XCTAssertEqual(auth.deviceCode, "DEV")
        XCTAssertEqual(auth.userCode, "BDBW-ZSH6")
        XCTAssertEqual(auth.verificationURIComplete, "https://accounts.x.ai/oauth2/device?user_code=BDBW-ZSH6")
        XCTAssertEqual(auth.interval, 5)
        XCTAssertEqual(auth.expiresIn, 900)
    }

    func testParseDeviceAuthorizationFallsBackToVerificationURI() throws {
        let json = """
        {"device_code":"DEV","user_code":"CODE","verification_uri":"https://accounts.x.ai/oauth2/device"}
        """.data(using: .utf8)!

        let auth = try XCTUnwrap(GrokAuth.parseDeviceAuthorization(json))
        XCTAssertEqual(auth.verificationURIComplete, "https://accounts.x.ai/oauth2/device")
        // Defaults applied when the server omits interval / expiry.
        XCTAssertEqual(auth.interval, 5)
        XCTAssertEqual(auth.expiresIn, 900)
    }

    func testParseDeviceAuthorizationRejectsMissingDeviceCode() {
        let json = """
        {"user_code":"CODE","verification_uri":"https://accounts.x.ai/oauth2/device"}
        """.data(using: .utf8)!
        XCTAssertNil(GrokAuth.parseDeviceAuthorization(json))
    }

    // MARK: - Token response parsing

    func testParseTokenSuccessComputesExpiryWithSkewAndEmail() throws {
        let idToken = makeIDToken(email: "dev@x.ai")
        let json = """
        {"access_token":"ACCESS","refresh_token":"REFRESH","token_type":"Bearer","expires_in":3600,"id_token":"\(idToken)"}
        """.data(using: .utf8)!
        let now = Date(timeIntervalSince1970: 1_000_000)

        let result = GrokAuth.parseTokenResponse(json, statusCode: 200, now: now)
        let creds = try XCTUnwrap(result.successValue)
        XCTAssertEqual(creds.access, "ACCESS")
        XCTAssertEqual(creds.refresh, "REFRESH")
        XCTAssertEqual(creds.email, "dev@x.ai")
        // now_ms + expires_in*1000 - refreshSkewMs = 1_000_000_000 + 3_600_000 - 120_000
        XCTAssertEqual(creds.expiresAtMs, 1_003_480_000, accuracy: 0.5)
    }

    func testParseTokenRefreshWithoutRotatedRefreshTokenLeavesEmpty() throws {
        // A refresh grant may omit refresh_token; parsing yields "" so the caller
        // can carry the previous refresh token forward.
        let json = """
        {"access_token":"ACCESS2","expires_in":1800}
        """.data(using: .utf8)!
        let creds = try XCTUnwrap(GrokAuth.parseTokenResponse(json, statusCode: 200, now: Date()).successValue)
        XCTAssertEqual(creds.access, "ACCESS2")
        XCTAssertEqual(creds.refresh, "")
    }

    func testParseTokenMapsStandardDeviceFlowErrors() {
        XCTAssertEqual(tokenError(#"{"error":"authorization_pending"}"#), .authorizationPending)
        XCTAssertEqual(tokenError(#"{"error":"slow_down"}"#), .slowDown)
        XCTAssertEqual(tokenError(#"{"error":"access_denied"}"#), .accessDenied)
        XCTAssertEqual(tokenError(#"{"error":"expired_token"}"#), .expiredToken)
    }

    func testParseTokenMapsUnknownErrorToDescription() {
        let json = #"{"error":"invalid_grant","error_description":"bad code"}"#
        XCTAssertEqual(tokenError(json), .tokenError("bad code"))
    }

    func testParseTokenSuccessRequiresAccessToken() {
        // HTTP 200 with no access_token is not a valid success.
        let json = #"{"token_type":"Bearer"}"#.data(using: .utf8)!
        XCTAssertNil(GrokAuth.parseTokenResponse(json, statusCode: 200, now: Date()).successValue)
    }

    // MARK: - id_token email extraction

    func testEmailFromIDTokenDecodesPayload() {
        XCTAssertEqual(GrokAuth.emailFromIDToken(makeIDToken(email: "a@b.com")), "a@b.com")
    }

    func testEmailFromIDTokenHandlesMalformedInput() {
        XCTAssertNil(GrokAuth.emailFromIDToken(nil))
        XCTAssertNil(GrokAuth.emailFromIDToken(""))
        XCTAssertNil(GrokAuth.emailFromIDToken("not-a-jwt"))
    }

    // MARK: - Credential storage round-trip

    func testCredentialsRoundTripOmitsISOExpiredField() throws {
        let creds = GrokAuth.Credentials(access: "A", refresh: "R", expiresAtMs: 123_456, email: "u@x.ai")
        let json = GrokAuth.credentialsJSON(creds)

        XCTAssertEqual(json["type"] as? String, "grok-cli")
        XCTAssertEqual(json["email"] as? String, "u@x.ai")
        XCTAssertEqual(json["disabled"] as? Bool, false)
        // No ISO `expired` field, so AuthManager never flags the account expired
        // even though the short-lived access token in `expires` rotates.
        XCTAssertNil(json["expired"])

        let restored = try XCTUnwrap(GrokAuth.credentials(from: json))
        XCTAssertEqual(restored, creds)
    }

    func testCredentialsJSONDefaultsEmailWhenMissing() {
        let creds = GrokAuth.Credentials(access: "A", refresh: "R", expiresAtMs: 0, email: nil)
        XCTAssertEqual(GrokAuth.credentialsJSON(creds)["email"] as? String, "grok-user")
    }

    func testCredentialsFromJSONRejectsMissingTokens() {
        XCTAssertNil(GrokAuth.credentials(from: ["type": "grok-cli", "refresh": "R"]))
        XCTAssertNil(GrokAuth.credentials(from: ["type": "grok-cli", "access": "A"]))
    }

    // MARK: - Access-token expiry

    func testIsAccessExpiredBoundary() {
        let now = Date(timeIntervalSince1970: 2_000)
        let nowMs = now.timeIntervalSince1970 * 1000
        let expired = GrokAuth.Credentials(access: "A", refresh: "R", expiresAtMs: nowMs - 1, email: nil)
        let valid = GrokAuth.Credentials(access: "A", refresh: "R", expiresAtMs: nowMs + 1, email: nil)
        XCTAssertTrue(expired.isAccessExpired(now: now))
        XCTAssertFalse(valid.isAccessExpired(now: now))
    }

    // MARK: - Persistence round-trip

    func testPersistThenLoadRoundTripsCredentials() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let creds = GrokAuth.Credentials(access: "ACCESS", refresh: "REFRESH", expiresAtMs: 9_999_999_999_999, email: "u@x.ai")
        GrokAuth.persist(creds, to: GrokAuth.credentialsURL(in: dir))

        let loaded = try XCTUnwrap(GrokAuth.loadActiveCredentials(in: dir))
        XCTAssertEqual(loaded.credentials, creds)
        XCTAssertEqual(loaded.url.lastPathComponent, "grok-cli.json")
    }

    func testLoadActiveCredentialsSkipsDisabledAndNonGrokFiles() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        try writeJSON(["type": "grok-cli", "access": "A", "refresh": "R", "expires": 9_999_999_999_999, "disabled": true],
                      to: dir.appendingPathComponent("grok-cli.json"))
        try writeJSON(["type": "cursor", "apiKey": "k"], to: dir.appendingPathComponent("cursor.json"))
        XCTAssertNil(GrokAuth.loadActiveCredentials(in: dir))
    }

    // MARK: - Helpers

    private func tokenError(_ json: String) -> GrokAuth.GrokAuthError? {
        if case .failure(let error) = GrokAuth.parseTokenResponse(json.data(using: .utf8)!, statusCode: 400, now: Date()) {
            return error
        }
        return nil
    }

    private func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("grok-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func writeJSON(_ obj: [String: Any], to url: URL) throws {
        let data = try JSONSerialization.data(withJSONObject: obj)
        try data.write(to: url)
    }

    private func makeIDToken(email: String) -> String {
        let payload = try! JSONSerialization.data(withJSONObject: ["email": email])
        let b64 = payload.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        return "eyJhbGciOiJSUzI1NiJ9.\(b64).signature"
    }
}

private extension Result where Success == GrokAuth.Credentials {
    var successValue: GrokAuth.Credentials? {
        if case .success(let value) = self { return value }
        return nil
    }
}
