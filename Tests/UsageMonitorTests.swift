import Foundation
import XCTest
@testable import WatcherCore

/// Exercise the real coordinator against an isolated executable that cannot contact OpenAI.
@MainActor
final class UsageMonitorTests: XCTestCase {
    @MainActor private final class ExpiryClock {
        var date = Date()
        func advance(_ seconds: TimeInterval = 31) { date = date.addingTimeInterval(seconds) }
    }

    @MainActor private final class Fixture {
        let directory: URL
        let defaults: UserDefaults
        let suite = "WatcherMonitorTests-\(UUID())"
        let client: AppServerClient
        let monitor: UsageMonitor
        let store: ResetAttemptStore
        let expiryClock = ExpiryClock()

        init() throws {
            directory = FileManager.default.temporaryDirectory.appendingPathComponent("WatcherMonitor-\(UUID())")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
            let executable = directory.appendingPathComponent("fake-codex")
            let script = #"""
            #!/bin/sh
            fixture_dir=$(/usr/bin/dirname "$0")
            account_reads=0
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
                  if [ -f "$fixture_dir/delay-usage" ]; then /bin/sleep 0.2; fi
                  result=$(/bin/cat "$fixture_dir/usage.json") ;;
                *account*read*)
                  account_reads=$((account_reads + 1))
                  if { [ "$account_reads" -eq 3 ] && [ -f "$fixture_dir/replace-on-preflight" ]; } ||
                     { [ "$account_reads" -eq 2 ] && [ -f "$fixture_dir/replace-on-retry-preflight" ]; }; then
                    /bin/cp "$fixture_dir/next-account.json" "$fixture_dir/account.json"
                    /bin/cp "$fixture_dir/next-usage.json" "$fixture_dir/usage.json"
                  fi
                  result=$(/bin/cat "$fixture_dir/account.json") ;;
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
                                     requestTimeout: .seconds(3))
            monitor = UsageMonitor(client: client, defaults: defaults, expiryNow: { [expiryClock] in expiryClock.date })
            store = ResetAttemptStore(directory: directory.appendingPathComponent("State"))
            try writeAccount("account-a")
            try writeUsage()
        }

        func writeAccount(_ id: String) throws {
            try write(["account": ["type": "chatgpt", "email": "\(id)@example.invalid", "planType": "pro"]], to: "account.json")
        }

        func writeUsage(owner: String = "account-a", includeCard: Bool = true,
                        expirySeconds: TimeInterval = 3600, usedPercent: Double = 40) throws {
            let now = Date().timeIntervalSince1970
            try write([
                "accountId": owner,
                "rateLimits": ["limitId": "codex", "primary": ["usedPercent": usedPercent, "windowDurationMins": 60, "resetsAt": now + 1800]],
                "rateLimitResetCredits": ["availableCount": includeCard ? 1 : 0,
                    "credits": includeCard ? [["id": "card-a", "status": "available", "resetType": "codexRateLimits", "grantedAt": now - 60, "expiresAt": now + expirySeconds]] : []]
            ], to: "usage.json")
        }

        func write(_ object: [String: Any], to name: String) throws {
            try JSONSerialization.data(withJSONObject: object).write(to: directory.appendingPathComponent(name), options: .atomic)
        }

        func addFutureDateCard() throws {
            let url = directory.appendingPathComponent("usage.json")
            var object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
            var summary = try XCTUnwrap(object["rateLimitResetCredits"] as? [String: Any])
            var cards = try XCTUnwrap(summary["credits"] as? [[String: Any]])
            var other = try XCTUnwrap(cards.first)
            other["id"] = "card-b-tomorrow"
            other["expiresAt"] = Date().addingTimeInterval(86400).timeIntervalSince1970
            cards.append(other)
            summary["credits"] = cards
            summary["availableCount"] = cards.count
            object["rateLimitResetCredits"] = summary
            try write(object, to: "usage.json")
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

    func testExpiryHandlingDefaultsOffAndZeroUsageStillAutomaticallyAttemptsOnce() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        try fixture.writeUsage(expirySeconds: 800, usedPercent: 0)
        try await fixture.refresh()
        await fixture.monitor.processExpiringCredits()
        XCTAssertTrue(try fixture.consumeRequests().isEmpty)
        await fixture.monitor.configureExpiryHandling(.automatic)
        await fixture.monitor.processExpiringCredits()
        XCTAssertEqual(try fixture.consumeRequests().count, 1)
        // The fake server intentionally keeps returning the same available card.
        await fixture.monitor.processExpiringCredits()
        XCTAssertEqual(try fixture.consumeRequests().count, 1)
        fixture.monitor.shutdown()
        let restartedClient = AppServerClient(executablePath: fixture.client.executablePath,
            runtimeDirectory: fixture.client.runtimeDirectory)
        let restarted = UsageMonitor(client: restartedClient, defaults: fixture.defaults)
        defer { restarted.shutdown() }
        await restarted.processExpiringCredits()
        XCTAssertEqual(try fixture.consumeRequests().count, 1, "Restart must not create a new consume request")
    }

    func testExpiryReminderNeedsPermissionAndOnlyOpensManualConfirmation() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        try fixture.writeUsage(expirySeconds: 800)
        try await fixture.refresh()
        fixture.monitor.requestExpiryNotificationPermission = { false }
        await fixture.monitor.configureExpiryHandling(.remind)
        XCTAssertEqual(fixture.monitor.expiryConfiguration.mode, .off)
        fixture.monitor.requestExpiryNotificationPermission = { true }
        var reminders: [CreditExpiryReminder] = []
        fixture.monitor.deliverExpiryReminder = { reminders.append($0) }
        await fixture.monitor.configureExpiryHandling(.remind)
        await fixture.monitor.processExpiringCredits()
        await fixture.monitor.processExpiringCredits()
        XCTAssertEqual(reminders.count, 1)
        XCTAssertTrue(try fixture.consumeRequests().isEmpty)
        let reminder = try XCTUnwrap(reminders.first)
        await fixture.monitor.reviewExpiringCredit(accountKey: reminder.accountKey, creditID: reminder.creditID)
        XCTAssertEqual(fixture.monitor.expiryReview?.creditID, "card-a")
        XCTAssertTrue(try fixture.consumeRequests().isEmpty)
        XCTAssertNil(try fixture.store.pending(for: "account-a"))
    }

    func testFailedExpiryNotificationCanBeRetriedWithoutConsuming() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        try fixture.writeUsage(expirySeconds: 800)
        try await fixture.refresh()
        fixture.monitor.requestExpiryNotificationPermission = { true }
        fixture.monitor.deliverExpiryReminder = { _ in throw WatcherError.message("denied") }
        await fixture.monitor.configureExpiryHandling(.remind)
        await fixture.monitor.processExpiringCredits()
        var delivered = 0
        fixture.monitor.deliverExpiryReminder = { _ in delivered += 1 }
        await fixture.monitor.processExpiringCredits()
        XCTAssertEqual(delivered, 1)
        XCTAssertTrue(try fixture.consumeRequests().isEmpty)
    }

    func testAutomaticExpiryStopsOnAccountChangePendingRequestAndReadFailure() async throws {
        for reason in ["account", "pending", "read"] {
            let fixture = try Fixture()
            defer { fixture.cleanup() }
            try fixture.writeUsage(expirySeconds: 800)
            try await fixture.refresh()
            await fixture.monitor.configureExpiryHandling(.automatic)
            switch reason {
            case "account":
                try fixture.writeAccount("account-b")
                try fixture.writeUsage(owner: "account-b", expirySeconds: 800)
            case "pending": _ = try fixture.store.prepare(creditID: "card-b", owner: "account-a")
            default: try fixture.marker("reject-usage")
            }
            await fixture.monitor.processExpiringCredits()
            XCTAssertTrue(try fixture.consumeRequests().isEmpty, reason)
        }
    }

    func testAutomaticExpiryWaitsBeforeRetryAndManualRetryKeepsOriginalKey() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        try fixture.writeUsage(expirySeconds: 800)
        try await fixture.refresh()
        await fixture.monitor.configureExpiryHandling(.automatic)
        try fixture.marker("hang-consume")
        await fixture.monitor.processExpiringCredits()
        let pending = try XCTUnwrap(fixture.monitor.pendingRedemption)
        try fixture.removeMarker("hang-consume")
        await fixture.monitor.processExpiringCredits()
        XCTAssertEqual(try fixture.consumeRequests().count, 1)
        XCTAssertEqual(fixture.monitor.pendingRedemption?.idempotencyKey, pending.idempotencyKey)
        let retry = try XCTUnwrap(fixture.monitor.makeResetConfirmation(for: nil))
        await fixture.monitor.redeem(retry)
        let params = try XCTUnwrap(fixture.consumeRequests().last?["params"] as? [String: Any])
        XCTAssertEqual(params["idempotencyKey"] as? String, pending.idempotencyKey)
    }

    func testAutomaticExpiryRetriesTwiceWithSameCardAndKeyThenStops() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        try fixture.writeUsage(expirySeconds: 800)
        try fixture.addFutureDateCard()
        try await fixture.refresh()
        await fixture.monitor.configureExpiryHandling(.automatic)
        try fixture.marker("hang-consume")
        for attempt in 1...3 {
            await fixture.monitor.processExpiringCredits()
            XCTAssertEqual(try fixture.consumeRequests().count, attempt)
            XCTAssertEqual(fixture.monitor.pendingRedemption?.automatic?.attempts, attempt)
            fixture.expiryClock.advance()
        }
        await fixture.monitor.processExpiringCredits()
        XCTAssertEqual(try fixture.consumeRequests().count, 3)
        let pending = try XCTUnwrap(fixture.monitor.pendingRedemption)
        for request in try fixture.consumeRequests() {
            let params = try XCTUnwrap(request["params"] as? [String: Any])
            XCTAssertEqual(params["creditId"] as? String, "card-a")
            XCTAssertEqual(params["idempotencyKey"] as? String, pending.idempotencyKey)
        }
    }

    func testAutomaticRetryResumesAfterRestartAndStopsAfterSuccess() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        try fixture.writeUsage(expirySeconds: 800)
        try await fixture.refresh()
        await fixture.monitor.configureExpiryHandling(.automatic)
        try fixture.marker("hang-consume")
        await fixture.monitor.processExpiringCredits()
        let original = try XCTUnwrap(fixture.monitor.pendingRedemption)
        fixture.monitor.shutdown()
        try fixture.removeMarker("hang-consume")
        fixture.expiryClock.advance()
        let restarted = UsageMonitor(client: AppServerClient(executablePath: fixture.client.executablePath,
            runtimeDirectory: fixture.client.runtimeDirectory), defaults: fixture.defaults,
            expiryNow: { fixture.expiryClock.date })
        defer { restarted.shutdown() }
        await restarted.processExpiringCredits()
        await restarted.processExpiringCredits()
        XCTAssertEqual(try fixture.consumeRequests().count, 2)
        let params = try XCTUnwrap(fixture.consumeRequests().last?["params"] as? [String: Any])
        XCTAssertEqual(params["creditId"] as? String, original.creditID)
        XCTAssertEqual(params["idempotencyKey"] as? String, original.idempotencyKey)
        XCTAssertNil(restarted.pendingRedemption)
    }

    func testRetryCannotSwitchToAnotherCardOrChangedExpiryOrAccount() async throws {
        for change in ["another-card", "changed-expiry", "expired", "account", "disabled"] {
            let fixture = try Fixture()
            defer { fixture.cleanup() }
            try fixture.writeUsage(expirySeconds: 800)
            try await fixture.refresh()
            await fixture.monitor.configureExpiryHandling(.automatic)
            try fixture.marker("hang-consume")
            await fixture.monitor.processExpiringCredits()
            let original = try XCTUnwrap(fixture.monitor.pendingRedemption)
            try fixture.removeMarker("hang-consume")
            switch change {
            case "another-card":
                let url = fixture.directory.appendingPathComponent("usage.json")
                var object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
                var credits = try XCTUnwrap(object["rateLimitResetCredits"] as? [String: Any])
                var cards = try XCTUnwrap(credits["credits"] as? [[String: Any]])
                cards[0]["id"] = "card-b-different-date"
                cards[0]["expiresAt"] = Date().addingTimeInterval(850).timeIntervalSince1970
                credits["credits"] = cards
                object["rateLimitResetCredits"] = credits
                try fixture.write(object, to: "usage.json")
            case "changed-expiry": try fixture.writeUsage(expirySeconds: 700)
            case "expired": fixture.expiryClock.advance(900)
            case "account":
                try fixture.writeAccount("account-b")
                try fixture.writeUsage(owner: "account-b", expirySeconds: 800)
            default: await fixture.monitor.configureExpiryHandling(.off)
            }
            fixture.expiryClock.advance()
            await fixture.monitor.processExpiringCredits()
            XCTAssertEqual(try fixture.consumeRequests().count, 1, change)
            XCTAssertEqual(try fixture.store.pending(for: "account-a")?.idempotencyKey, original.idempotencyKey)
        }
    }

    func testAutomaticRetryRechecksOriginalExpiryDuringExecutionPreflight() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        try fixture.writeUsage(expirySeconds: 800)
        try await fixture.refresh()
        await fixture.monitor.configureExpiryHandling(.automatic)
        try fixture.marker("hang-consume")
        await fixture.monitor.processExpiringCredits()
        let original = try XCTUnwrap(fixture.monitor.pendingRedemption)
        try fixture.removeMarker("hang-consume")
        let account = fixture.directory.appendingPathComponent("account.json")
        let usage = fixture.directory.appendingPathComponent("usage.json")
        let oldUsage = try Data(contentsOf: usage)
        try FileManager.default.copyItem(at: account, to: fixture.directory.appendingPathComponent("next-account.json"))
        try fixture.writeUsage(expirySeconds: 700)
        try FileManager.default.copyItem(at: usage, to: fixture.directory.appendingPathComponent("next-usage.json"))
        try oldUsage.write(to: usage)
        try fixture.marker("replace-on-retry-preflight")
        fixture.expiryClock.advance()
        await fixture.monitor.processExpiringCredits()
        XCTAssertEqual(try fixture.consumeRequests().count, 1)
        XCTAssertEqual(try fixture.store.pending(for: "account-a")?.idempotencyKey, original.idempotencyKey)
        XCTAssertEqual(try fixture.store.pending(for: "account-a")?.automatic?.attempts, 1)
    }

    func testConcurrentAutomaticRetryUsesOneSharedAttemptReservation() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        try fixture.writeUsage(expirySeconds: 800)
        try await fixture.refresh()
        await fixture.monitor.configureExpiryHandling(.automatic)
        try fixture.marker("hang-consume")
        await fixture.monitor.processExpiringCredits()
        fixture.expiryClock.advance()
        let other = UsageMonitor(client: AppServerClient(executablePath: fixture.client.executablePath,
            runtimeDirectory: fixture.client.runtimeDirectory, requestTimeout: .seconds(3)), defaults: fixture.defaults,
            expiryNow: { fixture.expiryClock.date })
        defer { other.shutdown() }
        async let first: Void = fixture.monitor.processExpiringCredits()
        async let second: Void = other.processExpiringCredits()
        _ = await (first, second)
        XCTAssertEqual(try fixture.consumeRequests().count, 2)
        XCTAssertEqual(try fixture.store.pending(for: "account-a")?.automatic?.attempts, 2)
    }

    func testDisablingDuringExpiryRefreshPreventsAutomaticConsumption() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        try fixture.writeUsage(expirySeconds: 800)
        try await fixture.refresh()
        await fixture.monitor.configureExpiryHandling(.automatic)
        try fixture.marker("delay-usage")
        let check = Task { await fixture.monitor.processExpiringCredits() }
        while !fixture.monitor.isBusy { await Task.yield() }
        await fixture.monitor.configureExpiryHandling(.off)
        await check.value
        XCTAssertTrue(try fixture.consumeRequests().isEmpty)
        XCTAssertEqual(fixture.monitor.expiryConfiguration.mode, .off)
    }

    func testExpiryAutoOutsideLeadWindowAndExpiredCardsDoNotConsume() async throws {
        for seconds: Double in [1000, -1, 0] {
            let fixture = try Fixture()
            defer { fixture.cleanup() }
            try fixture.writeUsage(expirySeconds: seconds)
            try await fixture.refresh()
            await fixture.monitor.configureExpiryHandling(.automatic)
            await fixture.monitor.processExpiringCredits()
            XCTAssertTrue(try fixture.consumeRequests().isEmpty)
        }
    }

    func testConcurrentExpiryMonitorsSendOnlyOneConsumption() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        try fixture.writeUsage(expirySeconds: 800)
        try await fixture.refresh()
        await fixture.monitor.configureExpiryHandling(.automatic)
        let other = UsageMonitor(client: AppServerClient(executablePath: fixture.client.executablePath,
            runtimeDirectory: fixture.client.runtimeDirectory), defaults: fixture.defaults)
        defer { other.shutdown() }
        async let first: Void = fixture.monitor.processExpiringCredits()
        async let second: Void = other.processExpiringCredits()
        _ = await (first, second)
        XCTAssertEqual(try fixture.consumeRequests().count, 1)
    }

    func testNotificationClickForAnotherAccountCannotOpenConfirmation() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        try fixture.writeUsage(expirySeconds: 800)
        try await fixture.refresh()
        try fixture.writeAccount("account-b")
        try fixture.writeUsage(owner: "account-b", expirySeconds: 800)
        await fixture.monitor.reviewExpiringCredit(accountKey: "account-a", creditID: "card-a")
        XCTAssertNil(fixture.monitor.expiryReview)
        XCTAssertTrue(try fixture.consumeRequests().isEmpty)
    }

    func testDeniedReminderPermissionStopsPreviouslyEnabledAutomaticMode() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        try fixture.writeUsage(expirySeconds: 800)
        try await fixture.refresh()
        await fixture.monitor.configureExpiryHandling(.automatic)
        fixture.monitor.requestExpiryNotificationPermission = { false }
        await fixture.monitor.configureExpiryHandling(.remind)
        XCTAssertEqual(fixture.monitor.expiryConfiguration.mode, .off)
        await fixture.monitor.processExpiringCredits()
        XCTAssertTrue(try fixture.consumeRequests().isEmpty)
    }

    func testAutomaticExpiryRevalidatesAccountAndCardImmediatelyBeforeSending() async throws {
        for change in ["account", "expiry"] {
            let fixture = try Fixture()
            defer { fixture.cleanup() }
            try fixture.writeUsage(expirySeconds: 800)
            try await fixture.refresh()
            await fixture.monitor.configureExpiryHandling(.automatic)
            let account = try Data(contentsOf: fixture.directory.appendingPathComponent("account.json"))
            let usage = try Data(contentsOf: fixture.directory.appendingPathComponent("usage.json"))
            try fixture.writeAccount(change == "account" ? "account-b" : "account-a")
            try fixture.writeUsage(owner: change == "account" ? "account-b" : "account-a",
                                   expirySeconds: change == "expiry" ? -1 : 800)
            try FileManager.default.copyItem(at: fixture.directory.appendingPathComponent("account.json"),
                                            to: fixture.directory.appendingPathComponent("next-account.json"))
            try FileManager.default.copyItem(at: fixture.directory.appendingPathComponent("usage.json"),
                                            to: fixture.directory.appendingPathComponent("next-usage.json"))
            try account.write(to: fixture.directory.appendingPathComponent("account.json"))
            try usage.write(to: fixture.directory.appendingPathComponent("usage.json"))
            try fixture.marker("replace-on-preflight")
            await fixture.monitor.processExpiringCredits()
            XCTAssertTrue(try fixture.consumeRequests().isEmpty, change)
            XCTAssertNil(try fixture.store.pending(for: "account-a"))
        }
    }

    func testReminderClickWaitsForDashboardRefreshWithoutConsuming() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        try fixture.writeUsage(expirySeconds: 800)
        try await fixture.refresh()
        try fixture.marker("delay-usage")
        let refresh = Task { await fixture.monitor.refresh() }
        while !fixture.monitor.isBusy { await Task.yield() }
        await fixture.monitor.reviewExpiringCredit(accountKey: "account-a", creditID: "card-a")
        await refresh.value
        XCTAssertEqual(fixture.monitor.expiryReview?.creditID, "card-a")
        XCTAssertTrue(try fixture.consumeRequests().isEmpty)
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
