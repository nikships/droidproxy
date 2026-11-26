import Foundation

/// Mistral's Chat Completions API accepts only the `system`, `user`, `assistant`
/// and `tool` roles and answers 422 `union_tag_invalid` for anything else.
/// Droid sends its system prompt as `developer`, and CLIProxyAPI's Responses-to-Chat
/// translation keeps that role, so every Mistral turn fails before a token is produced.
enum MistralRequestRewriter {
    static func isMistralModel(_ model: String?) -> Bool {
        guard let model else { return false }
        return MistralCredentialStore.modelIDs.contains(model)
    }

    /// Top-level arrays whose objects are conversation items (Chat `messages`, Responses `input`).
    private static let messageArrays: Set<String> = ["messages", "input"]
    private static let system = Array(#""system""#.utf8)

    /// Returns the body with every message's `developer` role changed to `system`,
    /// or nil when nothing changed. Only the `role` member of an object directly inside
    /// a top-level `messages` or `input` array is touched, so a `{"role":"developer"}`
    /// literal in a tool schema keeps its value. The raw text is edited in place to
    /// keep key order intact.
    static func rewriteDeveloperRoles(_ body: String) -> String? {
        var bytes = Array(body.utf8)
        guard let spans = developerRoleSpans(in: bytes), !spans.isEmpty else { return nil }
        for span in spans.reversed() {
            bytes.replaceSubrange(span, with: system)
        }
        return String(decoding: bytes, as: UTF8.self)
    }

    private static func developerRoleSpans(in b: [UInt8]) -> [Range<Int>]? {
        var spans: [Range<Int>] = []
        let parsed = forEachMember(ofObjectAt: skipWhitespace(b, 0), in: b) { key, valueStart in
            guard messageArrays.contains(key) else { return }
            forEachElement(ofArrayAt: valueStart, in: b) { elementStart in
                forEachMember(ofObjectAt: elementStart, in: b) { key, valueStart in
                    guard key == "role", let end = stringEnd(b, valueStart),
                          decodedString(b, valueStart..<end) == "developer" else { return }
                    spans.append(valueStart..<end)
                }
            }
        }
        return parsed == nil ? nil : spans
    }

    // MARK: - Minimal JSON scanning over UTF-8 bytes

    private static let quote = UInt8(ascii: "\"")
    private static let backslash = UInt8(ascii: "\\")
    private static let openBrace = UInt8(ascii: "{")
    private static let closeBrace = UInt8(ascii: "}")
    private static let openBracket = UInt8(ascii: "[")
    private static let closeBracket = UInt8(ascii: "]")
    private static let colon = UInt8(ascii: ":")
    private static let comma = UInt8(ascii: ",")
    private static let whitespace: Set<UInt8> = [0x20, 0x09, 0x0A, 0x0D]

    /// Calls `visit` with each member's decoded key and the index of its value.
    /// Returns the index after the object, or nil when `start` is not a well-formed object.
    @discardableResult
    private static func forEachMember(ofObjectAt start: Int, in b: [UInt8], _ visit: (String, Int) -> Void) -> Int? {
        guard start < b.count, b[start] == openBrace else { return nil }
        var i = skipWhitespace(b, start + 1)
        if i < b.count, b[i] == closeBrace { return i + 1 }
        while true {
            guard let keyEnd = stringEnd(b, i) else { return nil }
            guard let key = decodedString(b, i..<keyEnd) else { return nil }
            i = skipWhitespace(b, keyEnd)
            guard i < b.count, b[i] == colon else { return nil }
            let valueStart = skipWhitespace(b, i + 1)
            visit(key, valueStart)
            guard let end = valueEnd(b, valueStart) else { return nil }
            i = skipWhitespace(b, end)
            guard i < b.count else { return nil }
            if b[i] == closeBrace { return i + 1 }
            guard b[i] == comma else { return nil }
            i = skipWhitespace(b, i + 1)
        }
    }

    /// Calls `visit` with the index of each element. Returns the index after the array,
    /// or nil when `start` is not a well-formed array.
    @discardableResult
    private static func forEachElement(ofArrayAt start: Int, in b: [UInt8], _ visit: (Int) -> Void) -> Int? {
        guard start < b.count, b[start] == openBracket else { return nil }
        var i = skipWhitespace(b, start + 1)
        if i < b.count, b[i] == closeBracket { return i + 1 }
        while true {
            visit(i)
            guard let end = valueEnd(b, i) else { return nil }
            i = skipWhitespace(b, end)
            guard i < b.count else { return nil }
            if b[i] == closeBracket { return i + 1 }
            guard b[i] == comma else { return nil }
            i = skipWhitespace(b, i + 1)
        }
    }

    private static func skipWhitespace(_ b: [UInt8], _ start: Int) -> Int {
        var i = start
        while i < b.count, whitespace.contains(b[i]) { i += 1 }
        return i
    }

    /// Index after the closing quote of the string starting at `start`.
    private static func stringEnd(_ b: [UInt8], _ start: Int) -> Int? {
        guard start < b.count, b[start] == quote else { return nil }
        var i = start + 1
        while i < b.count {
            if b[i] == backslash {
                i += 2
            } else if b[i] == quote {
                return i + 1
            } else {
                i += 1
            }
        }
        return nil
    }

    /// The value of the JSON string token in `range` (quotes included), with escapes such as
    /// `\u0064` resolved, or nil when the token is invalid.
    private static func decodedString(_ b: [UInt8], _ range: Range<Int>) -> String? {
        let inner = b[(range.lowerBound + 1)..<(range.upperBound - 1)]
        guard inner.contains(backslash) else { return String(decoding: inner, as: UTF8.self) }
        return (try? JSONSerialization.jsonObject(with: Data(b[range]), options: .fragmentsAllowed)) as? String
    }

    /// Index after the value starting at `start`.
    private static func valueEnd(_ b: [UInt8], _ start: Int) -> Int? {
        guard start < b.count else { return nil }
        let first = b[start]
        if first == quote { return stringEnd(b, start) }
        if first == openBrace || first == openBracket {
            var depth = 0
            var i = start
            while i < b.count {
                let c = b[i]
                if c == quote {
                    guard let end = stringEnd(b, i) else { return nil }
                    i = end
                    continue
                }
                if c == openBrace || c == openBracket {
                    depth += 1
                } else if c == closeBrace || c == closeBracket {
                    depth -= 1
                    if depth == 0 { return i + 1 }
                }
                i += 1
            }
            return nil
        }
        var i = start
        while i < b.count, b[i] != comma, b[i] != closeBrace, b[i] != closeBracket, !whitespace.contains(b[i]) {
            i += 1
        }
        return i > start ? i : nil
    }
}
