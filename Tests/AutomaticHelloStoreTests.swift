import Foundation
import XCTest
@testable import WatcherCore

final class AutomaticHelloStoreTests: XCTestCase {
    private func observation(used: Double = 0, reset: Double? = 10000, time: Double = 100,
                             account: String = "account-a", window: String = "codex.primary") -> HelloObservation {
        HelloObservation(accountKey: account,
            window: UsageWindow(id: window, bucketID: "codex", name: "Codex",
                quota: QuotaWindow(usedPercent: used, windowDurationMins: 300, resetsAt: reset)),
            startedAt: Date(timeIntervalSince1970: time))
    }
    private func withStore(_ body: (AutomaticHelloStore, URL) throws -> Void) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("HelloStore-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        try body(AutomaticHelloStore(directory: directory), directory)
    }

    func testClaimSurvivesRestartAndResetTimeChangesWithoutUsage() throws {
        try withStore { store, directory in
            let claim = try XCTUnwrap(store.observe(observation(), claim: true))
            XCTAssertNotNil(claim.attemptID)
            let restored = AutomaticHelloStore(directory: directory)
            XCTAssertNil(try restored.observe(observation(reset: 20000, time: 200), claim: true))
            XCTAssertNil(try restored.observe(observation(reset: 50, time: 300), claim: true))
            XCTAssertEqual(try restored.record(account: "account-a", windowID: "codex.primary")?.attemptID, claim.attemptID)
        }
    }

    func testHelloBaselineCannotImmediatelyRearmButLaterUseThenFullCan() throws {
        try withStore { store, _ in
            let claim = try XCTUnwrap(store.observe(observation(), claim: true))
            try store.finish(account: "account-a", windowID: "codex.primary", attemptID: try XCTUnwrap(claim.attemptID),
                             outcome: "completed", baseline: observation(used: 0.2, time: 110))
            XCTAssertNil(try store.observe(observation(used: 0.4, time: 120), claim: true))
            XCTAssertNil(try store.observe(observation(time: 130), claim: true))
            XCTAssertNil(try store.observe(observation(used: 2, time: 140), claim: true))
            let next = try XCTUnwrap(store.observe(observation(reset: 20000, time: 150), claim: true))
            XCTAssertNotEqual(next.attemptID, claim.attemptID)
            // A late callback from the previous operation cannot clear or alter this claim.
            try store.finish(account: "account-a", windowID: "codex.primary", attemptID: try XCTUnwrap(claim.attemptID),
                             outcome: "completed", baseline: observation(used: 90, time: 160))
            XCTAssertEqual(try store.record(account: "account-a", windowID: "codex.primary")?.outcome, "reserved")
        }
    }

    func testUnknownOutcomeAndLateSnapshotsNeverReopenClaim() throws {
        try withStore { store, _ in
            let claim = try XCTUnwrap(store.observe(observation(time: 200), claim: true))
            try store.finish(account: "account-a", windowID: "codex.primary", attemptID: try XCTUnwrap(claim.attemptID), outcome: "unknown")
            XCTAssertNil(try store.observe(observation(used: 50, time: 199), claim: true))
            XCTAssertNil(try store.observe(observation(time: 210), claim: true))
            XCTAssertNil(try store.observe(observation(used: 0.3, time: 220), claim: true))
            XCTAssertNil(try store.observe(observation(time: 230), claim: true))
        }
    }

    func testMissingInvalidAndFractionalUsageCannotTrigger() throws {
        try withStore { store, _ in
            for input in [observation(reset: nil), observation(reset: .nan), observation(reset: -1), observation(used: .nan),
                          observation(used: -1), observation(used: 0.01), observation(used: 101)] {
                XCTAssertNil(try store.observe(input, claim: true))
            }
            // A past deadline is eligible too, after the coordinator's fresh preflight.
            XCTAssertNotNil(try store.observe(observation(reset: 50, time: 200), claim: true))
        }
    }

    func testAccountsAndWindowsAreSeparateAndCorruptRecordsFailClosed() throws {
        try withStore { store, directory in
            XCTAssertNotNil(try store.observe(observation(), claim: true))
            XCTAssertNotNil(try store.observe(observation(account: "account-b"), claim: true))
            XCTAssertNotNil(try store.observe(observation(window: "codex.secondary"), claim: true))
            try Data("broken".utf8).write(to: directory.appendingPathComponent("automatic-hello.json"))
            XCTAssertThrowsError(try store.observe(observation(time: 200), claim: true))
        }
    }

    func testConcurrentStoresClaimOneEpisodeExactlyOnce() throws {
        try withStore { _, directory in
            let lock = NSLock()
            var successes = 0
            var errors: [Error] = []
            let input = observation()
            DispatchQueue.concurrentPerform(iterations: 12) { _ in
                do {
                    let result = try AutomaticHelloStore(directory: directory).observe(input, claim: true)
                    lock.lock(); defer { lock.unlock() }
                    if result != nil { successes += 1 }
                } catch {
                    lock.lock(); defer { lock.unlock() }; errors.append(error)
                }
            }
            XCTAssertTrue(errors.isEmpty)
            XCTAssertEqual(successes, 1)
        }
    }
}
