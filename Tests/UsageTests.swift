import XCTest
@testable import WatcherCore

final class UsageTests: XCTestCase {
    func testNaturalTimeBaselineAndDeviation() throws {
        let quota = QuotaWindow(usedPercent: 21, windowDurationMins: 10080, resetsAt: 1793082734)
        let now = Date(timeIntervalSince1970: 1792553989)
        XCTAssertEqual(try XCTUnwrap(quota.standardPercent(at: now)), 12.57523148, accuracy: 0.000001)
        XCTAssertEqual(try XCTUnwrap(quota.deviation(at: now)), 8.42476852, accuracy: 0.000001)
    }

    func testMissingInvalidAndExpiredWindowsAreNotInvented() {
        let now = Date(timeIntervalSince1970: 1000)
        XCTAssertNil(QuotaWindow(usedPercent: 0, windowDurationMins: nil, resetsAt: 2000).standardPercent(at: now))
        XCTAssertNil(QuotaWindow(usedPercent: 0, windowDurationMins: 0, resetsAt: 2000).standardPercent(at: now))
        XCTAssertNil(QuotaWindow(usedPercent: 80, windowDurationMins: 60, resetsAt: 1000).deviation(at: now))
        XCTAssertEqual(QuotaWindow(usedPercent: 0, windowDurationMins: 1, resetsAt: 5000).standardPercent(at: now), 0)
    }

    func testMultipleBucketsDoNotDuplicateLegacyBucket() throws {
        let data = Data(#"{"rateLimits":{"limitId":"codex","primary":{"usedPercent":90}},"rateLimitsByLimitId":{"codex":{"primary":{"usedPercent":21,"windowDurationMins":10080,"resetsAt":1793082734},"secondary":{"usedPercent":5}},"other":{"primary":{"usedPercent":7}}},"rateLimitResetCredits":{"availableCount":3,"credits":null}}"#.utf8)
        let snapshot = try JSONDecoder().decode(UsageSnapshot.self, from: data)
        XCTAssertEqual(snapshot.windows.count, 3)
        XCTAssertEqual(Set(snapshot.windows.map(\.id)).count, 3)
        XCTAssertEqual(snapshot.windows.first?.quota.usedPercent, 21)
        XCTAssertEqual(snapshot.rateLimitResetCredits?.availableCount, 3)
        XCTAssertNil(snapshot.rateLimitResetCredits?.credits)
    }

    func testLegacyFallbackAndPartialCreditDetails() throws {
        let data = Data(#"{"rateLimits":{"primary":{"usedPercent":0}},"rateLimitsByLimitId":{},"rateLimitResetCredits":{"availableCount":2,"credits":[{"id":"one","resetType":"codexRateLimits","status":"available","grantedAt":1,"expiresAt":1000}]}}"#.utf8)
        let snapshot = try JSONDecoder().decode(UsageSnapshot.self, from: data)
        XCTAssertEqual(snapshot.windows.count, 1)
        let card = try XCTUnwrap(snapshot.rateLimitResetCredits?.credits?.first)
        XCTAssertTrue(card.isUsable(at: Date(timeIntervalSince1970: 999)))
        XCTAssertFalse(card.isUsable(at: Date(timeIntervalSince1970: 1000)))
        XCTAssertEqual(snapshot.rateLimitResetCredits?.availableCount, 2)
    }

    @MainActor
    func testAppServerHandshakeWithIsolatedLoggedOutProfile() async throws {
        guard ProcessInfo.processInfo.environment["WATCHER_LIVE_SMOKE"] == "1" else {
            throw XCTSkip("Set WATCHER_LIVE_SMOKE=1 to check a locally installed Codex CLI without logging in.")
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("WatcherSmoke-\(UUID())")
        let client = AppServerClient(runtimeDirectory: directory)
        defer { client.stop(); try? FileManager.default.removeItem(at: directory) }
        try await client.connect()
        XCTAssertTrue(client.isReady)
        let response: AccountResponse = try await client.request("account/read", params: ["refreshToken": false])
        XCTAssertNil(response.account, "An isolated runtime must not pick up the user's existing Codex login.")
    }

    func testRedemptionSurvivesRestartAndCannotSwitchCardsDuringRetry() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("WatcherReset-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let first = try ResetAttemptStore(directory: directory).prepare(creditID: "card-a", owner: "account-a")
        let restarted = ResetAttemptStore(directory: directory)
        let retry = try restarted.prepare(creditID: "card-b", owner: "account-a")
        XCTAssertEqual(retry.creditID, "card-a")
        XCTAssertEqual(retry.idempotencyKey, first.idempotencyKey)
        XCTAssertNil(try restarted.pending(for: "account-b"))
        let other = try restarted.prepare(creditID: "card-b", owner: "account-b")
        XCTAssertNotEqual(other.idempotencyKey, first.idempotencyKey)
        try restarted.clear(owner: "account-a", idempotencyKey: first.idempotencyKey)
        XCTAssertNil(try restarted.pending(for: "account-a"))
        XCTAssertEqual(try restarted.pending(for: "account-b")?.idempotencyKey, other.idempotencyKey)
    }

    func testCorruptRedemptionStoreDoesNotSilentlyCreateAnotherAttempt() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("WatcherCorrupt-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("corrupted".utf8).write(to: directory.appendingPathComponent("pending-resets.json"))
        XCTAssertThrowsError(try ResetAttemptStore(directory: directory).prepare(creditID: "card", owner: "account"))
    }

    func testConcurrentInstancesReuseOneRedemptionKey() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("WatcherConcurrent-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let results = LockedRedemptionResults()
        DispatchQueue.concurrentPerform(iterations: 32) { index in
            do {
                let attempt = try ResetAttemptStore(directory: directory).prepare(creditID: "card-\(index)", owner: "same-account")
                results.record(attempt.idempotencyKey)
            } catch { results.record(nil) }
        }
        XCTAssertEqual(results.keys.count, 1)
        XCTAssertEqual(results.failures, 0)
    }

    func testLateResultCannotClearNewerRedemption() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("WatcherLateResult-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ResetAttemptStore(directory: directory)
        let old = try store.prepare(creditID: "old", owner: "account")
        try store.clear(owner: "account", idempotencyKey: old.idempotencyKey)
        let new = try store.prepare(creditID: "new", owner: "account")
        try store.clear(owner: "account", idempotencyKey: old.idempotencyKey)
        XCTAssertEqual(try store.pending(for: "account")?.idempotencyKey, new.idempotencyKey)
    }
}

private final class LockedRedemptionResults: @unchecked Sendable {
    private let lock = NSLock()
    private(set) var keys = Set<String>()
    private(set) var failures = 0

    func record(_ key: String?) {
        lock.lock()
        defer { lock.unlock() }
        if let key { keys.insert(key) } else { failures += 1 }
    }
}
