import Foundation

/// Strict RFC 8259 JSON value. Numbers keep their literal text so counters can be checked exactly;
/// a repeated object member keeps its last occurrence.
indirect enum JournalJSON: Equatable {
    case object([String: JournalJSON])
    case array([JournalJSON])
    case string(String)
    case number(String)
    case bool(Bool)
    case null

    /// Which members to materialize. `.all` keeps everything below; other members are validated and skipped.
    struct Selection {
        let members: [String: Selection]?
        static let all = Selection(members: nil)
    }

    static func parse(_ data: Data, select: Selection = .all) -> JournalJSON? {
        data.withUnsafeBytes { parse($0.bindMemory(to: UInt8.self), select: select) }
    }

    static func parse(_ text: String, select: Selection = .all) -> JournalJSON? {
        var text = text
        return text.withUTF8 { parse($0, select: select) }
    }

    private static func parse(_ bytes: UnsafeBufferPointer<UInt8>, select: Selection) -> JournalJSON? {
        var parser = JournalJSONParser(bytes: bytes)
        guard let value = parser.value(depth: 0, select: select) else { return nil }
        parser.skipWhitespace()
        return parser.index == parser.bytes.count ? value : nil
    }

    subscript(key: String) -> JournalJSON? {
        if case .object(let members) = self { return members[key] }
        return nil
    }

    var object: [String: JournalJSON]? {
        if case .object(let members) = self { return members }
        return nil
    }

    var array: [JournalJSON]? {
        if case .array(let items) = self { return items }
        return nil
    }

    var string: String? {
        if case .string(let value) = self { return value }
        return nil
    }
}

private struct JournalJSONParser {
    let bytes: UnsafeBufferPointer<UInt8>
    var index = 0
    private static let maxDepth = 512

    init(bytes: UnsafeBufferPointer<UInt8>) { self.bytes = bytes }

    private var peek: UInt8? { index < bytes.count ? bytes[index] : nil }

    mutating func skipWhitespace() {
        while index < bytes.count {
            switch bytes[index] {
            case 0x20, 0x09, 0x0A, 0x0D: index += 1
            default: return
            }
        }
    }

    /// A nil `select` validates the value without building it and returns `.null`.
    /// `depth` counts the arrays and objects enclosing this value, so a container here is at depth + 1.
    mutating func value(depth: Int, select: JournalJSON.Selection?) -> JournalJSON? {
        skipWhitespace()
        guard let byte = peek else { return nil }
        switch byte {
        case UInt8(ascii: "{"): return depth < Self.maxDepth ? object(depth: depth, select: select) : nil
        case UInt8(ascii: "["): return depth < Self.maxDepth ? array(depth: depth, select: select) : nil
        case UInt8(ascii: "\""): return string(keep: select != nil).map { select == nil ? .null : .string($0) }
        case UInt8(ascii: "t"): return literal("true") ? .bool(true) : nil
        case UInt8(ascii: "f"): return literal("false") ? .bool(false) : nil
        case UInt8(ascii: "n"): return literal("null") ? .null : nil
        default: return number().map { select == nil ? .null : .number($0) }
        }
    }

    private mutating func object(depth: Int, select: JournalJSON.Selection?) -> JournalJSON? {
        index += 1
        var members: [String: JournalJSON] = [:]
        skipWhitespace()
        if peek == UInt8(ascii: "}") {
            index += 1
            return .object(members)
        }
        while true {
            skipWhitespace()
            guard peek == UInt8(ascii: "\""), let key = string(keep: true) else { return nil }
            skipWhitespace()
            guard peek == UInt8(ascii: ":") else { return nil }
            index += 1
            let child = select.flatMap { $0.members == nil ? JournalJSON.Selection.all : $0.members?[key] }
            guard let item = value(depth: depth + 1, select: child) else { return nil }
            if child != nil { members[key] = item }
            skipWhitespace()
            switch peek {
            case UInt8(ascii: ","): index += 1
            case UInt8(ascii: "}"):
                index += 1
                return select == nil ? .null : .object(members)
            default: return nil
            }
        }
    }

    private mutating func array(depth: Int, select: JournalJSON.Selection?) -> JournalJSON? {
        index += 1
        let child = select?.members == nil ? select : nil
        var items: [JournalJSON] = []
        skipWhitespace()
        if peek == UInt8(ascii: "]") {
            index += 1
            return child == nil ? .null : .array(items)
        }
        while true {
            guard let item = value(depth: depth + 1, select: child) else { return nil }
            if child != nil { items.append(item) }
            skipWhitespace()
            switch peek {
            case UInt8(ascii: ","): index += 1
            case UInt8(ascii: "]"):
                index += 1
                return child == nil ? .null : .array(items)
            default: return nil
            }
        }
    }

    private mutating func literal(_ word: String) -> Bool {
        let count = word.utf8.count
        guard bytes.count - index >= count, bytes[index..<(index + count)].elementsEqual(word.utf8) else { return false }
        index += count
        return true
    }

    private mutating func digits() -> Bool {
        let start = index
        while let byte = peek, byte >= 0x30, byte <= 0x39 { index += 1 }
        return index > start
    }

    private mutating func number() -> String? {
        let start = index
        if peek == UInt8(ascii: "-") { index += 1 }
        if peek == UInt8(ascii: "0") { index += 1 } else if !digits() { return nil }
        if peek == UInt8(ascii: ".") {
            index += 1
            guard digits() else { return nil }
        }
        if peek == UInt8(ascii: "e") || peek == UInt8(ascii: "E") {
            index += 1
            if peek == UInt8(ascii: "+") || peek == UInt8(ascii: "-") { index += 1 }
            guard digits() else { return nil }
        }
        return String(decoding: UnsafeBufferPointer(rebasing: bytes[start..<index]), as: UTF8.self)
    }

    private mutating func hex4() -> UInt32? {
        guard bytes.count - index >= 4 else { return nil }
        var value: UInt32 = 0
        for _ in 0..<4 {
            let byte = bytes[index]
            let digit: UInt8
            switch byte {
            case 0x30...0x39: digit = byte - 0x30
            case 0x41...0x46: digit = byte - 0x37
            case 0x61...0x66: digit = byte - 0x57
            default: return nil
            }
            value = value << 4 | UInt32(digit)
            index += 1
        }
        return value
    }

    /// Without `keep`, escapes and control characters are checked but no text is built.
    private mutating func string(keep: Bool) -> String? {
        index += 1
        var out: [UInt8] = []
        var runStart = index
        while index < bytes.count {
            let byte = bytes[index]
            if byte == UInt8(ascii: "\"") {
                if keep { out.append(contentsOf: bytes[runStart..<index]) }
                index += 1
                return keep ? String(bytes: out, encoding: .utf8) : ""
            }
            if byte < 0x20 { return nil }
            guard byte == UInt8(ascii: "\\") else {
                index += 1
                continue
            }
            if keep { out.append(contentsOf: bytes[runStart..<index]) }
            index += 1
            guard let escape = peek else { return nil }
            index += 1
            switch escape {
            case UInt8(ascii: "\""), UInt8(ascii: "\\"), UInt8(ascii: "/"): out.append(escape)
            case UInt8(ascii: "b"): out.append(0x08)
            case UInt8(ascii: "f"): out.append(0x0C)
            case UInt8(ascii: "n"): out.append(0x0A)
            case UInt8(ascii: "r"): out.append(0x0D)
            case UInt8(ascii: "t"): out.append(0x09)
            case UInt8(ascii: "u"):
                guard var scalar = hex4() else { return nil }
                if (0xD800...0xDBFF).contains(scalar) {
                    guard bytes.count - index >= 2, bytes[index] == UInt8(ascii: "\\"), bytes[index + 1] == UInt8(ascii: "u") else { return nil }
                    index += 2
                    guard let low = hex4(), (0xDC00...0xDFFF).contains(low) else { return nil }
                    scalar = 0x10000 + ((scalar - 0xD800) << 10) + (low - 0xDC00)
                } else if (0xDC00...0xDFFF).contains(scalar) {
                    return nil
                }
                if keep, let unicode = Unicode.Scalar(scalar) { out.append(contentsOf: Array(String(Character(unicode)).utf8)) }
            default: return nil
            }
            if !keep { out.removeAll(keepingCapacity: true) }
            runStart = index
        }
        return nil
    }
}
