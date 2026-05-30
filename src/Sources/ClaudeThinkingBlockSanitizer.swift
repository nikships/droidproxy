import Foundation

struct ClaudeThinkingBlockSanitizer {
    private struct FieldLocation {
        let pairRange: Range<String.Index>
        let valueRange: Range<String.Index>
    }

    private struct Replacement {
        let range: Range<String.Index>
        let text: String
    }

    private static let removableThinkingTypes: Set<String> = [
        "thinking",
        "redacted_thinking"
    ]

    // Substituted for a content array that would otherwise become `[]` after stripping.
    // Replacing (rather than dropping the message) keeps the assistant turn in place so
    // user/assistant roles still alternate.
    private static let emptyContentPlaceholder = "[{\"type\":\"text\",\"text\":\"...\"}]"

    static func sanitize(_ json: String) -> String {
        guard let messagesLocation = findTopLevelFieldLocation(in: json, key: "messages"),
              let messages = arrayElementRanges(in: json, arrayRange: messagesLocation.valueRange) else {
            return json
        }

        let messageInfos = messages.map { messageInfo(in: json, range: $0) }
        let preserveThinkingAtIndex = latestAssistantIndexWithTrailingToolResults(messageInfos)
        var replacements: [Replacement] = []

        for (index, info) in messageInfos.enumerated() {
            guard info.role == "assistant",
                  index != preserveThinkingAtIndex,
                  let contentRange = info.contentRange,
                  let blocks = arrayElementRanges(in: json, arrayRange: contentRange) else {
                continue
            }

            let removableIndexes = blocks.indices.filter { blockIndex in
                guard let type = objectStringField(in: json, objectRange: blocks[blockIndex], key: "type") else {
                    return false
                }
                return removableThinkingTypes.contains(type)
            }

            guard !removableIndexes.isEmpty else {
                continue
            }

            // Removing every block would leave `"content":[]`, which Anthropic rejects.
            // Replace the content with a placeholder instead of deleting the array so the
            // assistant message (and role alternation) is preserved.
            if removableIndexes.count == blocks.count {
                replacements.append(Replacement(range: contentRange, text: emptyContentPlaceholder))
            } else {
                let ranges = rangesForRemoving(forRemoving: removableIndexes, from: blocks, in: json)
                replacements.append(contentsOf: ranges.map { Replacement(range: $0, text: "") })
            }
        }

        guard !replacements.isEmpty else {
            return json
        }

        var result = ""
        result.reserveCapacity(json.count)
        var cursor = json.startIndex
        for replacement in replacements.sorted(by: { $0.range.lowerBound < $1.range.lowerBound }) {
            guard cursor <= replacement.range.lowerBound else {
                continue
            }
            result.append(contentsOf: json[cursor..<replacement.range.lowerBound])
            result.append(replacement.text)
            cursor = replacement.range.upperBound
        }
        result.append(contentsOf: json[cursor..<json.endIndex])
        return result
    }

    private struct MessageInfo {
        let role: String?
        let contentRange: Range<String.Index>?
        let isToolResultTurn: Bool
    }

    private static func messageInfo(in json: String, range: Range<String.Index>) -> MessageInfo {
        let role = objectStringField(in: json, objectRange: range, key: "role")
        guard let content = findObjectFieldLocation(in: json, key: "content", objectRange: range) else {
            return MessageInfo(role: role, contentRange: nil, isToolResultTurn: false)
        }

        return MessageInfo(role: role,
                           contentRange: content.valueRange,
                           isToolResultTurn: role == "user" && contentHasAnyToolResult(in: json,
                                                                                       range: content.valueRange))
    }

    private static func latestAssistantIndexWithTrailingToolResults(_ messages: [MessageInfo]) -> Int? {
        var index = messages.count - 1
        var sawTrailingToolResults = false

        while index >= 0 {
            let message = messages[index]
            guard message.role == "user", message.isToolResultTurn else {
                break
            }
            sawTrailingToolResults = true
            index -= 1
        }

        guard sawTrailingToolResults,
              index >= 0,
              messages[index].role == "assistant" else {
            return nil
        }
        return index
    }

    private static func contentHasAnyToolResult(in json: String, range: Range<String.Index>) -> Bool {
        guard let blocks = arrayElementRanges(in: json, arrayRange: range),
              !blocks.isEmpty else {
            return false
        }

        return blocks.contains { blockRange in
            objectStringField(in: json, objectRange: blockRange, key: "type") == "tool_result"
        }
    }

    private static func rangesForRemoving(forRemoving indexes: [Int],
                                          from elements: [Range<String.Index>],
                                          in json: String) -> [Range<String.Index>] {
        guard !indexes.isEmpty else {
            return []
        }

        var ranges: [Range<String.Index>] = []
        var groupStart = indexes[0]
        var previous = indexes[0]

        func appendGroup(start: Int, end: Int) {
            let deleteRange: Range<String.Index>
            if start == 0 && end == elements.count - 1 {
                deleteRange = elements[start].lowerBound..<elements[end].upperBound
            } else if start == 0 {
                deleteRange = elements[start].lowerBound..<elements[end + 1].lowerBound
            } else {
                deleteRange = elements[start - 1].upperBound..<elements[end].upperBound
            }
            ranges.append(deleteRange)
        }

        for index in indexes.dropFirst() {
            if index == previous + 1 {
                previous = index
                continue
            }
            appendGroup(start: groupStart, end: previous)
            groupStart = index
            previous = index
        }
        appendGroup(start: groupStart, end: previous)
        return ranges
    }

    private static func findTopLevelFieldLocation(in json: String, key: String) -> FieldLocation? {
        findObjectFieldLocation(in: json, key: key, objectRange: json.startIndex..<json.endIndex)
    }

    private static func findObjectFieldLocation(in json: String,
                                                key targetKey: String,
                                                objectRange: Range<String.Index>) -> FieldLocation? {
        guard var index = firstNonWhitespaceIndex(in: json,
                                                  from: objectRange.lowerBound,
                                                  before: objectRange.upperBound),
              json[index] == "{" else {
            return nil
        }

        index = json.index(after: index)
        while true {
            guard let keyStart = firstNonWhitespaceIndex(in: json,
                                                         from: index,
                                                         before: objectRange.upperBound) else {
                return nil
            }

            if json[keyStart] == "}" {
                return nil
            }
            guard json[keyStart] == "\"",
                  let (key, keyEnd) = parseJSONStringToken(in: json,
                                                           startingAt: keyStart,
                                                           before: objectRange.upperBound),
                  let colonIndex = firstNonWhitespaceIndex(in: json,
                                                           from: keyEnd,
                                                           before: objectRange.upperBound),
                  json[colonIndex] == ":" else {
                return nil
            }

            let afterColon = json.index(after: colonIndex)
            guard let valueStart = firstNonWhitespaceIndex(in: json,
                                                           from: afterColon,
                                                           before: objectRange.upperBound),
                  let valueEnd = consumeJSONValue(in: json,
                                                  startingAt: valueStart,
                                                  before: objectRange.upperBound) else {
                return nil
            }

            if key == targetKey {
                return FieldLocation(pairRange: keyStart..<valueEnd,
                                     valueRange: valueStart..<valueEnd)
            }

            guard let delimiterIndex = firstNonWhitespaceIndex(in: json,
                                                               from: valueEnd,
                                                               before: objectRange.upperBound) else {
                return nil
            }

            let delimiter = json[delimiterIndex]
            if delimiter == "," {
                index = json.index(after: delimiterIndex)
                continue
            }
            if delimiter == "}" {
                return nil
            }
            return nil
        }
    }

    private static func objectStringField(in json: String,
                                          objectRange: Range<String.Index>,
                                          key: String) -> String? {
        guard let location = findObjectFieldLocation(in: json, key: key, objectRange: objectRange),
              json[location.valueRange.lowerBound] == "\"",
              let (value, valueEnd) = parseJSONStringToken(in: json,
                                                           startingAt: location.valueRange.lowerBound,
                                                           before: location.valueRange.upperBound),
              valueEnd == location.valueRange.upperBound else {
            return nil
        }
        return value
    }

    private static func arrayElementRanges(in json: String,
                                           arrayRange: Range<String.Index>) -> [Range<String.Index>]? {
        guard var index = firstNonWhitespaceIndex(in: json,
                                                  from: arrayRange.lowerBound,
                                                  before: arrayRange.upperBound),
              json[index] == "[" else {
            return nil
        }

        var elements: [Range<String.Index>] = []
        index = json.index(after: index)
        while true {
            guard let valueStart = firstNonWhitespaceIndex(in: json,
                                                           from: index,
                                                           before: arrayRange.upperBound) else {
                return nil
            }

            if json[valueStart] == "]" {
                return elements
            }

            guard let valueEnd = consumeJSONValue(in: json,
                                                  startingAt: valueStart,
                                                  before: arrayRange.upperBound) else {
                return nil
            }
            elements.append(valueStart..<valueEnd)

            guard let delimiterIndex = firstNonWhitespaceIndex(in: json,
                                                               from: valueEnd,
                                                               before: arrayRange.upperBound) else {
                return nil
            }

            let delimiter = json[delimiterIndex]
            if delimiter == "," {
                index = json.index(after: delimiterIndex)
                continue
            }
            if delimiter == "]" {
                return elements
            }
            return nil
        }
    }

    private static func firstNonWhitespaceIndex(in json: String,
                                                from start: String.Index,
                                                before end: String.Index) -> String.Index? {
        var index = start
        while index < end, json[index].isWhitespace {
            index = json.index(after: index)
        }
        return index < end ? index : nil
    }

    private static func parseJSONStringToken(in json: String,
                                             startingAt startQuote: String.Index,
                                             before end: String.Index) -> (String, String.Index)? {
        guard json[startQuote] == "\"" else {
            return nil
        }

        var index = json.index(after: startQuote)
        var escaped = false
        while index < end {
            let char = json[index]
            if escaped {
                escaped = false
            } else if char == "\\" {
                escaped = true
            } else if char == "\"" {
                let value = String(json[json.index(after: startQuote)..<index])
                return (value, json.index(after: index))
            }
            index = json.index(after: index)
        }
        return nil
    }

    private static func consumeJSONValue(in json: String,
                                         startingAt start: String.Index,
                                         before end: String.Index) -> String.Index? {
        guard start < end else {
            return nil
        }

        let first = json[start]
        if first == "\"" {
            return parseJSONStringToken(in: json, startingAt: start, before: end)?.1
        }

        if first == "{" || first == "[" {
            return consumeCompositeJSONValue(in: json, startingAt: start, before: end)
        }

        var index = start
        while index < end {
            let char = json[index]
            if char == "," || char == "}" || char == "]" || char.isWhitespace {
                break
            }
            index = json.index(after: index)
        }
        return index > start ? index : nil
    }

    private static func consumeCompositeJSONValue(in json: String,
                                                  startingAt start: String.Index,
                                                  before end: String.Index) -> String.Index? {
        var index = start
        var depth = 0
        var inString = false
        var escaped = false

        while index < end {
            let char = json[index]
            if inString {
                if escaped {
                    escaped = false
                } else if char == "\\" {
                    escaped = true
                } else if char == "\"" {
                    inString = false
                }
            } else {
                if char == "\"" {
                    inString = true
                } else if char == "{" || char == "[" {
                    depth += 1
                } else if char == "}" || char == "]" {
                    depth -= 1
                    if depth == 0 {
                        return json.index(after: index)
                    }
                    if depth < 0 {
                        return nil
                    }
                }
            }
            index = json.index(after: index)
        }
        return nil
    }
}
