import XCTest
@testable import CLIProxyMenuBar

/// Answers every request from `handler`, so no test touches the network.
final class MistralStubProtocol: URLProtocol {
    typealias Handler = (URLRequest, Data?) throws -> (HTTPURLResponse, Data)
    static var handler: Handler?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        var body = request.httpBody
        if body == nil, let stream = request.httpBodyStream {
            stream.open()
            var data = Data()
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                if count <= 0 { break }
                data.append(buffer, count: count)
            }
            stream.close()
            body = data
        }
        do {
            guard let handler = Self.handler else { throw URLError(.unknown) }
            let (response, data) = try handler(request, body)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

private final class Recorder: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [TimeInterval] = []
    func add(_ value: TimeInterval) { lock.lock(); values.append(value); lock.unlock() }
    var all: [TimeInterval] { lock.lock(); defer { lock.unlock() }; return values }
}

final class MistralVibeSignInTests: XCTestCase {
    private let pollURL = "https://console.mistral.ai/api/vibe/sign-in/p1/poll"
    private var directory: URL!
    private var store: MistralCredentialStore!
    private var session: URLSession!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        store = MistralCredentialStore(directory: directory)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MistralStubProtocol.self]
        session = URLSession(configuration: configuration)
    }

    override func tearDownWithError() throws {
        MistralStubProtocol.handler = nil
        try? FileManager.default.removeItem(at: directory)
    }

    private func reply(_ request: URLRequest, _ status: Int, _ json: Any? = nil, headers: [String: String] = [:]) throws -> (HTTPURLResponse, Data) {
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: headers)!
        let data = try json.map { try JSONSerialization.data(withJSONObject: $0) } ?? Data()
        return (response, data)
    }

    private func startJSON(expires: String = "2099-01-01T00:00:00Z") -> [String: Any] {
        [
            "process_id": "p1",
            "sign_in_url": "https://console.mistral.ai/codestral/cli/authenticate?process_id=p1&complete_token=secret",
            "poll_url": pollURL,
            "expires_at": expires
        ]
    }

    private func signIn(sleeps: Recorder = Recorder(), now: Date = Date(timeIntervalSince1970: 1_800_000_000)) -> MistralVibeSignIn {
        MistralVibeSignIn(session: session, store: store, now: { now }, sleep: { sleeps.add($0) })
    }

    private func json(_ body: Data?) -> [String: Any] {
        (body.flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any]) ?? [:]
    }

    func testPKCEChallengeMatchesTheRFC7636Vector() {
        XCTAssertEqual(
            MistralVibeSignIn.challenge(for: "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"),
            "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM"
        )
    }

    func testVerifierIsRandomBase64URLOf64Bytes() {
        let first = MistralVibeSignIn.makeVerifier()
        XCTAssertEqual(first.count, 86)
        XCTAssertNil(first.rangeOfCharacter(from: CharacterSet(charactersIn: "+/=")))
        XCTAssertNotEqual(first, MistralVibeSignIn.makeVerifier())
    }

    func testNormalFlowPollsThenExchangesWithTheVerifier() async throws {
        var polls = 0
        var startBody: [String: Any] = [:]
        var exchangeBody: [String: Any] = [:]
        var startHadAuth = true
        MistralStubProtocol.handler = { request, body in
            let path = request.url!.path
            switch (request.httpMethod ?? "", path) {
            case ("POST", "/api/vibe/sign-in"):
                startBody = self.json(body)
                startHadAuth = request.value(forHTTPHeaderField: "Authorization") != nil
                XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
                return try self.reply(request, 200, self.startJSON())
            case ("GET", "/api/vibe/sign-in/p1/poll"):
                polls += 1
                return try self.reply(request, 200, polls == 1
                    ? ["status": "pending"]
                    : ["status": "completed", "exchange_token": "xt"])
            case ("POST", "/api/vibe/sign-in/p1/exchange"):
                exchangeBody = self.json(body)
                return try self.reply(request, 200, ["api_key": "  vibe-key  "])
            default:
                XCTFail("unexpected \(request.httpMethod ?? "") \(path)")
                return try self.reply(request, 404)
            }
        }
        let sleeps = Recorder()
        let flow = signIn(sleeps: sleeps)
        let (start, verifier) = try await flow.start()
        XCTAssertEqual(start.processID, "p1")
        XCTAssertEqual(start.signInURL.host, "console.mistral.ai")
        XCTAssertNotNil(start.expiresAt)
        let key = try await flow.waitForKey(start, verifier: verifier)

        XCTAssertEqual(key, "vibe-key")
        XCTAssertFalse(startHadAuth)
        XCTAssertEqual(startBody["code_challenge_method"] as? String, "S256")
        XCTAssertEqual(startBody["code_challenge"] as? String, MistralVibeSignIn.challenge(for: verifier))
        XCTAssertEqual(exchangeBody["exchange_token"] as? String, "xt")
        XCTAssertEqual(exchangeBody["code_verifier"] as? String, verifier)
        XCTAssertEqual(sleeps.all, [15, 15])
    }

    func testRunChecksAndSavesTheKeyAsABrowserAccount() async throws {
        var opened: URL?
        var checkedKey: String?
        MistralStubProtocol.handler = { request, body in
            switch (request.httpMethod ?? "", request.url!.host ?? "", request.url!.path) {
            case ("POST", "console.mistral.ai", "/api/vibe/sign-in"):
                return try self.reply(request, 200, self.startJSON())
            case ("GET", "console.mistral.ai", _):
                return try self.reply(request, 200, ["status": "completed", "exchange_token": "xt"])
            case ("POST", "console.mistral.ai", _):
                return try self.reply(request, 200, ["api_key": "saved-key"])
            case ("GET", "api.mistral.ai", "/v1/models"):
                checkedKey = request.value(forHTTPHeaderField: "Authorization")
                return try self.reply(request, 200, ["data": []])
            default:
                return try self.reply(request, 404)
            }
        }
        let id = try await signIn().run { opened = $0 }
        XCTAssertEqual(opened?.host, "console.mistral.ai")
        XCTAssertEqual(checkedKey, "Bearer saved-key")
        XCTAssertEqual(store.accounts.map(\.id), [id])
        XCTAssertEqual(store.accounts.first?.source, .browser)
        XCTAssertEqual(store.accounts.first?.apiKey, "saved-key")
    }

    func testRunRefusesAKeyMistralRejects() async {
        MistralStubProtocol.handler = { request, _ in
            switch (request.httpMethod ?? "", request.url!.host ?? "") {
            case ("POST", "console.mistral.ai") where request.url!.path == "/api/vibe/sign-in":
                return try self.reply(request, 200, self.startJSON())
            case ("GET", "console.mistral.ai"):
                return try self.reply(request, 200, ["status": "completed", "exchange_token": "xt"])
            case ("POST", "console.mistral.ai"):
                return try self.reply(request, 200, ["api_key": "bad"])
            default:
                return try self.reply(request, 401)
            }
        }
        do {
            _ = try await signIn().run { _ in }
            XCTFail("expected an error")
        } catch {
            guard case .server = error as? MistralSignInError else { return XCTFail("\(error)") }
        }
        XCTAssertTrue(store.accounts.isEmpty)
    }

    func testCancellingDuringTheKeyCheckSavesNothing() async {
        var task: Task<String, Error>?
        MistralStubProtocol.handler = { request, _ in
            switch (request.httpMethod ?? "", request.url!.host ?? "", request.url!.path) {
            case ("POST", "console.mistral.ai", "/api/vibe/sign-in"):
                return try self.reply(request, 200, self.startJSON())
            case ("GET", "console.mistral.ai", _):
                return try self.reply(request, 200, ["status": "completed", "exchange_token": "xt"])
            case ("POST", "console.mistral.ai", _):
                return try self.reply(request, 200, ["api_key": "k"])
            case ("GET", "api.mistral.ai", "/v1/models"):
                task?.cancel()
                return try self.reply(request, 200, ["data": []])
            default:
                return try self.reply(request, 404)
            }
        }
        let flow = signIn()
        task = Task { try await flow.run { _ in } }
        do {
            _ = try await task!.value
            XCTFail("expected cancellation")
        } catch {
            XCTAssertEqual(error as? MistralSignInError, .cancelled)
        }
        XCTAssertTrue(store.accounts.isEmpty)
    }

    func testRateLimitWaitsAtLeastRetryAfterAndBacksOff() async throws {
        var polls = 0
        MistralStubProtocol.handler = { request, _ in
            if request.httpMethod == "POST", request.url!.path.hasSuffix("exchange") {
                return try self.reply(request, 200, ["api_key": "k"])
            }
            polls += 1
            switch polls {
            case 1: return try self.reply(request, 429, nil, headers: ["Retry-After": "40"])
            case 2: return try self.reply(request, 429, nil, headers: ["Retry-After": "1"])
            default: return try self.reply(request, 200, ["status": "completed", "exchange_token": "xt"])
            }
        }
        let sleeps = Recorder()
        let start = MistralSignInStart(processID: "p1", signInURL: URL(string: "https://console.mistral.ai/x")!,
                                       pollURL: URL(string: pollURL)!, expiresAt: Date(timeIntervalSince1970: 4_000_000_000))
        _ = try await signIn(sleeps: sleeps).waitForKey(start, verifier: "v")
        // 15 first; 429 with Retry-After 40 -> 40; next 429 doubles to 80, capped at 60.
        XCTAssertEqual(sleeps.all, [15, 40, 60])
    }

    private func expectError(_ expected: MistralSignInError, status: Int, body: Any?, file: StaticString = #filePath, line: UInt = #line) async {
        MistralStubProtocol.handler = { request, _ in try self.reply(request, status, body) }
        let start = MistralSignInStart(processID: "p1", signInURL: URL(string: "https://console.mistral.ai/x")!,
                                       pollURL: URL(string: pollURL)!, expiresAt: Date(timeIntervalSince1970: 4_000_000_000))
        do {
            _ = try await signIn().waitForKey(start, verifier: "v")
            XCTFail("expected \(expected)", file: file, line: line)
        } catch {
            XCTAssertEqual(error as? MistralSignInError, expected, file: file, line: line)
        }
    }

    func testEndStatesMapToErrors() async {
        await expectError(.expired, status: 410, body: nil)
        await expectError(.expired, status: 200, body: ["status": "expired"])
        await expectError(.denied, status: 200, body: ["status": "denied"])
        await expectError(.server("nope"), status: 200, body: ["status": "error", "message": "nope"])
        await expectError(.notEntitled, status: 403, body: ["error_code": 9004])
        await expectError(.notEntitled, status: 403, body: ["detail": ["error_code": "9004"]])
    }

    func testPastDeadlineExpires() async {
        MistralStubProtocol.handler = { request, _ in try self.reply(request, 200, ["status": "pending"]) }
        let start = MistralSignInStart(processID: "p1", signInURL: URL(string: "https://console.mistral.ai/x")!,
                                       pollURL: URL(string: pollURL)!, expiresAt: Date(timeIntervalSince1970: 1_000))
        do {
            _ = try await signIn().waitForKey(start, verifier: "v")
            XCTFail("expected expiry")
        } catch {
            XCTAssertEqual(error as? MistralSignInError, .expired)
        }
    }

    func testThreeNetworkErrorsInARowFail() async {
        var polls = 0
        MistralStubProtocol.handler = { _, _ in
            polls += 1
            throw URLError(.notConnectedToInternet)
        }
        let start = MistralSignInStart(processID: "p1", signInURL: URL(string: "https://console.mistral.ai/x")!,
                                       pollURL: URL(string: pollURL)!, expiresAt: Date(timeIntervalSince1970: 4_000_000_000))
        do {
            _ = try await signIn().waitForKey(start, verifier: "v")
            XCTFail("expected failure")
        } catch {
            guard case .server = error as? MistralSignInError else { return XCTFail("\(error)") }
        }
        XCTAssertEqual(polls, 3)
    }

    func testANetworkErrorBetweenSuccessesDoesNotCount() async throws {
        var polls = 0
        MistralStubProtocol.handler = { request, _ in
            if request.httpMethod == "POST" { return try self.reply(request, 200, ["api_key": "k"]) }
            polls += 1
            switch polls {
            case 1, 2, 4, 5: throw URLError(.timedOut)
            case 3: return try self.reply(request, 200, ["status": "pending"])
            default: return try self.reply(request, 200, ["status": "completed", "exchange_token": "xt"])
            }
        }
        let start = MistralSignInStart(processID: "p1", signInURL: URL(string: "https://console.mistral.ai/x")!,
                                       pollURL: URL(string: pollURL)!, expiresAt: Date(timeIntervalSince1970: 4_000_000_000))
        let key = try await signIn().waitForKey(start, verifier: "v")
        XCTAssertEqual(key, "k")
    }

    func testCancellingStopsThePollQuickly() async {
        MistralStubProtocol.handler = { request, _ in try self.reply(request, 200, ["status": "pending"]) }
        let flow = MistralVibeSignIn(session: session, store: store, pollInterval: 600)
        let start = MistralSignInStart(processID: "p1", signInURL: URL(string: "https://console.mistral.ai/x")!,
                                       pollURL: URL(string: pollURL)!, expiresAt: Date().addingTimeInterval(3_600))
        let task = Task { try await flow.waitForKey(start, verifier: "v") }
        try? await Task.sleep(nanoseconds: 50_000_000)
        task.cancel()
        let began = Date()
        do {
            _ = try await task.value
            XCTFail("expected cancellation")
        } catch {
            XCTAssertEqual(error as? MistralSignInError, .cancelled)
        }
        XCTAssertLessThan(Date().timeIntervalSince(began), 5)
    }

    func testMissingFieldsInTheStartAnswerFail() async {
        MistralStubProtocol.handler = { request, _ in try self.reply(request, 200, ["process_id": "p1"]) }
        do {
            _ = try await signIn().start()
            XCTFail("expected failure")
        } catch {
            guard case .server = error as? MistralSignInError else { return XCTFail("\(error)") }
        }
    }

    func testNonHTTPSSignInURLIsRefused() async {
        var answer = startJSON()
        answer["sign_in_url"] = "http://evil.example/x"
        MistralStubProtocol.handler = { request, _ in try self.reply(request, 200, answer) }
        do {
            _ = try await signIn().start()
            XCTFail("expected failure")
        } catch {
            guard case .server = error as? MistralSignInError else { return XCTFail("\(error)") }
        }
    }

    func testKeyCheckDistinguishesRejectedFromUnreachable() async {
        MistralStubProtocol.handler = { request, _ in try self.reply(request, 401) }
        let rejected = await MistralKeyCheck.check(apiKey: "k", session: session)
        XCTAssertEqual(rejected, .rejected)
        MistralStubProtocol.handler = { _, _ in throw URLError(.notConnectedToInternet) }
        let unknown = await MistralKeyCheck.check(apiKey: "k", session: session)
        XCTAssertEqual(unknown, .unknown)
        MistralStubProtocol.handler = { request, _ in try self.reply(request, 200, ["data": []]) }
        let valid = await MistralKeyCheck.check(apiKey: "k", session: session)
        XCTAssertEqual(valid, .valid)
    }
}
