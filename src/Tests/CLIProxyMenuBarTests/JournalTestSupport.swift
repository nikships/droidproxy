import Foundation
import os
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
    JournalRequest(endpoint: endpoint, forwardedEndpoint: forwarded ?? endpoint, headers: headers, body: body)
}

func journalSession(_ headers: [(String, String)], _ body: String) -> String? {
    JournalRequest.session(headers: headers, body: JournalJSON.parse(body))
}

/// A lock found by reflection that a test holds from another thread.
protocol HeldLock {
    func hold(_ entered: DispatchSemaphore, until release: DispatchSemaphore)
}

extension HeldLock where Self: NSLocking {
    func hold(_ entered: DispatchSemaphore, until release: DispatchSemaphore) {
        lock()
        entered.signal()
        release.wait()
        unlock()
    }
}

extension NSLock: HeldLock {}
extension NSRecursiveLock: HeldLock {}
extension OSAllocatedUnfairLock: HeldLock {
    func hold(_ entered: DispatchSemaphore, until release: DispatchSemaphore) {
        withLockUnchecked { _ in
            entered.signal()
            release.wait()
        }
    }
}

/// Holds every lock stored in `objects` from other threads while `body` runs and returns how long `body` took, in ms.
/// The locks are released after `releaseAfter` seconds, so a `body` that waits on one returns then.
func millisecondsWithLocksHeld(in objects: [AnyObject], releaseAfter: TimeInterval = 0.2, _ body: () -> Void) -> Double {
    let locks = objects.flatMap { Mirror(reflecting: $0).children.compactMap { $0.value as? HeldLock } }
    let entered = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
    let holders = DispatchGroup()
    for lock in locks {
        DispatchQueue.global().async(group: holders) { lock.hold(entered, until: release) }
        entered.wait()
    }
    DispatchQueue.global().asyncAfter(deadline: .now() + releaseAfter) { for _ in locks { release.signal() } }
    let start = DispatchTime.now().uptimeNanoseconds
    body()
    let elapsed = Double(DispatchTime.now().uptimeNanoseconds - start) / 1e6
    holders.wait()
    return elapsed
}
