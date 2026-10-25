import Network
import XCTest
@testable import CLIProxyMenuBar

final class ControlAPIAuthorizationTests: XCTestCase {
    private let token = String(repeating: "ab", count: 32)

    private func request(
        method: String = "GET",
        path: String = "/droidproxy/control/status",
        headers: [String: String] = [:],
        body: Data = Data()
    ) -> ControlAPI.Request {
        var all = ["host": "127.0.0.1:8317", "authorization": "Bearer \(token)"]
        for (key, value) in headers { all[key] = value }
        return ControlAPI.Request(method: method, path: path, headers: all.filter { !$0.value.isEmpty }, body: body)
    }

    private func status(_ request: ControlAPI.Request, loopback: Bool = true) -> Int? {
        ControlAPI.authorize(request, peerIsLoopback: loopback, token: token, port: 8317)?.status
    }

    func testAcceptsLoopbackRequestWithHostAndToken() {
        XCTAssertNil(status(request()))
        XCTAssertNil(status(request(headers: ["host": "localhost:8317"])))
        XCTAssertNil(status(request(headers: ["host": "LOCALHOST:8317"])))
        XCTAssertNil(status(request(headers: ["authorization": "bearer \(token)"])))
    }

    func testRefusesNonLoopbackPeer() {
        XCTAssertEqual(status(request(), loopback: false), 403)
    }

    func testRefusesAnyOriginHeader() {
        XCTAssertEqual(status(request(headers: ["origin": "http://localhost:8317"])), 403)
        XCTAssertEqual(status(request(headers: ["origin": "null"])), 403)
    }

    func testRefusesOtherHosts() {
        XCTAssertEqual(status(request(headers: ["host": ""])), 403)
        XCTAssertEqual(status(request(headers: ["host": "127.0.0.1:8318"])), 403)
        XCTAssertEqual(status(request(headers: ["host": "evil.example:8317"])), 403)
        XCTAssertEqual(status(request(headers: ["host": "127.0.0.1"])), 403)
        XCTAssertEqual(status(request(headers: ["host": "192.168.1.5:8317"])), 403)
    }

    func testRefusesMissingOrWrongToken() {
        XCTAssertEqual(status(request(headers: ["authorization": ""])), 401)
        XCTAssertEqual(status(request(headers: ["authorization": "Bearer nope"])), 401)
        XCTAssertEqual(status(request(headers: ["authorization": "Basic \(token)"])), 401)
        XCTAssertEqual(status(request(headers: ["authorization": "Bearer \(token)x"])), 401)
    }

    func testForbiddenComesBeforeUnauthorized() {
        XCTAssertEqual(status(request(headers: ["authorization": "", "origin": "https://a.b"])), 403)
    }

    func testRefusesBodiesOverTheLimit() {
        let limit = ControlAPI.maxBodyBytes
        XCTAssertNil(status(request(method: "POST", headers: ["content-length": "\(limit)"], body: Data(count: limit))))
        XCTAssertEqual(status(request(method: "POST", headers: ["content-length": "\(limit + 1)"])), 413)
        XCTAssertEqual(status(request(method: "POST", body: Data(count: limit + 1))), 413)
    }

    func testConstantTimeEquals() {
        XCTAssertTrue(ControlAPI.constantTimeEquals(token, token))
        XCTAssertFalse(ControlAPI.constantTimeEquals(token, String(token.dropLast())))
        XCTAssertFalse(ControlAPI.constantTimeEquals(token, String(token.dropLast()) + "c"))
        XCTAssertFalse(ControlAPI.constantTimeEquals("", token))
        XCTAssertTrue(ControlAPI.constantTimeEquals("", ""))
    }

    func testLoopbackHosts() {
        XCTAssertTrue(ControlAPI.isLoopback(host: NWEndpoint.Host("127.0.0.1")))
        XCTAssertTrue(ControlAPI.isLoopback(host: NWEndpoint.Host("127.8.9.10")))
        XCTAssertTrue(ControlAPI.isLoopback(host: NWEndpoint.Host("::1")))
        XCTAssertTrue(ControlAPI.isLoopback(host: NWEndpoint.Host("::ffff:127.0.0.1")))
        XCTAssertFalse(ControlAPI.isLoopback(host: NWEndpoint.Host("192.168.1.2")))
        XCTAssertFalse(ControlAPI.isLoopback(host: NWEndpoint.Host("100.64.0.7")))
        XCTAssertFalse(ControlAPI.isLoopback(host: NWEndpoint.Host("fe80::1")))
        XCTAssertFalse(ControlAPI.isLoopback(host: .name("localhost", nil)))
        XCTAssertFalse(ControlAPI.isLoopback(nil))
        XCTAssertTrue(ControlAPI.isLoopback(.hostPort(host: "127.0.0.1", port: 50000)))
    }

    func testJSONContentType() {
        XCTAssertTrue(ControlAPI.isJSONContentType("application/json"))
        XCTAssertTrue(ControlAPI.isJSONContentType("Application/JSON; charset=utf-8"))
        XCTAssertFalse(ControlAPI.isJSONContentType(nil))
        XCTAssertFalse(ControlAPI.isJSONContentType("text/plain"))
        XCTAssertFalse(ControlAPI.isJSONContentType("application/x-www-form-urlencoded"))
    }
}

final class ControlAPIParsingTests: XCTestCase {
    func testRecognizesControlRequestsFromTheRequestLine() {
        XCTAssertTrue(ControlAPI.looksLikeControlRequest(Data("GET /droidproxy/control/status HTTP/1.1\r\nHost: x\r\n\r\n".utf8)))
        XCTAssertTrue(ControlAPI.looksLikeControlRequest(Data("POST /droidproxy/control/connect?x=1 HTTP/1.1\r\n".utf8)))
        XCTAssertTrue(ControlAPI.looksLikeControlRequest(Data("GET /droidproxy/control HTTP/1.1\r\n".utf8)))
        XCTAssertFalse(ControlAPI.looksLikeControlRequest(Data("GET /droidproxy/usage HTTP/1.1\r\n".utf8)))
        XCTAssertFalse(ControlAPI.looksLikeControlRequest(Data("GET /droidproxy/controlx HTTP/1.1\r\n".utf8)))
        XCTAssertFalse(ControlAPI.looksLikeControlRequest(Data("POST /v1/messages HTTP/1.1\r\n".utf8)))
        XCTAssertFalse(ControlAPI.looksLikeControlRequest(Data("GET /droidproxy/control/status".utf8)))
    }

    func testParsesMethodPathHeadersAndBody() throws {
        let raw = "post /droidproxy/control/connect?debug=1 HTTP/1.1\r\nHost: 127.0.0.1:8317\r\nContent-Type: application/json\r\nAuthorization: Bearer t\r\n\r\n{\"provider\":\"claude\"}"
        let request = try XCTUnwrap(ControlAPI.parseRequest(Data(raw.utf8)))
        XCTAssertEqual(request.method, "POST")
        XCTAssertEqual(request.path, "/droidproxy/control/connect")
        XCTAssertEqual(request.headers["host"], "127.0.0.1:8317")
        XCTAssertEqual(request.headers["content-type"], "application/json")
        XCTAssertEqual(request.headers["authorization"], "Bearer t")
        XCTAssertEqual(String(data: request.body, encoding: .utf8), "{\"provider\":\"claude\"}")
    }

    func testRoutes() {
        XCTAssertEqual(ControlAPI.match(method: "GET", path: "/droidproxy/control/status"), .route(.status))
        XCTAssertEqual(ControlAPI.match(method: "POST", path: "/droidproxy/control/connect"), .route(.connect))
        XCTAssertEqual(ControlAPI.match(method: "POST", path: "/droidproxy/control/connect/cancel"), .route(.cancelConnect))
        XCTAssertEqual(ControlAPI.match(method: "POST", path: "/droidproxy/control/accounts/remove"), .route(.removeAccount))
        XCTAssertEqual(ControlAPI.match(method: "POST", path: "/droidproxy/control/providers"), .route(.providers))
        XCTAssertEqual(ControlAPI.match(method: "POST", path: "/droidproxy/control/factory-models"), .route(.factoryModels))
        XCTAssertEqual(ControlAPI.match(method: "GET", path: "/droidproxy/control/models"), .route(.models))
        XCTAssertEqual(ControlAPI.match(method: "POST", path: "/droidproxy/control/open"), .route(.open))
        XCTAssertEqual(ControlAPI.match(method: "POST", path: "/droidproxy/control/status"), .methodNotAllowed)
        XCTAssertEqual(ControlAPI.match(method: "GET", path: "/droidproxy/control/connect"), .methodNotAllowed)
        XCTAssertEqual(ControlAPI.match(method: "GET", path: "/droidproxy/control/nope"), .notFound)
        XCTAssertEqual(ControlAPI.match(method: "GET", path: "/droidproxy/control"), .notFound)
        XCTAssertEqual(ControlAPI.match(method: "GET", path: "/droidproxy/control/status/"), .notFound)
    }

    func testReasonPhrases() {
        XCTAssertEqual(ThinkingProxy.reasonPhrase(for: 202), "Accepted")
        XCTAssertEqual(ThinkingProxy.reasonPhrase(for: 415), "Unsupported Media Type")
        XCTAssertEqual(ThinkingProxy.reasonPhrase(for: 500), "Internal Server Error")
    }

    func testLaunchedByDroidOffice() {
        XCTAssertTrue(LaunchContext.launchedByDroidOffice(["/x/CLIProxyMenuBar", "--launched-by", "droid-office"]))
        XCTAssertTrue(LaunchContext.launchedByDroidOffice(["/x/CLIProxyMenuBar", "--launched-by=droid-office"]))
        XCTAssertFalse(LaunchContext.launchedByDroidOffice(["/x/CLIProxyMenuBar"]))
        XCTAssertFalse(LaunchContext.launchedByDroidOffice(["/x/CLIProxyMenuBar", "--launched-by"]))
        XCTAssertFalse(LaunchContext.launchedByDroidOffice(["/x/CLIProxyMenuBar", "--launched-by", "someone-else"]))
    }
}
