import Foundation
import XCTest
@testable import WatcherCore

final class AutomaticRedemptionStoreTests: XCTestCase {
    func testRetryBudgetLeasesAndLateFinishesAreSharedAcrossRestarts() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ResetAttemptStore(directory: root)
        let original = try XCTUnwrap(store.prepareNew(creditID: "card-a", owner: "owner", automaticExpiresAt: 1900))
        let first = try XCTUnwrap(store.reserveAutomaticAttempt(owner: "owner", expected: original, at: Date(timeIntervalSince1970: 1000)))
        let other = ResetAttemptStore(directory: root)
        XCTAssertNil(try other.reserveAutomaticAttempt(owner: "owner", expected: first, at: Date(timeIntervalSince1970: 1030)))
        try store.finishAutomaticAttempt(owner: "owner", expected: first, at: Date(timeIntervalSince1970: 1002))
        let second = try XCTUnwrap(other.reserveAutomaticAttempt(owner: "owner", expected: first, at: Date(timeIntervalSince1970: 1032)))
        try store.finishAutomaticAttempt(owner: "owner", expected: first, at: Date(timeIntervalSince1970: 1033))
        XCTAssertNil(try store.reserveAutomaticAttempt(owner: "owner", expected: second, at: Date(timeIntervalSince1970: 1065)),
                     "A late first callback must not release the second attempt's lease")
        try other.finishAutomaticAttempt(owner: "owner", expected: second, at: Date(timeIntervalSince1970: 1033))
        let third = try XCTUnwrap(store.reserveAutomaticAttempt(owner: "owner", expected: second, at: Date(timeIntervalSince1970: 1063)))
        try store.finishAutomaticAttempt(owner: "owner", expected: third, at: Date(timeIntervalSince1970: 1064))
        XCTAssertNil(try other.reserveAutomaticAttempt(owner: "owner", expected: third, at: Date(timeIntervalSince1970: 1094)))
        XCTAssertEqual(third.automatic?.attempts, 3)
        XCTAssertEqual(third.idempotencyKey, original.idempotencyKey)
        XCTAssertEqual(third.creditID, original.creditID)
    }

    func testCrashedLeaseRecoversOnlySameOriginalRequest() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ResetAttemptStore(directory: root)
        let original = try XCTUnwrap(store.prepareNew(creditID: "card-a", owner: "owner", automaticExpiresAt: 1900))
        let first = try XCTUnwrap(store.reserveAutomaticAttempt(owner: "owner", expected: original, at: Date(timeIntervalSince1970: 1000)))
        let recovered = try XCTUnwrap(ResetAttemptStore(directory: root).reserveAutomaticAttempt(
            owner: "owner", expected: first, at: Date(timeIntervalSince1970: 1090)))
        XCTAssertEqual(recovered.automatic?.attempts, 2)
        XCTAssertEqual(recovered.idempotencyKey, original.idempotencyKey)
        XCTAssertNil(try store.reserveAutomaticAttempt(owner: "other", expected: recovered, at: Date(timeIntervalSince1970: 1200)))
        var changed = recovered
        changed.automatic = AutomaticRedemption(expiresAt: 2000)
        XCTAssertNil(try store.reserveAutomaticAttempt(owner: "owner", expected: changed, at: Date(timeIntervalSince1970: 1200)))
        XCTAssertNil(try store.reserveAutomaticAttempt(owner: "owner", expected: recovered, at: Date(timeIntervalSince1970: 1900)))
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
        XCTAssertNil(try store.reserveAutomaticAttempt(owner: "owner", expected: legacy, at: .now))
        XCTAssertEqual(legacy.idempotencyKey, "old-key")
    }
}
