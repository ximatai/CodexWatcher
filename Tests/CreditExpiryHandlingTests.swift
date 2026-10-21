import Foundation
import XCTest
@testable import WatcherCore

final class CreditExpiryHandlingTests: XCTestCase {
    private func card(_ id: String, expiry: Double?, status: String = "available", type: String = "codexRateLimits") -> ResetCredit {
        .init(id: id, resetType: type, status: status, grantedAt: 0, expiresAt: expiry, title: nil, description: nil)
    }

    func testLeadWindowIncludesFifteenMinutesButExcludesExpiredUnknownAndUnsupportedCards() {
        let now = Date(timeIntervalSince1970: 1000)
        let invalid = [card("expired", expiry: 1000), card("unknown", expiry: nil),
                       card("far", expiry: 1901), card("spent", expiry: 1001, status: "redeemed"),
                       card("other", expiry: 1001, type: "other")]
        XCTAssertNil(CreditExpiryPolicy.candidate(in: invalid, at: now))
        XCTAssertEqual(CreditExpiryPolicy.candidate(in: invalid + [card("edge", expiry: 1900)], at: now)?.id, "edge")
        XCTAssertEqual(CreditExpiryPolicy.candidate(in: [card("later", expiry: 1900), card("first", expiry: 1001)], at: now)?.id, "first")
    }

    func testActionClaimsSurviveRestartAndSeparateAccountsAndModes() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = CreditExpiryActionStore(directory: root)
        let reminder = CreditExpiryReminder(accountKey: "a", creditID: "card", expiresAt: Date(timeIntervalSince1970: 1900))
        XCTAssertTrue(try store.claim(reminder, mode: .automatic))
        XCTAssertFalse(try CreditExpiryActionStore(directory: root).claim(reminder, mode: .automatic))
        XCTAssertFalse(try store.claim(.init(accountKey: "a", creditID: "card",
            expiresAt: reminder.expiresAt.addingTimeInterval(60)), mode: .automatic),
            "A changed expiry must not rearm automatic consumption for the same card")
        XCTAssertTrue(try store.claim(reminder, mode: .remind))
        try store.releaseReminder(reminder)
        XCTAssertTrue(try store.claim(reminder, mode: .remind))
        XCTAssertTrue(try store.contains(reminder, mode: .automatic))
        XCTAssertTrue(try store.claim(.init(accountKey: "b", creditID: "card", expiresAt: reminder.expiresAt), mode: .automatic))
    }

    func testCorruptActionStoreFailsClosed() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("invalid".utf8).write(to: root.appendingPathComponent("expiry-actions.json"))
        let reminder = CreditExpiryReminder(accountKey: "a", creditID: "card", expiresAt: .now)
        XCTAssertThrowsError(try CreditExpiryActionStore(directory: root).claim(reminder, mode: .automatic))
    }

    func testConcurrentInstancesAllowOnlyOneAutomaticClaim() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let reminder = CreditExpiryReminder(accountKey: "a", creditID: "card", expiresAt: .now)
        let resultLock = NSLock()
        var successes = 0
        var failures = 0
        DispatchQueue.concurrentPerform(iterations: 16) { _ in
            do {
                let claimed = try CreditExpiryActionStore(directory: root).claim(reminder, mode: .automatic)
                resultLock.lock()
                if claimed { successes += 1 }
                resultLock.unlock()
            } catch {
                resultLock.lock(); failures += 1; resultLock.unlock()
            }
        }
        XCTAssertEqual(successes, 1)
        XCTAssertEqual(failures, 0)
    }
}
