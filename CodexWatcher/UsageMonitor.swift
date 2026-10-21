import AppKit
import Foundation
import Observation

@MainActor @Observable
final class UsageMonitor {
    private(set) var displayDate = Date()

    func updateClock() { displayDate = .now }

    private(set) var account: WatcherAccount?
    private(set) var snapshot: UsageSnapshot?
    private(set) var lastUpdated: Date?
    private(set) var isBusy = false
    private(set) var loginID: String?
    private(set) var loginURL: URL?
    private(set) var errorMessage: String?
    private(set) var notice: String?
    private(set) var pendingRedemption: PendingRedemption?
    var selectedWindowID: String? {
        didSet { UserDefaults.standard.set(selectedWindowID, forKey: "selectedWindowID") }
    }
    private(set) var executablePath: String
    @ObservationIgnored private let client: AppServerClient
    @ObservationIgnored private let resetStore: ResetAttemptStore
    @ObservationIgnored private var started = false
    @ObservationIgnored private var pollTask: Task<Void, Never>?
    @ObservationIgnored private var notificationTask: Task<Void, Never>?
    @ObservationIgnored private var loginTimeout: Task<Void, Never>?

    init() {
        let path = UserDefaults.standard.string(forKey: "codexExecutablePath")
            ?? AppServerClient.defaultExecutablePath
        executablePath = path
        selectedWindowID = UserDefaults.standard.string(forKey: "selectedWindowID")
        client = AppServerClient(executablePath: path)
        resetStore = ResetAttemptStore(directory: client.runtimeDirectory.deletingLastPathComponent()
            .appendingPathComponent("State", isDirectory: true))
        client.onNotification = { [weak self] method, params in
            self?.handleNotification(method, params: params)
        }
    }

    var windows: [UsageWindow] { snapshot?.windows ?? [] }
    var selectedWindow: UsageWindow? {
        windows.first { $0.id == selectedWindowID }
            ?? windows.filter { $0.bucketID == "codex" }.max {
                ($0.quota.windowDurationMins ?? 0) < ($1.quota.windowDurationMins ?? 0)
            } ?? windows.first
    }
    var sortedCredits: [ResetCredit] {
        (snapshot?.rateLimitResetCredits?.credits ?? []).sorted {
            ($0.expiresAt ?? .greatestFiniteMagnitude) < ($1.expiresAt ?? .greatestFiniteMagnitude)
        }
    }
    var pendingCredit: ResetCredit? {
        guard let pendingRedemption else { return nil }
        return sortedCredits.first { $0.id == pendingRedemption.creditID }
    }
    private var redemptionStorageKey: String? {
        guard let id = snapshot?.accountId ?? account?.email else { return nil }
        return id
    }

    var canRedeem: Bool { redemptionStorageKey != nil && errorMessage == nil }

    func canConfirmRedemption(_ credit: ResetCredit?, at date: Date) -> Bool {
        guard !isBusy, account != nil, redemptionStorageKey != nil else { return false }
        // A retry must remain possible if the consumed card disappeared from the refreshed list.
        if pendingRedemption != nil { return true }
        guard canRedeem, !isStale(at: date), let credit else { return false }
        return sortedCredits.contains { $0.id == credit.id && $0.isUsable(at: date) }
    }

    func isStale(at date: Date) -> Bool {
        guard let lastUpdated else { return true }
        return errorMessage != nil || date.timeIntervalSince(lastUpdated) > 600
            || (selectedWindow?.quota.resetDate.map { $0 <= date } ?? false)
    }

    func menuTitle() -> String {
        guard account != nil, let quota = selectedWindow?.quota else { return "—%" }
        return PresentationFormat().percent(quota.usedPercent)
    }

    func start() async {
        guard !started else { return }
        started = true
        await refresh()
        pollTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(300)) } catch { break }
                await self?.refresh()
            }
        }
    }

    func shutdown() {
        pollTask?.cancel()
        notificationTask?.cancel()
        loginTimeout?.cancel()
        client.stop()
    }

    func refresh() async {
        guard !isBusy else { return }
        isBusy = true
        defer { isBusy = false }
        do {
            try await client.connect()
            try await readAccountAndUsage()
            errorMessage = nil
        } catch { errorMessage = error.localizedDescription }
    }

    private func readAccountAndUsage() async throws {
        let response: AccountResponse = try await client.request("account/read", params: ["refreshToken": false])
        if response.account?.email != account?.email || response.account == nil {
            snapshot = nil
            lastUpdated = nil
            pendingRedemption = nil
        }
        account = response.account
        guard account?.type == "chatgpt" else {
            snapshot = nil
            lastUpdated = nil
            return
        }
        let fresh: UsageSnapshot = try await client.request("account/rateLimits/read")
        snapshot = fresh
        lastUpdated = .now
        if let key = redemptionStorageKey {
            pendingRedemption = try resetStore.pending(for: key)
        } else { pendingRedemption = nil }
    }

    func login() async {
        guard !isBusy, loginID == nil else { return }
        isBusy = true
        notice = nil
        defer { isBusy = false }
        do {
            try await client.connect()
            let response: LoginResult = try await client.request("account/login/start", params: ["type": "chatgpt"])
            loginID = response.loginId
            guard let value = response.authUrl, let url = URL(string: value), url.scheme == "https",
                  let host = url.host, ["auth.openai.com", "chatgpt.com", "auth0.openai.com"].contains(host) else {
                await cancelLogin()
                throw WatcherError.message("登录链接不可用，请更新 Codex CLI 后重试。")
            }
            loginURL = url
            guard NSWorkspace.shared.open(url) else {
                await cancelLogin()
                throw WatcherError.message("无法打开浏览器，请检查默认浏览器设置。")
            }
            errorMessage = nil
            loginTimeout?.cancel()
            loginTimeout = Task { @MainActor [weak self] in
                do { try await Task.sleep(for: .seconds(600)) } catch { return }
                await self?.cancelLogin()
                self?.errorMessage = "登录等待已结束，请重新连接。"
            }
        } catch { errorMessage = error.localizedDescription }
    }

    func cancelLogin() async {
        guard let id = loginID else { return }
        loginTimeout?.cancel()
        loginTimeout = nil
        loginID = nil
        loginURL = nil
        let _: EmptyResponse? = try? await client.request("account/login/cancel", params: ["loginId": id])
    }

    func logout() async {
        guard !isBusy else { return }
        isBusy = true
        defer { isBusy = false }
        do {
            let _: EmptyResponse = try await client.request("account/logout")
            account = nil
            snapshot = nil
            lastUpdated = nil
            pendingRedemption = nil
            notice = nil
            errorMessage = nil
        } catch { errorMessage = error.localizedDescription }
    }

    /// Persist before sending; unknown outcomes are retried with the same key, even after restart.
    func redeem(_ credit: ResetCredit?) async {
        guard canConfirmRedemption(credit, at: .now), let storageKey = redemptionStorageKey else { return }
        let confirmedAttempt = pendingRedemption
        isBusy = true
        notice = nil
        defer { isBusy = false }
        do {
            try await client.connect()
            // The dialog may have remained open across expiry, reconnection or an account change.
            try await readAccountAndUsage()
            guard redemptionStorageKey == storageKey else {
                throw WatcherError.message("账号已变化，请重新核对账号和重置卡后再操作。")
            }
            let attempt: PendingRedemption
            if let confirmedAttempt {
                guard pendingRedemption?.idempotencyKey == confirmedAttempt.idempotencyKey else {
                    notice = "上次操作状态已更新，请查看最新额度后再操作。"
                    return
                }
                attempt = confirmedAttempt
            } else if let credit {
                guard pendingRedemption == nil else {
                    throw WatcherError.message("存在尚未确认的重置，请先核实上次操作。")
                }
                guard !isStale(at: .now), sortedCredits.contains(where: {
                    $0.id == credit.id && $0.isUsable(at: .now)
                }) else {
                    throw WatcherError.message("所选重置卡或额度状态已变化，请刷新后重新确认。")
                }
                attempt = try resetStore.prepare(creditID: credit.id, owner: storageKey)
                pendingRedemption = attempt
                guard attempt.creditID == credit.id else {
                    throw WatcherError.message("其他实例已开始重置，请先核实该操作。")
                }
            } else { return }
            let result: ResetResult = try await client.request("account/rateLimitResetCredit/consume", params: [
                "creditId": attempt.creditID, "idempotencyKey": attempt.idempotencyKey
            ])
            switch result.outcome {
            case "reset", "alreadyRedeemed": notice = "重置已完成。"
            case "nothingToReset": notice = "当前没有符合条件的额度可重置。"
            case "noCredit": notice = "当前没有可用的重置卡。"
            default: throw WatcherError.message("重置结果未知，请重试确认。")
            }
            try resetStore.clear(owner: storageKey, idempotencyKey: attempt.idempotencyKey)
            pendingRedemption = nil
            try await readAccountAndUsage()
            errorMessage = nil
        } catch {
            notice = nil
            errorMessage = pendingRedemption == nil ? error.localizedDescription
                : "尚未确认重置结果。请使用“重试上次重置”核实，重试不会重复消耗。"
        }
    }

    func chooseExecutable() async {
        guard !isBusy, loginID == nil else { return }
        let panel = NSOpenPanel()
        panel.title = "选择 Codex CLI 可执行文件"
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = URL(fileURLWithPath: "/opt/homebrew/bin")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard FileManager.default.isExecutableFile(atPath: url.path) else {
            errorMessage = "请选择可执行的 codex 文件。"
            return
        }
        client.stop()
        client.executablePath = url.path
        executablePath = url.path
        UserDefaults.standard.set(url.path, forKey: "codexExecutablePath")
        await refresh()
    }

    private func handleNotification(_ method: String, params: [String: Any]) {
        if method == "account/login/completed" {
            guard let id = params["loginId"] as? String, id == loginID else { return }
            loginID = nil
            loginURL = nil
            loginTimeout?.cancel()
            if params["success"] as? Bool != true {
                errorMessage = "登录未完成，请重试；若官方客户端正在登录，请先完成该流程。"
                return
            }
        } else if method != "account/updated" { return }
        notificationTask?.cancel()
        notificationTask = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .milliseconds(500)) } catch { return }
            // A read or redemption may still own the client; retry after it finishes.
            while self?.isBusy == true {
                do { try await Task.sleep(for: .milliseconds(200)) } catch { return }
            }
            await self?.refresh()
        }
    }
}
