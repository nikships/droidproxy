import XCTest
import CryptoKit
import Darwin
@testable import CLIProxyMenuBar

final class RequestJournalTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("request-journal-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: directory)
    }

    private func resource(_ name: String) throws -> Data {
        try Data(contentsOf: XCTUnwrap(Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Contract")))
    }

    private func object(_ value: some Encodable) throws -> NSDictionary {
        try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(value)) as? NSDictionary)
    }

    private func cases() throws -> [[String: Any]] {
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: resource("request-journal-v1.transcripts.json")) as? [String: Any])
        return try XCTUnwrap(root["cases"] as? [[String: Any]])
    }

    func testContractDigests() throws {
        let manifest = try XCTUnwrap(String(data: resource("CONTRACT_SOURCE"), encoding: .utf8))
        XCTAssertTrue(manifest.contains("nikships/droidproxy-omarchy"))
        XCTAssertTrue(manifest.contains("ce6d3e2"))
        let lines = manifest.split(separator: "\n").filter { $0.contains("  request-journal-") }
        XCTAssertEqual(lines.count, 4)
        for line in lines {
            let parts = line.split(separator: " ")
            let hash = SHA256.hash(data: try resource(String(parts[1]))).map { String(format: "%02x", $0) }.joined()
            XCTAssertEqual(hash, String(parts[0]))
        }
    }

    func testGoldenEncoderRoundTripsFieldForFieldAndSchema() throws {
        let schema = try JournalSchema(data: resource("request-journal-v1.schema.json"))
        let lines = try XCTUnwrap(String(data: resource("request-journal-v1.golden.jsonl"), encoding: .utf8)).split(separator: "\n")
        for line in lines {
            let wrapper = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
            let record = try XCTUnwrap(wrapper["record"] as? NSDictionary)
            let valid = try XCTUnwrap(wrapper["valid"] as? Bool)
            XCTAssertEqual(schema.valid(record), valid, wrapper["name"] as? String ?? "")
            if valid {
                let decoded = try JSONDecoder().decode(JournalRecord.self, from: JSONSerialization.data(withJSONObject: record))
                XCTAssertEqual(try object(decoded), record)
            }
        }
    }

    func testEveryTranscriptAtEverySplitAndBytewise() throws {
        let schema = try JournalSchema(data: resource("request-journal-v1.schema.json"))
        var dumped = Data()
        for fixture in try cases() {
            let raw = try XCTUnwrap(fixture["response"] as? String)
            let bytes = Data(try raw.unicodeScalars.map { try XCTUnwrap(UInt8(exactly: $0.value)) })
            let name = try XCTUnwrap(fixture["name"] as? String)
            let expected = try XCTUnwrap(fixture["expect"] as? NSDictionary)
            for split in 0...bytes.count {
                let record = try replay(fixture, chunks: [Data(bytes.prefix(split)), Data(bytes.dropFirst(split))])
                try compare(record, expected: expected, name: "\(name) split \(split)")
                if split == 0 {
                    XCTAssertTrue(schema.valid(try object(record)), name)
                    dumped.append(try JSONEncoder().encode(record))
                    dumped.append(10)
                }
            }
            try compare(replay(fixture, chunks: bytes.map { Data([$0]) }), expected: expected, name: "\(name) bytewise")
        }
        if let path = ProcessInfo.processInfo.environment["JOURNAL_RECORDS_PATH"] {
            try dumped.write(to: URL(fileURLWithPath: path))
        }
    }

    private func compare(_ record: JournalRecord, expected: NSDictionary, name: String) throws {
        let actual = try object(record).mutableCopy() as! NSMutableDictionary
        if name.hasPrefix("no_trace_header") {
            XCTAssertNotNil(record.execution_id.range(of: "^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$", options: .regularExpression))
            actual["execution_id"] = expected["execution_id"]
        }
        XCTAssertEqual(actual, expected, name)
    }

    private func replay(_ fixture: [String: Any], chunks: [Data]) throws -> JournalRecord {
        let req = try XCTUnwrap(fixture["request"] as? [String: Any])
        let path = try XCTUnwrap(req["endpoint"] as? String)
        let headers = try XCTUnwrap(req["headers"] as? [String: String]).map { ($0.key, $0.value) }
        let body = try XCTUnwrap(req["body"] as? [String: Any])
        let obs = try XCTUnwrap(fixture["observation"] as? [String: Any])
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let start = try XCTUnwrap(f.date(from: XCTUnwrap(obs["started_at"] as? String)))
        let end = try XCTUnwrap(f.date(from: XCTUnwrap(obs["ended_at"] as? String)))
        var instant = JournalInstant(wall: start, monotonic: 1_000_000_000)
        let seats = try XCTUnwrap(fixture["seat_snapshot"] as? [[String: Any]]).map {
            try JSONDecoder().decode(JournalSeat.self, from: JSONSerialization.data(withJSONObject: $0))
        }
        var result: JournalRecord?
        let observation = ResponseObservation(
            request: JournalRequest(endpoint: path, forwardedEndpoint: path, headers: headers, body: body),
            clock: { instant },
            bindSeat: { index in
                guard let seat = seats.first(where: { $0.auth_index == index }) else { return nil }
                return JournalSeatBinding(identity: seat, isValid: { true })
            }, emit: { result = $0 })
        instant = JournalInstant(wall: start, monotonic: 1_000_000_000 + UInt64(obs["first_body_elapsed_ms"] as? Int ?? 0) * 1_000_000)
        chunks.forEach(observation.feed)
        instant = JournalInstant(wall: end, monotonic: 1_100_000_000)
        observation.finish(.eof)
        observation.finish(.upstreamError)
        return try XCTUnwrap(result)
    }

    func testSessionPrecedenceAndStrictGrammar() {
        let body: [String: Any] = ["prompt_cache_key": "body-session-0001", "metadata": ["user_id": "user_session_legacy-session-0001"]]
        XCTAssertEqual(JournalRequest.session(headers: [("X-Session-ID", "bad id"), ("x-session-id", "\tHeader-Session:0001 ")], body: body), "Header-Session:0001")
        XCTAssertEqual(JournalRequest.session(headers: [("X-Session-ID", "bad"), ("X-Claude-Code-Session-Id", "second-header-0001")], body: body), "second-header-0001")
        XCTAssertEqual(JournalRequest.session(headers: [], body: body), "body-session-0001")
        for value in ["", "short", " bad-session-0001", "bad-session-0001 ", "bad-session-0001\n", "å-session-0001", String(repeating: "a", count: 129)] {
            XCTAssertNil(JournalRequest.validSession(value))
        }
        for user in [
            #"{"session_id":42}"#, #"{"parent_session_id":"parent-session-0001"}"#,
            #"{bad_session_legacy-session-0001"#, #"{"session_id":" bad-session-0001"}"#
        ] {
            XCTAssertNil(JournalRequest.session(headers: [], body: ["metadata": ["user_id": user]]))
        }
        XCTAssertEqual(JournalRequest.session(headers: [], body: ["metadata": ["user_id": "user_session_first-0001_session_last-session-0001"]]), "last-session-0001")
        XCTAssertNil(JournalRequest.session(headers: [], body: ["request": ["metadata": ["user_id": #"{"session_id":"nested-session-0001"}"#]]]))
    }

    func testAdmissionAndProviderTable() {
        let admitted = [
            "/v1/messages", "/v1/chat/completions", "/v1/completions", "/v1/responses",
            "/backend-api/codex/responses", "/v1/responses/compact", "/backend-api/codex/responses/compact",
            "/v1/alpha/search", "/backend-api/codex/alpha/search", "/v1/images/generations", "/v1/images/edits",
            "/v1/videos", "/v1/videos/generations", "/v1/videos/edits", "/v1/videos/extensions", "/openai/v1/videos",
            "/v1/audio/speech", "/v1/tts", "/v1/live", "/v1/realtime", "/v1/realtime/calls", "/v1/realtime/translations",
            "/v1beta/interactions", "/v1beta/models/gemini-3:generateContent", "/v1beta/models/gemini-3:streamGenerateContent"
        ]
        for path in admitted {
            XCTAssertTrue(JournalRequest.admitted(method: "POST", path: path + "?query=1"), path)
            XCTAssertFalse(JournalRequest.admitted(method: "GET", path: path), path)
        }
        for path in ["/api/v1/responses", "/v1/responses/extra", "/v1/messages/count_tokens",
                     "/v1/models", "/health", "/oauth/callback", "/management", "/v1/realtime/sessions",
                     "/v1/realtime/client_secrets", "/v1/realtime/calls/123/accept",
                     "/v1beta/models/:generateContent", "/v1beta/models/a/b:generateContent", "/v1beta/models/gemini:countTokens"] {
            XCTAssertFalse(JournalRequest.admitted(method: "POST", path: path), path)
        }
        for (model, path, provider) in [
            ("claude-a", "/v1/responses", "claude"), ("gemini-claude-a", "/v1/responses", "claude"),
            ("ag-c55s-high", "/v1/responses", "claude"), ("ag-c55o-high", "/v1/responses", "claude"),
            ("ag-c46s-thinking", "/v1/responses", "claude"), ("ag-c46o-thinking", "/v1/responses", "claude"),
            ("gemini-a", "/v1/responses", "gemini"), ("custom", "/v1beta/interactions", "gemini"),
            ("gpt-a", "/v1/messages", "codex"), ("codex-a", "/v1/responses", "codex"),
            ("custom", "/backend-api/codex/responses", "codex"), ("custom", "/v1/alpha/search", "codex"),
            ("custom", "/v1/messages", "claude"), ("custom", "/v1/responses", "openai"),
            ("GPT-a", "/openai/v1/videos", "openai"), ("custom", "/other", "unknown")
        ] {
            XCTAssertEqual(JournalRequest.provider(model: model, path: path), provider)
        }
        let native = JournalRequest(endpoint: "/v1beta/models/gemini-3:generateContent?x=1", forwardedEndpoint: "/v1beta/models/gemini-3:generateContent", headers: [], body: [:])
        XCTAssertEqual(native.model, "gemini-3")
        XCTAssertNil(JournalRequest(endpoint: "/v1beta/interactions", forwardedEndpoint: "/v1beta/interactions", headers: [], body: ["agent": "agent-1"]).model)
    }

    private func sampleRecord() throws -> JournalRecord {
        let fixture = try XCTUnwrap(cases().first)
        return try replay(fixture, chunks: [Data((fixture["response"] as! String).utf8)])
    }

    func testWriterModesMonthAndTornTail() throws {
        let journal = directory.appendingPathComponent("journal")
        let writer = JournalWriter(directory: journal)
        var record = try sampleRecord()
        record.started_at = "2026-10-31T23:59:59.999Z"
        try writer.append(record)
        let file = journal.appendingPathComponent("requests-2026-10.jsonl")
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: journal.path)[.posixPermissions] as? Int, 0o700)
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? Int, 0o600)
        let initial = try Data(contentsOf: file)
        let handle = try FileHandle(forWritingTo: file)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("{torn".utf8))
        try handle.close()
        try writer.append(record)
        let repaired = try String(contentsOf: file).split(separator: "\n")
        XCTAssertEqual(repaired.count, 2)
        for line in repaired {
            XCTAssertEqual(try JSONDecoder().decode(JournalRecord.self, from: Data(line.utf8)), record)
        }
        try Data("no-complete-line".utf8).write(to: file)
        try writer.append(record)
        XCTAssertEqual(try JSONDecoder().decode(JournalRecord.self, from: Data(contentsOf: file)), record)
        XCTAssertEqual(try Data(contentsOf: file).count, initial.count)
    }

    func testWriterRejectsSymlinksAndNonRegularFiles() throws {
        let journal = directory.appendingPathComponent("journal")
        let target = directory.appendingPathComponent("target")
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: journal, withDestinationURL: target)
        let writer = JournalWriter(directory: journal)
        let record = try sampleRecord()
        XCTAssertThrowsError(try writer.append(record))
        try FileManager.default.removeItem(at: journal)
        try FileManager.default.createDirectory(at: journal, withIntermediateDirectories: true)
        let file = journal.appendingPathComponent("requests-2026-11.jsonl")
        let other = directory.appendingPathComponent("other")
        try Data("untouched".utf8).write(to: other)
        try FileManager.default.createSymbolicLink(at: file, withDestinationURL: other)
        XCTAssertThrowsError(try writer.append(record))
        XCTAssertEqual(try String(contentsOf: other), "untouched")
        try FileManager.default.removeItem(at: file)
        XCTAssertEqual(mkfifo(file.path, 0o600), 0)
        XCTAssertThrowsError(try writer.append(record))
    }

    func testTwoWriterHandlesDoNotInterleaveLines() throws {
        let journal = directory.appendingPathComponent("journal")
        let a = JournalWriter(directory: journal)
        let b = JournalWriter(directory: journal)
        let record = try sampleRecord()
        let errors = NSLock()
        var failures: [Error] = []
        DispatchQueue.concurrentPerform(iterations: 40) { i in
            do { try (i.isMultiple(of: 2) ? a : b).append(record) }
            catch { errors.lock(); failures.append(error); errors.unlock() }
        }
        XCTAssertTrue(failures.isEmpty, "\(failures)")
        let lines = try String(contentsOf: journal.appendingPathComponent("requests-2026-11.jsonl")).split(separator: "\n")
        XCTAssertEqual(lines.count, 40)
        for line in lines {
            XCTAssertEqual(try JSONDecoder().decode(JournalRecord.self, from: Data(line.utf8)), record)
        }
    }

    func testQueueOverflowReturnsWithoutWaitingAndCountsWriteErrors() throws {
        let journal = directory.appendingPathComponent("journal")
        let writer = JournalWriter(directory: journal, capacity: 1)
        let record = try sampleRecord()
        try writer.append(record)
        let fd = open(journal.appendingPathComponent("requests-2026-11.jsonl").path, O_RDWR)
        XCTAssertGreaterThanOrEqual(fd, 0)
        defer { close(fd) }
        XCTAssertEqual(flock(fd, LOCK_EX), 0)
        writer.enqueue(record)
        writer.enqueue(record)
        XCTAssertEqual(writer.counters.drops, 1)
        XCTAssertEqual(flock(fd, LOCK_UN), 0)
        writer.flush()
        XCTAssertEqual(writer.counters.errors, 0)
        let denied = directory.appendingPathComponent("denied")
        try Data().write(to: denied)
        let badWriter = JournalWriter(directory: denied.appendingPathComponent("journal"))
        badWriter.enqueue(record)
        badWriter.flush()
        XCTAssertEqual(badWriter.counters.errors, 1)
    }

    func testSeatIndexAndReplacementRevalidation() throws {
        XCTAssertEqual(JournalSeatIndex.index(type: "ClAuDe", path: "/tmp/auth/../auth/seat.json"), "00ca8bd6864a1ba4")
        let auth = directory.appendingPathComponent("auth")
        try FileManager.default.createDirectory(at: auth, withIntermediateDirectories: true)
        let file = auth.appendingPathComponent("seat.json")
        try Data(#"{"type":"claude","email":"old@example.invalid","organization":{"uuid":"org-old"},"access_token":"never-record"}"#.utf8).write(to: file)
        let seats = JournalSeatIndex(directory: auth)
        let index = JournalSeatIndex.index(type: "claude", path: file.path)
        let bound = try XCTUnwrap(seats.bind(index))
        XCTAssertEqual(bound.identity.email, "old@example.invalid")
        XCTAssertEqual(bound.identity.org, "org-old")
        XCTAssertTrue(bound.isValid())
        try Data(#"{"type":"claude","email":"new@example.invalid"}"#.utf8).write(to: file, options: .atomic)
        XCTAssertFalse(bound.isValid())
        XCTAssertEqual(seats.bind(index)?.identity.email, "new@example.invalid")
        try FileManager.default.removeItem(at: file)
        XCTAssertFalse(bound.isValid())
    }

    func testUnreadableSeatLosesIdentityWithoutFingerprintChange() throws {
        let file = directory.appendingPathComponent("seat.json")
        try Data(#"{"type":"codex","account_id":"account-old"}"#.utf8).write(to: file)
        let seats = JournalSeatIndex(directory: directory)
        let bound = try XCTUnwrap(seats.bind(JournalSeatIndex.index(type: "codex", path: file.path)))
        XCTAssertEqual(bound.identity.account_id, "account-old")
        XCTAssertEqual(chmod(file.path, 0), 0)
        defer { chmod(file.path, 0o600) }
        XCTAssertFalse(bound.isValid())
    }

    func testMidRequestSeatReplacementEmitsOnlyIndexAndRole() throws {
        let file = directory.appendingPathComponent("seat.json")
        try Data(#"{"type":"claude","email":"old@example.invalid"}"#.utf8).write(to: file)
        let seats = JournalSeatIndex(directory: directory)
        let index = JournalSeatIndex.index(type: "claude", path: file.path)
        var record: JournalRecord?
        let observation = ResponseObservation(
            request: JournalRequest(endpoint: "/v1/messages", forwardedEndpoint: "/v1/messages", headers: [], body: [:]),
            bindSeat: seats.bind, emit: { record = $0 })
        observation.feed(Data("HTTP/1.1 200 OK\r\nX-CPA-TRACE-ID: 20261111100000-\(index)-019a7140-0000-7000-8000-000000000001\r\nContent-Length: 2\r\n\r\n".utf8))
        try Data(#"{"type":"claude","email":"replacement@example.invalid"}"#.utf8).write(to: file, options: .atomic)
        observation.feed(Data("{}".utf8))
        observation.finish(.delivered)
        XCTAssertEqual(record?.seat, JournalSeat(auth_index: index, role: "served"))
    }
}

/// Minimal evaluator for the pinned schema's vocabulary, not a production validator.
struct JournalSchema {
    let root: [String: Any]
    init(data: Data) throws { root = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any]) }
    static func bundled() throws -> JournalSchema {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "request-journal-v1.schema.json", withExtension: nil, subdirectory: "Contract"))
        return try JournalSchema(data: Data(contentsOf: url))
    }
    func valid(_ value: Any) -> Bool { valid(value, schema: root) }

    private func valid(_ value: Any, schema s: [String: Any]) -> Bool {
        if let ref = s["$ref"] as? String {
            let name = String(ref.split(separator: "/").last!)
            guard let defs = root["$defs"] as? [String: Any], let target = defs[name] as? [String: Any] else { return false }
            return valid(value, schema: target)
        }
        if let any = s["anyOf"] as? [[String: Any]], !any.contains(where: { valid(value, schema: $0) }) { return false }
        if let all = s["allOf"] as? [[String: Any]], !all.allSatisfy({ valid(value, schema: $0) }) { return false }
        if let condition = s["if"] as? [String: Any] {
            let branch = s[valid(value, schema: condition) ? "then" : "else"] as? [String: Any] ?? [:]
            if !valid(value, schema: branch) { return false }
        }
        if let types = (s["type"] as? [String]) ?? (s["type"] as? String).map({ [$0] }) {
            let matches = types.contains {
                switch $0 {
                case "null": return value is NSNull
                case "string": return value is String
                case "object": return value is NSDictionary
                case "integer":
                    guard let n = value as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID() else { return false }
                    return n.doubleValue.rounded() == n.doubleValue
                default: return false
                }
            }
            if !matches { return false }
        }
        if let expected = s["const"], !equal(value, expected) { return false }
        if let choices = s["enum"] as? [Any], !choices.contains(where: { equal(value, $0) }) { return false }
        if let text = value as? String {
            if let pattern = s["pattern"] as? String, text.range(of: pattern, options: .regularExpression) == nil { return false }
            if let min = s["minLength"] as? Int, text.count < min { return false }
        }
        if let number = value as? NSNumber {
            if let min = s["minimum"] as? Double, number.doubleValue < min { return false }
            if let max = s["maximum"] as? Double, number.doubleValue > max { return false }
        }
        if let object = value as? [String: Any] {
            let props = s["properties"] as? [String: [String: Any]] ?? [:]
            if let required = s["required"] as? [String], !required.allSatisfy({ object[$0] != nil }) { return false }
            if s["additionalProperties"] as? Bool == false, !object.keys.allSatisfy({ props[$0] != nil }) { return false }
            for (key, subschema) in props {
                if let field = object[key], !valid(field, schema: subschema) { return false }
            }
        }
        return true
    }

    private func equal(_ a: Any, _ b: Any) -> Bool {
        (a as? NSObject)?.isEqual(b) == true
    }
}
