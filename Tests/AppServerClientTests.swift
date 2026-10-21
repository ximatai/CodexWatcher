import XCTest
@testable import WatcherCore

final class AppServerClientTests: XCTestCase {
    private func fixture() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("WatcherFakeServer-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let executable = directory.appendingPathComponent("fake-codex")
        let script = #"""
        #!/bin/sh
        while IFS= read -r line; do
          id=$(printf '%s' "$line" | /usr/bin/sed -n 's/.*"id":\([0-9][0-9]*\).*/\1/p')
          case "$line" in
            *initialized*) ;;
            *initialize*) printf '{"id":%s,"result":{}}\n' "$id" ;;
            *test-error*) printf '{"id":%s,"error":{"code":-32000,"message":"private-token-sentinel"}}\n' "$id" ;;
            *test-exit*) exit 0 ;;
            *test-hang*) ;;
            *account*read*) printf '{"id":%s,' "$id"; printf '"result":{"account":null}}\n' ;;
          esac
        done
        """#
        try Data(script.utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        return directory
    }

    @MainActor
    func testHandshakeAndErrorsDoNotExposeServerDetails() async throws {
        let directory = try fixture()
        let client = AppServerClient(executablePath: directory.appendingPathComponent("fake-codex").path,
                                     runtimeDirectory: directory.appendingPathComponent("runtime"))
        defer { client.stop(); try? FileManager.default.removeItem(at: directory) }
        try await client.connect()
        let result: AccountResponse = try await client.request("account/read")
        XCTAssertNil(result.account)
        do {
            let _: EmptyResponse = try await client.request("test-error")
            XCTFail("Expected a JSON-RPC error")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("-32000"))
            XCTAssertFalse(error.localizedDescription.contains("private-token-sentinel"))
        }
    }

    @MainActor
    func testTimeoutAndDisconnectAllowReconnect() async throws {
        let directory = try fixture()
        let client = AppServerClient(executablePath: directory.appendingPathComponent("fake-codex").path,
                                     runtimeDirectory: directory.appendingPathComponent("runtime"),
                                     requestTimeout: .seconds(1))
        defer { client.stop(); try? FileManager.default.removeItem(at: directory) }
        try await client.connect()
        do {
            let _: EmptyResponse = try await client.request("test-hang")
            XCTFail("Expected timeout")
        } catch { XCTAssertFalse(client.isReady) }
        try await client.connect()
        XCTAssertTrue(client.isReady)
        do {
            let _: EmptyResponse = try await client.request("test-exit")
            XCTFail("Expected disconnect")
        } catch { XCTAssertFalse(client.isReady) }
        try await client.connect()
        XCTAssertTrue(client.isReady)
    }
}
