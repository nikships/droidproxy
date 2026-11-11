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
        XCTAssertTrue(manifest.contains("e5e76a9d4343e1f89845f47f2e9fa792f757b07f"))
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

    /// Contract replay: whole, bytewise, and every two-read split (every 509th offset over 64 KiB).
    func testEveryTranscriptAtEverySplitAndBytewise() throws {
        let schema = try JournalSchema(data: resource("request-journal-v1.schema.json"))
        var dumped = Data()
        for fixture in try cases() {
            let raw = try XCTUnwrap(fixture["response"] as? String)
            let bytes = Data(try raw.unicodeScalars.map { try XCTUnwrap(UInt8(exactly: $0.value)) })
            let name = try XCTUnwrap(fixture["name"] as? String)
            let expected = try XCTUnwrap(fixture["expect"] as? NSDictionary)
            let splits = bytes.count > 64 * 1024 ? Array(stride(from: 509, to: bytes.count, by: 509)) : Array(0...bytes.count)
            var replays: [(String, [Data])] = [("whole", [bytes]), ("bytewise", bytes.map { Data([$0]) })]
            replays += splits.map { ("split \($0)", [Data(bytes.prefix($0)), Data(bytes.dropFirst($0))]) }
            var mismatches: [String] = []
            for (label, reads) in replays {
                let record = try replay(fixture, reads: reads)
                if let difference = try difference(record, expected: expected, fixture: fixture) {
                    mismatches.append("\(label): \(difference)")
                }
                if label == "whole" {
                    XCTAssertTrue(schema.valid(try object(record)), name)
                    dumped.append(try JSONEncoder().encode(record))
                    dumped.append(10)
                }
            }
            XCTAssertTrue(mismatches.isEmpty, "\(name): \(mismatches.count) of \(replays.count) replays differ; first \(mismatches.first ?? "")")
        }
        if let path = ProcessInfo.processInfo.environment["JOURNAL_RECORDS_PATH"] {
            try dumped.write(to: URL(fileURLWithPath: path))
        }
    }

    private func difference(_ record: JournalRecord, expected: NSDictionary, fixture: [String: Any]) throws -> String? {
        let actual = try object(record).mutableCopy() as! NSMutableDictionary
        if (fixture["nondeterministic_fields"] as? [String])?.contains("execution_id") == true {
            guard record.execution_id.range(of: "^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$", options: .regularExpression) != nil else {
                return "execution_id \(record.execution_id) is not a UUIDv4"
            }
            actual["execution_id"] = expected["execution_id"]
        }
        guard actual != expected else { return nil }
        let keys = Set(actual.allKeys.compactMap { $0 as? String }).union(expected.allKeys.compactMap { $0 as? String })
        return keys.sorted().filter { !((actual[$0] as? NSObject)?.isEqual(expected[$0]) ?? (expected[$0] == nil)) }
            .map { "\($0)=\(actual[$0] ?? "absent") want \(expected[$0] ?? "absent")" }.joined(separator: ", ")
    }

    /// Each read returns at first_body_elapsed_ms and is written to the client, completing at ended_at;
    /// the end signal arrives at end_signal_elapsed_ms (default ended_at).
    private func replay(_ fixture: [String: Any], reads: [Data]) throws -> JournalRecord {
        let req = try XCTUnwrap(fixture["request"] as? [String: Any])
        let path = try XCTUnwrap(req["endpoint"] as? String)
        let forwarded = (fixture["expect"] as? [String: Any])?["forwarded_endpoint"] as? String
        let headers = try XCTUnwrap(req["headers"] as? [String: String]).map { ($0.key, $0.value) }
        let body = try (req["body_raw"] as? String) ?? String(decoding: JSONSerialization.data(withJSONObject: XCTUnwrap(req["body"])), as: UTF8.self)
        let obs = try XCTUnwrap(fixture["observation"] as? [String: Any])
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let start = try XCTUnwrap(f.date(from: XCTUnwrap(obs["started_at"] as? String)))
        let end = try XCTUnwrap(f.date(from: XCTUnwrap(obs["ended_at"] as? String)))
        let writeAt = Int((end.timeIntervalSince(start) * 1000).rounded())
        let readAt = try XCTUnwrap(obs["first_body_elapsed_ms"] as? Int)
        let signalAt = obs["end_signal_elapsed_ms"] as? Int ?? writeAt
        let failsAt = obs["end_signal"] as? String == "client_write_failed" ? try XCTUnwrap(obs["client_write_fails_at"] as? Int) : nil
        let clock = JournalTestClock(start: start)
        let seats = try XCTUnwrap(fixture["seat_snapshot"] as? [[String: Any]]).map {
            try JSONDecoder().decode(JournalSeat.self, from: JSONSerialization.data(withJSONObject: $0))
        }
        var results: [JournalRecord] = []
        let observation = ResponseObservation(
            request: journalRequest(path, forwarded: forwarded, headers: headers, body: body),
            clock: { clock.now },
            bindSeat: { index in
                guard let seat = seats.first(where: { $0.auth_index == index }) else { return nil }
                return JournalSeatBinding(identity: seat, isValid: { true })
            }, emit: { results.append($0()) })
        var offset = 0
        var failed = false
        for read in reads where !read.isEmpty {
            if let failsAt, failsAt >= offset, failsAt < offset + read.count {
                let accepted = failsAt - offset
                failWrite(observation, accepted: Data(read.prefix(accepted)), undelivered: Data(read.dropFirst(accepted)),
                          clock: clock, readAt: readAt, writeAt: writeAt)
                failed = true
                break
            }
            deliver(observation, read, clock: clock, readAt: readAt, writeAt: writeAt)
            offset += read.count
        }
        if !failed {
            clock.now = clock.at(signalAt)
            observation.finish(.eof)
        }
        observation.finish(.upstreamError)
        XCTAssertEqual(results.count, 1)
        return try XCTUnwrap(results.first)
    }

    func testSessionPrecedenceAndStrictGrammar() {
        let body = #"{"prompt_cache_key":"body-session-0001","metadata":{"user_id":"user_session_legacy-session-0001"}}"#
        XCTAssertEqual(journalSession([("X-Session-ID", "bad id"), ("x-session-id", "\tHeader-Session:0001 ")], body), "Header-Session:0001")
        XCTAssertEqual(journalSession([("X-Session-ID", "bad"), ("X-Claude-Code-Session-Id", "second-header-0001")], body), "second-header-0001")
        XCTAssertEqual(journalSession([], body), "body-session-0001")
        for value in ["", "short", " bad-session-0001", "bad-session-0001 ", "bad-session-0001\n", "å-session-0001", String(repeating: "a", count: 129)] {
            XCTAssertNil(JournalRequest.validSession(value))
        }
        for user in [
            #"{"session_id":42}"#, #"{"parent_session_id":"parent-session-0001"}"#,
            #"{bad_session_legacy-session-0001"#, #"{"session_id":" bad-session-0001"}"#
        ] {
            let body = String(decoding: try! JSONSerialization.data(withJSONObject: ["metadata": ["user_id": user]]), as: UTF8.self)
            XCTAssertNil(journalSession([], body), user)
        }
        XCTAssertEqual(journalSession([], #"{"metadata":{"user_id":"user_session_first-0001_session_last-session-0001"}}"#), "last-session-0001")
        XCTAssertNil(journalSession([], #"{"request":{"metadata":{"user_id":"{\"session_id\":\"nested-session-0001\"}"}}}"#))
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
        let native = journalRequest("/v1beta/models/gemini-3:generateContent?x=1", forwarded: "/v1beta/models/gemini-3:generateContent")
        XCTAssertEqual(native.fields.model, "gemini-3")
        XCTAssertNil(journalRequest("/v1beta/interactions", body: #"{"agent":"agent-1"}"#).fields.model)
    }

    private func sampleRecord() throws -> JournalRecord {
        let fixture = try XCTUnwrap(cases().first)
        return try replay(fixture, reads: [Data((fixture["response"] as! String).utf8)])
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
        let line = String(decoding: initial, as: UTF8.self)
        XCTAssertTrue(line.contains(#""endpoint":"\#(record.endpoint)""#), line)
        XCTAssertFalse(line.contains(#"\/"#), line)
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
        writer.enqueue { record }
        writer.enqueue { record }
        XCTAssertEqual(writer.counters.drops, 1)
        XCTAssertEqual(flock(fd, LOCK_UN), 0)
        writer.flush()
        XCTAssertEqual(writer.counters.errors, 0)
        let denied = directory.appendingPathComponent("denied")
        try Data().write(to: denied)
        let badWriter = JournalWriter(directory: denied.appendingPathComponent("journal"))
        badWriter.enqueue { record }
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
        let bound = DispatchSemaphore(value: 0)
        let observation = ResponseObservation(request: journalRequest("/v1/messages"), bindSeat: { index in
            defer { bound.signal() }
            return seats.bind(index)
        }, emit: { record = $0() })
        deliver(observation, Data("HTTP/1.1 200 OK\r\nX-CPA-TRACE-ID: 20261111100000-\(index)-019a7140-0000-7000-8000-000000000001\r\nContent-Length: 2\r\n\r\n".utf8))
        XCTAssertEqual(bound.wait(timeout: .now() + 3), .success)
        try Data(#"{"type":"claude","email":"replacement@example.invalid"}"#.utf8).write(to: file, options: .atomic)
        deliver(observation, Data("{}".utf8))
        XCTAssertEqual(record?.seat, JournalSeat(auth_index: index, role: "served"))
    }

    func testSeatFileRulesBindOnlyOwnedRegularJSONFiles() throws {
        let auth = directory.appendingPathComponent("auth")
        try FileManager.default.createDirectory(at: auth, withIntermediateDirectories: true)
        func write(_ name: String, _ email: String) throws -> String {
            let url = auth.appendingPathComponent(name)
            try Data(#"{"type":"claude","email":"\#(email)"}"#.utf8).write(to: url)
            return JournalSeatIndex.index(type: "claude", path: url.path)
        }
        let regular = try write("regular.json", "seat@example.invalid")
        let upper = try write("upper.JSON", "upper@example.invalid")
        let backslash = try write(#"back\slash.json"#, "slash@example.invalid")
        let target = directory.appendingPathComponent("target.json")
        try Data(#"{"type":"claude","email":"link@example.invalid"}"#.utf8).write(to: target)
        let link = auth.appendingPathComponent("link.json")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        XCTAssertEqual(mkfifo(auth.appendingPathComponent("fifo.json").path, 0o600), 0)
        let fifoTarget = directory.appendingPathComponent("fifo-target")
        XCTAssertEqual(mkfifo(fifoTarget.path, 0o600), 0)
        try FileManager.default.createSymbolicLink(at: auth.appendingPathComponent("fifo-link.json"), withDestinationURL: fifoTarget)
        try FileManager.default.createSymbolicLink(at: auth.appendingPathComponent("device-link.json"), withDestinationURL: URL(fileURLWithPath: "/dev/null"))
        let seats = JournalSeatIndex(directory: auth)
        seats.refresh()
        XCTAssertEqual(seats.bind(regular)?.identity,
                       JournalSeat(auth_index: regular, role: "served", file: "regular.json", email: "seat@example.invalid"))
        XCTAssertNil(seats.bind(upper))
        XCTAssertNil(seats.bind(JournalSeatIndex.index(type: "claude", path: link.path)))
        let slash = try XCTUnwrap(seats.bind(backslash))
        XCTAssertNil(slash.identity.file)
        XCTAssertEqual(slash.identity.email, "slash@example.invalid")
        var record = try sampleRecord()
        record.seat = slash.identity
        XCTAssertTrue(try JournalSchema.bundled().valid(object(record)))
    }

    func testIdentityReadsOnlyListedMembersWithClaudeOrgPrecedence() throws {
        let auth = directory.appendingPathComponent("auth")
        try FileManager.default.createDirectory(at: auth, withIntermediateDirectories: true)
        let file = auth.appendingPathComponent("seat.json")
        let cases: [(String, String?, String?, String?)] = [
            (#"{"type":"claude","organization_uuid":"org-a","organization":{"uuid":"org-b"}}"#, "org-a", nil, nil),
            (#"{"type":"claude","organization_uuid":"","organization":{"uuid":"org-b"}}"#, "org-b", nil, nil),
            (#"{"type":"claude","organization_uuid":7,"organization":{"uuid":"org-b"}}"#, "org-b", nil, nil),
            (#"{"type":"claude","organization":{"organization_uuid":"org-c"},"account_id":"acct"}"#, nil, nil, nil),
            (#"{"type":"claude","email":"first@example.invalid","email":"last@example.invalid","organization":{"uuid":"org-b","uuid":"org-d"}}"#, "org-d", "last@example.invalid", nil),
            (#"{"type":"claude","email":" padded@example.invalid ","access_token":{"nested":[1,2,{"x":"y"}]}}"#, nil, " padded@example.invalid ", nil),
            (#"{"type":"codex","account_id":"acct-top","tokens":{"account_id":"acct-nested"},"organization_uuid":"org"}"#, nil, nil, "acct-top"),
            (#"{"type":"codex","tokens":{"account_id":"acct-nested"}}"#, nil, nil, nil)
        ]
        for (json, org, email, account) in cases {
            try Data(json.utf8).write(to: file, options: .atomic)
            let type = json.contains(#""type":"codex""#) ? "codex" : "claude"
            let identity = try XCTUnwrap(JournalSeatIndex(directory: auth).bind(JournalSeatIndex.index(type: type, path: file.path))?.identity, json)
            XCTAssertEqual(identity.org, org, json)
            XCTAssertEqual(identity.email, email, json)
            XCTAssertEqual(identity.account_id, account, json)
        }
        try Data(#"{"type":"claude","email":"x@example.invalid",}"#.utf8).write(to: file, options: .atomic)
        XCTAssertNil(JournalSeatIndex(directory: auth).bind(JournalSeatIndex.index(type: "claude", path: file.path)))
    }

    func testSeatFileWithInvalidUTF8InAnUnreadMemberIsNotIndexed() throws {
        let auth = directory.appendingPathComponent("auth")
        try FileManager.default.createDirectory(at: auth, withIntermediateDirectories: true)
        let cases: [(name: String, bytes: [UInt8], strict: Bool)] = [
            ("valid two-byte sequence", [0xc3, 0xa9], true),
            ("0xff", [0xff], false),
            ("overlong", [0xc0, 0xaf], false),
            ("surrogate", [0xed, 0xa0, 0x80], false)
        ]
        for (i, c) in cases.enumerated() {
            let json = Data(#"{"type":"claude","email":"seat@example.invalid","organization_uuid":"org-1","access_token":"a"#.utf8)
                + c.bytes + Data(#"b"}"#.utf8)
            try json.write(to: auth.appendingPathComponent("claude-\(i).json"))
        }
        let seats = JournalSeatIndex(directory: auth)
        for (i, c) in cases.enumerated() {
            let name = "claude-\(i).json"
            let index = JournalSeatIndex.index(type: "claude", path: auth.appendingPathComponent(name).path)
            var builder: (() -> JournalRecord)?
            let observation = ResponseObservation(request: journalRequest("/v1/messages"), bindSeat: seats.bind, emit: { builder = $0 })
            deliver(observation, Data("HTTP/1.1 200 OK\r\nX-CPA-TRACE-ID: 20261111100000-\(index)-019a7140-0000-7000-8000-000000000001\r\nContent-Length: 2\r\n\r\n{}".utf8))
            let expected = c.strict
                ? JournalSeat(auth_index: index, role: "served", file: name, email: "seat@example.invalid", org: "org-1")
                : JournalSeat(auth_index: index, role: "served")
            XCTAssertEqual(try XCTUnwrap(builder?(), c.name).seat, expected, c.name)
        }
    }

    private func lockedJournal(log: @escaping (String) -> Void = { _ in }) throws -> (JournalWriter, JournalRecord, URL, Int32) {
        let journal = directory.appendingPathComponent("journal")
        let writer = JournalWriter(directory: journal, log: log)
        let record = try sampleRecord()
        try writer.append(record)
        let file = journal.appendingPathComponent("requests-2026-11.jsonl")
        let fd = open(file.path, O_RDWR)
        XCTAssertGreaterThanOrEqual(fd, 0)
        XCTAssertEqual(flock(fd, LOCK_EX), 0)
        return (writer, record, file, fd)
    }

    func testLockWaitIsBoundedAndCountsTheRecordAsDropped() throws {
        let (writer, record, file, fd) = try lockedJournal()
        defer { flock(fd, LOCK_UN); close(fd) }
        writer.enqueue { record }
        let gaveUp = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in writer.counters.drops == 1 }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [gaveUp], timeout: 5), .completed)
        XCTAssertEqual(writer.counters.errors, 0)
        XCTAssertEqual(try String(contentsOf: file).split(separator: "\n").count, 1)
    }

    func testShutdownFlushIsBoundedAndCountsWhatRemains() throws {
        let (writer, record, file, fd) = try lockedJournal()
        defer { flock(fd, LOCK_UN); close(fd) }
        for _ in 0..<3 { writer.enqueue { record } }
        let returned = DispatchSemaphore(value: 0)
        let started = Date()
        DispatchQueue.global().async { writer.flush(); returned.signal() }
        XCTAssertEqual(returned.wait(timeout: .now() + 5), .success)
        XCTAssertLessThan(Date().timeIntervalSince(started), 4)
        let counted = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in writer.counters.drops == 3 }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [counted], timeout: 5), .completed)
        XCTAssertEqual(try String(contentsOf: file).split(separator: "\n").count, 1)
    }

    func testFlushReturnsWithinItsBoundWhileTheLogSinkIsStalled() throws {
        let stalled = DispatchSemaphore(value: 0)
        let (writer, record, _, fd) = try lockedJournal(log: { _ in stalled.wait() })
        defer {
            for _ in 0..<8 { stalled.signal() }
            flock(fd, LOCK_UN)
            close(fd)
        }
        for _ in 0..<2 { writer.enqueue { record } }
        let returned = DispatchSemaphore(value: 0)
        DispatchQueue.global().async { writer.flush(timeout: 0.2); returned.signal() }
        XCTAssertEqual(returned.wait(timeout: .now() + 2), .success)
    }

    func testSeatRefreshContentionDoesNotHoldTheRelayOrFinalization() throws {
        let auth = directory.appendingPathComponent("auth")
        try FileManager.default.createDirectory(at: auth, withIntermediateDirectories: true)
        let file = auth.appendingPathComponent("seat.json")
        try Data(#"{"type":"claude","email":"seat@example.invalid"}"#.utf8).write(to: file)
        let payload = Data((#"{"type":"claude","data":["# + String(repeating: "1,", count: 500_000) + "1]}").utf8)
        for i in 0..<40 { try payload.write(to: auth.appendingPathComponent("bulk\(i).json")) }
        let index = JournalSeatIndex.index(type: "claude", path: file.path)
        let seats = JournalSeatIndex(directory: auth)
        XCTAssertNotNil(seats.bind(index))
        var builder: (() -> JournalRecord)?
        let observation = ResponseObservation(request: journalRequest("/v1/messages"), bindSeat: seats.bind, emit: { builder = $0 })
        let entered = DispatchSemaphore(value: 0), refreshed = DispatchSemaphore(value: 0)
        DispatchQueue.global().async { entered.signal(); seats.refresh(); refreshed.signal() }
        entered.wait()
        usleep(10_000)
        var start = DispatchTime.now().uptimeNanoseconds
        deliver(observation, Data("HTTP/1.1 200 OK\r\nX-CPA-TRACE-ID: 20261111100000-\(index)-019a7140-0000-7000-8000-000000000001\r\nContent-Length: 2\r\n\r\n".utf8))
        let traced = Double(DispatchTime.now().uptimeNanoseconds - start) / 1e6
        start = DispatchTime.now().uptimeNanoseconds
        deliver(observation, Data("{}".utf8))
        let finalized = Double(DispatchTime.now().uptimeNanoseconds - start) / 1e6
        XCTAssertEqual(refreshed.wait(timeout: .now() + 10), .success)
        XCTAssertLessThan(traced, 1, "learning the trace waited \(traced) ms for the seat index")
        XCTAssertLessThan(finalized, 1, "finalization waited \(finalized) ms for the seat index")
        let record = try XCTUnwrap(builder?())
        XCTAssertEqual(record.outcome, "complete")
        XCTAssertEqual(record.seat?.email, "seat@example.invalid")
    }

    private func journalLines(_ journal: URL) throws -> Int {
        let file = journal.appendingPathComponent("requests-2026-11.jsonl")
        guard FileManager.default.fileExists(atPath: file.path) else { return 0 }
        return try String(contentsOf: file).split(separator: "\n").count
    }

    func testEnqueueAndDropAccountingNeverWaitForWriterState() throws {
        let journal = directory.appendingPathComponent("journal")
        let writer = JournalWriter(directory: journal, capacity: 1, log: { _ in })
        let record = try sampleRecord()
        let available = millisecondsWithLocksHeld(in: [writer]) { writer.enqueue { record } }
        XCTAssertLessThan(available, 10, "enqueue with a free slot waited \(available) ms")
        let active = DispatchSemaphore(value: 0), gate = DispatchSemaphore(value: 0)
        writer.enqueue { active.signal(); gate.wait(); return record }
        XCTAssertEqual(active.wait(timeout: .now() + 3), .success)
        let full = millisecondsWithLocksHeld(in: [writer]) { writer.enqueue { record } }
        XCTAssertLessThan(full, 10, "dropping on a full queue waited \(full) ms")
        gate.signal()
        writer.flush()
        let counted = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in writer.counters.drops == 2 }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [counted], timeout: 3), .completed)
        XCTAssertEqual(try journalLines(journal), 1)
    }

    func testObservationCallsNeverWaitForJournalState() throws {
        let auth = directory.appendingPathComponent("auth"), journal = directory.appendingPathComponent("journal")
        try FileManager.default.createDirectory(at: auth, withIntermediateDirectories: true)
        let file = auth.appendingPathComponent("seat.json")
        try Data(#"{"type":"claude","email":"seat@example.invalid"}"#.utf8).write(to: file)
        let seats = JournalSeatIndex(directory: auth)
        let writer = JournalWriter(directory: journal, log: { _ in })
        let head = "HTTP/1.1 200 OK\r\nX-CPA-TRACE-ID: 20261111100000-\(JournalSeatIndex.index(type: "claude", path: file.path))"
            + "-019a7140-0000-7000-8000-000000000001\r\nContent-Length: 2\r\n\r\n"
        func observation() -> ResponseObservation {
            ResponseObservation(request: journalRequest("/v1/messages"), bindSeat: seats.bind, emit: writer.enqueue)
        }
        deliver(observation(), Data((head + "{}").utf8))
        writer.flush()
        let (delivering, failing, finishing) = (observation(), observation(), observation())
        let calls: [(String, () -> Void)] = [
            ("delivered", { deliver(delivering, Data((head + "{}").utf8)) }),
            ("writeFailed", { failWrite(failing, accepted: Data(head.utf8), undelivered: Data("{}".utf8)) }),
            ("delivered head", { deliver(finishing, Data(head.utf8)) }),
            ("finish", { finishing.finish(.eof) })
        ]
        for (name, call) in calls {
            let elapsed = millisecondsWithLocksHeld(in: [delivering, failing, finishing, writer, seats], call)
            XCTAssertLessThan(elapsed, 10, "\(name) waited \(elapsed) ms")
        }
        let counted = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in writer.counters.drops == 3 }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [counted], timeout: 3), .completed)
        writer.flush()
        XCTAssertEqual(try journalLines(journal), 1)
    }

    func testFlushDeadlineCountsQueuedAndInFlightRecordsOnceAndNeverWritesThem() throws {
        let logged = NSLock()
        var lines: [String] = []
        let (writer, record, _, fd) = try lockedJournal(log: { line in logged.lock(); lines.append(line); logged.unlock() })
        var locked = true
        defer { if locked { flock(fd, LOCK_UN) }; close(fd) }
        for _ in 0..<8 { writer.enqueue { record } }
        usleep(100_000)
        writer.flush(timeout: 0.2)
        XCTAssertEqual(writer.counters.drops, 8)
        flock(fd, LOCK_UN)
        locked = false
        writer.flush(timeout: 5)
        XCTAssertEqual(writer.counters.drops, 8)
        XCTAssertEqual(try journalLines(directory.appendingPathComponent("journal")), 1)
        let reported = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in logged.lock(); defer { logged.unlock() }; return !lines.isEmpty }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [reported], timeout: 3), .completed)
        logged.lock()
        XCTAssertEqual(lines.first, "[RequestJournal] 8 records dropped, 0 write errors")
        logged.unlock()
    }

    func testFlushDeadlineDropsRecordsWaitingForTheirParseOrSeatWork() throws {
        let journal = directory.appendingPathComponent("journal")
        let writer = JournalWriter(directory: journal, log: { _ in })
        let body = #"{"model":"claude-fixture","values":["# + String(repeating: "1,", count: 4_000_000) + "1]}"
        ResponseObservation(request: journalRequest("/v1/messages", body: body), emit: writer.enqueue).finish(.backendUnreachable)
        let release = DispatchSemaphore(value: 0)
        let seated = ResponseObservation(request: journalRequest("/v1/messages"), bindSeat: { _ in
            _ = release.wait(timeout: .now() + 3)
            return nil
        }, emit: writer.enqueue)
        deliver(seated, Data("HTTP/1.1 200 OK\r\nX-CPA-TRACE-ID: 20261111100000-0123456789abcdef-019a7140-0000-7000-8000-000000000001\r\nContent-Length: 0\r\n\r\n".utf8))
        writer.flush(timeout: 0.05)
        XCTAssertEqual(writer.counters.drops, 2)
        release.signal()
        writer.flush(timeout: 30)
        XCTAssertEqual(writer.counters.drops, 2)
        XCTAssertEqual(writer.counters.errors, 0)
        XCTAssertEqual(try journalLines(journal), 0)
    }

    private func residentBytes() -> Int {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count) }
        }
        XCTAssertEqual(result, KERN_SUCCESS)
        return Int(info.resident_size)
    }

    /// 255 queued 5 MB requests behind a stalled writer would hold about 1.3 GB if records kept their request bodies.
    func testQueuedRecordsDoNotHoldRequestBodies() throws {
        let writer = JournalWriter(directory: directory.appendingPathComponent("journal"), log: { _ in })
        let record = try sampleRecord()
        let active = DispatchSemaphore(value: 0), gate = DispatchSemaphore(value: 0)
        writer.enqueue { active.signal(); gate.wait(); return record }
        XCTAssertEqual(active.wait(timeout: .now() + 3), .success)
        let baseline = residentBytes()
        var peak = baseline
        for i in 0..<255 {
            autoreleasepool {
                let body = #"{"model":"claude-fixture","prompt_cache_key":"session-fixture-0001","messages":[{"role":"user","content":""#
                    + String(repeating: "x", count: 5_000_000) + #""}],"id":"\#(i)"}"#
                ResponseObservation(request: journalRequest("/v1/messages", body: body), emit: writer.enqueue).finish(.backendUnreachable)
            }
            peak = max(peak, residentBytes())
        }
        writer.flush(timeout: 0)
        gate.signal()
        writer.flush(timeout: 10)
        XCTAssertLessThan(peak - baseline, 61 << 20, "peak grew \((peak - baseline) >> 20) MiB")
    }

    func testCredentialFilesOverOneMiBAreNotReadForIdentity() throws {
        let auth = directory.appendingPathComponent("auth")
        try FileManager.default.createDirectory(at: auth, withIntermediateDirectories: true)
        func write(_ name: String, size: Int) throws -> String {
            let prefix = #"{"type":"claude","email":"big@example.invalid","pad":""#
            let json = prefix + String(repeating: "a", count: size - prefix.utf8.count - 2) + #""}"#
            XCTAssertEqual(json.utf8.count, size)
            let url = auth.appendingPathComponent(name)
            try Data(json.utf8).write(to: url)
            return JournalSeatIndex.index(type: "claude", path: url.path)
        }
        let atLimit = try write("limit.json", size: 1_048_576)
        let over = try write("over.json", size: 1_048_577)
        let seats = JournalSeatIndex(directory: auth)
        XCTAssertEqual(seats.bind(atLimit)?.identity.email, "big@example.invalid")
        XCTAssertNil(seats.bind(over))
    }

    func testAuthDirectoryChangeRefreshesSeatsOffThePostingThread() throws {
        let auth = directory.appendingPathComponent("auth")
        try FileManager.default.createDirectory(at: auth, withIntermediateDirectories: true)
        let payload = Data((#"{"type":"claude","data":["# + String(repeating: "1,", count: 500_000) + "1]}").utf8)
        for i in 0..<8 { try payload.write(to: auth.appendingPathComponent("bulk\(i).json")) }
        let journal = RequestJournal(directory: directory.appendingPathComponent("journal"), authDirectory: auth)
        let start = DispatchTime.now().uptimeNanoseconds
        NotificationCenter.default.post(name: .authDirectoryChanged, object: nil)
        let posted = Double(DispatchTime.now().uptimeNanoseconds - start) / 1e6
        XCTAssertLessThan(posted, 5, "posting waited \(posted) ms for the seat refresh")
        journal.flush()
    }

    func testCachedHitRechecksBindability() throws {
        let auth = directory.appendingPathComponent("auth")
        try FileManager.default.createDirectory(at: auth, withIntermediateDirectories: true)
        let json = Data(#"{"type":"claude","email":"seat@example.invalid"}"#.utf8)
        let target = directory.appendingPathComponent("target.json")
        try json.write(to: target)
        let file = auth.appendingPathComponent("seat.json")
        try FileManager.default.createSymbolicLink(at: file, withDestinationURL: target)
        let index = JournalSeatIndex.index(type: "claude", path: file.path)
        let seats = JournalSeatIndex(directory: auth)
        XCTAssertNil(seats.bind(index))
        try FileManager.default.removeItem(at: file)
        try json.write(to: file)
        XCTAssertEqual(seats.bind(index)?.identity.email, "seat@example.invalid")
        try FileManager.default.removeItem(at: file)
        try FileManager.default.createSymbolicLink(at: file, withDestinationURL: target)
        XCTAssertNil(seats.bind(index))
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
