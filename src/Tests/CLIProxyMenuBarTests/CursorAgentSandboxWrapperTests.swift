import XCTest
@testable import CLIProxyMenuBar

final class CursorAgentSandboxWrapperTests: XCTestCase {
    func testWrapperForcesSandboxOnPrint() {
        let script = CursorAgentSandboxWrapper.wrapperScript(realAgentPath: "/opt/agent")
        XCTAssertTrue(script.contains("exec \"$REAL\" --sandbox enabled \"$@\""))
        XCTAssertTrue(script.contains("login|logout|status"))
        XCTAssertTrue(script.contains("/opt/agent"))
    }

    func testInstallWritesExecutableWrapper() throws {
        let real = URL(fileURLWithPath: "/usr/bin/true")
        let wrapper = try XCTUnwrap(CursorAgentSandboxWrapper.install(realAgent: real))
        XCTAssertEqual(wrapper.lastPathComponent, CursorAgentSandboxWrapper.fileName)
        let attrs = try FileManager.default.attributesOfItem(atPath: wrapper.path)
        let perms = try XCTUnwrap(attrs[.posixPermissions] as? NSNumber).intValue
        XCTAssertEqual(perms & 0o111, 0o111)
        let body = try String(contentsOf: wrapper, encoding: .utf8)
        XCTAssertTrue(body.contains("--sandbox enabled"))
        XCTAssertTrue(body.contains("/usr/bin/true"))
    }
}
