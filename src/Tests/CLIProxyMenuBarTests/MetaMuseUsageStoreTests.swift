import XCTest
@testable import CLIProxyMenuBar

final class MetaMuseUsageStoreTests: XCTestCase {
    /// Captured from `POST https://api.meta.ai/v1/responses` (stream) on 2026-09-23.
    private let usageDataLine = #"data: {"subscription":{"tier":"27681393394859588","weekly":{"resets_at":1790553600,"used_percent":6},"window":{"resets_at":1790204220,"used_percent":7,"window_duration_mins":300}},"type":"response.subscription_usage"}"#

    private let observedAt = Date(timeIntervalSince1970: 1_790_189_303)

    func testParseRealSubscriptionUsageEvent() throws {
        let snapshot = try XCTUnwrap(MetaMuseUsageEvent.parse(dataLine: usageDataLine, observedAt: observedAt))

        XCTAssertEqual(snapshot.windowUsedPercent, 7)
        XCTAssertEqual(snapshot.windowResetsAt, Date(timeIntervalSince1970: 1_790_204_220))
        XCTAssertEqual(snapshot.windowDurationMins, 300)
        XCTAssertEqual(snapshot.weeklyUsedPercent, 6)
        XCTAssertEqual(snapshot.weeklyResetsAt, Date(timeIntervalSince1970: 1_790_553_600))
        XCTAssertEqual(snapshot.tier, "27681393394859588")
        XCTAssertEqual(snapshot.observedAt, observedAt)
    }

    func testParseRejectsOtherEventsAndMalformedLines() {
        let lines = [
            #"data: {"response":{"id":"resp_123"},"sequence_number":0,"type":"response.created"}"#,
            "data: [DONE]",
            "event: response.subscription_usage",
            "not an sse line",
            "",
            #"data: {"type":"response.subscription_usage"}"#,
            #"data: {"subscription":{"weekly":{"resets_at":1,"used_percent":1},"window":{"resets_at":1,"used_percent":1}},"type":"other"}"#,
            #"data: { invalid json"#,
        ]
        for line in lines {
            XCTAssertNil(MetaMuseUsageEvent.parse(dataLine: line, observedAt: observedAt), "line: \(line)")
        }
    }

    func testParseClampsPercentsAndDefaultsWindowDuration() throws {
        let line = #"data: {"subscription":{"weekly":{"resets_at":1790553600,"used_percent":150},"window":{"resets_at":1790204220,"used_percent":-5}},"type":"response.subscription_usage"}"#

        let snapshot = try XCTUnwrap(MetaMuseUsageEvent.parse(dataLine: line, observedAt: observedAt))

        XCTAssertEqual(snapshot.windowUsedPercent, 0)
        XCTAssertEqual(snapshot.weeklyUsedPercent, 100)
        XCTAssertEqual(snapshot.windowDurationMins, MetaMuseUsageEvent.defaultWindowDurationMins)
        XCTAssertNil(snapshot.tier)
    }

    func testSnifferReassemblesEventSplitAcrossChunks() throws {
        let bytes = Array((usageDataLine + "\n").utf8)
        let first = Data(bytes.prefix(90))
        let second = Data(bytes.dropFirst(90).prefix(60))
        let third = Data(bytes.dropFirst(150))

        var pending = ""
        var snapshots: [MetaMuseUsageSnapshot] = []
        for chunk in [first, second, third] {
            let result = MetaMuseUsageSniffer.scan(chunk: chunk, pending: pending, observedAt: observedAt)
            pending = result.pending
            snapshots += result.snapshots
        }

        XCTAssertEqual(snapshots.count, 1)
        XCTAssertEqual(snapshots.first?.windowUsedPercent, 7)
        XCTAssertEqual(snapshots.first?.weeklyUsedPercent, 6)
        XCTAssertEqual(snapshots.first?.observedAt, observedAt)
        XCTAssertTrue(pending.isEmpty)
    }

    func testSnifferIgnoresUnrelatedTrafficAndCapsPending() {
        let stream = "HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\n\r\n"
            + "event: response.created\n"
            + #"data: {"type":"response.created"}"# + "\n"
            + "data: [DONE]\n"
        let result = MetaMuseUsageSniffer.scan(
            chunk: Data(stream.utf8), pending: "", observedAt: observedAt
        )

        XCTAssertTrue(result.snapshots.isEmpty)
        XCTAssertTrue(result.pending.isEmpty)

        let huge = Data(repeating: 0x41, count: MetaMuseUsageSniffer.maxPendingCount + 100)
        let capped = MetaMuseUsageSniffer.scan(chunk: huge, pending: "", observedAt: observedAt)
        XCTAssertTrue(capped.snapshots.isEmpty)
        XCTAssertEqual(capped.pending.count, MetaMuseUsageSniffer.maxPendingCount)
    }

    func testStoreRoundTripAndRemoval() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = MetaMuseUsageStore(directory: directory)

        XCTAssertNil(store.snapshot(for: "alice"))

        let snapshot = try XCTUnwrap(MetaMuseUsageEvent.parse(dataLine: usageDataLine, observedAt: observedAt))
        store.record(accountID: "alice", snapshot: snapshot)

        XCTAssertEqual(MetaMuseUsageStore(directory: directory).snapshot(for: "alice"), snapshot)
        let attributes = try FileManager.default.attributesOfItem(atPath: store.usageURL.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)

        store.remove(accountID: "alice")
        XCTAssertNil(MetaMuseUsageStore(directory: directory).snapshot(for: "alice"))
    }
}
