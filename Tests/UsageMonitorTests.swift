import Foundation
import AppKit
import XCTest
@testable import WatcherCore

/// Exercise the real coordinator against an isolated executable that cannot contact OpenAI.
@MainActor
final class UsageMonitorTests: XCTestCase {
    @MainActor private final class ExpiryClock {
        var date = Date()
        var override: (() -> Date)?
        func now() -> Date { override?() ?? date }
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
              method=$(printf '%s' "$line" | /usr/bin/sed -n 's/.*"method":"\([^"]*\)".*/\1/p')
              case "$method" in
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
                *model*list*)
                  result='{"data":[{"model":"fixture-model","isDefault":true,"hidden":false,"supportedReasoningEfforts":[{"reasoningEffort":"low"}]}],"nextCursor":null}' ;;
                *thread*start*)
                  if [ -f "$fixture_dir/delay-hello-prepare" ]; then /bin/sleep 0.3; fi
                  if [ -f "$fixture_dir/change-hello-account" ]; then
                    /bin/cp "$fixture_dir/next-account.json" "$fixture_dir/account.json"
                    /bin/cp "$fixture_dir/next-usage.json" "$fixture_dir/usage.json"
                  fi
                  result='{"thread":{"id":"hello-thread","ephemeral":true},"modelProvider":"openai"}' ;;
                *turn*start*)
                  if [ ! -f "$fixture_dir/State/automatic-hello.json" ]; then
                    printf '{"id":%s,"error":{"code":-32001}}\n' "$id"; continue
                  fi
                  if [ -f "$fixture_dir/hang-hello" ]; then continue; fi
                  if [ -f "$fixture_dir/post-hello.json" ]; then /bin/cp "$fixture_dir/post-hello.json" "$fixture_dir/usage.json"; fi
                  printf '{"id":%s,"result":{"turn":{"id":"hello-turn","status":"inProgress"}}}\n' "$id"
                  if [ -f "$fixture_dir/hold-hello-completion" ]; then continue; fi
                  printf '{"method":"turn/completed","params":{"threadId":"hello-thread","turn":{"id":"hello-turn","status":"completed"}}}\n'
                  continue ;;
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
                  if [ -f "$fixture_dir/reject-after-consume" ]; then /usr/bin/touch "$fixture_dir/reject-usage"; fi
                  if [ -f "$fixture_dir/nothing-to-reset" ]; then
                    result='{"outcome":"nothingToReset"}'
                  else
                    result='{"outcome":"reset"}'
                  fi ;;
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
            monitor = UsageMonitor(client: client, defaults: defaults, expiryNow: { [expiryClock] in expiryClock.now() })
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

        func enableAutomatic() async throws {
            let authorization = try XCTUnwrap(monitor.makeAutomaticExpiryAuthorization())
            await monitor.configureExpiryHandling(.automatic, authorization: authorization)
            XCTAssertEqual(monitor.expiryConfiguration.mode, .automatic)
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

        func helloRequests() throws -> [[String: Any]] {
            let content = try String(contentsOf: directory.appendingPathComponent("requests.jsonl"), encoding: .utf8)
            return try content.split(separator: "\n").compactMap { line in
                let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
                return object["method"] as? String == "turn/start" ? object : nil
            }
        }

        func enableHello() throws {
            let authorization = try XCTUnwrap(monitor.makeAutomaticHelloAuthorization(windowID: "codex.primary"))
            monitor.configureAutomaticHello(true, authorization: authorization)
            XCTAssertTrue(monitor.automaticHelloConfiguration.enabled)
        }

        func waitForRequest(_ method: String) async throws {
            let deadline = Date().addingTimeInterval(3)
            while Date() < deadline {
                if let log = try? String(contentsOf: directory.appendingPathComponent("requests.jsonl"), encoding: .utf8) {
                    let found = log.split(separator: "\n").contains {
                        ((try? JSONSerialization.jsonObject(with: Data($0.utf8))) as? [String: Any])?["method"] as? String == method
                    }
                    if found { return }
                }
                try await Task.sleep(for: .milliseconds(5))
            }
            XCTFail("Fixture did not receive \(method)")
        }

        func cleanup() {
            monitor.shutdown()
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: directory)
        }
    }

    func testAutomaticHelloDefaultsOffAndOnlyFullRawUsageCanTrigger() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        try fixture.writeUsage(usedPercent: 0)
        try await fixture.refresh()
        XCTAssertFalse(fixture.monitor.automaticHelloConfiguration.enabled)
        await fixture.monitor.processAutomaticHello()
        XCTAssertTrue(try fixture.helloRequests().isEmpty)
        try fixture.enableHello()
        try fixture.writeUsage(usedPercent: 0.01)
        await fixture.monitor.processAutomaticHello()
        XCTAssertTrue(try fixture.helloRequests().isEmpty)
        try fixture.writeUsage(usedPercent: 0)
        await fixture.monitor.processAutomaticHello()
        XCTAssertEqual(try fixture.helloRequests().count, 1)
        XCTAssertEqual(fixture.monitor.automaticHelloRecord?.outcome, "completed", fixture.monitor.automaticHelloMessage ?? "No error")
        let params = try XCTUnwrap(fixture.helloRequests().first?["params"] as? [String: Any])
        let input = try XCTUnwrap(params["input"] as? [[String: Any]])
        XCTAssertEqual(input.first?["text"] as? String, "hello")
        XCTAssertEqual(params["approvalPolicy"] as? String, "never")
        XCTAssertTrue(try fixture.consumeRequests().isEmpty)
    }

    func testHelloStaysLatchedAcrossFullReadTimeChangeToggleAndRestart() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        try fixture.writeUsage(usedPercent: 0)
        try await fixture.refresh()
        try fixture.enableHello()
        await fixture.monitor.processAutomaticHello()
        try fixture.writeUsage(usedPercent: 0) // A different future resetsAt must not trigger another turn.
        await fixture.monitor.processAutomaticHello()
        fixture.monitor.configureAutomaticHello(false)
        try fixture.enableHello()
        await fixture.monitor.processAutomaticHello()
        let restarted = UsageMonitor(client: AppServerClient(executablePath: fixture.client.executablePath,
            runtimeDirectory: fixture.client.runtimeDirectory), defaults: fixture.defaults)
        defer { restarted.shutdown() }
        await restarted.processAutomaticHello()
        XCTAssertEqual(try fixture.helloRequests().count, 1)
    }

    func testHelloRearmsAfterLaterUsageAndNonNaturalReturnToFull() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        try fixture.writeUsage(usedPercent: 0)
        try await fixture.refresh()
        try fixture.enableHello()
        await fixture.monitor.processAutomaticHello()
        try fixture.writeUsage(usedPercent: 0.2) // Ignore the greeting's own small use.
        await fixture.monitor.processAutomaticHello()
        try fixture.writeUsage(usedPercent: 0)
        await fixture.monitor.processAutomaticHello()
        XCTAssertEqual(try fixture.helloRequests().count, 1)
        try fixture.writeUsage(usedPercent: 15)
        await fixture.monitor.processAutomaticHello()
        try fixture.writeUsage(usedPercent: 0) // Future deadline: externally reset quota.
        await fixture.monitor.processAutomaticHello()
        XCTAssertEqual(try fixture.helloRequests().count, 2)
    }

    func testHelloUnknownResultIsNotAutomaticallyRetried() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        try fixture.writeUsage(usedPercent: 0)
        try await fixture.refresh()
        try fixture.enableHello()
        try fixture.marker("hang-hello")
        await fixture.monitor.processAutomaticHello()
        XCTAssertEqual(fixture.monitor.automaticHelloRecord?.outcome, "unknown")
        try fixture.removeMarker("hang-hello")
        await fixture.monitor.processAutomaticHello()
        XCTAssertEqual(try fixture.helloRequests().count, 1)
    }

    func testHelloPastDeadlineIsEligibleButMissingDeadlineAndPendingResetAreNot() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let now = Date().timeIntervalSince1970
        try fixture.write(["accountId": "account-a", "rateLimits": ["limitId": "codex",
            "primary": ["usedPercent": 0, "windowDurationMins": 300]]], to: "usage.json")
        try await fixture.refresh()
        try fixture.enableHello()
        await fixture.monitor.processAutomaticHello()
        XCTAssertTrue(try fixture.helloRequests().isEmpty)
        try fixture.write(["accountId": "account-a", "rateLimits": ["limitId": "codex",
            "primary": ["usedPercent": 0, "windowDurationMins": 300, "resetsAt": now - 60]]], to: "usage.json")
        let pending = try fixture.store.prepare(creditID: "card-a", owner: "account-a")
        await fixture.monitor.processAutomaticHello()
        XCTAssertTrue(try fixture.helloRequests().isEmpty)
        try fixture.store.clear(owner: "account-a", idempotencyKey: pending.idempotencyKey)
        await fixture.monitor.processAutomaticHello()
        XCTAssertEqual(try fixture.helloRequests().count, 1)
    }

    func testHelloAuthorizationAndFinalPreflightCannotFollowAnotherAccount() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        try fixture.writeUsage(usedPercent: 0)
        try await fixture.refresh()
        let authorization = try XCTUnwrap(fixture.monitor.makeAutomaticHelloAuthorization(windowID: "codex.primary"))
        try fixture.writeAccount("account-b")
        try fixture.writeUsage(owner: "account-b", usedPercent: 0)
        try await fixture.refresh()
        fixture.monitor.configureAutomaticHello(true, authorization: authorization)
        XCTAssertFalse(fixture.monitor.automaticHelloConfiguration.enabled)
        try fixture.writeAccount("account-a")
        try fixture.writeUsage(usedPercent: 0)
        try await fixture.refresh()
        try fixture.enableHello()
        try fixture.write(["account": ["type": "chatgpt", "email": "account-b@example.invalid"]], to: "next-account.json")
        let usage = try Data(contentsOf: fixture.directory.appendingPathComponent("usage.json"))
        var changed = try XCTUnwrap(JSONSerialization.jsonObject(with: usage) as? [String: Any])
        changed["accountId"] = "account-b"
        try fixture.write(changed, to: "next-usage.json")
        try fixture.marker("change-hello-account")
        await fixture.monitor.processAutomaticHello()
        XCTAssertTrue(try fixture.helloRequests().isEmpty)
    }

    func testDisablingHelloDuringPreparationStopsInference() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        try fixture.writeUsage(usedPercent: 0)
        try await fixture.refresh()
        try fixture.enableHello()
        try fixture.marker("delay-hello-prepare")
        let task = Task { await fixture.monitor.processAutomaticHello() }
        for _ in 0..<200 {
            let log = (try? String(contentsOf: fixture.directory.appendingPathComponent("requests.jsonl"), encoding: .utf8)) ?? ""
            if log.contains("thread") { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        fixture.monitor.configureAutomaticHello(false)
        await task.value
        XCTAssertFalse(fixture.monitor.automaticHelloConfiguration.enabled)
        XCTAssertTrue(try fixture.helloRequests().isEmpty)
    }

    func testSlowHelloPreparationAllowsForegroundRefreshAndUsesItsOwnFreshPreflight() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        try fixture.writeUsage(usedPercent: 0)
        try await fixture.refresh()
        try fixture.enableHello()
        try fixture.marker("delay-hello-prepare")
        let task = Task { await fixture.monitor.processAutomaticHello() }
        try await fixture.waitForRequest("thread/start")
        XCTAssertFalse(fixture.monitor.isBusy)
        let previousUpdate = fixture.monitor.lastUpdated
        try fixture.writeUsage(usedPercent: 25)
        await fixture.monitor.refresh()
        XCTAssertEqual(fixture.monitor.selectedWindow?.quota.usedPercent, 25)
        XCTAssertNotEqual(fixture.monitor.lastUpdated, previousUpdate)
        await task.value
        XCTAssertTrue(try fixture.helloRequests().isEmpty, "Fresh preflight must observe the intervening usage")
    }

    func testManualResetPreemptsHelloPreparationBeforeAnyInference() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        try fixture.writeUsage(usedPercent: 0)
        try await fixture.refresh()
        try fixture.enableHello()
        try fixture.marker("delay-hello-prepare")
        let task = Task { await fixture.monitor.processAutomaticHello() }
        try await fixture.waitForRequest("thread/start")
        let confirmation = try XCTUnwrap(fixture.monitor.makeResetConfirmation(for: fixture.monitor.sortedCredits.first))
        await fixture.monitor.redeem(confirmation)
        await task.value
        XCTAssertEqual(try fixture.consumeRequests().count, 1)
        XCTAssertTrue(try fixture.helloRequests().isEmpty)
    }

    func testWaitingHelloDoesNotBlockRefreshAndLogoutStopsItsSession() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        try fixture.writeUsage(usedPercent: 0)
        try await fixture.refresh()
        try fixture.enableHello()
        try fixture.marker("hold-hello-completion")
        let task = Task { await fixture.monitor.processAutomaticHello() }
        try await fixture.waitForRequest("turn/start")
        XCTAssertFalse(fixture.monitor.isBusy)
        XCTAssertTrue(fixture.monitor.isSendingHello)
        try fixture.writeUsage(usedPercent: 20)
        await fixture.monitor.refresh()
        XCTAssertEqual(fixture.monitor.selectedWindow?.quota.usedPercent, 20)
        await fixture.monitor.logout()
        await task.value
        XCTAssertNil(fixture.monitor.account)
        XCTAssertFalse(fixture.monitor.isSendingHello)
        let record = try AutomaticHelloStore(directory: fixture.directory.appendingPathComponent("State"))
            .record(account: "account-a", windowID: "codex.primary")
        XCTAssertEqual(record?.outcome, "unknown")
        XCTAssertEqual(try fixture.helloRequests().count, 1)
    }

    func testExpiringCardRedemptionPreemptsWaitingHello() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        try fixture.writeUsage(expirySeconds: 800, usedPercent: 0)
        try await fixture.refresh()
        try await fixture.enableAutomatic()
        try fixture.enableHello()
        try fixture.marker("hold-hello-completion")
        let task = Task { await fixture.monitor.processAutomaticHello() }
        try await fixture.waitForRequest("turn/start")
        XCTAssertFalse(fixture.monitor.isBusy)
        await fixture.monitor.processExpiringCredits()
        await task.value
        XCTAssertEqual(try fixture.consumeRequests().count, 1)
        XCTAssertEqual(try fixture.helloRequests().count, 1)
        XCTAssertEqual(fixture.monitor.notice, "重置已完成。")
        XCTAssertFalse(fixture.monitor.isSendingHello)
    }

    func testStartupReturnsBeforeBackgroundHelloCompletesAndShutdownStopsIt() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        try fixture.writeUsage(usedPercent: 0)
        try await fixture.refresh()
        try fixture.enableHello()
        try fixture.marker("hold-hello-completion")
        var startupReturned = false
        let startup = Task { await fixture.monitor.start(); startupReturned = true }
        try await fixture.waitForRequest("turn/start")
        XCTAssertTrue(startupReturned)
        XCTAssertFalse(fixture.monitor.isBusy)
        fixture.monitor.shutdown()
        await startup.value
        let deadline = Date().addingTimeInterval(3)
        while fixture.monitor.isSendingHello && Date() < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertFalse(fixture.monitor.isSendingHello)
        XCTAssertEqual(try fixture.helloRequests().count, 1)
    }

    func testWakeRefreshesDisplayedUsageWhileHelloIsWaitingWithoutDuplicatingIt() async throws {
        final class Notifications: CreditExpiryNotificationService {
            func requestPermission() async -> Bool { false }
            func deliver(_ reminder: CreditExpiryReminder) async throws {}
            func clear() {}
        }
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        try fixture.writeUsage(usedPercent: 0)
        try await fixture.refresh()
        try fixture.enableHello()
        try fixture.marker("hold-hello-completion")
        let center = NotificationCenter()
        let runtime = CreditExpiryRuntime(monitor: fixture.monitor, notifications: Notifications(), wakeNotifications: center)
        defer { runtime.stop() }
        await runtime.start()
        try await fixture.waitForRequest("turn/start")
        let previousUpdate = fixture.monitor.lastUpdated
        try fixture.writeUsage(usedPercent: 15)
        center.post(name: NSWorkspace.didWakeNotification, object: nil)
        let deadline = Date().addingTimeInterval(3)
        while fixture.monitor.selectedWindow?.quota.usedPercent != 15 && Date() < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertEqual(fixture.monitor.selectedWindow?.quota.usedPercent, 15)
        XCTAssertNotEqual(fixture.monitor.lastUpdated, previousUpdate)
        XCTAssertEqual(try fixture.helloRequests().count, 1)
        XCTAssertTrue(fixture.monitor.isSendingHello)
        runtime.stop()
        let stoppedBy = Date().addingTimeInterval(3)
        while fixture.monitor.isSendingHello && Date() < stoppedBy {
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertFalse(fixture.monitor.isSendingHello)
    }

    func testConcurrentHelloMonitorsShareOnePersistentClaim() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        try fixture.writeUsage(usedPercent: 0)
        try await fixture.refresh()
        try fixture.enableHello()
        let second = UsageMonitor(client: AppServerClient(executablePath: fixture.client.executablePath,
            runtimeDirectory: fixture.client.runtimeDirectory), defaults: fixture.defaults)
        defer { second.shutdown() }
        async let firstRun: Void = fixture.monitor.processAutomaticHello()
        async let secondRun: Void = second.processAutomaticHello()
        _ = await (firstRun, secondRun)
        XCTAssertEqual(try fixture.helloRequests().count, 1)
    }

    func testAutomaticAuthorizationCannotFollowAccountChangeWhileDialogIsOpen() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        try await fixture.refresh()
        let authorization = try XCTUnwrap(fixture.monitor.makeAutomaticExpiryAuthorization())
        try fixture.writeAccount("account-b")
        try fixture.writeUsage(owner: "account-b", expirySeconds: 800)
        try await fixture.refresh()
        await fixture.monitor.configureExpiryHandling(.automatic, authorization: authorization)
        XCTAssertEqual(fixture.monitor.expiryConfiguration.mode, .off)
        XCTAssertNotNil(fixture.monitor.expiryHandlingMessage)
        await fixture.monitor.configureExpiryHandling(.automatic)
        XCTAssertEqual(fixture.monitor.expiryConfiguration.mode, .off, "No authorization must also fail")
        let current = try XCTUnwrap(fixture.monitor.makeAutomaticExpiryAuthorization())
        await fixture.monitor.configureExpiryHandling(.automatic, authorization: current)
        XCTAssertEqual(fixture.monitor.expiryConfiguration.accountKey, "account-b")
        XCTAssertTrue(try fixture.consumeRequests().isEmpty)
    }

    func testFinalAutomaticCheckAfterReservationStopsExpiredOrDisabledRequests() async throws {
        for reason in ["expiry", "disabled"] {
            let fixture = try Fixture()
            defer { fixture.cleanup() }
            try fixture.writeUsage(expirySeconds: 800)
            try await fixture.refresh()
            try await fixture.enableAutomatic()
            let initialDate = fixture.expiryClock.date
            fixture.expiryClock.override = {
                let file = fixture.directory.appendingPathComponent("State/pending-resets.json")
                let entries = (try? Data(contentsOf: file)).flatMap {
                    try? JSONDecoder().decode([String: PendingRedemption].self, from: $0)
                }
                let reserved = entries?["account-a"]?.automatic?.attempts ?? 0
                if reserved > 0 {
                    if reason == "disabled" {
                        let data = try! JSONEncoder().encode(CreditExpiryConfiguration())
                        fixture.defaults.set(data, forKey: "creditExpiryConfiguration")
                    } else { return initialDate.addingTimeInterval(900) }
                }
                return initialDate
            }
            await fixture.monitor.processExpiringCredits()
            XCTAssertEqual(try fixture.store.pending(for: "account-a")?.automatic?.attempts, 1)
            XCTAssertTrue(try fixture.consumeRequests().isEmpty, reason)
            fixture.expiryClock.override = nil
        }
    }

    func testExpiryReviewQueueWaitsThroughRefreshAndSheetDismissal() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        try fixture.writeUsage(expirySeconds: 800)
        try await fixture.refresh()
        let queue = CreditExpiryReviewQueue()
        queue.enqueue(.init(accountKey: "account-a", creditID: "card-a"), dismissingSheet: true)
        queue.enqueue(.init(accountKey: "account-a", creditID: "card-a"), dismissingSheet: false)
        XCTAssertTrue(queue.isDismissingSheet, "Another notification must not end an ongoing sheet dismissal")
        XCTAssertNil(queue.nextConfirmation(using: fixture.monitor))
        XCTAssertNotNil(queue.pending)
        try fixture.marker("delay-usage")
        let refresh = Task { await fixture.monitor.refresh() }
        while !fixture.monitor.isBusy { await Task.yield() }
        queue.isDismissingSheet = false
        XCTAssertNil(queue.nextConfirmation(using: fixture.monitor))
        XCTAssertNotNil(queue.pending, "A busy read must not consume the intent")
        await refresh.value
        let target = try XCTUnwrap(queue.nextConfirmation(using: fixture.monitor))
        XCTAssertEqual(target.creditID, "card-a")
        XCTAssertNil(queue.pending)
        XCTAssertNil(queue.nextConfirmation(using: fixture.monitor))
        queue.enqueue(.init(accountKey: "other-account", creditID: "card-a"))
        XCTAssertNil(queue.nextConfirmation(using: fixture.monitor))
        XCTAssertNil(queue.pending, "An invalid account must discard the intent")
        XCTAssertTrue(try fixture.consumeRequests().isEmpty)
    }

    func testSharedExpiryRuntimeStartsOffAndWiresWakeAndReminderCallbacks() async throws {
        final class Notifications: CreditExpiryNotificationService {
            var permissionRequests = 0
            var delivered: [CreditExpiryReminder] = []
            func requestPermission() async -> Bool { permissionRequests += 1; return true }
            func deliver(_ reminder: CreditExpiryReminder) async throws { delivered.append(reminder) }
            func clear() { delivered.removeAll() }
        }
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        try fixture.writeUsage(expirySeconds: 800)
        let notifications = Notifications()
        let center = NotificationCenter()
        let runtime = CreditExpiryRuntime(monitor: fixture.monitor, notifications: notifications,
                                          wakeNotifications: center)
        defer { runtime.stop() }
        await runtime.start()
        XCTAssertEqual(fixture.monitor.expiryConfiguration.mode, .off)
        XCTAssertEqual(notifications.permissionRequests, 0)
        XCTAssertTrue(notifications.delivered.isEmpty)
        XCTAssertTrue(try fixture.consumeRequests().isEmpty)
        await fixture.monitor.configureExpiryHandling(.remind)
        center.post(name: NSWorkspace.didWakeNotification, object: nil)
        let deadline = Date().addingTimeInterval(5)
        while notifications.delivered.isEmpty && Date() < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertEqual(notifications.permissionRequests, 1)
        XCTAssertEqual(notifications.delivered.count, 1)
        XCTAssertEqual(notifications.delivered.first?.creditID, "card-a")
        XCTAssertTrue(try fixture.consumeRequests().isEmpty)
    }

    func testExpiryHandlingDefaultsOffAndZeroUsageStillAutomaticallyAttemptsOnce() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        try fixture.writeUsage(expirySeconds: 800, usedPercent: 0)
        try await fixture.refresh()
        await fixture.monitor.processExpiringCredits()
        XCTAssertTrue(try fixture.consumeRequests().isEmpty)
        try await fixture.enableAutomatic()
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
            try await fixture.enableAutomatic()
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
        try await fixture.enableAutomatic()
        try fixture.marker("hang-consume")
        await fixture.monitor.processExpiringCredits()
        let pending = try XCTUnwrap(fixture.monitor.pendingRedemption)
        XCTAssertEqual(fixture.monitor.expiryStatusTitle, "待重试 · 1/3")
        XCTAssertNotNil(fixture.monitor.automaticRetryDate, "An unknown write result must retain its retry schedule")
        try fixture.removeMarker("hang-consume")
        await fixture.monitor.processExpiringCredits()
        XCTAssertEqual(try fixture.consumeRequests().count, 1)
        XCTAssertEqual(fixture.monitor.pendingRedemption?.idempotencyKey, pending.idempotencyKey)
        let retry = try XCTUnwrap(fixture.monitor.makeResetConfirmation(for: nil))
        await fixture.monitor.redeem(retry)
        XCTAssertNil(fixture.monitor.automaticRetryDate)
        let params = try XCTUnwrap(fixture.consumeRequests().last?["params"] as? [String: Any])
        XCTAssertEqual(params["idempotencyKey"] as? String, pending.idempotencyKey)
    }

    func testAutomaticExpiryRetriesTwiceWithSameCardAndKeyThenStops() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        try fixture.writeUsage(expirySeconds: 800)
        try fixture.addFutureDateCard()
        try await fixture.refresh()
        try await fixture.enableAutomatic()
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
        try await fixture.enableAutomatic()
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
            try await fixture.enableAutomatic()
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
        try await fixture.enableAutomatic()
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
        try await fixture.enableAutomatic()
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
        try await fixture.enableAutomatic()
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
            try await fixture.enableAutomatic()
            await fixture.monitor.processExpiringCredits()
            XCTAssertTrue(try fixture.consumeRequests().isEmpty)
        }
    }

    func testConcurrentExpiryMonitorsSendOnlyOneConsumption() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        try fixture.writeUsage(expirySeconds: 800)
        try await fixture.refresh()
        try await fixture.enableAutomatic()
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
        try await fixture.enableAutomatic()
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
            try await fixture.enableAutomatic()
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

    func testSuccessfulResetSurvivesReadFailureAndRecoveryOnlyReads() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        try await fixture.refresh()
        let card = try XCTUnwrap(fixture.monitor.sortedCredits.first)
        let confirmation = try XCTUnwrap(fixture.monitor.makeResetConfirmation(for: card))
        try fixture.marker("reject-after-consume")
        await fixture.monitor.redeem(confirmation)
        XCTAssertEqual(fixture.monitor.notice, "重置已完成。")
        XCTAssertEqual(fixture.monitor.noticeKind, .success)
        XCTAssertNotNil(fixture.monitor.errorMessage)
        XCTAssertNil(fixture.monitor.pendingRedemption)
        XCTAssertNil(try fixture.store.pending(for: "account-a"))
        XCTAssertEqual(try fixture.consumeRequests().count, 1)
        XCTAssertNotNil(fixture.monitor.redemptionBlockingReason(for: card, at: .now))

        try fixture.removeMarker("reject-usage")
        await fixture.monitor.refresh()
        XCTAssertNil(fixture.monitor.errorMessage)
        XCTAssertEqual(fixture.monitor.notice, "重置已完成。")
        XCTAssertEqual(try fixture.consumeRequests().count, 1, "Recovery must only read")
        XCTAssertNil(fixture.monitor.redemptionBlockingReason(for: card, at: .now))
    }

    func testNothingToResetIsInformationalRatherThanSuccess() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        try await fixture.refresh()
        try fixture.marker("nothing-to-reset")
        let confirmation = try XCTUnwrap(fixture.monitor.makeResetConfirmation(for: fixture.monitor.sortedCredits.first))
        await fixture.monitor.redeem(confirmation)
        XCTAssertEqual(fixture.monitor.noticeKind, .information)
        XCTAssertEqual(fixture.monitor.notice, "当前没有符合条件的额度可重置。")
        XCTAssertNil(fixture.monitor.pendingRedemption)
        XCTAssertEqual(try fixture.consumeRequests().count, 1)
    }

    func testWindowSelectionSurvivesRefreshAndKeepsOtherWindowsAvailable() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let now = Date().timeIntervalSince1970
        try fixture.write([
            "accountId": "account-a",
            "rateLimits": ["limitId": "codex",
                "primary": ["usedPercent": 84, "windowDurationMins": 300, "resetsAt": now + 1800],
                "secondary": ["usedPercent": 35, "windowDurationMins": 10080, "resetsAt": now + 86400]]
        ], to: "usage.json")
        try await fixture.refresh()
        XCTAssertEqual(fixture.monitor.selectedWindow?.id, "codex.secondary")
        XCTAssertEqual(fixture.monitor.windows.count, 2)
        fixture.monitor.selectedWindowID = "codex.primary"
        try await fixture.refresh()
        XCTAssertEqual(fixture.monitor.selectedWindow?.quota.usedPercent, 84)
        XCTAssertEqual(fixture.defaults.string(forKey: "selectedWindowID"), "codex.primary")
        XCTAssertEqual(fixture.monitor.windows.count, 2)
        XCTAssertTrue(try fixture.consumeRequests().isEmpty)
    }

    func testProWithoutWeeklyLimitShowsOnlyReturnedShortWindow() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let now = Date().timeIntervalSince1970
        for explicitNull in [false, true] {
            var bucket: [String: Any] = ["limitId": "codex",
                "primary": ["usedPercent": 42, "windowDurationMins": 300, "resetsAt": now + 5400]]
            if explicitNull { bucket["secondary"] = NSNull() }
            try fixture.write(["accountId": "account-a", "rateLimits": bucket], to: "usage.json")
            try await fixture.refresh()
            XCTAssertEqual(fixture.monitor.account?.planDisplayName, "Pro")
            XCTAssertEqual(fixture.monitor.windows.count, 1)
            let selected = try XCTUnwrap(fixture.monitor.selectedWindow)
            XCTAssertEqual(selected.id, "codex.primary")
            XCTAssertEqual(selected.quota.windowDurationMins, 300)
            XCTAssertEqual(selected.quota.usedPercent, 42)
            XCTAssertNotNil(selected.quota.deviation(at: .now))
        }
        XCTAssertTrue(try fixture.consumeRequests().isEmpty)
    }

    func testRemovedWeeklyLimitFallsBackFromPreviousSelection() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let now = Date().timeIntervalSince1970
        try fixture.write([
            "accountId": "account-a",
            "rateLimits": ["limitId": "codex",
                "primary": ["usedPercent": 42, "windowDurationMins": 300, "resetsAt": now + 5400],
                "secondary": ["usedPercent": 35, "windowDurationMins": 10080, "resetsAt": now + 86400]]
        ], to: "usage.json")
        try await fixture.refresh()
        fixture.monitor.selectedWindowID = "codex.secondary"
        XCTAssertEqual(fixture.monitor.selectedWindow?.quota.windowDurationMins, 10080)
        try fixture.write([
            "accountId": "account-a",
            "rateLimits": ["limitId": "codex",
                "primary": ["usedPercent": 42, "windowDurationMins": 300, "resetsAt": now + 5400]]
        ], to: "usage.json")
        try await fixture.refresh()
        XCTAssertEqual(fixture.monitor.windows.count, 1)
        XCTAssertEqual(fixture.monitor.selectedWindow?.id, "codex.primary")
        XCTAssertEqual(fixture.monitor.menuTitle(), PresentationFormat().percent(42))
        XCTAssertFalse(fixture.monitor.isStale(at: .now))
        XCTAssertTrue(try fixture.consumeRequests().isEmpty)
    }

    func testTrendHistorySurvivesReadFailureAndDoesNotCrossAccounts() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        try await fixture.refresh()
        let original = fixture.monitor.trendHistory
        XCTAssertEqual(original["codex.primary"]?.last?.remaining, 60)
        try fixture.marker("reject-usage")
        await fixture.monitor.refresh()
        XCTAssertEqual(fixture.monitor.trendHistory, original)
        try fixture.writeAccount("account-b")
        await fixture.monitor.refresh()
        XCTAssertTrue(fixture.monitor.trendHistory.isEmpty)
        try FileManager.default.removeItem(at: fixture.directory.appendingPathComponent("reject-usage"))
        try fixture.writeUsage(owner: "account-b", usedPercent: 75)
        try await fixture.refresh()
        XCTAssertEqual(fixture.monitor.trendHistory["codex.primary"]?.map(\.remaining), [25])
        await fixture.monitor.logout()
        XCTAssertTrue(fixture.monitor.trendHistory.isEmpty)
        XCTAssertTrue(try fixture.consumeRequests().isEmpty)
        XCTAssertTrue(try fixture.helloRequests().isEmpty)
    }

    func testBrokenTrendStorageDoesNotFailQuotaRefresh() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        try await fixture.refresh()
        let files = try FileManager.default.contentsOfDirectory(at: fixture.directory.appendingPathComponent("State"),
                                                               includingPropertiesForKeys: nil)
        let history = try XCTUnwrap(files.first { $0.lastPathComponent.hasPrefix("usage-trend-") && $0.pathExtension == "json" })
        try Data("invalid".utf8).write(to: history)
        try await fixture.refresh()
        XCTAssertTrue(fixture.monitor.trendStorageFailed)
        XCTAssertTrue(fixture.monitor.trendHistory.isEmpty)
        XCTAssertNil(fixture.monitor.errorMessage)
        XCTAssertEqual(fixture.monitor.selectedWindow?.quota.usedPercent, 40)
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
        XCTAssertTrue(fixture.monitor.isRedeeming)
        await fixture.monitor.redeem(confirmation)
        await first.value
        XCTAssertFalse(fixture.monitor.isRedeeming)
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
