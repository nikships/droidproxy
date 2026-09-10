import XCTest
@testable import CLIProxyMenuBar

final class GrokNativeToolCallRewriterTests: XCTestCase {
    func testParsesExecuteFromStalledSession() throws {
        let text = """
        Checking the working tree and remaining over-cap files so I can continue the editorial demotions from the last batch.<|tool_calls_begin|><|tool_call_begin|>
        Execute
        <|tool_sep|>summary
        Check git status and remaining diffs
        <|tool_sep|>command
        cd /tmp && git status
        <|tool_sep|>timeout
        30
        <|tool_sep|>riskLevel
        low
        <|tool_call_end|><|tool_calls_end|>
        """

        let parsed = try XCTUnwrap(GrokNativeToolCallRewriter.parse(text))
        XCTAssertTrue(parsed.prefix.hasPrefix("Checking the working tree"))
        XCTAssertFalse(parsed.prefix.contains("<|tool_calls_begin|>"))
        XCTAssertEqual(parsed.calls.count, 1)
        XCTAssertEqual(parsed.calls[0].name, "Execute")
        XCTAssertEqual(parsed.calls[0].arguments["summary"] as? String, "Check git status and remaining diffs")
        XCTAssertEqual(parsed.calls[0].arguments["command"] as? String, "cd /tmp && git status")
        XCTAssertEqual(parsed.calls[0].arguments["timeout"] as? Int, 30)
        XCTAssertEqual(parsed.calls[0].arguments["riskLevel"] as? String, "low")
    }

    func testParsesEndFeatureRunWithJSONHandoff() throws {
        let text = """
        Handing that state back now.<|tool_calls_begin|><|tool_call_begin|>
        EndFeatureRun
        <|tool_sep|>successState
        partial
        <|tool_sep|>returnToOrchestrator
        true
        <|tool_sep|>validatorsPassed
        false
        <|tool_sep|>handoff
        {"salientSummary": "Paused mid-feature", "whatWasImplemented": "Measured counts"}
        <|tool_call_end|><|tool_calls_end|>
        """

        let parsed = try XCTUnwrap(GrokNativeToolCallRewriter.parse(text))
        XCTAssertEqual(parsed.prefix, "Handing that state back now.")
        XCTAssertEqual(parsed.calls[0].name, "EndFeatureRun")
        XCTAssertEqual(parsed.calls[0].arguments["successState"] as? String, "partial")
        XCTAssertEqual(parsed.calls[0].arguments["returnToOrchestrator"] as? Bool, true)
        XCTAssertEqual(parsed.calls[0].arguments["validatorsPassed"] as? Bool, false)
        let handoff = try XCTUnwrap(parsed.calls[0].arguments["handoff"] as? [String: Any])
        XCTAssertEqual(handoff["salientSummary"] as? String, "Paused mid-feature")
    }

    func testParsesSingleArgSkillCall() throws {
        let text = """
        <|tool_calls_begin|><|tool_call_begin|>
        Skill
        <|tool_sep|>skill
        mission-worker-base
        <|tool_call_end|><|tool_calls_end|>
        """

        let parsed = try XCTUnwrap(GrokNativeToolCallRewriter.parse(text))
        XCTAssertEqual(parsed.prefix, "")
        XCTAssertEqual(parsed.calls[0].name, "Skill")
        XCTAssertEqual(parsed.calls[0].arguments["skill"] as? String, "mission-worker-base")
    }

    func testParsesMultipleToolCalls() throws {
        let text = """
        <|tool_calls_begin|><|tool_call_begin|>
        Grep
        <|tool_sep|>pattern
        uppercase
        <|tool_call_end|><|tool_call_begin|>
        Read
        <|tool_sep|>path
        /tmp/a.swift
        <|tool_call_end|><|tool_calls_end|>
        """

        let parsed = try XCTUnwrap(GrokNativeToolCallRewriter.parse(text))
        XCTAssertEqual(parsed.calls.map(\.name), ["Grep", "Read"])
        XCTAssertEqual(parsed.calls[0].arguments["pattern"] as? String, "uppercase")
        XCTAssertEqual(parsed.calls[1].arguments["path"] as? String, "/tmp/a.swift")
    }

    func testParsesInlineCommandKey() throws {
        let text = """
        <|tool_calls_begin|><|tool_call_begin|>
        Execute
        <|tool_sep|>command: pwd
        <|tool_sep|>summary
        Print working directory
        <|tool_call_end|><|tool_calls_end|>
        """
        let parsed = try XCTUnwrap(GrokNativeToolCallRewriter.parse(text))
        XCTAssertEqual(parsed.calls[0].arguments["command"] as? String, "pwd")
        XCTAssertEqual(parsed.calls[0].arguments["summary"] as? String, "Print working directory")
    }

    func testRemapsFactoryWriteMarkupToCreate() throws {
        let text = """
        <|tool_calls_begin|><|tool_call_begin|>
        Write
        <|tool_sep|>path
        /tmp/ping.txt
        <|tool_sep|>contents
        hello-from-droid-tool-test
        <|tool_call_end|><|tool_calls_end|>
        """
        let parsed = try XCTUnwrap(GrokNativeToolCallRewriter.parse(text))
        XCTAssertEqual(parsed.calls[0].name, "Create")
        XCTAssertEqual(parsed.calls[0].arguments["file_path"] as? String, "/tmp/ping.txt")
        XCTAssertEqual(parsed.calls[0].arguments["content"] as? String, "hello-from-droid-tool-test")
    }

    func testParsesTruncatedCallMissingEndTags() throws {
        let text = """
        keep going<|tool_calls_begin|><|tool_call_begin|>
        Execute
        <|tool_sep|>command
        ls
        """

        let parsed = try XCTUnwrap(GrokNativeToolCallRewriter.parse(text))
        XCTAssertEqual(parsed.prefix, "keep going")
        XCTAssertEqual(parsed.calls[0].name, "Execute")
        XCTAssertEqual(parsed.calls[0].arguments["command"] as? String, "ls")
    }

    func testShouldRewriteCoversCatalogAndUpstreamGrokIds() {
        for model in [
            "grok-4.6",
            "grok-4.6-fast",
            "cursor-grok-4.6",
            "cursor-grok-4.6-fast"
        ] {
            XCTAssertTrue(
                GrokNativeToolCallRewriter.shouldRewrite(model: model),
                "expected rewrite for \(model)"
            )
        }
        XCTAssertFalse(GrokNativeToolCallRewriter.shouldRewrite(model: "cursor-composer-2.5"))
        XCTAssertFalse(GrokNativeToolCallRewriter.shouldRewrite(model: "claude-opus-4-6"))
        XCTAssertFalse(GrokNativeToolCallRewriter.shouldRewrite(model: nil))
        XCTAssertFalse(GrokNativeToolCallRewriter.shouldRewrite(model: ""))
    }

    func testEncodeToolCallsRepairsReadPathAlias() throws {
        let calls = [
            GrokNativeToolCallRewriter.NativeCall(name: "Read", arguments: ["path": "/tmp/a.swift"])
        ]
        let encoded = GrokNativeToolCallRewriter.encodeToolCalls(calls)
        let function = try XCTUnwrap(encoded[0]["function"] as? [String: Any])
        let args = try XCTUnwrap(function["arguments"] as? String)
        let parsed = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(args.utf8)) as? [String: Any])
        XCTAssertEqual(parsed["file_path"] as? String, "/tmp/a.swift")
    }

    func testParsesFencedJSONWriteCall() throws {
        let text = """
        ```json
        {"name":"Write","arguments":{"path":"/tmp/droidproxy-composer-markup.txt","contents":"hello-composer"}}
        ```
        """
        let parsed = try XCTUnwrap(GrokNativeToolCallRewriter.parse(text))
        XCTAssertEqual(parsed.calls.count, 1)
        XCTAssertEqual(parsed.calls[0].name, "Create")
        XCTAssertEqual(parsed.calls[0].arguments["file_path"] as? String, "/tmp/droidproxy-composer-markup.txt")
        XCTAssertEqual(parsed.calls[0].arguments["content"] as? String, "hello-composer")
    }

    func testParsesJSONWriteFilePathAlias() throws {
        let text = """
        ```json
        {"name":"Write","arguments":{"file_path":"/tmp/x.txt","content":"hi"}}
        ```
        """
        let parsed = try XCTUnwrap(GrokNativeToolCallRewriter.parse(text))
        XCTAssertEqual(parsed.calls[0].name, "Create")
        XCTAssertEqual(parsed.calls[0].arguments["file_path"] as? String, "/tmp/x.txt")
        XCTAssertEqual(parsed.calls[0].arguments["content"] as? String, "hi")
    }

    func testParsesBareJSONFunctionCall() throws {
        let text = #"here {"name":"Delete","arguments":{"path":"/tmp/x.txt"}}"#
        let parsed = try XCTUnwrap(GrokNativeToolCallRewriter.parse(text))
        XCTAssertEqual(parsed.prefix, "here")
        XCTAssertEqual(parsed.calls[0].name, "Execute")
        XCTAssertEqual(parsed.calls[0].arguments["command"] as? String, "rm -f '/tmp/x.txt'")
    }

    func testParsesSequentialJSONWriteThenDelete() throws {
        let text = """
        ```json
        {"name":"Write","arguments":{"path":"/tmp/ping.txt","contents":"hello"}}
        ```
        ```json
        {"name":"Delete","arguments":{"path":"/tmp/ping.txt"}}
        ```
        """
        let parsed = try XCTUnwrap(GrokNativeToolCallRewriter.parse(text))
        XCTAssertEqual(parsed.calls.count, 2)
        XCTAssertEqual(parsed.calls[0].name, "Create")
        XCTAssertEqual(parsed.calls[0].arguments["content"] as? String, "hello")
        XCTAssertEqual(parsed.calls[1].name, "Execute")
        XCTAssertEqual(parsed.calls[1].arguments["command"] as? String, "rm -f '/tmp/ping.txt'")
    }

    func testDedupesRepeatedJSONWriteCall() throws {
        let text = """
        {"name":"Write","arguments":{"path":"/tmp/ping.txt","contents":"hello"}}
        {"name":"Write","arguments":{"path":"/tmp/ping.txt","contents":"hello"}}
        """
        let parsed = try XCTUnwrap(GrokNativeToolCallRewriter.parse(text))
        XCTAssertEqual(parsed.calls.count, 1)
        XCTAssertEqual(parsed.calls[0].name, "Create")
    }

    func testJSONRewriteLiftsIntoOpenAIToolCalls() throws {
        let body = """
        {"choices":[{"message":{"role":"assistant","content":"```json\\n{\\"name\\":\\"Write\\",\\"arguments\\":{\\"path\\":\\"/tmp/a.txt\\",\\"contents\\":\\"hi\\"}}\\n```"},"finish_reason":"stop"}]}
        """
        let rewritten = try XCTUnwrap(GrokNativeToolCallRewriter.rewriteChatCompletionJSON(body))
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(rewritten.utf8)) as? [String: Any])
        let choice = try XCTUnwrap((root["choices"] as? [[String: Any]])?.first)
        XCTAssertEqual(choice["finish_reason"] as? String, "tool_calls")
        let message = try XCTUnwrap(choice["message"] as? [String: Any])
        let toolCalls = try XCTUnwrap(message["tool_calls"] as? [[String: Any]])
        let function = try XCTUnwrap(toolCalls[0]["function"] as? [String: Any])
        XCTAssertEqual(function["name"] as? String, "Create")
    }

    func testLeavesPlainTextUnchanged() {
        XCTAssertNil(GrokNativeToolCallRewriter.parse("just a sentence"))
        XCTAssertNil(GrokNativeToolCallRewriter.rewriteChatCompletionJSON(
            #"{"choices":[{"message":{"role":"assistant","content":"hi"}}]}"#
        ))
    }

    func testRewritesNonStreamingChatCompletion() throws {
        let body = """
        {"id":"chatcmpl_abc","choices":[{"index":0,"message":{"role":"assistant","content":"Working.<|tool_calls_begin|><|tool_call_begin|>\\nExecute\\n<|tool_sep|>command\\nls\\n<|tool_call_end|><|tool_calls_end|>"},"finish_reason":"stop"}]}
        """

        let rewritten = try XCTUnwrap(GrokNativeToolCallRewriter.rewriteChatCompletionJSON(body))
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(rewritten.utf8)) as? [String: Any])
        let choice = try XCTUnwrap((root["choices"] as? [[String: Any]])?.first)
        XCTAssertEqual(choice["finish_reason"] as? String, "tool_calls")
        let message = try XCTUnwrap(choice["message"] as? [String: Any])
        XCTAssertEqual(message["content"] as? String, "Working.")
        let toolCalls = try XCTUnwrap(message["tool_calls"] as? [[String: Any]])
        XCTAssertEqual(toolCalls.count, 1)
        XCTAssertEqual(toolCalls[0]["type"] as? String, "function")
        let function = try XCTUnwrap(toolCalls[0]["function"] as? [String: Any])
        XCTAssertEqual(function["name"] as? String, "Execute")
        let args = try XCTUnwrap(function["arguments"] as? String)
        let parsedArgs = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(args.utf8)) as? [String: Any])
        XCTAssertEqual(parsedArgs["command"] as? String, "ls")
    }

    func testDoesNotRewriteWhenToolCallsAlreadyPresent() {
        let body = """
        {"choices":[{"message":{"role":"assistant","content":"x<|tool_calls_begin|>","tool_calls":[{"id":"call_1","type":"function","function":{"name":"Read","arguments":"{}"}}]}}]}
        """
        XCTAssertNil(GrokNativeToolCallRewriter.rewriteChatCompletionJSON(body))
    }

    func testRewritesSSEContentDeltasIntoToolCalls() throws {
        let sse = """
        data: {"id":"chatcmpl_1","object":"chat.completion.chunk","created":1,"model":"grok-4.6-fast","choices":[{"index":0,"delta":{"role":"assistant","content":"Working."},"finish_reason":null}]}

        data: {"id":"chatcmpl_1","object":"chat.completion.chunk","created":1,"model":"grok-4.6-fast","choices":[{"index":0,"delta":{"content":"<|tool_calls_begin|><|tool_call_begin|>\\nExecute\\n<|tool_sep|>command\\nls\\n<|tool_call_end|><|tool_calls_end|>"},"finish_reason":null}]}

        data: {"id":"chatcmpl_1","object":"chat.completion.chunk","created":1,"model":"grok-4.6-fast","choices":[{"index":0,"delta":{},"finish_reason":"stop"}]}

        data: [DONE]

        """

        let rewritten = try XCTUnwrap(GrokNativeToolCallRewriter.rewriteSSEBody(sse))
        XCTAssertTrue(rewritten.contains("\"finish_reason\":\"tool_calls\""))
        XCTAssertTrue(rewritten.contains("\"name\":\"Execute\""))
        XCTAssertTrue(rewritten.contains("Working."))
        XCTAssertFalse(rewritten.contains("tool_calls_begin"))
        XCTAssertTrue(rewritten.contains("data: [DONE]"))
    }

    func testRewritesHTTPJSONResponseAndUpdatesContentLength() throws {
        let json = #"{"choices":[{"message":{"role":"assistant","content":"<|tool_calls_begin|><|tool_call_begin|>\nSkill\n<|tool_sep|>skill\natlas-builder\n<|tool_call_end|><|tool_calls_end|>"},"finish_reason":"stop"}]}"#
        var raw = Data("HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: \(json.utf8.count)\r\n\r\n".utf8)
        raw.append(Data(json.utf8))

        let rewritten = GrokNativeToolCallRewriter.rewriteHTTPResponse(raw)
        XCTAssertNotEqual(rewritten, raw)
        let text = try XCTUnwrap(String(data: rewritten, encoding: .utf8))
        XCTAssertTrue(text.contains("tool_calls"))
        XCTAssertTrue(text.contains("atlas-builder"))
        XCTAssertTrue(text.contains("Content-Length:"))
        XCTAssertFalse(text.contains("tool_calls_begin"))
    }

    func testHTTPPassthroughWhenNoMarkup() {
        let json = #"{"choices":[{"message":{"role":"assistant","content":"hello"}}]}"#
        var raw = Data("HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: \(json.utf8.count)\r\n\r\n".utf8)
        raw.append(Data(json.utf8))
        XCTAssertEqual(GrokNativeToolCallRewriter.rewriteHTTPResponse(raw), raw)
    }

    func testRewritesChunkedSSEHTTPResponseAndRebuildsContentLength() throws {
        let sse = """
        data: {"id":"chatcmpl_1","object":"chat.completion.chunk","created":1,"model":"grok-4.6-fast","choices":[{"index":0,"delta":{"role":"assistant","content":"Working."},"finish_reason":null}]}

        data: {"id":"chatcmpl_1","object":"chat.completion.chunk","created":1,"model":"grok-4.6-fast","choices":[{"index":0,"delta":{"content":"<|tool_calls_begin|><|tool_call_begin|>\\nExecute\\n<|tool_sep|>command\\nls\\n<|tool_call_end|><|tool_calls_end|>"},"finish_reason":null}]}

        data: {"id":"chatcmpl_1","object":"chat.completion.chunk","created":1,"model":"grok-4.6-fast","choices":[{"index":0,"delta":{},"finish_reason":"stop"}]}

        data: [DONE]

        """
        let body = Data(sse.utf8)
        var chunked = Data()
        chunked.append(Data("\(String(body.count, radix: 16))\r\n".utf8))
        chunked.append(body)
        chunked.append(Data("\r\n0\r\n\r\n".utf8))

        var raw = Data("HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nTransfer-Encoding: chunked\r\n\r\n".utf8)
        raw.append(chunked)

        let rewritten = GrokNativeToolCallRewriter.rewriteHTTPResponse(raw)
        XCTAssertNotEqual(rewritten, raw)
        let text = try XCTUnwrap(String(data: rewritten, encoding: .utf8))
        XCTAssertTrue(text.contains("Content-Type: text/event-stream"))
        XCTAssertTrue(text.contains("Content-Length:"))
        XCTAssertFalse(text.contains("Transfer-Encoding:"))
        XCTAssertTrue(text.contains("\"finish_reason\":\"tool_calls\""))
        XCTAssertTrue(text.contains("\"name\":\"Execute\""))
        XCTAssertFalse(text.contains("tool_calls_begin"))
    }
}
