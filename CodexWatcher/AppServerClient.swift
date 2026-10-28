import Foundation

enum WatcherError: LocalizedError {
    case message(String)
    var errorDescription: String? {
        switch self { case .message(let text): return text }
    }
}

/// JSON-RPC transport. Account monitoring and opt-in hello use separate processes.
@MainActor
final class AppServerClient {
    var onNotification: ((String, [String: Any]) -> Void)?
    var onDisconnect: (() -> Void)?
    private var process: Process?
    private var input: FileHandle?
    private var output: FileHandle?
    private var readTask: Task<Void, Never>?
    private var startup: Task<Void, Error>?
    private var sequence = 0
    private var generation = UUID()
    private var buffer = Data()
    private var pending: [Int: (CheckedContinuation<Data, Error>, Task<Void, Never>)] = [:]
    private(set) var isReady = false
    private let requestTimeout: Duration
    private let automaticHello: Bool
    var helloWorkspace: URL { runtimeDirectory.deletingLastPathComponent().appendingPathComponent("HelloWorkspace") }

    let runtimeDirectory: URL
    var executablePath: String

    init(executablePath: String? = nil,
         runtimeDirectory: URL? = nil,
         requestTimeout: Duration = .seconds(30), automaticHello: Bool = false) {
        self.requestTimeout = requestTimeout
        self.automaticHello = automaticHello
        self.executablePath = executablePath ?? Self.defaultExecutablePath
        self.runtimeDirectory = runtimeDirectory ?? FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        )[0].appendingPathComponent("CodexWatcher/Runtime", isDirectory: true)
    }

    func makeHelloClient() -> AppServerClient {
        AppServerClient(executablePath: executablePath, runtimeDirectory: runtimeDirectory,
                        requestTimeout: requestTimeout, automaticHello: true)
    }

    static var defaultExecutablePath: String {
        ["/opt/homebrew/bin/codex", "/usr/local/bin/codex"].first {
            FileManager.default.isExecutableFile(atPath: $0)
        } ?? "/opt/homebrew/bin/codex"
    }

    func connect() async throws {
        if let startup { return try await startup.value }
        if isReady { return }
        let task = Task { @MainActor in
            try launch()
            let _: EmptyResponse = try await request("initialize", params: [
                "clientInfo": ["name": "codex_watcher", "title": "Codex Watcher", "version": "0.1.0"]
            ])
            try send(["method": "initialized", "params": [:]])
            isReady = true
        }
        startup = task
        defer { startup = nil }
        do { try await task.value }
        catch { stop(); throw error }
    }

    private func launch() throws {
        guard FileManager.default.isExecutableFile(atPath: executablePath) else {
            throw WatcherError.message(L10n.text("未找到 Codex CLI，请安装后选择 codex 可执行文件。"))
        }
        try FileManager.default.createDirectory(at: runtimeDirectory, withIntermediateDirectories: true,
                                               attributes: [.posixPermissions: 0o700])
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: runtimeDirectory.path)
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: executablePath)
        proc.arguments = ["app-server", "--stdio", "-c", "cli_auth_credentials_store=\"keyring\""]
        if automaticHello {
            try FileManager.default.createDirectory(at: helloWorkspace, withIntermediateDirectories: true,
                                                   attributes: [.posixPermissions: 0o700])
            let disabled = ["shell_tool", "apps", "plugins", "remote_plugin", "hooks", "memories",
                            "multi_agent", "browser_use", "browser_use_external", "in_app_browser",
                            "computer_use", "view_image", "code_mode", "code_mode_host", "shell_snapshot",
                            "goals", "sleep_tool", "skill_search", "workspace_dependencies"]
            for feature in disabled { proc.arguments! += ["-c", "features.\(feature)=false"] }
            for setting in ["web_search=\"disabled\"", "project_doc_max_bytes=0", "mcp_servers={}",
                            "notify=[]", "features.skip_host_skill_discovery=true"] {
                proc.arguments! += ["-c", setting]
            }
        }
        // Do not inherit API keys or token overrides from a shell/IDE launching the app.
        let inherited = ProcessInfo.processInfo.environment
        let allowed = ["HOME", "USER", "LOGNAME", "TMPDIR", "LANG", "LC_ALL", "LC_CTYPE", "SHELL",
                       "SSL_CERT_FILE", "SSL_CERT_DIR", "HTTPS_PROXY", "HTTP_PROXY", "ALL_PROXY", "NO_PROXY",
                       "https_proxy", "http_proxy", "all_proxy", "no_proxy"]
        var environment = inherited.filter { allowed.contains($0.key) }
        // Independent profile, including a distinct keychain entry, owned by Codex.
        environment["CODEX_HOME"] = runtimeDirectory.path
        environment["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        proc.environment = environment
        proc.currentDirectoryURL = automaticHello ? helloWorkspace : runtimeDirectory
        let stdin = Pipe(), stdout = Pipe()
        proc.standardInput = stdin
        proc.standardOutput = stdout
        // Auth URLs and tokens must never enter application logs.
        proc.standardError = FileHandle.nullDevice
        let stream = AsyncStream<Data> { continuation in
            stdout.fileHandleForReading.readabilityHandler = { handle in
                let bytes = handle.availableData
                if bytes.isEmpty { continuation.finish() }
                else { continuation.yield(bytes) }
            }
            proc.terminationHandler = { _ in continuation.finish() }
        }
        let currentGeneration = UUID()
        generation = currentGeneration
        process = proc
        input = stdin.fileHandleForWriting
        output = stdout.fileHandleForReading
        buffer.removeAll()
        do { try proc.run() }
        catch { stop(); throw WatcherError.message(L10n.text("Codex CLI 启动失败：\(error.localizedDescription)")) }
        readTask = Task { @MainActor [weak self] in
            for await bytes in stream {
                guard let self, generation == currentGeneration, !Task.isCancelled else { return }
                receive(bytes)
            }
            guard let self, generation == currentGeneration, !Task.isCancelled else { return }
            stop(reason: L10n.text("Codex 连接已断开，请刷新重连。"))
        }
    }

    func request<T: Decodable>(_ method: String, params: [String: Any] = [:]) async throws -> T {
        sequence += 1
        let id = sequence
        let bytes: Data = try await withCheckedThrowingContinuation { continuation in
            let timeout = Task { @MainActor [weak self] in
                do { try await Task.sleep(for: self?.requestTimeout ?? .seconds(30)) } catch { return }
                if self?.pending[id] != nil {
                    // Recreate a wedged transport on the next refresh. Persisted redemptions remain retryable.
                    self?.stop(reason: L10n.text("请求超时，请刷新重连。"))
                }
            }
            pending[id] = (continuation, timeout)
            do { try send(["id": id, "method": method, "params": params]) }
            catch {
                if let entry = pending.removeValue(forKey: id) {
                    entry.1.cancel()
                    entry.0.resume(throwing: error)
                }
            }
        }
        return try JSONDecoder().decode(T.self, from: bytes)
    }

    private func send(_ message: [String: Any]) throws {
        guard let input, process?.isRunning == true else {
            throw WatcherError.message(L10n.text("Codex 尚未连接。"))
        }
        var bytes = try JSONSerialization.data(withJSONObject: message)
        bytes.append(0x0a)
        try input.write(contentsOf: bytes)
    }

    private func receive(_ bytes: Data) {
        buffer.append(bytes)
        // Bound malformed output without keeping an unbounded buffer in memory.
        guard buffer.count < 8 * 1024 * 1024 else {
            stop(reason: L10n.text("Codex 返回的数据超出预期。"))
            return
        }
        while let newline = buffer.firstIndex(of: 0x0a) {
            let line = buffer.prefix(upTo: newline)
            buffer.removeSubrange(...newline)
            guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { continue }
            if let id = object["id"] as? Int, let entry = pending.removeValue(forKey: id) {
                entry.1.cancel()
                if let error = object["error"] as? [String: Any] {
                    // Server errors can contain request details. Keep only the numerical code.
                    let code = error["code"] as? Int ?? -1
                    entry.0.resume(throwing: WatcherError.message(L10n.text("Codex 请求失败（\(String(code))），请检查登录状态或 CLI 版本。")))
                } else if let result = object["result"],
                          let data = try? JSONSerialization.data(withJSONObject: result, options: [.fragmentsAllowed]) {
                    entry.0.resume(returning: data)
                } else {
                    entry.0.resume(throwing: WatcherError.message(L10n.text("Codex 返回了无法识别的数据。")))
                }
            } else if automaticHello, object["method"] != nil, let requestID = object["id"] {
                // Never grant permissions or execute client-side tools for a hello.
                try? send(["id": requestID, "error": ["code": -32601, "message": "Unsupported request"]])
                stop(reason: L10n.text("自动 hello 请求了额外能力，已停止。"))
                return
            } else if let method = object["method"] as? String, object["id"] == nil {
                onNotification?(method, object["params"] as? [String: Any] ?? [:])
            }
        }
    }

    func stop(reason: String = L10n.text("连接已关闭。")) {
        generation = UUID()
        isReady = false
        readTask?.cancel()
        readTask = nil
        output?.readabilityHandler = nil
        try? input?.close()
        input = nil
        output = nil
        process?.terminationHandler = nil
        if process?.isRunning == true { process?.terminate() }
        process = nil
        let entries = pending.values
        pending.removeAll()
        for entry in entries {
            entry.1.cancel()
            entry.0.resume(throwing: WatcherError.message(reason))
        }
        onDisconnect?()
    }
}

struct EmptyResponse: Decodable {}
