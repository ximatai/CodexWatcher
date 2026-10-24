import Foundation
import XCTest
@testable import WatcherCore

@MainActor
final class AutomaticHelloSessionTests: XCTestCase {
    private func fixture(_ behavior: String) throws -> (URL, AppServerClient) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("HelloSession-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data(behavior.utf8).write(to: directory.appendingPathComponent("behavior"))
        let script = #"""
        #!/bin/sh
        fixture_dir=$(/usr/bin/dirname "$0")
        printf '%s\n' "$@" > "$fixture_dir/arguments.txt"
        while IFS= read -r line; do
          printf '%s\n' "$line" >> "$fixture_dir/requests.jsonl"
          id=$(printf '%s' "$line" | /usr/bin/sed -n 's/.*"id":\([0-9][0-9]*\).*/\1/p')
          method=$(printf '%s' "$line" | /usr/bin/sed -n 's/.*"method":"\([^"]*\)".*/\1/p')
          case "$method" in
            *initialized*) continue ;;
            *initialize*) result='{}' ;;
            *model*list*) result='{"data":[{"model":"test-default","isDefault":true,"hidden":false,"supportedReasoningEfforts":[{"reasoningEffort":"low"},{"reasoningEffort":"high"}]}],"nextCursor":null}' ;;
            *thread*start*) result='{"thread":{"id":"hello-thread","ephemeral":true},"modelProvider":"openai"}' ;;
            *turn*start*)
              behavior=$(/bin/cat "$fixture_dir/behavior")
              if [ "$behavior" = "early-completion" ]; then
                printf '{"method":"turn/completed","params":{"threadId":"hello-thread","turn":{"id":"hello-turn","status":"completed"}}}\n'
              fi
              status=inProgress
              if [ "$behavior" = "completed-ack-only" ]; then status=completed; fi
              printf '{"id":%s,"result":{"turn":{"id":"hello-turn","status":"%s"}}}\n' "$id" "$status"
              case "$behavior" in
                ack-only|completed-ack-only|early-completion) ;;
                wrong-thread) printf '{"method":"turn/completed","params":{"threadId":"another-thread","turn":{"id":"hello-turn","status":"completed"}}}\n' ;;
                wrong-turn) printf '{"method":"turn/completed","params":{"threadId":"hello-thread","turn":{"id":"other-turn","status":"completed"}}}\n' ;;
                approval) printf '{"id":999,"method":"item/commandExecution/requestApproval","params":{"threadId":"hello-thread"}}\n' ;;
                tool) printf '{"method":"item/started","params":{"threadId":"hello-thread","item":{"type":"commandExecution"}}}\n' ;;
                *) printf '{"method":"turn/completed","params":{"threadId":"hello-thread","turn":{"id":"hello-turn","status":"failed"}}}\n' ;;
              esac
              continue ;;
            *) continue ;;
          esac
          printf '{"id":%s,"result":%s}\n' "$id" "$result"
        done
        """#
        let executable = directory.appendingPathComponent("fake-codex")
        try Data(script.utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        let client = AppServerClient(executablePath: executable.path,
            runtimeDirectory: directory.appendingPathComponent("Runtime"), requestTimeout: .seconds(1)).makeHelloClient()
        return (directory, client)
    }

    func testEphemeralRestrictedHelloHandlesCompletionBeforeStartResponse() async throws {
        let (directory, client) = try fixture("early-completion")
        let session = AutomaticHelloSession(client: client, completionTimeout: 0.2)
        defer { session.stop(); try? FileManager.default.removeItem(at: directory) }
        try await session.prepare()
        try await session.sendHello { true }
        let log = try String(contentsOf: directory.appendingPathComponent("requests.jsonl"), encoding: .utf8)
        let rows = try log.split(separator: "\n").map { try XCTUnwrap(JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any]) }
        let start = try XCTUnwrap(rows.first { $0["method"] as? String == "thread/start" }?["params"] as? [String: Any])
        XCTAssertEqual(start["ephemeral"] as? Bool, true)
        XCTAssertEqual(start["modelProvider"] as? String, "openai")
        XCTAssertEqual(start["sandbox"] as? String, "read-only")
        XCTAssertEqual(start["cwd"] as? String, client.helloWorkspace.path)
        let turn = try XCTUnwrap(rows.first { $0["method"] as? String == "turn/start" }?["params"] as? [String: Any])
        XCTAssertEqual(turn["effort"] as? String, "low")
        XCTAssertEqual(turn["approvalPolicy"] as? String, "never")
        let sandbox = try XCTUnwrap(turn["sandboxPolicy"] as? [String: Any])
        let access = try XCTUnwrap(sandbox["access"] as? [String: Any])
        XCTAssertEqual(access["type"] as? String, "restricted")
        XCTAssertEqual(access["readableRoots"] as? [String], [client.helloWorkspace.path])
        let arguments = try String(contentsOf: directory.appendingPathComponent("arguments.txt"), encoding: .utf8)
        XCTAssertTrue(arguments.contains("features.hooks=false"))
        XCTAssertTrue(arguments.contains("features.shell_tool=false"))
        XCTAssertTrue(arguments.contains("project_doc_max_bytes=0"))
        XCTAssertTrue(arguments.contains("mcp_servers={}"))
        XCTAssertTrue(arguments.contains("features.apps=false"))
    }

    func testAcknowledgmentWrongThreadFailureAndToolRequestsAreNotSuccess() async throws {
        for behavior in ["ack-only", "completed-ack-only", "wrong-thread", "wrong-turn", "failed", "approval", "tool"] {
            let (directory, client) = try fixture(behavior)
            let session = AutomaticHelloSession(client: client, completionTimeout: 0.15)
            defer { session.stop(); try? FileManager.default.removeItem(at: directory) }
            try await session.prepare()
            do {
                try await session.sendHello { true }
                XCTFail("\(behavior) must not be reported as completed")
            } catch {}
        }
    }

    func testStoppedSessionCannotReconnectDuringLaterPreflight() async throws {
        let (directory, client) = try fixture("early-completion")
        let session = AutomaticHelloSession(client: client)
        defer { session.stop(); try? FileManager.default.removeItem(at: directory) }
        try await session.prepare()
        session.stop()
        do { _ = try await session.readAccountAndUsage(); XCTFail("Stopped session must stay stopped") } catch {}
        do { try await session.prepare(); XCTFail("Preparation must not restart a stopped session") } catch {}
        let log = try String(contentsOf: directory.appendingPathComponent("requests.jsonl"), encoding: .utf8)
        let methods = try log.split(separator: "\n").compactMap {
            (try JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any])?["method"] as? String
        }
        XCTAssertEqual(methods.filter { $0 == "initialize" }.count, 1)
        XCTAssertFalse(methods.contains("account/read"))
    }

    func testAuthorizationRevokedImmediatelyBeforeSendCreatesNoTurn() async throws {
        let (directory, client) = try fixture("early-completion")
        let session = AutomaticHelloSession(client: client)
        defer { session.stop(); try? FileManager.default.removeItem(at: directory) }
        try await session.prepare()
        do { try await session.sendHello { false }; XCTFail("Must stop") } catch {}
        let log = try String(contentsOf: directory.appendingPathComponent("requests.jsonl"), encoding: .utf8)
        let methods = try log.split(separator: "\n").compactMap {
            (try JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any])?["method"] as? String
        }
        XCTAssertFalse(methods.contains("turn/start"))
    }
}
