import Foundation
import XCTest
import Darwin
@testable import WatcherCore

final class AutomaticRedemptionStoreTests: XCTestCase {
    func testRetryBudgetLeasesAndLateFinishesAreSharedAcrossRestarts() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ResetAttemptStore(directory: root)
        let original = try XCTUnwrap(store.prepareNew(creditID: "card-a", owner: "owner", automaticExpiresAt: 1900))
        let first = try XCTUnwrap(store.reserveAutomaticAttempt(owner: "owner", expected: original, clock: { Date(timeIntervalSince1970: 1000) }))
        let other = ResetAttemptStore(directory: root)
        XCTAssertNil(try other.reserveAutomaticAttempt(owner: "owner", expected: first, clock: { Date(timeIntervalSince1970: 1030) }))
        try store.finishAutomaticAttempt(owner: "owner", expected: first, clock: { Date(timeIntervalSince1970: 1002) })
        let second = try XCTUnwrap(other.reserveAutomaticAttempt(owner: "owner", expected: first, clock: { Date(timeIntervalSince1970: 1032) }))
        try store.finishAutomaticAttempt(owner: "owner", expected: first, clock: { Date(timeIntervalSince1970: 1033) })
        XCTAssertNil(try store.reserveAutomaticAttempt(owner: "owner", expected: second, clock: { Date(timeIntervalSince1970: 1065) }),
                     "A late first callback must not release the second attempt's lease")
        try other.finishAutomaticAttempt(owner: "owner", expected: second, clock: { Date(timeIntervalSince1970: 1033) })
        let third = try XCTUnwrap(store.reserveAutomaticAttempt(owner: "owner", expected: second, clock: { Date(timeIntervalSince1970: 1063) }))
        try store.finishAutomaticAttempt(owner: "owner", expected: third, clock: { Date(timeIntervalSince1970: 1064) })
        XCTAssertNil(try other.reserveAutomaticAttempt(owner: "owner", expected: third, clock: { Date(timeIntervalSince1970: 1094) }))
        XCTAssertEqual(third.automatic?.attempts, 3)
        XCTAssertEqual(third.idempotencyKey, original.idempotencyKey)
        XCTAssertEqual(third.creditID, original.creditID)
    }

    func testCrashedLeaseRecoversOnlySameOriginalRequest() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ResetAttemptStore(directory: root)
        let original = try XCTUnwrap(store.prepareNew(creditID: "card-a", owner: "owner", automaticExpiresAt: 1900))
        let first = try XCTUnwrap(store.reserveAutomaticAttempt(owner: "owner", expected: original, clock: { Date(timeIntervalSince1970: 1000) }))
        let recovered = try XCTUnwrap(ResetAttemptStore(directory: root).reserveAutomaticAttempt(
            owner: "owner", expected: first, clock: { Date(timeIntervalSince1970: 1090) }))
        XCTAssertEqual(recovered.automatic?.attempts, 2)
        XCTAssertEqual(recovered.idempotencyKey, original.idempotencyKey)
        XCTAssertNil(try store.reserveAutomaticAttempt(owner: "other", expected: recovered, clock: { Date(timeIntervalSince1970: 1200) }))
        var changed = recovered
        changed.automatic = AutomaticRedemption(expiresAt: 2000)
        XCTAssertNil(try store.reserveAutomaticAttempt(owner: "owner", expected: changed, clock: { Date(timeIntervalSince1970: 1200) }))
        XCTAssertNil(try store.reserveAutomaticAttempt(owner: "owner", expected: recovered, clock: { Date(timeIntervalSince1970: 1900) }))
    }

    func testReservationReadsCurrentTimeAfterWaitingForFileLock() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ResetAttemptStore(directory: root)
        final class LockedClock: @unchecked Sendable {
            private let lock = NSLock()
            private var timestamp: TimeInterval = 1000
            func now() -> Date { lock.lock(); defer { lock.unlock() }; return Date(timeIntervalSince1970: timestamp) }
            func expire() { lock.lock(); defer { lock.unlock() }; timestamp = 2000 }
        }
        let clock = LockedClock()
        let original = try XCTUnwrap(store.prepareNew(creditID: "card-a", owner: "owner",
                                                      automaticExpiresAt: 1900))
        let descriptor = open(root.appendingPathComponent("pending-resets.lock").path, O_RDWR)
        XCTAssertGreaterThanOrEqual(descriptor, 0)
        defer { close(descriptor) }
        XCTAssertEqual(flock(descriptor, LOCK_EX), 0)
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.3) {
            clock.expire()
            _ = flock(descriptor, LOCK_UN)
        }
        let reserved = try store.reserveAutomaticAttempt(owner: "owner", expected: original, clock: clock.now)
        XCTAssertEqual(clock.now().timeIntervalSince1970, 2000)
        XCTAssertNil(reserved, "A card that expired while waiting must not be reserved")
        XCTAssertEqual(try store.pending(for: "owner")?.automatic?.attempts, 0)
    }

    func testLegacyPendingRequestCannotBeAdoptedForAutomaticRetry() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data(#"{"owner":{"creditID":"card-a","idempotencyKey":"old-key"}}"#.utf8)
            .write(to: root.appendingPathComponent("pending-resets.json"))
        let store = ResetAttemptStore(directory: root)
        let legacy = try XCTUnwrap(store.pending(for: "owner"))
        XCTAssertNil(legacy.automatic)
        XCTAssertNil(try store.reserveAutomaticAttempt(owner: "owner", expected: legacy, clock: Date.init))
        XCTAssertEqual(legacy.idempotencyKey, "old-key")
    }
}
