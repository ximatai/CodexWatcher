import Foundation

/// Uses an ephemeral thread, an empty working directory and restricted capabilities.
/// No replies or model context are retained by the application.
@MainActor
final class AutomaticHelloSession {
    private let client: AppServerClient
    private let completionTimeout: TimeInterval
    private var threadID: String?
    private var model: String?
    private var effort: String?
    private var completedTurns: [String: String] = [:]
    private var disconnected = false

    init(client: AppServerClient, completionTimeout: TimeInterval = 60) {
        self.client = client
        self.completionTimeout = completionTimeout
        client.onDisconnect = { [weak self] in self?.disconnected = true }
        client.onNotification = { [weak self] method, params in self?.receive(method, params: params) }
    }

    func readAccountAndUsage() async throws -> (WatcherAccount?, UsageSnapshot?) {
        try await client.connect()
        let account: AccountResponse = try await client.request("account/read", params: ["refreshToken": false])
        guard account.account?.type == "chatgpt" else { return (account.account, nil) }
        let usage: UsageSnapshot = try await client.request("account/rateLimits/read")
        return (account.account, usage)
    }

    func prepare() async throws {
        try await client.connect()
        var cursor: String?
        var selected: HelloModel?
        for _ in 0..<10 {
            var params: [String: Any] = ["limit": 100, "includeHidden": false]
            if let cursor { params["cursor"] = cursor }
            let catalog: HelloModelList = try await client.request("model/list", params: params)
            selected = catalog.data.first { $0.isDefault && !$0.hidden && ($0.inputModalities?.contains("text") ?? true) }
            if selected != nil || catalog.nextCursor == nil { break }
            cursor = catalog.nextCursor
        }
        guard let selected else { throw WatcherError.message("未找到可用的默认文本模型，已跳过自动 hello。") }
        model = selected.model
        let order = ["none", "minimal", "low", "medium", "high", "xhigh"]
        effort = order.first { value in selected.supportedReasoningEfforts.contains { $0.reasoningEffort == value } }
        let response: HelloThreadResponse = try await client.request("thread/start", params: [
            "model": selected.model, "modelProvider": "openai", "ephemeral": true,
            "cwd": client.helloWorkspace.path, "approvalPolicy": "never", "sandbox": "read-only",
            "baseInstructions": "Reply to the user's greeting with hello only. Do not call tools, read files, run commands, or continue working.",
            "developerInstructions": "This is one greeting, not a coding task. Return only the requested greeting.",
            "config": ["project_doc_max_bytes": 0, "web_search": "disabled"]
        ])
        guard response.modelProvider == "openai", response.thread.ephemeral == true,
              !response.thread.id.isEmpty else {
            throw WatcherError.message("CLI 未提供独立临时会话，已跳过自动 hello。")
        }
        threadID = response.thread.id
    }

    func sendHello(isAuthorized: () -> Bool) async throws {
        guard let threadID, let model, !disconnected, isAuthorized() else {
            throw WatcherError.message("自动 hello 条件已变化，已停止。")
        }
        var params: [String: Any] = [
            "threadId": threadID, "model": model, "serviceTierForTurn": "default",
            "input": [["type": "text", "text": "hello"]],
            "approvalPolicy": "never", "cwd": client.helloWorkspace.path,
            "sandboxPolicy": ["type": "readOnly", "access": ["type": "restricted",
                "includePlatformDefaults": false, "readableRoots": [client.helloWorkspace.path]]],
            "outputSchema": ["type": "object", "properties": ["message": ["type": "string", "enum": ["hello"]]],
                             "required": ["message"], "additionalProperties": false]
        ]
        if let effort { params["effort"] = effort }
        let response: HelloTurnResponse = try await client.request("turn/start", params: params)
        let turn = response.turn
        let deadline = Date().addingTimeInterval(completionTimeout)
        while !disconnected && Date() < deadline {
            let status = completedTurns[turn.id] ?? turn.status
            if status == "completed" { return }
            if status == "failed" || status == "interrupted" { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        stop()
        throw WatcherError.message("自动 hello 结果未确认。")
    }

    func stop() { client.stop() }

    private func receive(_ method: String, params: [String: Any]) {
        guard params["threadId"] as? String == threadID else { return }
        if method == "turn/completed", let turn = params["turn"] as? [String: Any],
           let id = turn["id"] as? String, let status = turn["status"] as? String {
            completedTurns[id] = status
        } else if method == "item/started", let item = params["item"] as? [String: Any],
                  let type = item["type"] as? String,
                  !["userMessage", "agentMessage", "reasoning"].contains(type) {
            stop()
        }
    }
}

private struct HelloModelList: Decodable {
    let data: [HelloModel]
    let nextCursor: String?
}
private struct HelloModel: Decodable {
    let model: String
    let isDefault: Bool
    let hidden: Bool
    let supportedReasoningEfforts: [HelloEffort]
    let inputModalities: [String]?
}
private struct HelloEffort: Decodable { let reasoningEffort: String }
private struct HelloThreadResponse: Decodable {
    struct Thread: Decodable { let id: String; let ephemeral: Bool? }
    let thread: Thread
    let modelProvider: String
}
private struct HelloTurnResponse: Decodable {
    struct Turn: Decodable { let id: String; let status: String }
    let turn: Turn
}
