import XCTest
@testable import CLIProxyMenuBar

final class ResponseObservationTests: XCTestCase {
    private let trace = "20261111100000-0123456789abcdef-019a7140-0000-7000-8000-000000000001"
    private let sseHead = "HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\n\r\n"
    private let chatUsage = #"data: {"choices":[],"usage":{"prompt_tokens":3,"completion_tokens":5}}"# + "\n\n"
    private let chatTokens = JournalTokens(input_uncached: 3, cache_read: 0, cache_creation: nil, output: 5, reasoning: nil)

    private func observe(_ raw: String, path: String = "/v1/messages", forwarded: String? = nil,
                         bytewise: Bool = false, end: JournalEnd = .eof) throws -> JournalRecord {
        try observe(Data(raw.utf8), path: path, forwarded: forwarded, bytewise: bytewise, end: end)
    }

    private func observe(_ bytes: Data, path: String = "/v1/messages", forwarded: String? = nil,
                         bytewise: Bool = false, end: JournalEnd = .eof) throws -> JournalRecord {
        var records: [JournalRecord] = []
        let observation = ResponseObservation(request: journalRequest(path, forwarded: forwarded), emit: { records.append($0) })
        for chunk in bytewise ? bytes.map({ Data([$0]) }) : [bytes] { deliver(observation, chunk) }
        observation.finish(end)
        observation.finish(.upstreamError)
        return try single(records)
    }

    /// Whole and bytewise replay must produce the same record.
    private func observeAnySplit(_ raw: String, path: String = "/v1/messages") throws -> JournalRecord {
        let whole = try observe(raw, path: path)
        var bytewise = try observe(raw, path: path, bytewise: true)
        bytewise.execution_id = whole.execution_id
        bytewise.started_at = whole.started_at
        bytewise.ended_at = whole.ended_at
        bytewise.latency_ms = whole.latency_ms
        bytewise.ttft_ms = whole.ttft_ms
        XCTAssertEqual(whole, bytewise, String(raw.prefix(60)))
        return whole
    }

    private func single(_ records: [JournalRecord]) throws -> JournalRecord {
        XCTAssertEqual(records.count, 1)
        let record = try XCTUnwrap(records.first)
        XCTAssertTrue(try JournalSchema.bundled().valid(JSONSerialization.jsonObject(with: JSONEncoder().encode(record))))
        return record
    }

    private func failed(_ response: Data, deliveredFirst: Int = 0, accepted: Int) throws -> JournalRecord {
        var records: [JournalRecord] = []
        let observation = ResponseObservation(request: journalRequest("/v1/messages"), emit: { records.append($0) })
        if deliveredFirst > 0 { deliver(observation, response.prefix(deliveredFirst)) }
        let rest = response.dropFirst(deliveredFirst)
        failWrite(observation, accepted: Data(rest.prefix(accepted)), undelivered: Data(rest.dropFirst(accepted)))
        observation.finish(.eof)
        return try single(records)
    }

    private func sized(_ head: String, _ body: String) -> String {
        "HTTP/1.1 200 OK\r\n\(head)Content-Length: \(body.utf8.count)\r\n\r\n\(body)"
    }

    func testPartialFinalHeadStillReportsObservedStatus() throws {
        let r = try observe("HTTP/1.1 100 Continue\r\n\r\nHTTP/1.1 429 Too Many Requests\r\nX-Partial:")
        XCTAssertEqual(r.status, 429)
        XCTAssertEqual(r.outcome, "upstream_closed_early")
        XCTAssertNil(r.ttft_ms)
        XCTAssertNil(try observe("HTTP/1.1 429 Too Many").status)
        XCTAssertNil(try observe("HTTP/1.1 100 Continue\r\n").status)
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
            (sseHead + "data: {}\n\n", "upstream_closed_early"),
            (sseHead + "event: error\ndata: {\"type\":\"error\"}\n\n", "upstream_error"),
            (sseHead + "event: error\ndata: {\"type\":\"overloaded_error\"}\n\n", "upstream_error"),
            (sseHead + "data: {\"error\":{\"message\":\"unavailable\"}}\n\n", "upstream_error")
        ] {
            XCTAssertEqual(try observe(raw).outcome, expected, raw)
        }
        XCTAssertEqual(try observe("", end: .backendUnreachable).status, 502)
        XCTAssertEqual(try observe("", end: .upstreamError).outcome, "upstream_error")
        let early = try observe("HTTP/1.1 200 OK\r\nContent-Length: 3\r\n\r\n{}", end: .upstreamError)
        XCTAssertEqual(early.outcome, "upstream_error")
        XCTAssertEqual(early.status, 200)
    }

    func testUndeliveredBytesTeachOnlyStatusAndTrace() throws {
        let json = #"{"type":"message","model":"actual-model","usage":{"input_tokens":3,"output_tokens":5}}"#
        let response = Data(sized("X-CPA-TRACE-ID: \(trace)\r\n", json).utf8)
        let statusEnd = try XCTUnwrap(response.range(of: Data("\r\n".utf8))).upperBound
        let headEnd = try XCTUnwrap(response.range(of: Data("\r\n\r\n".utf8))).upperBound
        for accepted in [0, 5, statusEnd, headEnd - 1] {
            let r = try failed(response, accepted: accepted)
            XCTAssertEqual(r.outcome, "client_disconnected", "\(accepted)")
            XCTAssertEqual(r.status, 200, "\(accepted)")
            XCTAssertEqual(r.trace_id, trace, "\(accepted)")
            XCTAssertEqual(r.seat, JournalSeat(auth_index: "0123456789abcdef", role: "served"), "\(accepted)")
            XCTAssertNil(r.tokens, "\(accepted)")
            XCTAssertNil(r.response_model, "\(accepted)")
            XCTAssertNil(r.ttft_ms, "\(accepted)")
        }
        for accepted in [headEnd, response.count - 1] {
            let r = try failed(response, accepted: accepted)
            XCTAssertEqual(r.outcome, "client_disconnected", "\(accepted)")
            XCTAssertNil(r.tokens, "\(accepted)")
            XCTAssertNil(r.response_model, "\(accepted)")
        }
        XCTAssertNil(try failed(response, accepted: headEnd).ttft_ms)
        XCTAssertNotNil(try failed(response, accepted: headEnd + 1).ttft_ms)

        let interim = Data("HTTP/1.1 100 Continue\r\nX-CPA-TRACE-ID: \(trace)\r\n\r\nHTTP/1.1 503 Service Unavailable\r\nX-Other: 1\r\n".utf8)
        let r = try failed(interim, accepted: 0)
        XCTAssertEqual(r.status, 503)
        XCTAssertNil(r.trace_id)

        let start = "event: message_start\ndata: {\"type\":\"message_start\",\"message\":{\"model\":\"start-model\",\"usage\":{\"input_tokens\":3}}}\n\n"
        let delta = "event: message_delta\ndata: {\"type\":\"message_delta\",\"usage\":{\"output_tokens\":5}}\n\n"
        let late = "event: message_delta\ndata: {\"type\":\"message_delta\",\"model\":\"late-model\",\"usage\":{\"output_tokens\":9}}\n\nevent: message_stop\ndata: {\"type\":\"message_stop\"}\n\n"
        let stream = Data((sseHead + start + delta + late).utf8)
        let kept = try failed(stream, deliveredFirst: (sseHead + start).utf8.count, accepted: delta.utf8.count)
        XCTAssertEqual(kept.outcome, "client_disconnected")
        XCTAssertEqual(kept.tokens, JournalTokens(input_uncached: 3, cache_read: 0, cache_creation: 0, output: 5, reasoning: nil))
        XCTAssertEqual(kept.response_model, "start-model")
    }

    func testEventOverTwoMiBIsDiscardedAndScanningResumes() throws {
        let pad = String(repeating: "a", count: 200 * 1024)
        var lines = [#"data: {"error":"discarded","#]
        for i in 0..<11 { lines.append(#"data: "p\#(i)":"\#(pad)","#) }
        lines.append(#"data: "end":1}"#)
        let raw = sseHead + lines.joined(separator: "\n") + "\n\n" + chatUsage + "data: [DONE]\n\n"
        let r = try observe(raw, path: "/v1/chat/completions")
        XCTAssertEqual(r.outcome, "complete")
        XCTAssertEqual(r.tokens, chatTokens)
    }

    func testSSELineCapExcludesTheLineTerminator() throws {
        let prefix = #"data: {"choices":[],"usage":{"prompt_tokens":3,"completion_tokens":5},"pad":""#
        let pad = String(repeating: "a", count: 256 * 1024 - prefix.utf8.count - 2)
        let atCap = prefix + pad + #""}"#
        XCTAssertEqual(atCap.utf8.count, 256 * 1024)
        let fits = try observe(sseHead + atCap + "\r\n\r\ndata: [DONE]\r\n\r\n", path: "/v1/chat/completions")
        XCTAssertEqual(fits.outcome, "complete")
        XCTAssertEqual(fits.tokens, chatTokens)
        let over = try observe(sseHead + prefix + pad + #"a"}"# + "\r\n\r\ndata: [DONE]\r\n\r\n", path: "/v1/chat/completions")
        XCTAssertEqual(over.outcome, "complete")
        XCTAssertNil(over.tokens)
    }

    func testTransferCodingListDecidesChunkingAndOpacity() throws {
        let json = #"{"type":"message","model":"m","usage":{"input_tokens":3,"output_tokens":5}}"#
        let tokens = JournalTokens(input_uncached: 3, cache_read: 0, cache_creation: 0, output: 5, reasoning: nil)
        let chunked = "\(String(json.utf8.count, radix: 16))\r\n\(json)\r\n0\r\n\r\n"
        let cases: [(String, String, String, JournalTokens?)] = [
            ("Transfer-Encoding: Chunked\r\n", chunked, "complete", tokens),
            ("Transfer-Encoding: gzip, chunked\r\n", chunked, "complete", nil),
            ("Transfer-Encoding: gzip\r\nTransfer-Encoding: CHUNKED\r\n", chunked, "complete", nil),
            ("Transfer-Encoding: chunked, gzip\r\n", json, "complete", nil),
            ("Transfer-Encoding: gzip\r\n", json, "complete", nil),
            ("Content-Encoding: identity\r\nContent-Length: \(json.utf8.count)\r\n", json, "complete", tokens),
            ("Content-Encoding: br\r\nContent-Length: \(json.utf8.count)\r\n", json, "complete", nil)
        ]
        for (headers, body, outcome, expected) in cases {
            let r = try observeAnySplit("HTTP/1.1 200 OK\r\n\(headers)\r\n\(body)")
            XCTAssertEqual(r.outcome, outcome, headers)
            XCTAssertEqual(r.tokens, expected, headers)
            XCTAssertEqual(r.response_model, expected == nil ? nil : "m", headers)
        }
    }

    func testProtocolErrorsAreExactlyTheContractSet() throws {
        for (body, expected) in [
            ("event: error\ndata: not json\n\n", "upstream_error"),
            ("event:error\ndata: {}\n\n", "upstream_error"),
            ("data: {\"error\":\"string-valued\"}\n\n", "upstream_error"),
            ("data: {\"type\":\"response.error\"}\n\n", "upstream_error"),
            ("data: {\"type\":\"response.failed\",\"response\":{}}\n\n", "upstream_error"),
            ("data: {\"type\":\"content_block_delta\",\"error\":{\"message\":\"x\"}}\n\ndata: {\"type\":\"message_stop\"}\n\n", "complete"),
            ("data: {\"error\":null}\n\ndata: [DONE]\n\n", "complete"),
            ("data: {\"type\":\"error\",}\n\ndata: [DONE]\n\n", "complete"),
            ("event: message_stop\ndata: {\"type\":\"ping\"}\n\n", "upstream_closed_early"),
            ("event: response.completed\ndata: {}\n\n", "upstream_closed_early")
        ] {
            XCTAssertEqual(try observeAnySplit(sseHead + body).outcome, expected, body)
        }
        let error = #"{"error":{"type":"rate_limit"}}"#
        let rateLimited = try observe("HTTP/1.1 429 Too Many Requests\r\nContent-Length: \(error.utf8.count)\r\n\r\n\(error)")
        XCTAssertEqual(rateLimited.outcome, "complete")
        XCTAssertEqual(rateLimited.status, 429)
    }

    func testCountersAreExactLiteralsAndNullOptionalsAreAbsent() throws {
        for usage in [
            #"{"input_tokens":-1,"output_tokens":3}"#,
            #"{"input_tokens":true,"output_tokens":3}"#,
            #"{"input_tokens":1.5,"output_tokens":3}"#,
            #"{"input_tokens":"1","output_tokens":3}"#,
            #"{"input_tokens":1}"#,
            #"{"input_tokens":1,"output_tokens":null}"#,
            #"{"input_tokens":1.0,"output_tokens":3}"#,
            #"{"input_tokens":1e3,"output_tokens":3}"#,
            #"{"input_tokens":-0,"output_tokens":3}"#,
            #"{"input_tokens":9223372036854775808,"output_tokens":3}"#,
            #"{"input_tokens":1,"output_tokens":3,"cache_read_input_tokens":2.0}"#,
            #"{"input_tokens":1,"output_tokens":3,"cache_creation_input_tokens":"2"}"#
        ] {
            let body = "{\"type\":\"message\",\"usage\":\(usage)}"
            XCTAssertNil(try observe(sized("", body)).tokens, usage)
        }
        for (usage, expected) in [
            (#"{"input_tokens":0,"output_tokens":0}"#, JournalTokens(input_uncached: 0, cache_read: 0, cache_creation: 0, output: 0, reasoning: nil)),
            (#"{"input_tokens":1,"output_tokens":3,"cache_read_input_tokens":null,"cache_creation_input_tokens":null}"#,
             JournalTokens(input_uncached: 1, cache_read: 0, cache_creation: 0, output: 3, reasoning: nil)),
            (#"{"input_tokens":9007199254740993,"output_tokens":9223372036854775807}"#,
             JournalTokens(input_uncached: 9_007_199_254_740_993, cache_read: 0, cache_creation: 0, output: Int64.max, reasoning: nil))
        ] {
            XCTAssertEqual(try observe(sized("", "{\"type\":\"message\",\"usage\":\(usage)}")).tokens, expected, usage)
        }
        for (usage, expected) in [
            (#"{"input_tokens":10,"output_tokens":4,"input_tokens_details":null,"output_tokens_details":null}"#,
             JournalTokens(input_uncached: 10, cache_read: 0, cache_creation: nil, output: 4, reasoning: nil)),
            (#"{"input_tokens":10,"output_tokens":4,"input_tokens_details":{"cached_tokens":null},"output_tokens_details":{"reasoning_tokens":null}}"#,
             JournalTokens(input_uncached: 10, cache_read: 0, cache_creation: nil, output: 4, reasoning: nil)),
            (#"{"input_tokens":10,"output_tokens":4,"input_tokens_details":5}"#, nil),
            (#"{"input_tokens":10,"output_tokens":4,"output_tokens_details":{"reasoning_tokens":1.0}}"#, nil)
        ] {
            XCTAssertEqual(try observe(sized("", "{\"object\":\"response\",\"usage\":\(usage)}"), path: "/v1/responses").tokens, expected, usage)
        }
        for (details, creation) in [
            (#"{"cache_write_tokens":null,"cached_creation_tokens":7}"#, Int64?(7)),
            (#"{"cache_write_tokens":2,"cached_creation_tokens":7}"#, 2),
            (#"{"cached_tokens":null,"cache_write_tokens":null}"#, nil)
        ] {
            let body = "{\"object\":\"chat.completion\",\"usage\":{\"prompt_tokens\":9,\"completion_tokens\":5,\"prompt_tokens_details\":\(details),\"completion_tokens_details\":null}}"
            XCTAssertEqual(try observe(sized("", body), path: "/v1/chat/completions").tokens,
                           JournalTokens(input_uncached: 9, cache_read: 0, cache_creation: creation, output: 5, reasoning: nil), details)
        }
    }

    func testHeadCapCountsFromTheFinalHeadAtAnySplit() throws {
        let prefix = "HTTP/1.1 200 OK\r\nX-Pad: "
        let suffix = "\r\nContent-Length: 2\r\n\r\n"
        let fill = 64 * 1024 - prefix.utf8.count - suffix.utf8.count
        let atCap = prefix + String(repeating: "a", count: fill) + suffix + "{}"
        XCTAssertEqual(try observeAnySplit(atCap).outcome, "complete")
        XCTAssertEqual(try observeAnySplit("HTTP/1.1 100 Continue\r\nX-Pad: \(String(repeating: "b", count: 40_000))\r\n\r\n" + atCap).outcome, "complete")
        let json = #"{"type":"message","model":"m","usage":{"input_tokens":1,"output_tokens":1}}"#
        let over = prefix + String(repeating: "a", count: fill + 1) + "\r\nContent-Length: \(json.utf8.count)\r\n\r\n" + json
        let r = try observeAnySplit(over)
        XCTAssertEqual(r.outcome, "upstream_error")
        XCTAssertEqual(r.status, 200)
        XCTAssertNil(r.tokens)
        XCTAssertNil(r.response_model)
        XCTAssertNil(r.ttft_ms)
        let unterminated = try observe("HTTP/1.1 200 OK\r\nX-Long: \(String(repeating: "a", count: 64 * 1024))")
        XCTAssertEqual(unterminated.outcome, "upstream_error")
        XCTAssertEqual(unterminated.status, 200)
    }

    func testStatusLineAndHeaderGrammar() throws {
        for (line, status) in [("HTTP/1.1 200\r\n", 200), ("HTTP/1.1 200 \r\n", 200), ("HTTP/1.0 404 Not Found\r\n", 404), ("HTTP/1.1 599 x y\r\n", 599)] {
            let r = try observeAnySplit(line + "Content-Length: 0\r\n\r\n")
            XCTAssertEqual(r.outcome, "complete", line)
            XCTAssertEqual(r.status, status, line)
        }
        for line in ["HTTP/1.1 20\r\n", "HTTP/2 200 OK\r\n", "HTTP/1.1 200OK\r\n", "HTTP/1.1 999 Custom\r\n", "HTTP/1.1  200 OK\r\n",
                     "HTTP/1.1 099 Low\r\n", "HTTP/1.1 2000 OK\r\n", "http/1.1 200 OK\r\n", "HTTP/1.1 200 OK\n"] {
            let r = try observeAnySplit(line + "Content-Length: 0\r\n\r\n")
            XCTAssertEqual(r.outcome, "upstream_error", line)
            XCTAssertNil(r.status, line)
        }
        for header in [": empty-name\r\n", "No Colon\r\n", "Bad Name: x\r\n", "X-Bare: lf\n"] {
            let r = try observeAnySplit("HTTP/1.1 200 OK\r\n" + header + "Content-Length: 0\r\n\r\n")
            XCTAssertEqual(r.outcome, "upstream_error", header)
            XCTAssertEqual(r.status, 200, header)
        }
        for body in ["2\n{}\r\n0\r\n\r\n", "2\r\n{}\n0\r\n\r\n", "2\r\n{}\r\n0\r\nBad\r\n\r\n", "2\r\n{}\r\n0\n\r\n"] {
            let r = try observeAnySplit("HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n" + body)
            XCTAssertEqual(r.outcome, "upstream_error", body)
        }
    }

    func testNonStreamEnvelopeFollowsForwardedPathFamily() throws {
        let responses = #"{"object":"response","model":"r","usage":{"input_tokens":4,"output_tokens":2}}"#
        let chat = #"{"object":"chat.completion","model":"c","usage":{"prompt_tokens":4,"completion_tokens":2}}"#
        let text = #"{"object":"text_completion","model":"t","usage":{"prompt_tokens":4,"completion_tokens":2}}"#
        let message = #"{"type":"message","model":"a","usage":{"input_tokens":4,"output_tokens":2}}"#
        let openAI = JournalTokens(input_uncached: 4, cache_read: 0, cache_creation: nil, output: 2, reasoning: nil)
        let anthropic = JournalTokens(input_uncached: 4, cache_read: 0, cache_creation: 0, output: 2, reasoning: nil)
        let cases: [(String, String?, String, JournalTokens?, String)] = [
            ("/v1/responses", nil, responses, openAI, "r"),
            ("/backend-api/codex/responses", nil, responses, openAI, "r"),
            ("/v1/responses/compact", nil, responses, nil, "r"),
            ("/v1/chat/completions", nil, responses, nil, "r"),
            ("/v1/responses", "/v1/chat/completions", chat, openAI, "c"),
            ("/v1/responses", "/v1/chat/completions", responses, nil, "r"),
            ("/v1/completions", nil, text, openAI, "t"),
            ("/v1/completions", nil, chat, nil, "c"),
            ("/v1/messages", nil, message, anthropic, "a"),
            ("/v1/chat/completions", nil, message, nil, "a"),
            ("/v1beta/interactions", nil, responses, nil, "r")
        ]
        for (path, forwarded, body, tokens, model) in cases {
            let r = try observe(sized("", body), path: path, forwarded: forwarded)
            XCTAssertEqual(r.tokens, tokens, "\(path) \(body)")
            XCTAssertEqual(r.response_model, model, "\(path) \(body)")
        }
    }

    func testStrictJSONAndLastDuplicateMember() throws {
        let duplicate = #"{"type":"message","usage":{"input_tokens":1,"output_tokens":2},"usage":{"input_tokens":3,"output_tokens":4}}"#
        XCTAssertEqual(try observe(sized("", duplicate)).tokens?.output, 4)
        for body in [
            #"{"type":"message","model":"m","usage":{"input_tokens":1,"output_tokens":2,}}"#,
            #"{"type":"message","model":"m","usage":{"input_tokens":1,"output_tokens":2}} x"#,
            #"{"type":"message","model":"m","usage":{"input_tokens":NaN,"output_tokens":2}}"#,
            #"{"type":"message","model":"m",/* c */"usage":{"input_tokens":1,"output_tokens":2}}"#,
            "{\"type\":\"message\",\"model\":\"m\u{01}\",\"usage\":{\"input_tokens\":1,\"output_tokens\":2}}"
        ] {
            let r = try observe(sized("", body))
            XCTAssertNil(r.tokens, body)
            XCTAssertNil(r.response_model, body)
        }
        XCTAssertEqual(try observe(sseHead + "data: {\"type\":\"message_stop\",}\n\n").outcome, "upstream_closed_early")
        let duplicateModel = journalRequest("/v1/chat/completions", body: #"{"model":"claude-x","model":"gpt-y"}"#)
        XCTAssertEqual(duplicateModel.model, "gpt-y")
        XCTAssertEqual(duplicateModel.provider, "codex")
        for body in [#"{"model":"gpt-y",}"#, #"{"model":"gpt-y"} // c"#, #"{"model":"gpt-y","prompt_cache_key":"body-session-0001",]"#] {
            let request = journalRequest("/v1/chat/completions", body: body)
            XCTAssertNil(request.model, body)
            XCTAssertNil(request.session, body)
        }
        XCTAssertNil(journalSession([], #"{"metadata":{"user_id":"{\"session_id\":\"json-session-0001\",}"}}"#))
        XCTAssertEqual(journalSession([], #"{"metadata":{"user_id":"{\"session_id\":\"json-session-0001\"}"}}"#), "json-session-0001")
    }

    func testChatUsagePublishesOnlyOnQualifyingChunks() throws {
        let partial = #"data: {"choices":[{"finish_reason":null}],"usage":{"prompt_tokens":3,"completion_tokens":5}}"# + "\n\n"
        XCTAssertNil(try observe(sseHead + partial, path: "/v1/chat/completions").tokens)
        XCTAssertNil(try observe(sseHead + partial + "data: [DONE]\n\n", path: "/v1/chat/completions").tokens)
        let numeric = #"data: {"choices":[{"finish_reason":5}],"usage":{"prompt_tokens":3,"completion_tokens":5}}"# + "\n\n"
        XCTAssertNil(try observe(sseHead + numeric + "data: [DONE]\n\n", path: "/v1/chat/completions").tokens)
        let stop = #"data: {"choices":[{"finish_reason":null},{"finish_reason":"stop"}],"usage":{"prompt_tokens":3,"completion_tokens":5}}"# + "\n\n"
        XCTAssertEqual(try observe(sseHead + stop, path: "/v1/chat/completions").tokens, chatTokens)
        let later = #"data: {"choices":[],"usage":{"prompt_tokens":3,"completion_tokens":8}}"# + "\n\n"
        XCTAssertEqual(try observe(sseHead + stop + later + "data: [DONE]\n\n", path: "/v1/chat/completions").tokens?.output, 8)
        let truncated = try observe(sseHead + chatUsage, path: "/v1/chat/completions", end: .clientDisconnected)
        XCTAssertEqual(truncated.outcome, "client_disconnected")
        XCTAssertEqual(truncated.tokens, chatTokens)
    }

    func testChunkSizeAndHeadersDoNotStartTTFTAndWallClockDoesNotSetLatency() throws {
        let clock = JournalTestClock()
        var record: JournalRecord?
        let observation = ResponseObservation(
            request: journalRequest("/v1/responses?q=1", forwarded: "/v1/chat/completions", headers: [("X-DroidProxy-Origin", "window-primer")], body: #"{"model":"gemini-original"}"#),
            clock: { clock.now }, emit: { record = $0 })
        deliver(observation, Data("HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n2\r\n".utf8), clock: clock, readAt: 10, writeAt: 11)
        deliver(observation, Data("{}\r\n0\r\n\r\n".utf8), clock: clock, readAt: 21, writeAt: 35)
        let r = try XCTUnwrap(record)
        XCTAssertEqual(r.ttft_ms, 21)
        XCTAssertEqual(r.latency_ms, 35)
        XCTAssertEqual(r.outcome, "complete")
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
    }
}
