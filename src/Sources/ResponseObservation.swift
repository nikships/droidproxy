import Foundation

struct JournalInstant {
    let wall: Date
    let monotonic: UInt64

    static func now() -> JournalInstant {
        JournalInstant(wall: Date(), monotonic: DispatchTime.now().uptimeNanoseconds)
    }
}

enum JournalEnd {
    case delivered, eof, upstreamError, clientDisconnected, backendUnreachable
}

/// Relay callbacks arrive on concurrent queues, so `feed` and `finish` are serialized by `lock`.
final class ResponseObservation {
    private enum Framing {
        case head, fixed, closeDelimited, chunkSize, chunkBody, chunkCRLF, trailers, done, opaque
    }
    private let request: JournalRequest
    private let clock: () -> JournalInstant
    private let started: JournalInstant
    private let bindSeat: (String) -> JournalSeatBinding?
    private let emit: (JournalRecord) -> Void
    private let lock = NSLock()
    private var framing = Framing.head
    private var sawStatusLine = false
    private var scratch = Data()
    private var remaining = 0
    private var trailerBytes = 0
    private var body = Data()
    private var line = Data()
    private var event = ""
    private var eventData = Data()
    private var scanning = true
    private var sse = false
    private var compressed = false
    private var status: Int?
    private var trace: String?
    private var execution = UUID().uuidString.lowercased()
    private var index: String?
    private var boundSeat: JournalSeatBinding?
    private var firstBody: UInt64?
    private var model: String?
    private var tokens: JournalTokens?
    private var chatUsage: JournalTokens?
    private var sawChatUsage = false
    private var anthropicUsage: [String: Any] = [:]
    private var completed = false
    private var protocolError = false
    private var finalized = false

    init(request: JournalRequest, clock: @escaping () -> JournalInstant = JournalInstant.now,
         bindSeat: @escaping (String) -> JournalSeatBinding? = { _ in nil },
         emit: @escaping (JournalRecord) -> Void) {
        self.request = request
        self.clock = clock
        self.started = clock()
        self.bindSeat = bindSeat
        self.emit = emit
    }

    func feed(_ data: Data) {
        lock.lock()
        defer { lock.unlock() }
        guard !finalized else { return }
        let now = clock()
        for byte in data {
            switch framing {
            case .head:
                scratch.append(byte)
                if !sawStatusLine, scratch.suffix(2).elementsEqual([13, 10]) {
                    sawStatusLine = true
                    let parts = String(decoding: scratch.dropLast(2), as: UTF8.self).split(separator: " ")
                    if parts.count >= 2, ["HTTP/1.0", "HTTP/1.1"].contains(String(parts[0])),
                       let code = Int(parts[1]), (100...599).contains(code) {
                        if code >= 200 { status = code }
                    } else {
                        malformed()
                    }
                }
                if scratch.count > 64 * 1024 {
                    scratch.removeAll()
                    framing = .opaque
                } else if scratch.suffix(4).elementsEqual([13, 10, 13, 10]) {
                    parseHead()
                }
            case .fixed:
                entity(byte, now: now)
                remaining -= 1
                if remaining == 0 { endBody() }
            case .closeDelimited:
                entity(byte, now: now)
            case .chunkSize:
                scratch.append(byte)
                if scratch.count > 64 * 1024 { malformed() }
                else if scratch.suffix(2).elementsEqual([13, 10]) {
                    let raw = String(decoding: scratch.dropLast(2), as: UTF8.self)
                    let size = raw.split(separator: ";", maxSplits: 1, omittingEmptySubsequences: false)[0]
                    guard !size.isEmpty, size.allSatisfy({ $0.isASCII && $0.isHexDigit }),
                          let count = Int(size, radix: 16) else { malformed(); continue }
                    scratch.removeAll(keepingCapacity: true)
                    remaining = count
                    framing = count == 0 ? .trailers : .chunkBody
                }
            case .chunkBody:
                entity(byte, now: now)
                remaining -= 1
                if remaining == 0 { framing = .chunkCRLF }
            case .chunkCRLF:
                scratch.append(byte)
                if (scratch.count == 1 && byte != 13) || (scratch.count == 2 && byte != 10) { malformed() }
                else if scratch.count == 2 {
                    scratch.removeAll(keepingCapacity: true)
                    framing = .chunkSize
                }
            case .trailers:
                trailerBytes += 1
                scratch.append(byte)
                if trailerBytes > 64 * 1024 { malformed() }
                else if scratch.suffix(2).elementsEqual([13, 10]) {
                    if scratch.count == 2 { endBody() }
                    else if !scratch.dropLast(2).contains(58) { malformed() }
                    scratch.removeAll(keepingCapacity: true)
                }
            case .done, .opaque:
                break
            }
        }
    }

    private func malformed() {
        if !completed { protocolError = true }
        framing = .opaque
        scratch.removeAll()
    }

    private func parseHead() {
        let lines = String(decoding: scratch, as: UTF8.self).components(separatedBy: "\r\n")
        scratch.removeAll(keepingCapacity: true)
        let parts = (lines.first ?? "").split(separator: " ", omittingEmptySubsequences: true)
        guard parts.count >= 2, parts[0].hasPrefix("HTTP/1."),
              let code = Int(parts[1]), (100...599).contains(code) else { malformed(); return }
        if (100..<200).contains(code) { sawStatusLine = false; return }
        status = code
        var headers: [String: String] = [:]
        for line in lines.dropFirst() where !line.isEmpty {
            guard let colon = line.firstIndex(of: ":") else { malformed(); return }
            let name = line[..<colon].lowercased()
            let value = String(line[line.index(after: colon)...]).trimmingCharacters(in: CharacterSet(charactersIn: " \t"))
            if let prior = headers[name], name == "content-length", prior != value { malformed(); return }
            headers[name] = value
        }
        trace = headers["x-cpa-trace-id"].flatMap { $0.isEmpty ? nil : $0 }
        if let trace {
            let pieces = trace.split(separator: "-", maxSplits: 2, omittingEmptySubsequences: false).map(String.init)
            if pieces.count == 3, Self.matches(pieces[2], "^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[1-8][0-9a-fA-F]{3}-[89abAB][0-9a-fA-F]{3}-[0-9a-fA-F]{12}$") {
                execution = pieces[2]
                if Self.matches(pieces[0], "^[0-9]{14}$"), Self.matches(pieces[1], "^[0-9a-f]{16}$") {
                    index = pieces[1]
                    boundSeat = bindSeat(pieces[1])
                }
            }
        }
        sse = headers["content-type"]?.lowercased().split(separator: ";").first == "text/event-stream"
        compressed = headers["content-encoding"].map { $0.lowercased() != "identity" && !$0.isEmpty } ?? false
        if code == 204 || code == 304 { endBody(); return }
        if let transfer = headers["transfer-encoding"] {
            guard transfer.lowercased() == "chunked" else { malformed(); return }
            framing = .chunkSize
        } else if let length = headers["content-length"] {
            guard !length.isEmpty, length.allSatisfy({ $0.isASCII && $0.isNumber }),
                  let n = Int(length) else { malformed(); return }
            remaining = n
            framing = .fixed
            if n == 0 { endBody() }
        } else {
            framing = .closeDelimited
        }
    }

    private static func matches(_ value: String, _ pattern: String) -> Bool {
        value.range(of: pattern, options: .regularExpression) != nil
    }

    private func entity(_ byte: UInt8, now: JournalInstant) {
        if firstBody == nil { firstBody = now.monotonic }
        guard scanning, !compressed, !completed, !protocolError else { return }
        if sse {
            if byte == 10 {
                if line.last == 13 { line.removeLast() }
                sseLine()
                line.removeAll(keepingCapacity: true)
            } else {
                line.append(byte)
                if line.count > 256 * 1024 { stopScanning() }
            }
        } else {
            body.append(byte)
            if body.count > 2 * 1024 * 1024 { stopScanning() }
        }
    }

    private func stopScanning() {
        scanning = false
        line.removeAll()
        eventData.removeAll()
        body.removeAll()
    }

    private func sseLine() {
        if line.isEmpty {
            processEvent()
            event = ""
            eventData.removeAll(keepingCapacity: true)
            return
        }
        let text = String(decoding: line, as: UTF8.self)
        if text.hasPrefix("event:") {
            event = String(text.dropFirst(6)).trimmingCharacters(in: CharacterSet(charactersIn: " "))
        } else if text.hasPrefix("data:") {
            var value = text.dropFirst(5)
            if value.first == " " { value = value.dropFirst() }
            if !eventData.isEmpty { eventData.append(10) }
            eventData.append(contentsOf: value.utf8)
            if eventData.count > 2 * 1024 * 1024 { stopScanning() }
        }
    }

    private func reportedModel(_ object: [String: Any]) {
        if let value = object["model"] as? String, !value.isEmpty { model = value }
    }

    private func processEvent() {
        guard !completed, !protocolError else { return }
        if eventData == Data("[DONE]".utf8) {
            if sawChatUsage { tokens = chatUsage }
            completed = true
            return
        }
        guard let object = try? JSONSerialization.jsonObject(with: eventData) as? [String: Any] else {
            if event == "error" { protocolError = true }
            return
        }
        let type = object["type"] as? String ?? event
        reportedModel(object)
        if let response = object["response"] as? [String: Any] { reportedModel(response) }
        if let message = object["message"] as? [String: Any] { reportedModel(message) }
        if event == "error" || object["error"] is [String: Any] {
            protocolError = true
            return
        }
        switch type {
        case "error", "response.failed", "response.error":
            protocolError = true
        case "message_start":
            anthropicUsage = (object["message"] as? [String: Any])?["usage"] as? [String: Any] ?? [:]
        case "message_delta":
            if let usage = object["usage"] as? [String: Any] {
                anthropicUsage.merge(usage) { _, new in new }
                tokens = usage["output_tokens"] == nil ? nil : Self.normalize(anthropicUsage, format: "anthropic")
            }
        case "message_stop":
            completed = true
        case "response.completed", "response.incomplete":
            if let response = object["response"] as? [String: Any],
               let usage = response["usage"] as? [String: Any] {
                tokens = Self.normalize(usage, format: "responses")
            }
            completed = true
        default:
            if let usage = object["usage"] as? [String: Any], let choices = object["choices"] as? [[String: Any]] {
                sawChatUsage = true
                chatUsage = Self.normalize(usage, format: "chat")
                let finalChunk = choices.isEmpty || choices.contains { $0["finish_reason"] != nil && !($0["finish_reason"] is NSNull) }
                tokens = finalChunk ? chatUsage : nil
            }
        }
    }

    private func endBody() {
        framing = .done
        if !sse && scanning && !compressed {
            if let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any] {
                reportedModel(object)
                if let usage = object["usage"] as? [String: Any] {
                    let format: String
                    if object["object"] as? String == "response" { format = "responses" }
                    else if usage["prompt_tokens"] != nil { format = "chat" }
                    else if object["type"] as? String == "message" || request.endpoint == "/v1/messages" { format = "anthropic" }
                    else { format = "responses" }
                    tokens = Self.normalize(usage, format: format)
                }
            }
        }
        if !protocolError { completed = true }
        body.removeAll()
    }

    private static func counter(_ value: Any?) -> Int64? {
        guard let n = value as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID() else { return nil }
        let d = n.doubleValue
        guard d >= 0, d < Double(Int64.max), d.rounded(.down) == d else { return nil }
        return n.int64Value
    }

    private static func normalize(_ usage: [String: Any], format: String) -> JournalTokens? {
        let anthropic = format == "anthropic"
        let chat = format == "chat"
        guard let input = counter(usage[chat ? "prompt_tokens" : "input_tokens"]),
              let output = counter(usage[chat ? "completion_tokens" : "output_tokens"]) else { return nil }
        if anthropic {
            guard let read = counter(usage["cache_read_input_tokens"] ?? 0),
                  let creation = counter(usage["cache_creation_input_tokens"] ?? 0) else { return nil }
            return JournalTokens(input_uncached: input, cache_read: read, cache_creation: creation, output: output, reasoning: nil)
        }
        let inputKey = chat ? "prompt_tokens_details" : "input_tokens_details"
        let outputKey = chat ? "completion_tokens_details" : "output_tokens_details"
        if let details = usage[inputKey], !(details is [String: Any]) { return nil }
        if let details = usage[outputKey], !(details is [String: Any]) { return nil }
        let details = usage[inputKey] as? [String: Any] ?? [:]
        let outDetails = usage[outputKey] as? [String: Any] ?? [:]
        guard let cached = counter(details["cached_tokens"] ?? 0), cached <= input else { return nil }
        var creation: Int64?
        if chat, let value = details["cache_write_tokens"] ?? details["cached_creation_tokens"] {
            guard let count = counter(value) else { return nil }
            creation = count
        }
        var reasoning: Int64?
        if let value = outDetails["reasoning_tokens"] {
            guard let count = counter(value) else { return nil }
            reasoning = count
        }
        return JournalTokens(input_uncached: input - cached, cache_read: cached, cache_creation: creation, output: output, reasoning: reasoning)
    }

    /// `.delivered` checks for framing completion; other signals finalize immediately.
    func finish(_ signal: JournalEnd) {
        lock.lock()
        defer { lock.unlock() }
        guard !finalized else { return }
        if case .delivered = signal, !completed, !protocolError { return }
        if case .eof = signal, framing == .closeDelimited, !sse { endBody() }
        let outcome: String
        switch signal {
        case .clientDisconnected: outcome = "client_disconnected"
        case .backendUnreachable: outcome = "backend_unreachable"; status = 502
        case .upstreamError: outcome = completed ? "complete" : "upstream_error"
        case .delivered, .eof:
            outcome = protocolError ? "upstream_error" : completed ? "complete" : "upstream_closed_early"
        }
        finalized = true
        let ended = clock()
        let latency = Self.milliseconds(started.monotonic, ended.monotonic)
        var seat: JournalSeat?
        if let index {
            seat = boundSeat.flatMap { $0.isValid() ? $0.identity : nil } ?? JournalSeat(auth_index: index, role: "last_tried")
            seat?.role = status.map { (200..<300).contains($0) } == true ? "served" : "last_tried"
        }
        emit(JournalRecord(
            execution_id: execution, trace_id: trace,
            started_at: Self.timestamp(started.wall), ended_at: Self.timestamp(ended.wall),
            latency_ms: latency, ttft_ms: firstBody.map { min(latency, Self.milliseconds(started.monotonic, $0)) },
            origin: request.origin, endpoint: request.endpoint, forwarded_endpoint: request.forwardedEndpoint,
            provider: request.provider, requested_model: request.model, response_model: model,
            status: status, outcome: outcome, seat: seat, client_session: request.session, tokens: tokens
        ))
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
