import Foundation
@testable import CLIProxyMenuBar

final class JournalTestClock {
    let start: JournalInstant
    var now: JournalInstant

    init(start wall: Date = Date(timeIntervalSince1970: 1_762_855_200)) {
        start = JournalInstant(wall: wall, monotonic: 1_000_000_000)
        now = start
    }

    func at(_ ms: Int) -> JournalInstant {
        JournalInstant(wall: start.wall.addingTimeInterval(Double(ms) / 1000), monotonic: start.monotonic + UInt64(ms) * 1_000_000)
    }
}

/// One upstream read returning at `readAt`, followed by a successful client write completing at `writeAt`.
func deliver(_ observation: ResponseObservation, _ data: Data, clock: JournalTestClock? = nil, readAt: Int = 0, writeAt: Int = 0) {
    clock?.now = clock!.at(writeAt)
    observation.delivered(data, readAt: clock?.at(readAt) ?? JournalInstant.now())
}

/// One upstream read whose client write accepted `accepted` and then failed.
func failWrite(_ observation: ResponseObservation, accepted: Data, undelivered: Data, clock: JournalTestClock? = nil, readAt: Int = 0, writeAt: Int = 0) {
    clock?.now = clock!.at(writeAt)
    observation.writeFailed(accepted: accepted, undelivered: undelivered, readAt: clock?.at(readAt) ?? JournalInstant.now())
}

func journalRequest(_ endpoint: String, forwarded: String? = nil, headers: [(String, String)] = [], body: String = "{}") -> JournalRequest {
    JournalRequest(endpoint: endpoint, forwardedEndpoint: forwarded ?? endpoint, headers: headers, body: Data(body.utf8))
}

func journalSession(_ headers: [(String, String)], _ body: String) -> String? {
    JournalRequest.session(headers: headers, body: JournalJSON.parse(Data(body.utf8)))
}
