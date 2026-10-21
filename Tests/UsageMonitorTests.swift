import Foundation
import XCTest
@testable import WatcherCore

/// Exercise the real coordinator against an isolated executable that cannot contact OpenAI.
@MainActor
final class UsageMonitorTests: XCTestCase {
    @MainActor private final class Fixture {
        let directory: URL
        let defaults: UserDefaults
        let suite = "WatcherMonitorTests-\(UUID())"
        let client: AppServerClient
        let monitor: UsageMonitor
        let store: ResetAttemptStore

        init() throws {
            directory = FileManager.default.temporaryDirectory.appendingPathComponent("WatcherMonitor-\(UUID())")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
            let executable = directory.appendingPathComponent("fake-codex")
            let script = #"""
            #!/bin/sh
            fixture_dir=$(/usr/bin/dirname "$0")
            while IFS= read -r line; do
              printf '%s\n' "$line" >> "$fixture_dir/requests.jsonl"
              id=$(printf '%s' "$line" | /usr/bin/sed -n 's/.*"id":\([0-9][0-9]*\).*/\1/p')
              case "$line" in
                *initialized*) continue ;;
                *initialize*) result='{}' ;;
                *account*rateLimits*read*)
                  if [ -f "$fixture_dir/reject-usage" ]; then
                    printf '{"id":%s,"error":{"code":-32000}}\n' "$id"
                    continue
                  fi
                  result=$(/bin/cat "$fixture_dir/usage.json") ;;
                *account*read*) result=$(/bin/cat "$fixture_dir/account.json") ;;
                *account*logout*)
                  if [ -f "$fixture_dir/reject-logout" ]; then
                    printf '{"id":%s,"error":{"code":-32000}}\n' "$id"
                    continue
                  fi
                  printf '{"account":null}' > "$fixture_dir/account.json"
                  result='{}' ;;
                *account*rateLimitResetCredit*consume*)
                  if [ ! -f "$fixture_dir/State/pending-resets.json" ]; then
                    printf '{"id":%s,"error":{"code":-32001}}\n' "$id"
                    continue
                  fi
                  if [ -f "$fixture_dir/hang-consume" ]; then continue; fi
                  result='{"outcome":"reset"}' ;;
                *) printf '{"id":%s,"error":{"code":-32601}}\n' "$id"; continue ;;
              esac
              printf '{"id":%s,"result":%s}\n' "$id" "$result"
            done
            """#
            try Data(script.utf8).write(to: executable)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
            client = AppServerClient(executablePath: executable.path,
                                     runtimeDirectory: directory.appendingPathComponent("Runtime"),
                                     requestTimeout: .seconds(1))
            monitor = UsageMonitor(client: client, defaults: defaults)
            store = ResetAttemptStore(directory: directory.appendingPathComponent("State"))
            try writeAccount("account-a")
            try writeUsage()
        }

        func writeAccount(_ id: String) throws {
            try write(["account": ["type": "chatgpt", "email": "\(id)@example.invalid", "planType": "pro"]], to: "account.json")
        }

        func writeUsage(owner: String = "account-a", includeCard: Bool = true) throws {
            let now = Date().timeIntervalSince1970
            try write([
                "accountId": owner,
                "rateLimits": ["limitId": "codex", "primary": ["usedPercent": 40, "windowDurationMins": 60, "resetsAt": now + 1800]],
                "rateLimitResetCredits": ["availableCount": includeCard ? 1 : 0,
                    "credits": includeCard ? [["id": "card-a", "status": "available", "resetType": "codexRateLimits", "grantedAt": now - 60, "expiresAt": now + 3600]] : []]
            ], to: "usage.json")
        }

        func write(_ object: [String: Any], to name: String) throws {
            try JSONSerialization.data(withJSONObject: object).write(to: directory.appendingPathComponent(name), options: .atomic)
        }

        func marker(_ name: String) throws { try Data().write(to: directory.appendingPathComponent(name)) }
        func removeMarker(_ name: String) throws { try FileManager.default.removeItem(at: directory.appendingPathComponent(name)) }

        func refresh() async throws {
            await monitor.refresh()
            _ = try XCTUnwrap(monitor.snapshot, monitor.errorMessage ?? "Missing fixture snapshot")
        }

        func consumeRequests() throws -> [[String: Any]] {
            let content = try String(contentsOf: directory.appendingPathComponent("requests.jsonl"), encoding: .utf8)
            return try content.split(separator: "\n").compactMap { line in
                let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
                return object["method"] as? String == "account/rateLimitResetCredit/consume" ? object : nil
            }
        }

        func cleanup() {
            monitor.shutdown()
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: directory)
        }
    }

    func testRefreshFailurePreservesLastUsageButBlocksResetUntilRecovery() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        try await fixture.refresh()
        let card = try XCTUnwrap(fixture.monitor.sortedCredits.first)
        let confirmation = try XCTUnwrap(fixture.monitor.makeResetConfirmation(for: card))
        try fixture.marker("reject-usage")
        await fixture.monitor.refresh()
        XCTAssertNotNil(fixture.monitor.snapshot)
        XCTAssertTrue(fixture.monitor.isStale(at: .now))
        XCTAssertFalse(fixture.monitor.canConfirmRedemption(confirmation, at: .now))
        await fixture.monitor.redeem(confirmation)
        XCTAssertTrue(try fixture.consumeRequests().isEmpty)
        try fixture.removeMarker("reject-usage")
        try await fixture.refresh()
        XCTAssertNil(fixture.monitor.errorMessage)
        XCTAssertFalse(fixture.monitor.isStale(at: .now))
        XCTAssertTrue(fixture.monitor.canConfirmRedemption(confirmation, at: .now))
    }

    func testLoggedOutAndChangedAccountClearPreviousUsageAndPendingOperation() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        _ = try fixture.store.prepare(creditID: "card-a", owner: "account-a")
        try await fixture.refresh()
        XCTAssertNotNil(fixture.monitor.pendingRedemption)
        try fixture.write(["account": NSNull()], to: "account.json")
        await fixture.monitor.refresh()
        XCTAssertNil(fixture.monitor.account)
        XCTAssertNil(fixture.monitor.snapshot)
        XCTAssertNil(fixture.monitor.pendingRedemption)
        try fixture.writeAccount("account-b")
        try fixture.writeUsage(owner: "account-b")
        try await fixture.refresh()
        XCTAssertEqual(fixture.monitor.account?.email, "account-b@example.invalid")
        XCTAssertNil(fixture.monitor.pendingRedemption)
        XCTAssertNotNil(try fixture.store.pending(for: "account-a"), "Logout must retain unresolved requests")
        XCTAssertTrue(try fixture.consumeRequests().isEmpty)
    }

    func testOpeningAndCancellingConfirmationDoesNotConsumeOrPersist() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        try await fixture.refresh()
        let card = try XCTUnwrap(fixture.monitor.sortedCredits.first)
        for _ in 0..<3 {
            XCTAssertNotNil(fixture.monitor.makeResetConfirmation(for: card))
        }
        // Cancellation dismisses the view without calling redeem.
        XCTAssertTrue(try fixture.consumeRequests().isEmpty)
        XCTAssertNil(try fixture.store.pending(for: "account-a"))
    }

    func testDoubleClickWhileConsumptionIsPendingSendsOnlyOneRequest() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        try await fixture.refresh()
        let card = try XCTUnwrap(fixture.monitor.sortedCredits.first)
        let confirmation = try XCTUnwrap(fixture.monitor.makeResetConfirmation(for: card))
        try fixture.marker("hang-consume")
        let first = Task { await fixture.monitor.redeem(confirmation) }
        // Wait for the fake server to observe the actual consume request.
        for _ in 0..<100 {
            if !(try fixture.consumeRequests()).isEmpty { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertTrue(fixture.monitor.isBusy)
        await fixture.monitor.redeem(confirmation)
        await first.value
        XCTAssertEqual(try fixture.consumeRequests().count, 1)
        XCTAssertNotNil(fixture.monitor.pendingRedemption)
    }

    func testLogoutReconnectsAndOnlyClearsAccountAfterSuccess() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        try await fixture.refresh()
        XCTAssertNotNil(fixture.monitor.account)
        fixture.client.stop()
        try fixture.marker("reject-logout")
        await fixture.monitor.logout()
        XCTAssertNotNil(fixture.monitor.account, "RPC failure must not be presented as a successful logout")
        XCTAssertNotNil(fixture.monitor.errorMessage)
        try fixture.removeMarker("reject-logout")
        fixture.client.stop()
        await fixture.monitor.logout()
        XCTAssertNil(fixture.monitor.account)
        XCTAssertNil(fixture.monitor.snapshot)
        XCTAssertNil(fixture.monitor.errorMessage)
    }

    func testTimedOutConsumptionRetainsAndReusesPersistedRequest() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        try await fixture.refresh()
        let card = try XCTUnwrap(fixture.monitor.sortedCredits.first)
        let confirmation = try XCTUnwrap(fixture.monitor.makeResetConfirmation(for: card))
        try fixture.marker("hang-consume")
        await fixture.monitor.redeem(confirmation)
        let pending = try XCTUnwrap(fixture.monitor.pendingRedemption)
        XCTAssertEqual(try fixture.store.pending(for: "account-a")?.idempotencyKey, pending.idempotencyKey)
        XCTAssertNotNil(fixture.monitor.errorMessage)
        try fixture.removeMarker("hang-consume")
        let retry = try XCTUnwrap(fixture.monitor.makeResetConfirmation(for: nil))
        await fixture.monitor.redeem(retry)
        let requests = try fixture.consumeRequests()
        XCTAssertEqual(requests.count, 2)
        for request in requests {
            let params = try XCTUnwrap(request["params"] as? [String: Any])
            XCTAssertEqual(params["idempotencyKey"] as? String, pending.idempotencyKey)
            XCTAssertEqual(params["creditId"] as? String, card.id)
        }
        XCTAssertNil(fixture.monitor.pendingRedemption)
        XCTAssertNil(try fixture.store.pending(for: "account-a"))
        XCTAssertNil(fixture.monitor.errorMessage)
    }

    func testPreflightRejectsAccountChangeWithoutConsuming() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        try await fixture.refresh()
        let card = try XCTUnwrap(fixture.monitor.sortedCredits.first)
        let confirmation = try XCTUnwrap(fixture.monitor.makeResetConfirmation(for: card))
        try fixture.writeAccount("account-b")
        try fixture.writeUsage(owner: "account-b")
        await fixture.monitor.redeem(confirmation)
        XCTAssertTrue(try fixture.consumeRequests().isEmpty)
        XCTAssertNil(try fixture.store.pending(for: "account-a"))
        XCTAssertEqual(fixture.monitor.notice, "操作已变化，请重新打开确认页。")
    }

    func testPreflightRejectsDisappearedCardWithoutConsuming() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        try await fixture.refresh()
        let card = try XCTUnwrap(fixture.monitor.sortedCredits.first)
        let confirmation = try XCTUnwrap(fixture.monitor.makeResetConfirmation(for: card))
        try fixture.writeUsage(includeCard: false)
        await fixture.monitor.redeem(confirmation)
        XCTAssertTrue(try fixture.consumeRequests().isEmpty)
        XCTAssertNil(try fixture.store.pending(for: "account-a"))
        XCTAssertNotNil(fixture.monitor.errorMessage)
    }

    func testNewConfirmationCannotBecomeAnotherCardsRetry() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        try await fixture.refresh()
        let card = try XCTUnwrap(fixture.monitor.sortedCredits.first)
        let confirmation = try XCTUnwrap(fixture.monitor.makeResetConfirmation(for: card))
        let other = try fixture.store.prepare(creditID: "card-b", owner: "account-a")
        try await fixture.refresh()
        XCTAssertNil(confirmation.retry, "The open page must remain a new operation, never switch to retry")
        XCTAssertFalse(fixture.monitor.isResetConfirmationCurrent(confirmation))
        XCTAssertFalse(fixture.monitor.canConfirmRedemption(confirmation, at: .now))
        XCTAssertNil(fixture.monitor.makeResetConfirmation(for: card))
        await fixture.monitor.redeem(confirmation)
        XCTAssertTrue(try fixture.consumeRequests().isEmpty)
        XCTAssertEqual(try fixture.store.pending(for: "account-a")?.idempotencyKey, other.idempotencyKey)
    }

    func testNewConfirmationRejectsPendingOperationDiscoveredDuringPreflight() async throws {
        for pendingCard in ["card-a", "card-b"] {
            let fixture = try Fixture()
            defer { fixture.cleanup() }
            try await fixture.refresh()
            let card = try XCTUnwrap(fixture.monitor.sortedCredits.first)
            let confirmation = try XCTUnwrap(fixture.monitor.makeResetConfirmation(for: card))
            let other = try fixture.store.prepare(creditID: pendingCard, owner: "account-a")
            // No UI refresh yet: the execution preflight must catch the external change.
            XCTAssertTrue(fixture.monitor.canConfirmRedemption(confirmation, at: .now))
            await fixture.monitor.redeem(confirmation)
            XCTAssertTrue(try fixture.consumeRequests().isEmpty)
            XCTAssertEqual(try fixture.store.pending(for: "account-a")?.idempotencyKey, other.idempotencyKey)
            XCTAssertEqual(fixture.monitor.notice, "操作已变化，请重新打开确认页。")
        }
    }

    func testRetryRejectsReplacedKeyEvenForSameCard() async throws {
        for refreshBeforeClick in [true, false] {
            let fixture = try Fixture()
            defer { fixture.cleanup() }
            let original = try fixture.store.prepare(creditID: "card-a", owner: "account-a")
            try await fixture.refresh()
            let confirmation = try XCTUnwrap(fixture.monitor.makeResetConfirmation(for: nil))
            try fixture.store.clear(owner: "account-a", idempotencyKey: original.idempotencyKey)
            let replacement = try fixture.store.prepare(creditID: "card-a", owner: "account-a")
            XCTAssertNotEqual(original.idempotencyKey, replacement.idempotencyKey)
            if refreshBeforeClick {
                try await fixture.refresh()
                XCTAssertFalse(fixture.monitor.canConfirmRedemption(confirmation, at: .now))
            }
            await fixture.monitor.redeem(confirmation)
            XCTAssertTrue(try fixture.consumeRequests().isEmpty)
            XCTAssertEqual(try fixture.store.pending(for: "account-a")?.idempotencyKey, replacement.idempotencyKey)
        }
    }

    func testRetryCanKeepOriginalTargetWhenCardDetailsDisappear() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let original = try fixture.store.prepare(creditID: "card-a", owner: "account-a")
        try fixture.writeUsage(includeCard: false)
        try await fixture.refresh()
        let confirmation = try XCTUnwrap(fixture.monitor.makeResetConfirmation(for: nil))
        XCTAssertNil(confirmation.credit)
        XCTAssertEqual(confirmation.creditID, "card-a")
        await fixture.monitor.redeem(confirmation)
        let request = try XCTUnwrap(fixture.consumeRequests().first)
        let params = try XCTUnwrap(request["params"] as? [String: Any])
        XCTAssertEqual(params["creditId"] as? String, "card-a")
        XCTAssertEqual(params["idempotencyKey"] as? String, original.idempotencyKey)
    }
}
