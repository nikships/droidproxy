import XCTest
import Network
import Darwin
import os
@testable import CLIProxyMenuBar

final class RequestJournalRelayTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("journal-relay-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: directory)
    }

    private func startProxy(targetPort: UInt16, journal: RequestJournal?) throws -> ThinkingProxy {
        let reservation = try LoopbackSocket()
        let port = reservation.port
        reservation.close()
        let proxy = ThinkingProxy(proxyPort: port, targetPort: targetPort, journal: { journal })
        proxy.start()
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in proxy.isRunning }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 3), .completed)
        return proxy
    }

    private func journal() -> RequestJournal {
        RequestJournal(directory: directory.appendingPathComponent("journal"), authDirectory: directory.appendingPathComponent("auth"))
    }

    private func records() throws -> [JournalRecord] {
        let journal = directory.appendingPathComponent("journal")
        guard FileManager.default.fileExists(atPath: journal.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(at: journal, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "jsonl" }
            .flatMap { try String(contentsOf: $0).split(separator: "\n").map {
                let data = Data($0.utf8)
                XCTAssertTrue(try JournalSchema.bundled().valid(JSONSerialization.jsonObject(with: data)))
                return try JSONDecoder().decode(JournalRecord.self, from: data)
            } }
    }

    private func request(path: String = "/v1/messages", model: String = "claude-journal-fixture") -> Data {
        let body = #"{"model":"\#(model)","prompt_cache_key":"relay-session-0001"}"#
        return Data(("POST \(path) HTTP/1.1\r\nHost: localhost\r\nAccept-Encoding: gzip\r\nX-DroidProxy-Origin: window-primer\r\nContent-Type: application/json\r\nContent-Length: \(body.utf8.count)\r\n\r\n" + body).utf8)
    }

    func testDisabledRelayPreservesBodyResponseAndEncodingHeader() throws {
        let upstream = try LoopbackSocket()
        defer { upstream.close() }
        let received = expectation(description: "upstream received unobserved request")
        let response = Data("HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\n{}".utf8)
        var forwarded = Data()
        upstream.serve { fd, data in
            forwarded = data
            LoopbackSocket.sendAll(response, fd: fd)
            received.fulfill()
        }
        let proxy = try startProxy(targetPort: upstream.port, journal: nil)
        defer { proxy.stop() }
        let fd = try LoopbackSocket.connect(port: proxy.proxyPort)
        defer { Darwin.close(fd) }
        let original = request()
        LoopbackSocket.sendAll(original, fd: fd)
        XCTAssertEqual(LoopbackSocket.readToEOF(fd), response)
        wait(for: [received], timeout: 3)
        let text = String(decoding: forwarded, as: UTF8.self)
        XCTAssertTrue(text.contains("Accept-Encoding: gzip\r\n"))
        XCTAssertFalse(text.lowercased().contains("x-droidproxy-origin:"))
        XCTAssertEqual(text.components(separatedBy: "\r\n\r\n").last,
                       String(decoding: original, as: UTF8.self).components(separatedBy: "\r\n\r\n").last)
        XCTAssertTrue(try records().isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("journal").path))
    }

    func testObservedStreamedAndNonStreamedExchanges() throws {
        for streamed in [false, true] {
            let auth = directory.appendingPathComponent("auth")
            try FileManager.default.createDirectory(at: auth, withIntermediateDirectories: true)
            let seat = auth.appendingPathComponent("seat.json")
            try Data(#"{"type":"claude","email":"seat@example.invalid","organization_uuid":"org-fixture"}"#.utf8).write(to: seat)
            let index = JournalSeatIndex.index(type: "claude", path: seat.path)
            let trace = "20261111100000-\(index)-019a7140-0000-7000-8000-000000000001"
            let json = #"{"type":"message","model":"actual-model","usage":{"input_tokens":3,"output_tokens":5}}"#
            let events = "event: message_start\ndata: {\"type\":\"message_start\",\"message\":{\"model\":\"actual-model\",\"usage\":{\"input_tokens\":3}}}\n\n"
                + "event: message_delta\ndata: {\"type\":\"message_delta\",\"usage\":{\"output_tokens\":5}}\n\n"
                + "event: message_stop\ndata: {\"type\":\"message_stop\"}\n\n"
            let head = "HTTP/1.1 200 OK\r\nX-CPA-TRACE-ID: \(trace)\r\n"
            let response: Data
            if streamed {
                response = Data((head + "Content-Type: text/event-stream\r\nTransfer-Encoding: chunked\r\n\r\n"
                    + "\(String(events.utf8.count, radix: 16))\r\n\(events)\r\n0\r\n\r\n").utf8)
            } else {
                response = Data((head + "Content-Type: application/json\r\nContent-Length: \(json.utf8.count)\r\n\r\n" + json).utf8)
            }
            let upstream = try LoopbackSocket()
            let received = expectation(description: "observed request \(streamed)")
            var forwarded = Data()
            upstream.serve { fd, data in
                forwarded = data
                LoopbackSocket.sendAll(Data(response.prefix(response.count / 2)), fd: fd)
                LoopbackSocket.sendAll(Data(response.dropFirst(response.count / 2)), fd: fd)
                received.fulfill()
            }
            let journal = journal()
            let proxy = try startProxy(targetPort: upstream.port, journal: journal)
            let fd = try LoopbackSocket.connect(port: proxy.proxyPort)
            LoopbackSocket.sendAll(request(), fd: fd)
            XCTAssertEqual(LoopbackSocket.readToEOF(fd), response)
            Darwin.close(fd)
            wait(for: [received], timeout: 3)
            journal.flush()
            let record = try XCTUnwrap(records().last)
            XCTAssertEqual(record.outcome, "complete")
            XCTAssertEqual(record.status, 200)
            XCTAssertEqual(record.origin, "primer")
            XCTAssertEqual(record.client_session, "relay-session-0001")
            XCTAssertEqual(record.requested_model, "claude-journal-fixture")
            XCTAssertEqual(record.response_model, "actual-model")
            XCTAssertEqual(record.tokens, JournalTokens(input_uncached: 3, cache_read: 0, cache_creation: 0, output: 5, reasoning: nil))
            XCTAssertEqual(record.seat?.email, "seat@example.invalid")
            XCTAssertEqual(record.seat?.org, "org-fixture")
            let text = String(decoding: forwarded, as: UTF8.self).lowercased()
            XCTAssertFalse(text.contains("accept-encoding:"))
            XCTAssertFalse(text.contains("x-droidproxy-origin:"))
            proxy.stop()
            upstream.close()
        }
        XCTAssertEqual(try records().count, 2)
    }

    func testOriginalModelAndPathSurviveRewriteAndHeadersTrimOnlyHTTPWhitespace() throws {
        let upstream = try LoopbackSocket()
        defer { upstream.close() }
        let received = expectation(description: "rewritten request")
        var forwarded = ""
        upstream.serve { fd, data in
            forwarded = String(decoding: data, as: UTF8.self)
            LoopbackSocket.sendAll(Data("HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\n{}".utf8), fd: fd)
            received.fulfill()
        }
        let journal = journal()
        let proxy = try startProxy(targetPort: upstream.port, journal: journal)
        defer { proxy.stop() }
        let fd = try LoopbackSocket.connect(port: proxy.proxyPort)
        defer { Darwin.close(fd) }
        let raw = String(decoding: request(path: "/v1/responses?x=1", model: "gemini-3.1-pro-preview"), as: UTF8.self)
            .replacingOccurrences(of: "Host: localhost\r\n", with: "Host: localhost\r\nX-Session-ID: \u{00a0}header-session-0001\r\n")
        LoopbackSocket.sendAll(Data(raw.utf8), fd: fd)
        _ = LoopbackSocket.readToEOF(fd)
        wait(for: [received], timeout: 3)
        journal.flush()
        let record = try XCTUnwrap(records().first)
        XCTAssertEqual(record.endpoint, "/v1/responses")
        XCTAssertEqual(record.forwarded_endpoint, "/v1/chat/completions")
        XCTAssertEqual(record.requested_model, "gemini-3.1-pro-preview")
        XCTAssertEqual(record.provider, "gemini")
        XCTAssertEqual(record.client_session, "relay-session-0001")
        XCTAssertTrue(forwarded.hasPrefix("POST /v1/chat/completions?x=1 HTTP/1.1\r\n"))
    }

    func testTerminalSSEEventDoesNotTruncateLaterHTTPFraming() throws {
        let upstream = try LoopbackSocket()
        defer { upstream.close() }
        let finished = expectation(description: "late chunk terminator sent")
        let release = DispatchSemaphore(value: 0)
        let body = "data: [DONE]\n\n"
        let first = Data(("HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nTransfer-Encoding: chunked\r\n\r\n"
            + "\(String(body.utf8.count, radix: 16))\r\n\(body)\r\n").utf8)
        let last = Data("0\r\nX-End: yes\r\n\r\n".utf8)
        upstream.serve { fd, _ in
            LoopbackSocket.sendAll(first, fd: fd)
            if release.wait(timeout: .now() + 3) == .success { LoopbackSocket.sendAll(last, fd: fd) }
            finished.fulfill()
        }
        let journal = journal()
        let proxy = try startProxy(targetPort: upstream.port, journal: journal)
        defer { proxy.stop() }
        let fd = try LoopbackSocket.connect(port: proxy.proxyPort)
        defer { Darwin.close(fd) }
        LoopbackSocket.sendAll(request(), fd: fd)
        let observed = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in (try? self.records().count) == 1 }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [observed], timeout: 3), .completed)
        release.signal()
        XCTAssertEqual(LoopbackSocket.readToEOF(fd), first + last)
        wait(for: [finished], timeout: 3)
        journal.flush()
        XCTAssertEqual(try records().first?.outcome, "complete")
        XCTAssertEqual(try records().count, 1)
    }

    func testClosedBackendPortAnswersClientTheSameWithJournalOnOrOff() throws {
        let unused = try LoopbackSocket()
        let targetPort = unused.port
        unused.close()
        let journal = journal()
        var answers: [Data] = []
        for observed in [false, true] {
            let proxy = try startProxy(targetPort: targetPort, journal: observed ? journal : nil)
            defer { proxy.stop() }
            let fd = try LoopbackSocket.connect(port: proxy.proxyPort)
            defer { Darwin.close(fd) }
            LoopbackSocket.sendAll(request(), fd: fd)
            answers.append(LoopbackSocket.readToEOF(fd))
        }
        XCTAssertEqual(answers[0], answers[1], String(decoding: answers[1], as: UTF8.self))
        journal.flush()
        let recorded = try records()
        XCTAssertLessThanOrEqual(recorded.count, 1)
        if let record = recorded.first {
            XCTAssertEqual(record.outcome, "backend_unreachable")
            XCTAssertEqual(record.status, 502)
        }
    }

    func testFailedClientWriteKeepsRelayingAndRecordsDisconnectWithObservedStatus() throws {
        let head = Data("HTTP/1.1 200 OK\r\nContent-Length: 16777216\r\n\r\n".utf8)
        let response = head + Data(repeating: 32, count: 16 * 1024 * 1024)
        let journal = journal()
        for observed in [false, true] {
            let upstream = try LoopbackSocket()
            defer { upstream.close() }
            let received = expectation(description: "upstream admitted request before disconnect")
            let finished = expectation(description: "upstream writer finished")
            let release = DispatchSemaphore(value: 0)
            var sent = 0
            upstream.serve { fd, _ in
                received.fulfill()
                guard release.wait(timeout: .now() + 3) == .success else { finished.fulfill(); return }
                sent = LoopbackSocket.sendAll(response, fd: fd)
                finished.fulfill()
            }
            let proxy = try startProxy(targetPort: upstream.port, journal: observed ? journal : nil)
            defer { proxy.stop() }
            let fd = try LoopbackSocket.connect(port: proxy.proxyPort)
            LoopbackSocket.sendAll(request(), fd: fd)
            wait(for: [received], timeout: 3)
            var lingerOption = linger(l_onoff: 1, l_linger: 0)
            setsockopt(fd, SOL_SOCKET, SO_LINGER, &lingerOption, socklen_t(MemoryLayout<linger>.size))
            Darwin.close(fd)
            release.signal()
            wait(for: [finished], timeout: 8)
            XCTAssertEqual(sent, response.count, observed ? "journal on" : "journal off")
        }
        let written = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in (try? self.records().count) == 1 }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [written], timeout: 3), .completed)
        journal.flush()
        let record = try XCTUnwrap(records().first)
        XCTAssertEqual(record.outcome, "client_disconnected")
        XCTAssertEqual(record.status, 200)
        XCTAssertNil(record.tokens)
    }

    func testInvalidUTF8RequestBodyIsAnswered400WithoutForwardingOrJournaling() throws {
        let upstream = try LoopbackSocket()
        defer { upstream.close() }
        let forwarded = expectation(description: "invalid body forwarded")
        forwarded.isInverted = true
        upstream.serve { _, _ in forwarded.fulfill() }
        let journal = journal()
        let proxy = try startProxy(targetPort: upstream.port, journal: journal)
        defer { proxy.stop() }
        let fd = try LoopbackSocket.connect(port: proxy.proxyPort)
        defer { Darwin.close(fd) }
        let body = Data(#"{"model":"claude-journal-fixture","prompt_cache_key":"relay-session-0001","input":"O"#.utf8) + [0xff] + Data(#"K"}"#.utf8)
        let head = "POST /v1/messages HTTP/1.1\r\nHost: localhost\r\nContent-Type: application/json\r\nContent-Length: \(body.count)\r\n\r\n"
        LoopbackSocket.sendAll(Data(head.utf8) + body, fd: fd)
        let answer = String(decoding: LoopbackSocket.readToEOF(fd), as: UTF8.self)
        XCTAssertTrue(answer.hasPrefix("HTTP/1.1 400 "), answer)
        wait(for: [forwarded], timeout: 0.5)
        journal.flush()
        XCTAssertTrue(try records().isEmpty)
    }

    func testCountTokensIsNotObservedEvenWithJournalEnabled() throws {
        let upstream = try LoopbackSocket()
        defer { upstream.close() }
        let done = expectation(description: "count tokens forwarded")
        upstream.serve { fd, _ in
            LoopbackSocket.sendAll(Data("HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\n{}".utf8), fd: fd)
            done.fulfill()
        }
        let journal = journal()
        let proxy = try startProxy(targetPort: upstream.port, journal: journal)
        defer { proxy.stop() }
        let fd = try LoopbackSocket.connect(port: proxy.proxyPort)
        defer { Darwin.close(fd) }
        LoopbackSocket.sendAll(request(path: "/v1/messages/count_tokens"), fd: fd)
        _ = LoopbackSocket.readToEOF(fd)
        wait(for: [done], timeout: 3)
        journal.flush()
        XCTAssertTrue(try records().isEmpty)
    }

    func testTargetResetAfterTheTerminalEventStillRecordsCompleteWhileItsClientWriteIsUnobserved() throws {
        let events = "event: message_start\ndata: {\"type\":\"message_start\",\"message\":{\"model\":\"actual-model\",\"usage\":{\"input_tokens\":3}}}\n\n"
            + "event: message_stop\ndata: {\"type\":\"message_stop\"}\n\n"
        let response = Data(("HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nTransfer-Encoding: chunked\r\n\r\n"
            + "\(String(events.utf8.count, radix: 16))\r\n\(events)\r\n").utf8)
        let upstream = try LoopbackSocket()
        defer { upstream.close() }
        let requested = DispatchSemaphore(value: 0), respond = DispatchSemaphore(value: 0), reset = DispatchSemaphore(value: 0)
        upstream.serve(reset: true) { fd, _ in
            requested.signal()
            guard respond.wait(timeout: .now() + 5) == .success else { return }
            LoopbackSocket.sendAll(response, fd: fd)
            _ = reset.wait(timeout: .now() + 5)
        }
        let journal = journal()
        let proxy = try startProxy(targetPort: upstream.port, journal: journal)
        defer { proxy.stop() }
        let fd = try LoopbackSocket.connect(port: proxy.proxyPort)
        defer { Darwin.close(fd) }
        LoopbackSocket.sendAll(request(), fd: fd)
        XCTAssertEqual(requested.wait(timeout: .now() + 3), .success)

        // ThinkingProxy runs client send completions on the global user-initiated queue, which runs at most
        // kern.wq_max_constrained_threads blocks at once. Queueing more blocks than that, all waiting, keeps the
        // terminal chunk's write completion behind them (the queue is FIFO) until they are released.
        let blockers = 512
        let started = OSAllocatedUnfairLock(initialState: 0)
        let release = DispatchSemaphore(value: 0)
        var released = false
        func releaseBlockers() {
            guard !released else { return }
            released = true
            for _ in 0..<blockers { release.signal() }
        }
        defer { releaseBlockers() }
        for _ in 0..<blockers {
            DispatchQueue.global(qos: .userInitiated).async {
                started.withLock { $0 += 1 }
                release.wait()
            }
        }
        respond.signal()
        var received = Data()
        XCTAssertTrue(LoopbackSocket.read(fd, into: &received) { $0.count >= response.count }, "the client never got the terminal event")
        reset.signal()
        // ThinkingProxy answers the target failure with a 502 after it has handled it for the journal.
        XCTAssertTrue(LoopbackSocket.read(fd, into: &received) { String(decoding: $0, as: UTF8.self).contains("HTTP/1.1 502") })
        XCTAssertLessThan(started.withLock { $0 }, blockers, "every blocker ran, so the client write completion was not held back")
        releaseBlockers()
        received.append(LoopbackSocket.readToEOF(fd))
        XCTAssertEqual(received.prefix(response.count), response)

        let written = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in (try? self.records().count) == 1 }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [written], timeout: 3), .completed)
        journal.flush()
        let record = try XCTUnwrap(records().first)
        XCTAssertEqual(record.outcome, "complete")
        XCTAssertEqual(record.status, 200)
    }
}

private final class LoopbackSocket {
    private var fd: Int32
    let port: UInt16

    init() throws {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw POSIXError(.EIO) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard result == 0, listen(fd, 4) == 0 else { Darwin.close(fd); throw POSIXError(.EIO) }
        var size = socklen_t(MemoryLayout<sockaddr_in>.size)
        withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { _ = getsockname(fd, $0, &size) }
        }
        port = UInt16(bigEndian: address.sin_port)
        self.fd = fd
    }

    deinit { close() }
    func close() {
        if fd >= 0 { shutdown(fd, SHUT_RDWR); Darwin.close(fd); fd = -1 }
    }

    /// Runs on its own thread rather than a dispatch queue, so it keeps serving while a test occupies the global queues.
    /// With `reset`, the peer is closed with an RST instead of a FIN once `handler` returns.
    func serve(reset: Bool = false, _ handler: @escaping (Int32, Data) -> Void) {
        let listener = fd
        Thread.detachNewThread {
            let peer = accept(listener, nil, nil)
            guard peer >= 0 else { return }
            defer {
                if reset {
                    var abort = linger(l_onoff: 1, l_linger: 0)
                    setsockopt(peer, SOL_SOCKET, SO_LINGER, &abort, socklen_t(MemoryLayout<linger>.size))
                } else {
                    shutdown(peer, SHUT_RDWR)
                }
                Darwin.close(peer)
            }
            Self.configure(peer)
            var request = Data()
            var buffer = [UInt8](repeating: 0, count: 65536)
            while true {
                let n = recv(peer, &buffer, buffer.count, 0)
                guard n > 0 else { return }
                request.append(contentsOf: buffer.prefix(n))
                if let end = request.range(of: Data("\r\n\r\n".utf8)) {
                    let head = String(decoding: request[..<end.lowerBound], as: UTF8.self)
                    let length = head.components(separatedBy: "\r\n").first { $0.lowercased().hasPrefix("content-length:") }
                        .flatMap { Int($0.dropFirst(15).trimmingCharacters(in: .whitespaces)) } ?? 0
                    if request.count - end.upperBound >= length { break }
                }
            }
            handler(peer, request)
        }
    }

    static func connect(port: UInt16) throws -> Int32 {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        configure(fd)
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard result == 0 else { Darwin.close(fd); throw POSIXError(.ECONNREFUSED) }
        return fd
    }

    private static func configure(_ fd: Int32) {
        var timeout = timeval(tv_sec: 3, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        var yes: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &yes, socklen_t(MemoryLayout<Int32>.size))
    }

    @discardableResult
    static func sendAll(_ data: Data, fd: Int32) -> Int {
        data.withUnsafeBytes { raw in
            var offset = 0
            while offset < raw.count {
                let n = send(fd, raw.baseAddress!.advanced(by: offset), raw.count - offset, 0)
                if n <= 0 { break }
                offset += n
            }
            return offset
        }
    }

    /// Reads into `data` until `done` holds or the stream ends; false when it ended first.
    static func read(_ fd: Int32, into data: inout Data, until done: (Data) -> Bool) -> Bool {
        var buffer = [UInt8](repeating: 0, count: 65536)
        while !done(data) {
            let n = recv(fd, &buffer, buffer.count, 0)
            if n <= 0 { return false }
            data.append(contentsOf: buffer.prefix(n))
        }
        return true
    }

    static func readToEOF(_ fd: Int32) -> Data {
        var result = Data()
        var buffer = [UInt8](repeating: 0, count: 65536)
        while true {
            let n = recv(fd, &buffer, buffer.count, 0)
            if n <= 0 { return result }
            result.append(contentsOf: buffer.prefix(n))
        }
    }
}
