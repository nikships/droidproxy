import Foundation

/// Converts Factory/Droid native Grok tool markup leaked into `message.content`
/// into OpenAI `tool_calls` so `generic-chat-completion-api` actually executes them.
///
/// Grok-via-DroidProxy (especially `cursor-grok-4.6-fast`) often writes:
///
/// ```
/// prefix text<|tool_calls_begin|><|tool_call_begin|>
/// Execute
/// <|tool_sep|>command
/// ls
/// <|tool_call_end|><|tool_calls_end|>
/// ```
///
/// Factory's first-party Grok adapter parses that. The custom OpenAI-compatible
/// route does not, so the turn ends as plain text and the worker goes quiet.
enum GrokNativeToolCallRewriter {
    static let callsBegin = "<|tool_calls_begin|>"
    static let callBegin = "<|tool_call_begin|>"
    static let callEnd = "<|tool_call_end|>"
    static let callsEnd = "<|tool_calls_end|>"
    static let sep = "<|tool_sep|>"

    /// Catalog ids (`cursor-grok-4.6`, `cursor-grok-4.6-fast`) and upstream ids
    /// (`grok-4.6`, `grok-4.6-fast`) all contain `grok`. Composer/Junie do not.
    static func shouldRewrite(model: String?) -> Bool {
        guard let model, !model.isEmpty else { return false }
        return model.range(of: "grok", options: .caseInsensitive) != nil
    }

    struct NativeCall: Equatable {
        let name: String
        let arguments: [String: Any]

        static func == (lhs: NativeCall, rhs: NativeCall) -> Bool {
            lhs.name == rhs.name && NSDictionary(dictionary: lhs.arguments).isEqual(to: rhs.arguments)
        }
    }

    struct ParsedMarkup {
        let prefix: String
        let calls: [NativeCall]
    }

    // MARK: - Parse

    static func parse(_ text: String) -> ParsedMarkup? {
        let raw: ParsedMarkup?
        if let markup = parseFactoryMarkup(text) {
            raw = markup
        } else {
            raw = parseJSONFunctionCall(text)
        }
        guard let raw else { return nil }
        let calls = dedupeConsecutive(raw.calls)
        guard !calls.isEmpty else { return nil }
        return ParsedMarkup(prefix: raw.prefix, calls: calls)
    }

    /// SSE/CLI stream parsers often repeat the same JSON object. Collapse
    /// consecutive identical calls so Droid does not run Create twice.
    private static func dedupeConsecutive(_ calls: [NativeCall]) -> [NativeCall] {
        var out: [NativeCall] = []
        for call in calls {
            if let last = out.last, last == call { continue }
            out.append(call)
        }
        return out
    }

    private static func parseFactoryMarkup(_ text: String) -> ParsedMarkup? {
        guard let beginRange = text.range(of: callsBegin) else {
            return nil
        }

        let prefix = String(text[..<beginRange.lowerBound])
        var cursor = beginRange.upperBound
        var calls: [NativeCall] = []

        while cursor < text.endIndex {
            if text[cursor...].hasPrefix(callsEnd) {
                break
            }

            guard let callStart = text.range(of: callBegin, range: cursor..<text.endIndex) else {
                break
            }
            cursor = callStart.upperBound

            let callLimit = nextMarker(
                in: text,
                from: cursor,
                markers: [callEnd, callsEnd, callBegin]
            ) ?? text.endIndex

            guard let parsed = parseOneCall(in: text, from: cursor, until: callLimit) else {
                cursor = callLimit
                if callLimit < text.endIndex, text[callLimit...].hasPrefix(callEnd) {
                    cursor = text.index(callLimit, offsetBy: callEnd.count)
                }
                continue
            }

            calls.append(parsed.call)
            cursor = parsed.end
            if cursor < text.endIndex, text[cursor...].hasPrefix(callEnd) {
                cursor = text.index(cursor, offsetBy: callEnd.count)
            }
        }

        guard !calls.isEmpty else {
            return nil
        }
        return ParsedMarkup(prefix: prefix, calls: calls)
    }

    /// Composer (and some Grok turns) emit a fenced `{"name","arguments"}`
    /// object instead of Factory markup. Lift that into the same parse result.
    /// Sequential JSON objects (Write then Delete) are collected in order.
    static func parseJSONFunctionCall(_ text: String) -> ParsedMarkup? {
        var calls: [NativeCall] = []
        var prefix = ""
        var rest = text.trimmingCharacters(in: .whitespacesAndNewlines)
        var capturedPrefix = false
        while let extracted = extractJSONValue(from: rest) {
            guard extracted.remainder.count < rest.count else { break }
            let more = nativeCalls(fromJSON: extracted.value)
            if more.isEmpty {
                rest = extracted.remainder.trimmingCharacters(in: .whitespacesAndNewlines)
                continue
            }
            if !capturedPrefix {
                prefix = extracted.prefix
                capturedPrefix = true
            }
            calls.append(contentsOf: more)
            rest = extracted.remainder.trimmingCharacters(in: .whitespacesAndNewlines)
            if rest.isEmpty { break }
        }
        guard !calls.isEmpty else {
            return nil
        }
        return ParsedMarkup(prefix: prefix, calls: calls)
    }

    private static func extractJSONValue(from text: String) -> (prefix: String, value: Any, remainder: String)? {
        var body = text
        var prefix = ""
        var remainderAfterFence: String?
        if let fence = firstCodeFence(in: text) {
            prefix = String(text[..<fence.range.lowerBound])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            body = fence.body
            remainderAfterFence = String(text[fence.range.upperBound...])
        }
        let startIndex = body.firstIndex(where: { $0 == "{" || $0 == "[" })
        guard let start = startIndex else { return nil }
        if fencePrefixIsEmpty(prefix), start > body.startIndex {
            prefix = String(body[..<start]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard let jsonSlice = matchingJSONSlice(in: body, from: start),
              let data = String(jsonSlice).data(using: .utf8),
              let value = try? JSONSerialization.jsonObject(with: data) else {
            return nil
        }
        let remainder: String
        if let remainderAfterFence {
            remainder = remainderAfterFence
        } else {
            remainder = String(body[jsonSlice.endIndex...])
        }
        return (prefix, value, remainder)
    }

    private static func fencePrefixIsEmpty(_ prefix: String) -> Bool {
        prefix.isEmpty
    }

    private static func firstCodeFence(in text: String) -> (range: Range<String.Index>, body: String)? {
        guard let opener = text.range(of: "```") else { return nil }
        var cursor = opener.upperBound
        if text[cursor...].hasPrefix("json") {
            cursor = text.index(cursor, offsetBy: 4)
        }
        if cursor < text.endIndex, text[cursor].isNewline {
            cursor = text.index(after: cursor)
        }
        guard let closer = text.range(of: "```", range: cursor..<text.endIndex) else {
            return nil
        }
        let body = String(text[cursor..<closer.lowerBound])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (opener.lowerBound..<closer.upperBound, body)
    }

    private static func matchingJSONSlice(in text: String, from start: String.Index) -> Substring? {
        var depth = 0
        var inString = false
        var escape = false
        var index = start
        while index < text.endIndex {
            let ch = text[index]
            if inString {
                if escape {
                    escape = false
                } else if ch == "\\" {
                    escape = true
                } else if ch == "\"" {
                    inString = false
                }
            } else {
                switch ch {
                case "\"":
                    inString = true
                case "{", "[":
                    depth += 1
                case "}", "]":
                    depth -= 1
                    if depth == 0 {
                        return text[start...index]
                    }
                default:
                    break
                }
            }
            index = text.index(after: index)
        }
        return nil
    }

    private static func nativeCalls(fromJSON value: Any) -> [NativeCall] {
        if let object = value as? [String: Any], let call = nativeCall(from: object) {
            return [call]
        }
        if let array = value as? [Any] {
            return array.compactMap { item in
                guard let object = item as? [String: Any] else { return nil }
                return nativeCall(from: object)
            }
        }
        return []
    }

    private static func nativeCall(from object: [String: Any]) -> NativeCall? {
        if object["choices"] != nil || object["id"] != nil && object["object"] != nil {
            return nil
        }
        var name = object["name"] as? String
        if name == nil, let tool = object["tool"] as? String {
            name = tool
        }
        var arguments: [String: Any]?
        if let nested = object["function"] as? [String: Any] {
            if name == nil {
                name = nested["name"] as? String
            }
            arguments = jsonObjectArguments(nested["arguments"])
        }
        if arguments == nil {
            arguments = jsonObjectArguments(object["arguments"])
        }
        guard let name, isToolName(name) else { return nil }
        if let arguments, !arguments.isEmpty {
            return canonicalize(name: name, arguments: arguments)
        }
        var rest = object
        rest.removeValue(forKey: "name")
        rest.removeValue(forKey: "tool")
        rest.removeValue(forKey: "type")
        rest.removeValue(forKey: "function")
        rest.removeValue(forKey: "id")
        guard !rest.isEmpty else { return nil }
        return canonicalize(name: name, arguments: rest)
    }

    /// Droid's file tools are Create/Edit/Execute. Cursor/Grok emit Write/Delete.
    static func canonicalize(name: String, arguments: [String: Any]) -> NativeCall {
        var args = arguments
        if name == "Write" || name == "write" || name == "Create" {
            remapString(&args, dest: "file_path", aliases: ["file_path", "path", "filePath", "filename"])
            remapString(&args, dest: "content", aliases: ["content", "contents", "body", "text"])
            var create: [String: Any] = [:]
            if let path = args["file_path"] { create["file_path"] = path }
            if let content = args["content"] { create["content"] = content }
            return NativeCall(name: "Create", arguments: create.isEmpty ? args : create)
        }
        if name == "Delete" || name == "delete" || name == "Remove" {
            remapString(&args, dest: "path", aliases: ["path", "file_path", "filePath", "filename"])
            if let path = args["path"] as? String, !path.isEmpty {
                return NativeCall(name: "Execute", arguments: [
                    "command": "rm -f \(shellSingleQuote(path))",
                    "summary": "Delete \(path)"
                ])
            }
        }
        if args["path"] == nil {
            for alias in ["file_path", "filePath", "filename"] {
                if let value = args[alias] as? String, !value.isEmpty {
                    args["path"] = value
                    break
                }
            }
        }
        if args["contents"] == nil {
            for alias in ["content", "body", "text"] {
                if let value = args[alias] as? String {
                    args["contents"] = value
                    break
                }
            }
        }
        return NativeCall(name: name, arguments: args)
    }

    private static func remapString(_ args: inout [String: Any], dest: String, aliases: [String]) {
        if let existing = args[dest] as? String, !existing.isEmpty {
            return
        }
        for alias in aliases {
            if let value = args[alias] as? String, !value.isEmpty {
                args[dest] = value
                return
            }
        }
    }

    private static func shellSingleQuote(_ path: String) -> String {
        "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private static func jsonObjectArguments(_ raw: Any?) -> [String: Any]? {
        if let object = raw as? [String: Any] {
            return object
        }
        if let text = raw as? String,
           let data = text.data(using: .utf8),
           let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            return object
        }
        return nil
    }

    private static func isToolName(_ name: String) -> Bool {
        guard name.count <= 64, name.range(of: "^[A-Za-z][A-Za-z0-9_]*$", options: .regularExpression) != nil else {
            return false
        }
        let blocked: Set<String> = ["object", "choices", "message", "assistant", "system", "user"]
        return !blocked.contains(name.lowercased())
    }

    private struct OneCall {
        let call: NativeCall
        let end: String.Index
    }

    private static func parseOneCall(
        in text: String,
        from start: String.Index,
        until limit: String.Index
    ) -> OneCall? {
        var cursor = start
        skipWhitespace(&cursor, in: text, until: limit)
        guard cursor < limit else { return nil }

        let nameEnd = nextMarker(in: text, from: cursor, markers: [sep, callEnd, callsEnd, callBegin], until: limit)
            ?? nextNewline(in: text, from: cursor, until: limit)
            ?? limit
        let name = String(text[cursor..<nameEnd]).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return nil }

        cursor = nameEnd
        if cursor < limit, text[cursor] == "\r" { cursor = text.index(after: cursor) }
        if cursor < limit, text[cursor] == "\n" { cursor = text.index(after: cursor) }

        var arguments: [String: Any] = [:]
        while cursor < limit, text[cursor...].hasPrefix(sep) {
            cursor = text.index(cursor, offsetBy: sep.count)
            skipHorizontalWhitespace(&cursor, in: text, until: limit)
            if cursor < limit, text[cursor] == "\r" { cursor = text.index(after: cursor) }
            if cursor < limit, text[cursor] == "\n" { cursor = text.index(after: cursor) }

            let keyEnd = nextNewline(in: text, from: cursor, until: limit)
                ?? nextMarker(in: text, from: cursor, markers: [sep, callEnd, callsEnd], until: limit)
                ?? limit
            var key = String(text[cursor..<keyEnd]).trimmingCharacters(in: .whitespacesAndNewlines)
            cursor = keyEnd
            if cursor < limit, text[cursor] == "\r" { cursor = text.index(after: cursor) }
            if cursor < limit, text[cursor] == "\n" { cursor = text.index(after: cursor) }

            let valueEnd = nextMarker(
                in: text,
                from: cursor,
                markers: [sep, callEnd, callsEnd, callBegin],
                until: limit
            ) ?? limit
            var value = String(text[cursor..<valueEnd])
            if value.hasSuffix("\r\n") {
                value.removeLast(2)
            } else if value.hasSuffix("\n") || value.hasSuffix("\r") {
                value.removeLast()
            }
            if let colon = key.firstIndex(of: ":") {
                let inline = String(key[key.index(after: colon)...])
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                key = String(key[..<colon]).trimmingCharacters(in: .whitespacesAndNewlines)
                if !inline.isEmpty, value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    value = inline
                }
            }
            if !key.isEmpty {
                arguments[key] = coerceJSONValue(value)
            }
            cursor = valueEnd
        }

        return OneCall(call: canonicalize(name: name, arguments: arguments), end: cursor)
    }

    // MARK: - Chat completion / SSE / HTTP

    /// Rewrites a non-streaming chat.completion JSON body. Returns nil when unchanged.
    static func rewriteChatCompletionJSON(_ json: String) -> String? {
        guard let data = json.data(using: .utf8),
              var root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              var choices = root["choices"] as? [[String: Any]],
              !choices.isEmpty else {
            return nil
        }

        var choice = choices[0]
        guard var message = choice["message"] as? [String: Any] else {
            return nil
        }

        if message["tool_calls"] != nil {
            return nil
        }

        guard let content = message["content"] as? String,
              let parsed = parse(content) else {
            return nil
        }

        if parsed.prefix.isEmpty {
            message["content"] = NSNull()
        } else {
            message["content"] = parsed.prefix
        }
        message["tool_calls"] = encodeToolCalls(parsed.calls)
        choice["message"] = message
        choice["finish_reason"] = "tool_calls"
        choices[0] = choice
        root["choices"] = choices

        guard let out = try? JSONSerialization.data(withJSONObject: root),
              let str = String(data: out, encoding: .utf8) else {
            return nil
        }
        return str
    }

    /// Rewrites an OpenAI SSE body. Returns nil when unchanged.
    static func rewriteSSEBody(_ sse: String) -> String? {
        let events = sseDataPayloads(sse)
        guard !events.isEmpty else { return nil }

        var content = ""
        var alreadyHasToolCalls = false
        var id = "chatcmpl-grok-native"
        var model = "grok-4.6"
        var created = Int(Date().timeIntervalSince1970)
        var usage: Any?

        for (index, payload) in events {
            if payload == "[DONE]" { continue }
            guard let data = payload.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                continue
            }
            if index == 0 || id == "chatcmpl-grok-native" {
                if let value = obj["id"] as? String { id = value }
                if let value = obj["model"] as? String { model = value }
                if let value = obj["created"] as? Int { created = value }
            }
            if let value = obj["usage"] {
                usage = value
            }
            guard let choices = obj["choices"] as? [[String: Any]],
                  let choice = choices.first else {
                continue
            }
            if let message = choice["message"] as? [String: Any] {
                if message["tool_calls"] != nil { alreadyHasToolCalls = true }
                if let text = message["content"] as? String { content += text }
            }
            if let delta = choice["delta"] as? [String: Any] {
                if delta["tool_calls"] != nil { alreadyHasToolCalls = true }
                if let text = delta["content"] as? String { content += text }
            }
        }

        guard !alreadyHasToolCalls, let parsed = parse(content) else {
            return nil
        }

        var out = ""
        if !parsed.prefix.isEmpty {
            out += sseLine(chunk(
                id: id,
                model: model,
                created: created,
                delta: ["role": "assistant", "content": parsed.prefix]
            ))
        } else {
            out += sseLine(chunk(
                id: id,
                model: model,
                created: created,
                delta: ["role": "assistant"]
            ))
        }

        let toolCalls = encodeToolCalls(parsed.calls)
        var indexed: [[String: Any]] = []
        for (index, call) in toolCalls.enumerated() {
            var entry = call
            entry["index"] = index
            indexed.append(entry)
        }
        out += sseLine(chunk(
            id: id,
            model: model,
            created: created,
            delta: ["tool_calls": indexed]
        ))
        out += sseLine(chunk(
            id: id,
            model: model,
            created: created,
            delta: [:] as [String: Any],
            finishReason: "tool_calls",
            usage: usage
        ))
        out += "data: [DONE]\n\n"
        return out
    }

    /// Rewrites a complete HTTP response. Returns the original bytes when unchanged.
    static func rewriteHTTPResponse(_ raw: Data) -> Data {
        guard let parsed = splitHTTPResponse(raw), parsed.statusCode == 200 else {
            return raw
        }

        var body = parsed.body
        if parsed.isChunked {
            guard let decoded = decodeChunkedBody(body) else {
                return raw
            }
            body = decoded
        }

        guard let decodedText = String(data: body, encoding: .utf8) else {
            return raw
        }

        var bodyText = decodedText
        var changed = false
        if parsed.isEventStream || bodyText.hasPrefix("data:") || bodyText.contains("\ndata:") {
            if let next = rewriteSSEBody(bodyText) {
                bodyText = next
                changed = true
            }
            if let next = GrokEndFeatureRunRepair.repairSSE(bodyText) {
                bodyText = next
                changed = true
            }
        } else {
            if let next = rewriteChatCompletionJSON(bodyText) {
                bodyText = next
                changed = true
            }
            if let next = GrokEndFeatureRunRepair.repairJSONBody(bodyText) {
                bodyText = next
                changed = true
            }
        }
        guard changed else { return raw }
        let rewritten = bodyText

        return buildHTTPResponse(
            statusLine: parsed.statusLine,
            headers: parsed.headers,
            body: rewritten,
            eventStream: parsed.isEventStream || rewritten.hasPrefix("data:")
        )
    }

    static func encodeToolCalls(_ calls: [NativeCall]) -> [[String: Any]] {
        calls.enumerated().map { index, call in
            let arguments = GrokEndFeatureRunRepair.repair(
                name: call.name,
                arguments: call.arguments
            ).arguments
            return [
                "id": toolCallId(name: call.name, index: index),
                "type": "function",
                "function": [
                    "name": call.name,
                    "arguments": jsonString(arguments) ?? "{}"
                ] as [String: Any]
            ] as [String: Any]
        }
    }

    static func coerceJSONValue(_ raw: String) -> Any {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed == "true" { return true }
        if trimmed == "false" { return false }
        if trimmed == "null" { return NSNull() }
        if let intVal = Int(trimmed), String(intVal) == trimmed {
            return intVal
        }
        if trimmed.contains("."), let doubleVal = Double(trimmed),
           Double(trimmed) != nil {
            return doubleVal
        }
        if (trimmed.hasPrefix("{") && trimmed.hasSuffix("}"))
            || (trimmed.hasPrefix("[") && trimmed.hasSuffix("]")),
           let data = trimmed.data(using: .utf8),
           let obj = try? JSONSerialization.jsonObject(with: data) {
            return obj
        }
        return raw
    }

    // MARK: - Internals

    private static func toolCallId(name: String, index: Int) -> String {
        let safe = name.lowercased().filter { $0.isLetter || $0.isNumber }
        return "call_grok_native_\(index)_\(safe)"
    }

    private static func jsonString(_ object: [String: Any]) -> String? {
        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object),
              let str = String(data: data, encoding: .utf8) else {
            return nil
        }
        return str
    }

    private static func sseDataPayloads(_ sse: String) -> [(Int, String)] {
        var payloads: [(Int, String)] = []
        for (index, rawLine) in sse.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
            var line = String(rawLine)
            if line.hasSuffix("\r") { line.removeLast() }
            if line.hasPrefix("data:") {
                var payload = String(line.dropFirst(5))
                if payload.hasPrefix(" ") { payload.removeFirst() }
                payloads.append((index, payload))
            }
        }
        return payloads
    }

    private static func chunk(
        id: String,
        model: String,
        created: Int,
        delta: [String: Any],
        finishReason: String? = nil,
        usage: Any? = nil
    ) -> [String: Any] {
        let choice: [String: Any] = [
            "index": 0,
            "delta": delta,
            "finish_reason": finishReason as Any? ?? NSNull()
        ]
        var obj: [String: Any] = [
            "id": id,
            "object": "chat.completion.chunk",
            "created": created,
            "model": model,
            "choices": [choice]
        ]
        if let usage {
            obj["usage"] = usage
        }
        return obj
    }

    private static func sseLine(_ object: [String: Any]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: object),
              let str = String(data: data, encoding: .utf8) else {
            return ""
        }
        return "data: \(str)\n\n"
    }

    private struct HTTPResponseParts {
        let statusLine: String
        let statusCode: Int
        let headers: [(String, String)]
        let body: Data
        let isChunked: Bool
        let isEventStream: Bool
    }

    private static func splitHTTPResponse(_ raw: Data) -> HTTPResponseParts? {
        let separator = Data([13, 10, 13, 10])
        guard let range = raw.range(of: separator) else { return nil }
        let headerData = raw[raw.startIndex..<range.lowerBound]
        let body = Data(raw[range.upperBound...])
        guard let headerText = String(data: headerData, encoding: .utf8) else { return nil }

        let lines = headerText.split(separator: "\r\n", omittingEmptySubsequences: false).map(String.init)
        guard let statusLine = lines.first else { return nil }
        let parts = statusLine.split(separator: " ")
        let statusCode = parts.count >= 2 ? Int(parts[1]) ?? 0 : 0

        var headers: [(String, String)] = []
        var isChunked = false
        var isEventStream = false
        for line in lines.dropFirst() where !line.isEmpty {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = String(line[..<colon])
            let value = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            let lower = name.lowercased()
            if lower == "transfer-encoding", value.lowercased().contains("chunked") {
                isChunked = true
            }
            if lower == "content-type", value.lowercased().contains("text/event-stream") {
                isEventStream = true
            }
            headers.append((name, value))
        }

        return HTTPResponseParts(
            statusLine: statusLine,
            statusCode: statusCode,
            headers: headers,
            body: body,
            isChunked: isChunked,
            isEventStream: isEventStream
        )
    }

    private static func decodeChunkedBody(_ data: Data) -> Data? {
        var offset = data.startIndex
        var decoded = Data()

        while offset < data.endIndex {
            guard let lineEnd = data[offset...].range(of: Data([13, 10])) else {
                return nil
            }
            let sizeText = String(data: data[offset..<lineEnd.lowerBound], encoding: .utf8)?
                .split(separator: ";").first
                .map(String.init)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard let size = Int(sizeText, radix: 16) else {
                return nil
            }
            offset = lineEnd.upperBound
            if size == 0 {
                return decoded
            }
            let next = data.index(offset, offsetBy: size, limitedBy: data.endIndex) ?? data.endIndex
            decoded.append(data[offset..<next])
            offset = next
            if offset < data.endIndex, data[offset] == 13 {
                offset = data.index(after: offset)
            }
            if offset < data.endIndex, data[offset] == 10 {
                offset = data.index(after: offset)
            }
        }
        return decoded
    }

    private static func buildHTTPResponse(
        statusLine: String,
        headers: [(String, String)],
        body: String,
        eventStream: Bool
    ) -> Data {
        let bodyData = Data(body.utf8)
        var out = statusLine + "\r\n"
        let dropped: Set<String> = [
            "content-length",
            "transfer-encoding",
            "connection",
            "content-encoding"
        ]
        for (name, value) in headers where !dropped.contains(name.lowercased()) {
            if name.lowercased() == "content-type", eventStream {
                continue
            }
            out += "\(name): \(value)\r\n"
        }
        if eventStream {
            out += "Content-Type: text/event-stream\r\n"
        }
        out += "Content-Length: \(bodyData.count)\r\n"
        out += "Connection: close\r\n\r\n"

        var data = Data(out.utf8)
        data.append(bodyData)
        return data
    }

    private static func nextMarker(
        in text: String,
        from start: String.Index,
        markers: [String],
        until limit: String.Index? = nil
    ) -> String.Index? {
        let end = limit ?? text.endIndex
        var best: String.Index?
        for marker in markers {
            if let range = text.range(of: marker, range: start..<end) {
                if best == nil || range.lowerBound < best! {
                    best = range.lowerBound
                }
            }
        }
        return best
    }

    private static func nextNewline(in text: String, from start: String.Index, until limit: String.Index) -> String.Index? {
        var index = start
        while index < limit {
            if text[index] == "\n" || text[index] == "\r" {
                return index
            }
            index = text.index(after: index)
        }
        return nil
    }

    private static func skipWhitespace(_ cursor: inout String.Index, in text: String, until limit: String.Index) {
        while cursor < limit, text[cursor].isWhitespace {
            cursor = text.index(after: cursor)
        }
    }

    private static func skipHorizontalWhitespace(_ cursor: inout String.Index, in text: String, until limit: String.Index) {
        while cursor < limit, text[cursor] == " " || text[cursor] == "\t" {
            cursor = text.index(after: cursor)
        }
    }
}
