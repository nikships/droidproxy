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
        guard let value = parser.value(select: select) else { return nil }
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

    /// An array or object whose closing bracket has not been read yet.
    private struct Container {
        let isObject: Bool
        /// An object's own selection; unused for an array.
        let select: JournalJSON.Selection?
        /// The selection of the value being read: the current member's, or every item's.
        var child: JournalJSON.Selection?
        var key = ""
        var members: [String: JournalJSON] = [:]
        var items: [JournalJSON] = []
    }

    /// A nil `select` validates the value without building it and returns `.null`.
    /// Open containers live in `open` rather than on the call stack: parsing runs on GCD worker threads, whose 512 KiB
    /// stacks a recursive parser overflows before the depth limit in debug builds.
    mutating func value(select: JournalJSON.Selection?) -> JournalJSON? {
        // `current` is the innermost open container and `open` holds the ones enclosing it.
        var open: [Container] = []
        var current: Container?
        var depth = 0
        var select = select
        parsing: while true {
            skipWhitespace()
            guard let byte = peek else { return nil }
            var result: JournalJSON
            switch byte {
            case UInt8(ascii: "{"), UInt8(ascii: "["):
                guard depth < Self.maxDepth else { return nil }
                index += 1
                skipWhitespace()
                let isObject = byte == UInt8(ascii: "{")
                let child = isObject ? nil : select?.members == nil ? select : nil
                if peek == UInt8(ascii: isObject ? "}" : "]") {
                    index += 1
                    result = isObject ? .object([:]) : child == nil ? .null : .array([])
                } else {
                    var container = Container(isObject: isObject, select: isObject ? select : nil, child: child)
                    if isObject {
                        guard memberName(&container) else { return nil }
                    }
                    if let enclosing = current { open.append(enclosing) }
                    select = container.child
                    current = container
                    depth += 1
                    continue parsing
                }
            case UInt8(ascii: "\""):
                guard let text = string(keep: select != nil) else { return nil }
                result = select == nil ? .null : .string(text)
            case UInt8(ascii: "t"):
                guard literal("true") else { return nil }
                result = .bool(true)
            case UInt8(ascii: "f"):
                guard literal("false") else { return nil }
                result = .bool(false)
            case UInt8(ascii: "n"):
                guard literal("null") else { return nil }
                result = .null
            default:
                guard let literal = number() else { return nil }
                result = select == nil ? .null : .number(literal)
            }
            // Hand the value to its container, then close every container that ends after it.
            while current != nil {
                let isObject = current!.isObject
                if current!.child != nil {
                    if isObject {
                        let key = current!.key
                        current!.members[key] = result
                    } else {
                        current!.items.append(result)
                    }
                }
                skipWhitespace()
                switch peek {
                case UInt8(ascii: ","):
                    index += 1
                    if isObject {
                        guard memberName(&current!) else { return nil }
                    }
                    select = current!.child
                    continue parsing
                case UInt8(ascii: isObject ? "}" : "]"):
                    index += 1
                    let closed = current!
                    current = open.popLast()
                    depth -= 1
                    if isObject {
                        result = closed.select == nil ? .null : .object(closed.members)
                    } else {
                        result = closed.child == nil ? .null : .array(closed.items)
                    }
                default:
                    return nil
                }
            }
            return result
        }
    }

    /// Reads a member's `"name":` and chooses the member's selection.
    private mutating func memberName(_ container: inout Container) -> Bool {
        skipWhitespace()
        guard peek == UInt8(ascii: "\""), let key = string(keep: true) else { return false }
        skipWhitespace()
        guard peek == UInt8(ascii: ":") else { return false }
        index += 1
        container.key = key
        container.child = container.select.flatMap { $0.members == nil ? JournalJSON.Selection.all : $0.members?[key] }
        return true
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

    /// Length of the well-formed UTF-8 sequence at `index`, or nil.
    private func utf8Length() -> Int? {
        let count: Int, second: ClosedRange<UInt8>
        switch bytes[index] {
        case 0xC2...0xDF: (count, second) = (2, 0x80...0xBF)
        case 0xE0: (count, second) = (3, 0xA0...0xBF)
        case 0xE1...0xEC, 0xEE...0xEF: (count, second) = (3, 0x80...0xBF)
        case 0xED: (count, second) = (3, 0x80...0x9F)
        case 0xF0: (count, second) = (4, 0x90...0xBF)
        case 0xF1...0xF3: (count, second) = (4, 0x80...0xBF)
        case 0xF4: (count, second) = (4, 0x80...0x8F)
        default: return nil
        }
        guard bytes.count - index >= count, second.contains(bytes[index + 1]) else { return nil }
        for offset in 2..<count where !(0x80...0xBF).contains(bytes[index + offset]) { return nil }
        return count
    }

    /// Without `keep`, escapes, control characters and UTF-8 are checked but no text is built.
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
            if byte >= 0x80 {
                guard let length = utf8Length() else { return nil }
                index += length
                continue
            }
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
