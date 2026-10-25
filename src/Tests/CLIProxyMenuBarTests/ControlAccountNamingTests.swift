import XCTest
@testable import CLIProxyMenuBar

final class ControlAccountNamingTests: XCTestCase {
    private func account(_ id: String, email: String?) -> AuthAccount {
        AuthAccount(
            id: id,
            email: email,
            login: nil,
            type: .claude,
            expired: nil,
            filePath: URL(fileURLWithPath: "/tmp/\(id)"),
            isDisabled: false,
            organizationName: nil,
            claudeSeatLabel: nil
        )
    }

    func testAnIDNamesItsAccountEvenWhenTheEmailIsShared() {
        let personal = account("claude-a@b.com-1.json", email: "a@b.com")
        let team = account("claude-a@b.com-2.json", email: "a@b.com")
        let picked = ProviderController.controlAccounts(named: "claude-a@b.com-2.json", in: [personal, team])
        XCTAssertEqual(picked, [team])
    }

    func testAnEmailNamesEveryAccountThatHasIt() {
        let personal = account("claude-a@b.com-1.json", email: "a@b.com")
        let team = account("claude-a@b.com-2.json", email: "a@b.com")
        let other = account("claude-c@d.com.json", email: "c@d.com")
        XCTAssertEqual(ProviderController.controlAccounts(named: "A@B.com", in: [personal, team, other]), [personal, team])
        XCTAssertEqual(ProviderController.controlAccounts(named: "c@d.com", in: [personal, team, other]), [other])
        XCTAssertEqual(ProviderController.controlAccounts(named: "x@y.com", in: [personal, team, other]), [])
    }
}
