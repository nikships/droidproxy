import Foundation

struct JournalInstant {
    let wall: Date
    let monotonic: UInt64

    static func now() -> JournalInstant {
        JournalInstant(wall: Date(), monotonic: DispatchTime.now().uptimeNanoseconds)
    }
}

enum JournalEnd {
    case eof, upstreamError, clientDisconnected, backendUnreachable
}

/// Relay callbacks arrive on concurrent queues, so every entry point is serialized by `lock`.
final class ResponseObservation {
    private enum Phase {
        case head, fixed, closeDelimited, chunkSize, chunkData, chunkDataEnd, trailers, ignored
    }
    private enum UsageFormat { case anthropic, responses, chat }
    private enum Counter { case absent, value(Int64), malformed }

    private static let cr: UInt8 = 13
    private static let lf: UInt8 = 10
    private static let headCap = 64 * 1024
    private static let sseLineCap = 256 * 1024
    private static let eventDataCap = 2 * 1024 * 1024
    private static let bodyCap = 2 * 1024 * 1024

    private let request: JournalRequest
    private let clock: () -> JournalInstant
    private let started: JournalInstant
    private let bindSeat: (String) -> JournalSeatBinding?
    private let emit: (@escaping () -> JournalRecord) -> Void
    private let lock = NSLock()

    private var phase = Phase.head
    private var line = Data()
    private var headBytes = 0
    private var sawStatusLine = false
    private var interim = false
    private var headers: [String: String] = [:]
    private var remaining = 0
    private var trailerBytes = 0
    private var malformed = false
    private var headOverflow = false
    private var sse = false
    private var opaque = false
    /// Set while scanning undelivered bytes: they may teach the status and trace but never fail the framing.
    private var learning = false

    private var body = Data()
    private var bodyOverflow = false
    private var sseLine = Data()
    private var sseLineOverflow = false
    private var afterCR = false
    private var eventName = ""
    private var eventData = Data()
    private var eventHasData = false
    private var discardEvent = false

    private var status: Int?
    private var sawTrace = false
    private var trace: String?
    private var execution = UUID().uuidString.lowercased()
    private var index: String?
    private var boundSeat: JournalSeatBinding?
    private var firstBody: UInt64?
    private var model: String?
    private var tokens: JournalTokens?
    private var chatPublished = false
    private var anthropicUsage: [String: JournalJSON] = [:]
    private var anthropicTerminal = false
    private var completed = false
    private var protocolError = false
    private var finalized = false

    /// `emit` receives a builder for the record; calling it parses the request body, so call it off the relay.
    init(request: JournalRequest, clock: @escaping () -> JournalInstant = JournalInstant.now,
         bindSeat: @escaping (String) -> JournalSeatBinding? = { _ in nil },
         emit: @escaping (@escaping () -> JournalRecord) -> Void) {
        self.request = request
        self.clock = clock
        self.started = clock()
        self.bindSeat = bindSeat
        self.emit = emit
    }

    /// Bytes a successful client write accepted; `readAt` is when the upstream read that carried them returned.
    /// Finalizes at this write when it reaches protocol completion, framing completion, or a protocol error.
    func delivered(_ data: Data, readAt: JournalInstant) {
        lock.lock()
        defer { lock.unlock() }
        guard !finalized else { return }
        consume(data, readAt: readAt)
        if protocolError { finalize("upstream_error") } else if completed { finalize("complete") }
    }

    /// A client write that accepted `accepted` and then failed; `undelivered` is the rest of its buffer.
    func writeFailed(accepted: Data, undelivered: Data, readAt: JournalInstant) {
        lock.lock()
        defer { lock.unlock() }
        guard !finalized else { return }
        consume(accepted, readAt: readAt)
        if phase == .head {
            learning = true
            consume(undelivered, readAt: readAt)
        }
        finalize(outcome(.clientDisconnected))
    }

    func finish(_ signal: JournalEnd) {
        lock.lock()
        defer { lock.unlock() }
        guard !finalized else { return }
        if case .eof = signal, phase == .closeDelimited, !sse { endBody() }
        finalize(outcome(signal))
    }

    private var stopped: Bool { phase == .ignored || completed || protocolError }

    private func consume(_ data: Data, readAt: JournalInstant) {
        var i = data.startIndex
        while i < data.endIndex, !stopped {
            switch phase {
            case .head:
                headByte(data[i])
                i += 1
            case .fixed, .chunkData:
                let n = min(remaining, data.endIndex - i)
                entity(data[i..<(i + n)], readAt: readAt)
                i += n
                remaining -= n
                if remaining == 0, !stopped {
                    if phase == .fixed { endBody() } else { phase = .chunkDataEnd }
                }
            case .closeDelimited:
                entity(data[i...], readAt: readAt)
                i = data.endIndex
            case .chunkSize:
                chunkSizeByte(data[i])
                i += 1
            case .chunkDataEnd:
                line.append(data[i])
                if line.first != Self.cr || (line.count == 2 && line.last != Self.lf) { violation() }
                else if line.count == 2 {
                    line.removeAll(keepingCapacity: true)
                    phase = .chunkSize
                }
                i += 1
            case .trailers:
                trailerByte(data[i])
                i += 1
            case .ignored:
                return
            }
        }
    }

    private func violation() {
        if !learning { malformed = true }
        phase = .ignored
        line = Data()
    }

    /// Appends to `line` and reports a CRLF-terminated line; a bare LF is a framing violation.
    private func lineByte(_ byte: UInt8) -> Bool {
        guard byte == Self.lf else {
            line.append(byte)
            return false
        }
        guard line.last == Self.cr else {
            violation()
            return false
        }
        line.removeLast()
        return true
    }

    private func headByte(_ byte: UInt8) {
        headBytes += 1
        if lineByte(byte) {
            headLine()
            line.removeAll(keepingCapacity: true)
        }
        if phase == .head, headBytes >= Self.headCap {
            if !learning { headOverflow = true }
            phase = .ignored
            line = Data()
        }
    }

    private static func isToken(_ byte: UInt8) -> Bool {
        switch byte {
        case 0x30...0x39, 0x41...0x5A, 0x61...0x7A: return true
        default: return Array("!#$%&'*+-.^_`|~".utf8).contains(byte)
        }
    }

    private static func isHex(_ byte: UInt8) -> Bool {
        (0x30...0x39).contains(byte) || (0x41...0x46).contains(byte) || (0x61...0x66).contains(byte)
    }

    private static func statusCode(_ line: Data) -> Int? {
        let b = [UInt8](line)
        guard b.count >= 12, b[0..<7].elementsEqual("HTTP/1.".utf8), b[7] == 0x30 || b[7] == 0x31, b[8] == 0x20,
              b[9..<12].allSatisfy({ (0x30...0x39).contains($0) }), b.count == 12 || b[12] == 0x20,
              let code = Int(String(decoding: b[9..<12], as: UTF8.self)), (100...599).contains(code) else { return nil }
        return code
    }

    private func headLine() {
        if !sawStatusLine {
            sawStatusLine = true
            guard let code = Self.statusCode(line) else { return violation() }
            interim = code < 200
            if !interim { status = code }
            return
        }
        if line.isEmpty {
            if interim {
                sawStatusLine = false
                interim = false
                headBytes = 0
            } else if learning {
                phase = .ignored
            } else {
                beginBody()
            }
            return
        }
        guard let colon = line.firstIndex(of: 58), colon > line.startIndex,
              line[..<colon].allSatisfy(Self.isToken) else { return violation() }
        guard !interim else { return }
        let name = String(decoding: line[..<colon], as: UTF8.self).lowercased()
        let value = String(decoding: line[(colon + 1)...], as: UTF8.self).trimmingCharacters(in: CharacterSet(charactersIn: " \t"))
        if name == "x-cpa-trace-id", !sawTrace {
            sawTrace = true
            learnTrace(value)
        }
        guard !learning else { return }
        switch name {
        case "transfer-encoding", "content-encoding":
            headers[name] = headers[name].map { "\($0),\(value)" } ?? value
        case "content-length":
            if let prior = headers[name], prior != value { return violation() }
            headers[name] = value
        default:
            headers[name] = value
        }
    }

    private func learnTrace(_ value: String) {
        trace = value.isEmpty ? nil : value
        let pieces = value.split(separator: "-", maxSplits: 2, omittingEmptySubsequences: false).map(String.init)
        guard pieces.count == 3, Self.matches(pieces[2], "^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[1-8][0-9a-fA-F]{3}-[89abAB][0-9a-fA-F]{3}-[0-9a-fA-F]{12}$") else { return }
        execution = pieces[2]
        if Self.matches(pieces[0], "^[0-9]{14}$"), Self.matches(pieces[1], "^[0-9a-f]{16}$") {
            index = pieces[1]
            boundSeat = bindSeat(pieces[1])
        }
    }

    private static func matches(_ value: String, _ pattern: String) -> Bool {
        value.range(of: pattern, options: .regularExpression) != nil
    }

    private static func codings(_ value: String?) -> [String] {
        (value ?? "").split(separator: ",").map { $0.trimmingCharacters(in: CharacterSet(charactersIn: " \t")).lowercased() }.filter { !$0.isEmpty }
    }

    private func beginBody() {
        sse = headers["content-type"]?.split(separator: ";", maxSplits: 1, omittingEmptySubsequences: false).first
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: " \t")).lowercased() } == "text/event-stream"
        let transfer = Self.codings(headers["transfer-encoding"])
        opaque = Self.codings(headers["content-encoding"]).contains { $0 != "identity" } || transfer.contains { $0 != "chunked" }
        if status == 204 || status == 304 { return endBody() }
        if !transfer.isEmpty {
            phase = transfer.last == "chunked" ? .chunkSize : .closeDelimited
        } else if let length = headers["content-length"] {
            guard !length.isEmpty, length.utf8.allSatisfy({ (0x30...0x39).contains($0) }), let n = Int(length) else { return violation() }
            remaining = n
            phase = .fixed
            if n == 0 { endBody() }
        } else {
            phase = .closeDelimited
        }
    }

    private func chunkSizeByte(_ byte: UInt8) {
        guard lineByte(byte) else {
            if phase == .chunkSize, line.count > Self.headCap { violation() }
            return
        }
        let size = line.prefix { $0 != UInt8(ascii: ";") }
        guard !size.isEmpty, size.allSatisfy(Self.isHex), size.drop(while: { $0 == 0x30 }).count <= 15,
              let count = Int(String(decoding: size, as: UTF8.self), radix: 16) else { return violation() }
        line.removeAll(keepingCapacity: true)
        remaining = count
        phase = count == 0 ? .trailers : .chunkData
    }

    private func trailerByte(_ byte: UInt8) {
        trailerBytes += 1
        if trailerBytes > Self.headCap { return violation() }
        guard lineByte(byte) else { return }
        if line.isEmpty { return endBody() }
        guard let colon = line.firstIndex(of: 58), colon > line.startIndex,
              line[..<colon].allSatisfy(Self.isToken) else { return violation() }
        line.removeAll(keepingCapacity: true)
    }

    private func entity(_ bytes: Data, readAt: JournalInstant) {
        guard !bytes.isEmpty else { return }
        if firstBody == nil { firstBody = readAt.monotonic }
        guard !opaque else { return }
        if sse {
            scanSSE(bytes)
        } else if !bodyOverflow {
            if body.count + bytes.count > Self.bodyCap {
                bodyOverflow = true
                body = Data()
            } else {
                body.append(bytes)
            }
        }
    }

    private func scanSSE(_ bytes: Data) {
        var i = bytes.startIndex
        while i < bytes.endIndex, !stopped {
            let byte = bytes[i]
            if byte == Self.lf || byte == Self.cr {
                let crlf = byte == Self.lf && afterCR
                afterCR = byte == Self.cr
                if !crlf { endSSELine() }
                i += 1
                continue
            }
            afterCR = false
            let end = bytes[i...].firstIndex { $0 == Self.lf || $0 == Self.cr } ?? bytes.endIndex
            if !sseLineOverflow {
                if sseLine.count + (end - i) > Self.sseLineCap {
                    sseLineOverflow = true
                    sseLine = Data()
                } else {
                    sseLine.append(bytes[i..<end])
                }
            }
            i = end
        }
    }

    private func endSSELine() {
        defer {
            sseLine.removeAll(keepingCapacity: true)
            sseLineOverflow = false
        }
        if sseLineOverflow { return discardCurrentEvent() }
        if sseLine.isEmpty { return dispatchEvent() }
        if discardEvent || sseLine.first == 58 { return }
        let colon = sseLine.firstIndex(of: 58)
        let name = sseLine[..<(colon ?? sseLine.endIndex)]
        var value = colon.map { sseLine[($0 + 1)...] } ?? sseLine[sseLine.endIndex...]
        if value.first == 0x20 { value = value.dropFirst() }
        if name.elementsEqual("event".utf8) {
            eventName = String(decoding: value, as: UTF8.self)
        } else if name.elementsEqual("data".utf8) {
            if eventData.count + value.count + (eventHasData ? 1 : 0) > Self.eventDataCap { return discardCurrentEvent() }
            if eventHasData { eventData.append(Self.lf) }
            eventData.append(value)
            eventHasData = true
        }
    }

    private func discardCurrentEvent() {
        discardEvent = true
        eventData = Data()
    }

    private func dispatchEvent() {
        defer {
            eventName = ""
            eventData.removeAll(keepingCapacity: true)
            eventHasData = false
            discardEvent = false
        }
        guard !discardEvent, eventHasData else { return }
        let payload = JournalJSON.parse(eventData)?.object
        if let payload { reportModel(payload) }
        if eventName == "error" {
            protocolError = true
            return
        }
        if eventData.elementsEqual("[DONE]".utf8) {
            completed = true
            return
        }
        guard let object = payload else { return }
        let type = object["type"]
        if let name = type?.string, ["error", "response.failed", "response.error"].contains(name) {
            protocolError = true
            return
        }
        if type == nil, let error = object["error"], error != .null {
            protocolError = true
            return
        }
        switch type?.string {
        case "message_start":
            mergeAnthropic(object["message"]?["usage"], delta: false)
        case "message_delta":
            mergeAnthropic(object["usage"], delta: true)
        case "message_stop":
            completed = true
        case "response.completed", "response.incomplete":
            tokens = Self.normalize(object["response"]?["usage"], format: .responses)
            completed = true
        default:
            guard let usage = object["usage"], usage != .null else { return }
            let choices = object["choices"]?.array
            let qualifies = choices?.isEmpty == true || choices?.contains { $0["finish_reason"]?.string != nil } == true
            if qualifies || chatPublished {
                chatPublished = true
                tokens = Self.normalize(usage, format: .chat)
            }
        }
    }

    private func mergeAnthropic(_ usage: JournalJSON?, delta: Bool) {
        guard let usage = usage?.object else { return }
        anthropicUsage.merge(usage) { $1 }
        if delta, usage["output_tokens"] != nil { anthropicTerminal = true }
        if anthropicTerminal { tokens = Self.normalize(.object(anthropicUsage), format: .anthropic) }
    }

    private func reportModel(_ object: [String: JournalJSON]) {
        for candidate in [object["model"], object["message"]?["model"], object["response"]?["model"]] {
            if let value = candidate?.string, !value.isEmpty { model = value }
        }
    }

    private func endBody() {
        completed = true
        phase = .ignored
        defer { body = Data() }
        guard !sse, !opaque, !bodyOverflow, let object = JournalJSON.parse(body)?.object else { return }
        reportModel(object)
        let format: UsageFormat
        switch request.forwardedEndpoint ?? request.endpoint {
        case "/v1/messages" where object["type"]?.string == "message": format = .anthropic
        case "/v1/responses", "/backend-api/codex/responses":
            guard object["object"]?.string == "response" else { return }
            format = .responses
        case "/v1/chat/completions" where object["object"]?.string == "chat.completion": format = .chat
        case "/v1/completions" where object["object"]?.string == "text_completion": format = .chat
        default: return
        }
        tokens = Self.normalize(object["usage"], format: format)
    }

    private static func counter(_ value: JournalJSON?) -> Counter {
        guard let value, value != .null else { return .absent }
        guard case .number(let literal) = value, literal.utf8.allSatisfy({ (0x30...0x39).contains($0) }),
              let n = Int64(literal) else { return .malformed }
        return .value(n)
    }

    private static func required(_ value: JournalJSON?) -> Int64? {
        if case .value(let n) = counter(value) { return n }
        return nil
    }

    /// `.some(nil)` when absent or null; nil when present and malformed.
    private static func optional(_ value: JournalJSON?) -> Int64?? {
        switch counter(value) {
        case .absent: return .some(nil)
        case .value(let n): return .some(n)
        case .malformed: return nil
        }
    }

    private static func details(_ value: JournalJSON?) -> [String: JournalJSON]? {
        guard let value, value != .null else { return [:] }
        return value.object
    }

    private static func normalize(_ usage: JournalJSON?, format: UsageFormat) -> JournalTokens? {
        guard let usage = usage?.object else { return nil }
        if format == .anthropic {
            guard let input = required(usage["input_tokens"]), let output = required(usage["output_tokens"]),
                  let read = optional(usage["cache_read_input_tokens"]),
                  let creation = optional(usage["cache_creation_input_tokens"]) else { return nil }
            return JournalTokens(input_uncached: input, cache_read: read ?? 0, cache_creation: creation ?? 0, output: output, reasoning: nil)
        }
        let chat = format == .chat
        guard let input = required(usage[chat ? "prompt_tokens" : "input_tokens"]),
              let output = required(usage[chat ? "completion_tokens" : "output_tokens"]),
              let inputDetails = details(usage[chat ? "prompt_tokens_details" : "input_tokens_details"]),
              let outputDetails = details(usage[chat ? "completion_tokens_details" : "output_tokens_details"]),
              let cached = optional(inputDetails["cached_tokens"]), (cached ?? 0) <= input,
              let reasoning = optional(outputDetails["reasoning_tokens"]) else { return nil }
        var creation: Int64?
        if chat {
            guard let write = optional(inputDetails["cache_write_tokens"]),
                  let fallback = optional(inputDetails["cached_creation_tokens"]) else { return nil }
            creation = write ?? fallback
        }
        return JournalTokens(input_uncached: input - (cached ?? 0), cache_read: cached ?? 0, cache_creation: creation, output: output, reasoning: reasoning)
    }

    private func outcome(_ signal: JournalEnd) -> String {
        if malformed || headOverflow { return "upstream_error" }
        switch signal {
        case .clientDisconnected: return "client_disconnected"
        case .backendUnreachable: return "backend_unreachable"
        case .upstreamError: return completed ? "complete" : "upstream_error"
        case .eof: return protocolError ? "upstream_error" : completed ? "complete" : "upstream_closed_early"
        }
    }

    private func finalize(_ outcome: String) {
        finalized = true
        if outcome == "backend_unreachable" { status = 502 }
        let ended = clock()
        let latency = Self.milliseconds(started.monotonic, ended.monotonic)
        var seat: JournalSeat?
        if let index {
            seat = boundSeat.flatMap { $0.isValid() ? $0.identity : nil } ?? JournalSeat(auth_index: index, role: "last_tried")
            seat?.role = status.map { (200..<300).contains($0) } == true ? "served" : "last_tried"
        }
        let unusable = malformed || headOverflow
        let (request, execution, trace, status) = (request, execution, trace, status)
        let ttft = firstBody.map { min(latency, Self.milliseconds(started.monotonic, $0)) }
        let model = headOverflow ? nil : model
        let tokens = unusable ? nil : tokens
        let (startedAt, endedAt) = (Self.timestamp(started.wall), Self.timestamp(ended.wall))
        emit {
            let fields = request.fields
            return JournalRecord(
                execution_id: execution, trace_id: trace, started_at: startedAt, ended_at: endedAt,
                latency_ms: latency, ttft_ms: ttft,
                origin: request.origin, endpoint: request.endpoint, forwarded_endpoint: request.forwardedEndpoint,
                provider: fields.provider, requested_model: fields.model, response_model: model,
                status: status, outcome: outcome, seat: seat, client_session: fields.session, tokens: tokens
            )
        }
    }

    private static func milliseconds(_ start: UInt64, _ end: UInt64) -> Int {
        end >= start ? Int((end - start) / 1_000_000) : 0
    }

    private static let timestampFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static func timestamp(_ date: Date) -> String {
        timestampFormatter.string(from: date)
    }
}
