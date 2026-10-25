import XCTest
@testable import CLIProxyMenuBar

@MainActor
private final class FakeBackend: ControlBackend {
    var status = ControlStatus(
        version: "1.8.180",
        backendRunning: true,
        providers: [
            ControlProvider(
                key: .claude,
                name: "Claude",
                enabled: true,
                accounts: [ControlAccount(id: "claude-a@b.com.json", label: "a@b.com", expired: false, disabled: false)],
                connecting: nil
            ),
            ControlProvider(
                key: .grok,
                name: "Grok",
                enabled: false,
                accounts: [],
                connecting: ProviderConnect(
                    startedAt: Date(timeIntervalSince1970: 1_000),
                    userCode: "ABCD-EFGH",
                    verificationURI: "https://accounts.x.ai/device?user_code=ABCD-EFGH",
                    error: nil
                )
            )
        ],
        factory: FactoryModels.Status(installed: 3, available: 14, stale: true)
    )
    var connectOutcome = ConnectOutcome.started(ProviderConnect(startedAt: Date(timeIntervalSince1970: 2_000)))
    var removeFailure: ControlAPI.Response?
    var applyResult: Result<FactoryModels.ApplyResult, Error> = .success(FactoryModels.ApplyResult(installed: 14, backup: nil))
    var models: [ControlModel] = []
    var calls: [String] = []

    func controlStatus() -> ControlStatus { status }
    func controlConnect(_ provider: ServiceType) -> ConnectOutcome {
        calls.append("connect \(provider.rawValue)")
        return connectOutcome
    }
    func controlCancelConnect(_ provider: ServiceType) { calls.append("cancel \(provider.rawValue)") }
    func controlRemoveAccount(_ provider: ServiceType, account: String) async -> ControlAPI.Response? {
        calls.append("remove \(provider.rawValue) \(account)")
        return removeFailure
    }
    func controlSetProviderEnabled(_ provider: ServiceType, enabled: Bool) {
        calls.append("enable \(provider.rawValue) \(enabled)")
    }
    func controlApplyFactoryModels() -> Result<FactoryModels.ApplyResult, Error> {
        calls.append("factory-models")
        return applyResult
    }
    func controlModels(now: Date) async -> [ControlModel] { models }
    func controlOpenSettings() { calls.append("open") }
}

@MainActor
final class ControlAPIRoutingTests: XCTestCase {
    private let token = String(repeating: "0f", count: 32)
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private var backend: FakeBackend!

    override func setUp() {
        super.setUp()
        backend = FakeBackend()
    }

    private func call(
        _ method: String,
        _ path: String,
        json: String? = nil,
        contentType: String? = "application/json"
    ) async throws -> (status: Int, body: [String: Any]) {
        var headers = ["host": "127.0.0.1:8317", "authorization": "Bearer \(token)"]
        if method == "POST", let contentType { headers["content-type"] = contentType }
        let request = ControlAPI.Request(
            method: method,
            path: "/droidproxy/control" + path,
            headers: headers,
            body: Data((json ?? "").utf8)
        )
        let response = await ControlAPI.handle(request, peerIsLoopback: true, token: token, port: 8317, backend: backend, now: now)
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: response.body) as? [String: Any])
        return (response.status, body)
    }

    func testStatusShape() async throws {
        let (status, body) = try await call("GET", "/status")
        XCTAssertEqual(status, 200)
        XCTAssertEqual(body["api"] as? Int, 1)
        XCTAssertEqual(body["version"] as? String, "1.8.180")
        XCTAssertEqual((body["backend"] as? [String: Any])?["running"] as? Bool, true)
        let factory = try XCTUnwrap(body["factory"] as? [String: Any])
        XCTAssertEqual(factory["installed"] as? Int, 3)
        XCTAssertEqual(factory["available"] as? Int, 14)
        XCTAssertEqual(factory["stale"] as? Bool, true)

        let providers = try XCTUnwrap(body["providers"] as? [[String: Any]])
        XCTAssertEqual(providers.map { $0["key"] as? String }, ["claude", "grok"])
        let claude = providers[0]
        XCTAssertEqual(claude["name"] as? String, "Claude")
        XCTAssertEqual(claude["enabled"] as? Bool, true)
        XCTAssertEqual(claude["connect"] as? String, "browser")
        XCTAssertTrue(claude["connecting"] is NSNull)
        let account = try XCTUnwrap((claude["accounts"] as? [[String: Any]])?.first)
        XCTAssertEqual(account["id"] as? String, "claude-a@b.com.json")
        XCTAssertEqual(account["label"] as? String, "a@b.com")
        XCTAssertEqual(account["expired"] as? Bool, false)
        XCTAssertEqual(account["disabled"] as? Bool, false)

        let grok = providers[1]
        XCTAssertEqual(grok["connect"] as? String, "device")
        XCTAssertEqual(grok["enabled"] as? Bool, false)
        let connecting = try XCTUnwrap(grok["connecting"] as? [String: Any])
        XCTAssertEqual(connecting["started_at"] as? String, "1970-01-01T00:16:40Z")
        XCTAssertEqual(connecting["user_code"] as? String, "ABCD-EFGH")
        XCTAssertEqual(connecting["verification_uri"] as? String, "https://accounts.x.ai/device?user_code=ABCD-EFGH")
        XCTAssertTrue(connecting["error"] is NSNull)
    }

    func testConnectStartsAndAnswers202() async throws {
        let (status, body) = try await call("POST", "/connect", json: #"{"provider":"codex"}"#)
        XCTAssertEqual(status, 202)
        let connecting = try XCTUnwrap(body["connecting"] as? [String: Any])
        XCTAssertEqual(connecting["started_at"] as? String, "1970-01-01T00:33:20Z")
        XCTAssertTrue(connecting["user_code"] is NSNull)
        XCTAssertTrue(connecting["verification_uri"] is NSNull)
        XCTAssertTrue(connecting["error"] is NSNull)
        XCTAssertEqual(backend.calls, ["connect codex"])
    }

    func testConnectAlreadyRunningIs409() async throws {
        backend.connectOutcome = .alreadyRunning
        let (status, body) = try await call("POST", "/connect", json: #"{"provider":"claude"}"#)
        XCTAssertEqual(status, 409)
        XCTAssertNotNil(body["error"] as? String)
    }

    func testConnectForAppOnlyProviderIs400() async throws {
        backend.connectOutcome = .needsApp
        let (status, body) = try await call("POST", "/connect", json: #"{"provider":"junie"}"#)
        XCTAssertEqual(status, 400)
        XCTAssertNotNil(body["error"] as? String)
    }

    func testUnknownOrMissingProviderIs400() async throws {
        let unknown = try await call("POST", "/connect", json: #"{"provider":"openai"}"#)
        XCTAssertEqual(unknown.status, 400)
        let missing = try await call("POST", "/connect", json: "{}")
        XCTAssertEqual(missing.status, 400)
        XCTAssertTrue(backend.calls.isEmpty)
    }

    func testPostWithoutJSONContentTypeIs415() async throws {
        let none = try await call("POST", "/connect", json: #"{"provider":"claude"}"#, contentType: nil)
        XCTAssertEqual(none.status, 415)
        let form = try await call("POST", "/open", json: "{}", contentType: "application/x-www-form-urlencoded")
        XCTAssertEqual(form.status, 415)
        XCTAssertTrue(backend.calls.isEmpty)
    }

    func testMalformedBodyIs400() async throws {
        let (status, body) = try await call("POST", "/connect", json: "[1,2]")
        XCTAssertEqual(status, 400)
        XCTAssertNotNil(body["error"] as? String)
    }

    func testUnknownPathAndWrongMethod() async throws {
        let missing = try await call("GET", "/nope")
        XCTAssertEqual(missing.status, 404)
        XCTAssertNotNil(missing.body["error"] as? String)
        let wrongMethod = try await call("GET", "/connect")
        XCTAssertEqual(wrongMethod.status, 405)
    }

    func testCancel() async throws {
        let (status, body) = try await call("POST", "/connect/cancel", json: #"{"provider":"meta"}"#)
        XCTAssertEqual(status, 200)
        XCTAssertTrue(body.isEmpty)
        XCTAssertEqual(backend.calls, ["cancel meta"])
    }

    func testRemoveAccountAnswersStatus() async throws {
        let (status, body) = try await call("POST", "/accounts/remove", json: #"{"provider":"claude","account":"a@b.com"}"#)
        XCTAssertEqual(status, 200)
        XCTAssertEqual(body["api"] as? Int, 1)
        XCTAssertEqual(backend.calls, ["remove claude a@b.com"])
    }

    func testRemoveAccountPassesRefusalThrough() async throws {
        backend.removeFailure = .error(404, "Claude has no account \"x\".")
        let (status, body) = try await call("POST", "/accounts/remove", json: #"{"provider":"claude","account":"x"}"#)
        XCTAssertEqual(status, 404)
        XCTAssertEqual(body["error"] as? String, "Claude has no account \"x\".")
        let missing = try await call("POST", "/accounts/remove", json: #"{"provider":"claude"}"#)
        XCTAssertEqual(missing.status, 400)
    }

    func testProviderSwitch() async throws {
        let (status, body) = try await call("POST", "/providers", json: #"{"provider":"kimi","enabled":false}"#)
        XCTAssertEqual(status, 200)
        XCTAssertNotNil(body["providers"])
        XCTAssertEqual(backend.calls, ["enable kimi false"])
        let notBool = try await call("POST", "/providers", json: #"{"provider":"kimi","enabled":"no"}"#)
        XCTAssertEqual(notBool.status, 400)
    }

    func testFactoryModels() async throws {
        let (status, body) = try await call("POST", "/factory-models", json: "{}")
        XCTAssertEqual(status, 200)
        XCTAssertEqual(body["installed"] as? Int, 14)
        XCTAssertTrue(body["backup"] is NSNull)

        backend.applyResult = .success(FactoryModels.ApplyResult(installed: 2, backup: URL(fileURLWithPath: "/tmp/settings.json.droidproxy-1.bak")))
        let withBackup = try await call("POST", "/factory-models", json: "")
        XCTAssertEqual(withBackup.body["backup"] as? String, "/tmp/settings.json.droidproxy-1.bak")

        backend.applyResult = .failure(CocoaError(.fileWriteNoPermission))
        let failed = try await call("POST", "/factory-models", json: "{}")
        XCTAssertEqual(failed.status, 500)
        XCTAssertNotNil(failed.body["error"] as? String)
    }

    func testModelsShape() async throws {
        let until = now.addingTimeInterval(3_600)
        backend.models = [
            ControlModel(id: "custom:droidproxy:opus-5-5", name: "Opus 5.5", provider: "claude", availability: .ok),
            ControlModel(
                id: "custom:droidproxy:gpt-6.1-sol",
                name: "GPT 6.1 Sol",
                provider: "codex",
                availability: .exhausted(until: until, window: "5-hour", account: "a@b.com")
            ),
            ControlModel(id: "custom:droidproxy:grok-4.7", name: "Grok 4.7", provider: "grok", availability: .signedOut),
            ControlModel(id: "custom:droidproxy:kimi-k3", name: "Kimi K3", provider: "kimi", availability: .disabled),
            ControlModel(id: "custom:droidproxy:junie-gpt-6.1-sol", name: "Junie Sol 6.1", provider: "junie", availability: .unknown),
            ControlModel(
                id: "custom:droidproxy:gpt-6-luna",
                name: "GPT 6 Luna",
                provider: "codex",
                availability: .exhausted(until: nil, window: "Weekly", account: nil)
            )
        ]
        let (status, body) = try await call("GET", "/models")
        XCTAssertEqual(status, 200)
        XCTAssertEqual(body["generated_at"] as? String, "2027-01-15T08:00:00Z")
        let models = try XCTUnwrap(body["models"] as? [[String: Any]])
        XCTAssertEqual(models.count, 6)
        XCTAssertEqual(models[0]["id"] as? String, "custom:droidproxy:opus-5-5")
        XCTAssertEqual(models[0]["name"] as? String, "Opus 5.5")
        XCTAssertEqual(models[0]["provider"] as? String, "claude")
        let states = models.compactMap { ($0["availability"] as? [String: Any])?["state"] as? String }
        XCTAssertEqual(states, ["ok", "exhausted", "signed-out", "disabled", "unknown", "exhausted"])
        let exhausted = try XCTUnwrap(models[1]["availability"] as? [String: Any])
        XCTAssertEqual(exhausted["until"] as? String, "2027-01-15T09:00:00Z")
        XCTAssertEqual(exhausted["window"] as? String, "5-hour")
        XCTAssertEqual(exhausted["account"] as? String, "a@b.com")
        let unknownReset = try XCTUnwrap(models[5]["availability"] as? [String: Any])
        XCTAssertTrue(unknownReset["until"] is NSNull)
        XCTAssertTrue(unknownReset["account"] is NSNull)
        XCTAssertEqual((models[0]["availability"] as? [String: Any])?.count, 1)
    }

    func testOpen() async throws {
        let (status, body) = try await call("POST", "/open", json: "{}")
        XCTAssertEqual(status, 200)
        XCTAssertTrue(body.isEmpty)
        XCTAssertEqual(backend.calls, ["open"])
    }

    func testRefusalsComeBeforeRouting() async throws {
        let request = ControlAPI.Request(method: "POST", path: "/droidproxy/control/open", headers: ["host": "127.0.0.1:8317"], body: Data())
        let response = await ControlAPI.handle(request, peerIsLoopback: true, token: token, port: 8317, backend: backend, now: now)
        XCTAssertEqual(response.status, 401)
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: response.body) as? [String: Any])
        XCTAssertNotNil(body["error"] as? String)
        XCTAssertFalse(String(data: response.body, encoding: .utf8)!.contains(token))
        XCTAssertTrue(backend.calls.isEmpty)
    }
}
