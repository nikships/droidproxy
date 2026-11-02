import XCTest
@testable import CLIProxyMenuBar

final class AuthAccountExpiryTests: XCTestCase {
    private let file = URL(fileURLWithPath: "/tmp/antigravity-a@b.com.json")
    private let past = "2026-01-01T00:00:00-08:00"

    private func account(_ json: [String: Any]) -> AuthAccount {
        AuthManager.parseAccount(json: json, file: file)!
    }

    func testAnExpiredAccessTokenWithARefreshTokenIsStillUsable() {
        let account = account(["type": "antigravity", "email": "a@b.com", "expired": past, "refresh_token": "1//refresh"])
        XCTAssertTrue(account.isAccessExpired)
        XCTAssertTrue(account.canRefresh)
        XCTAssertFalse(account.isExpired)
    }

    func testAnExpiredAccessTokenWithoutARefreshTokenNeedsSigningInAgain() {
        for json: [String: Any] in [
            ["type": "antigravity", "expired": past],
            ["type": "antigravity", "expired": past, "refresh_token": ""],
        ] {
            let account = account(json)
            XCTAssertFalse(account.canRefresh)
            XCTAssertTrue(account.isExpired)
        }
    }

    func testAFutureOrMissingExpiryIsNotExpired() {
        let future = ISO8601DateFormatter().string(from: Date().addingTimeInterval(3600))
        XCTAssertFalse(account(["type": "codex", "expired": future]).isAccessExpired)
        XCTAssertFalse(account(["type": "codex"]).isExpired)
    }

    func testTheControlAPIReportsARefreshableAccountAsNotExpired() {
        let account = account(["type": "antigravity", "email": "a@b.com", "expired": past, "refresh_token": "1//refresh"])
        let control = ControlAccount(id: account.id, label: account.displayName, expired: account.isExpired, disabled: account.isDisabled)
        XCTAssertFalse(control.expired)
    }
}
