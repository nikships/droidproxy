import XCTest
@testable import CLIProxyMenuBar

final class ResponseObservationTests: XCTestCase {
    private let trace = "20261111100000-0123456789abcdef-019a7140-0000-7000-8000-000000000001"

    private func observe(_ raw: String, end: JournalEnd = .eof) throws -> JournalRecord {
        var records: [JournalRecord] = []
        let observation = ResponseObservation(
            request: JournalRequest(endpoint: "/v1/messages", forwardedEndpoint: "/v1/messages", headers: [], body: [:]),
            emit: { records.append($0) })
        observation.feed(Data(raw.utf8))
        observation.finish(end)
        observation.finish(.upstreamError)
        XCTAssertEqual(records.count, 1)
        let record = try XCTUnwrap(records.first)
        XCTAssertTrue(try JournalSchema.bundled().valid(JSONSerialization.jsonObject(with: JSONEncoder().encode(record))))
        return record
    }

    func testPartialFinalHeadStillReportsObservedStatus() throws {
        let r = try observe("HTTP/1.1 100 Continue\r\n\r\nHTTP/1.1 429 Too Many Requests\r\nX-Partial:")
        XCTAssertEqual(r.status, 429)
        XCTAssertEqual(r.outcome, "upstream_closed_early")
        XCTAssertNil(r.ttft_ms)
    }

    func testFramingOutcomesAndFirstFinalizerWins() throws {
        for (raw, expected) in [
            ("", "upstream_closed_early"),
            ("HTTP/1.1 200 OK\r\nContent-Length: 4\r\n\r\nab", "upstream_closed_early"),
            ("HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nab", "complete"),
            ("HTTP/1.1 200 OK\r\n\r\n{}", "complete"),
            ("HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n2\r\n{}\r\n0\r\nX-End: yes\r\n\r\n", "complete"),
            ("HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\nz\r\n", "upstream_error"),
            ("HTTP/1.1 200 OK\r\nContent-Length: invalid\r\n\r\n", "upstream_error"),
            ("HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\n\r\ndata: {}\n\n", "upstream_closed_early"),
            ("HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\n\r\nevent: error\ndata: {\"type\":\"error\"}\n\n", "upstream_error"),
            ("HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\n\r\nevent: error\ndata: {\"type\":\"overloaded_error\"}\n\n", "upstream_error"),
            ("HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\n\r\ndata: {\"error\":{\"message\":\"unavailable\"}}\n\n", "upstream_error")
        ] {
            XCTAssertEqual(try observe(raw).outcome, expected, raw)
        }
        XCTAssertEqual(try observe("", end: .backendUnreachable).status, 502)
        XCTAssertEqual(try observe("", end: .upstreamError).outcome, "upstream_error")
        let disconnected = try observe("HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\n{}", end: .clientDisconnected)
        XCTAssertEqual(disconnected.outcome, "client_disconnected")
        XCTAssertEqual(disconnected.status, 200)
    }

    func testTerminalUsageSurvivesFailedClientWrite() throws {
        let raw = "HTTP/1.1 200 OK\r\nX-CPA-TRACE-ID: \(trace)\r\nContent-Type: text/event-stream\r\n\r\n"
            + "event: message_start\ndata: {\"type\":\"message_start\",\"message\":{\"model\":\"actual-model\",\"usage\":{\"input_tokens\":3}}}\n\n"
            + "event: message_delta\ndata: {\"type\":\"message_delta\",\"usage\":{\"output_tokens\":5}}\n\n"
            + "event: message_stop\ndata: {\"type\":\"message_stop\"}\n\n"
        let r = try observe(raw, end: .clientDisconnected)
        XCTAssertEqual(r.outcome, "client_disconnected")
        XCTAssertEqual(r.tokens, JournalTokens(input_uncached: 3, cache_read: 0, cache_creation: 0, output: 5, reasoning: nil))
        XCTAssertEqual(r.response_model, "actual-model")
        XCTAssertEqual(r.seat, JournalSeat(auth_index: "0123456789abcdef", role: "served"))
    }

    func testUnsupportedAndMalformedUsageIsNullAndZeroIsKnown() throws {
        for usage in [
            #"{"input_tokens":-1,"output_tokens":3}"#,
            #"{"input_tokens":true,"output_tokens":3}"#,
            #"{"input_tokens":1.5,"output_tokens":3}"#,
            #"{"input_tokens":"1","output_tokens":3}"#,
            #"{"input_tokens":1}"#,
            #"{"input_tokens":1,"output_tokens":3,"cache_read_input_tokens":null}"#
        ] {
            let body = "{\"type\":\"message\",\"usage\":\(usage)}"
            let r = try observe("HTTP/1.1 200 OK\r\nContent-Length: \(body.utf8.count)\r\n\r\n\(body)")
            XCTAssertNil(r.tokens, usage)
        }
        let zero = #"{"type":"message","usage":{"input_tokens":0,"output_tokens":0}}"#
        XCTAssertEqual(try observe("HTTP/1.1 200 OK\r\n\r\n\(zero)").tokens,
                       JournalTokens(input_uncached: 0, cache_read: 0, cache_creation: 0, output: 0, reasoning: nil))
    }

    func testChatPartialUsageIsNotTerminalButFinalUsageSurvivesTruncation() throws {
        let head = "HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\n\r\n"
        let partial = #"data: {"choices":[{"finish_reason":null}],"usage":{"prompt_tokens":3,"completion_tokens":5}}"# + "\n\n"
        XCTAssertNil(try observe(head + partial).tokens)
        XCTAssertEqual(try observe(head + partial + "data: [DONE]\n\n").tokens?.output, 5)
        let terminal = #"data: {"choices":[],"usage":{"prompt_tokens":3,"completion_tokens":5}}"# + "\n\n"
        XCTAssertEqual(try observe(head + terminal, end: .clientDisconnected).tokens?.output, 5)
    }

    func testChunkSizeAndHeadersDoNotStartTTFTAndWallClockDoesNotSetLatency() throws {
        let wall = Date(timeIntervalSince1970: 1_700_000_000)
        var now = JournalInstant(wall: wall, monotonic: 100_000_000)
        var record: JournalRecord?
        let observation = ResponseObservation(
            request: JournalRequest(endpoint: "/v1/responses?q=1", forwardedEndpoint: "/v1/chat/completions", headers: [("X-DroidProxy-Origin", "window-primer")], body: ["model": "gemini-original"]),
            clock: { now }, emit: { record = $0 })
        now = JournalInstant(wall: wall, monotonic: 110_000_000)
        observation.feed(Data("HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n2\r\n".utf8))
        now = JournalInstant(wall: wall, monotonic: 121_999_999)
        observation.feed(Data("{}\r\n0\r\n\r\n".utf8))
        now = JournalInstant(wall: wall.addingTimeInterval(-100), monotonic: 135_999_999)
        observation.finish(.delivered)
        let r = try XCTUnwrap(record)
        XCTAssertEqual(r.ttft_ms, 21)
        XCTAssertEqual(r.latency_ms, 35)
        XCTAssertLessThan(r.ended_at, r.started_at)
        XCTAssertEqual(r.origin, "primer")
        XCTAssertEqual(r.endpoint, "/v1/responses")
        XCTAssertEqual(r.forwarded_endpoint, "/v1/chat/completions")
        XCTAssertEqual(r.requested_model, "gemini-original")
    }

    func testObservationCapsDoNotInventUsage() throws {
        let body = String(repeating: " ", count: 2 * 1024 * 1024 + 1)
        let largeJSON = try observe("HTTP/1.1 200 OK\r\nContent-Length: \(body.count)\r\n\r\n\(body)")
        XCTAssertEqual(largeJSON.outcome, "complete")
        XCTAssertNil(largeJSON.tokens)
        let line = String(repeating: "a", count: 256 * 1024 + 1)
        let largeSSE = try observe("HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nContent-Length: \(line.count)\r\n\r\n\(line)")
        XCTAssertEqual(largeSSE.outcome, "complete")
        XCTAssertNil(largeSSE.tokens)
        let head = try observe("HTTP/1.1 200 OK\r\nX-Long: \(String(repeating: "a", count: 64 * 1024))")
        XCTAssertNil(head.tokens)
        XCTAssertNil(head.ttft_ms)
    }
}
