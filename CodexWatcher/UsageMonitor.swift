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
        didSet { defaults.set(selectedWindowID, forKey: "selectedWindowID") }
    }
    private(set) var executablePath: String
    @ObservationIgnored private let client: AppServerClient
    @ObservationIgnored private let resetStore: ResetAttemptStore
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var started = false
    @ObservationIgnored private var pollTask: Task<Void, Never>?
    @ObservationIgnored private var notificationTask: Task<Void, Never>?
    @ObservationIgnored private var loginTimeout: Task<Void, Never>?

    init(client suppliedClient: AppServerClient? = nil, defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let path = defaults.string(forKey: "codexExecutablePath")
            ?? AppServerClient.defaultExecutablePath
        client = suppliedClient ?? AppServerClient(executablePath: path)
        executablePath = client.executablePath
        selectedWindowID = defaults.string(forKey: "selectedWindowID")
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

    func makeResetConfirmation(for credit: ResetCredit?) -> ResetConfirmation? {
        guard let account, let owner = redemptionStorageKey else { return nil }
        let targetID: String
        if let pending = pendingRedemption {
            guard credit == nil || credit?.id == pending.creditID else { return nil }
            targetID = pending.creditID
        } else {
            guard let credit else { return nil }
            targetID = credit.id
        }
        let confirmation = ResetConfirmation(accountKey: owner, email: account.email, creditID: targetID,
            credit: sortedCredits.first { $0.id == targetID } ?? credit,
            windowID: selectedWindow?.id, retry: pendingRedemption)
        return canConfirmRedemption(confirmation, at: .now) ? confirmation : nil
    }

    func isResetConfirmationCurrent(_ confirmation: ResetConfirmation) -> Bool {
        guard account != nil, redemptionStorageKey == confirmation.accountKey else { return false }
        if let retry = confirmation.retry {
            return retry.creditID == confirmation.creditID
                && pendingRedemption?.creditID == confirmation.creditID
                && pendingRedemption?.idempotencyKey == retry.idempotencyKey
        }
        return pendingRedemption == nil
    }

    func canConfirmRedemption(_ confirmation: ResetConfirmation, at date: Date) -> Bool {
        guard !isBusy, isResetConfirmationCurrent(confirmation) else { return false }
        // A retry must remain possible if the consumed card disappeared from the refreshed list.
        if confirmation.retry != nil { return true }
        guard canRedeem, !isStale(at: date) else { return false }
        return sortedCredits.contains { $0.id == confirmation.creditID && $0.isUsable(at: date) }
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
            try await client.connect()
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
    func redeem(_ confirmation: ResetConfirmation) async {
        guard isResetConfirmationCurrent(confirmation) else {
            notice = "操作已变化，请重新打开确认页。"
            return
        }
        guard canConfirmRedemption(confirmation, at: .now) else { return }
        let storageKey = confirmation.accountKey
        isBusy = true
        notice = nil
        defer { isBusy = false }
        do {
            try await client.connect()
            // The dialog may have remained open across expiry, reconnection or an account change.
            try await readAccountAndUsage()
            guard isResetConfirmationCurrent(confirmation) else {
                notice = "操作已变化，请重新打开确认页。"
                return
            }
            let attempt: PendingRedemption
            if let confirmedAttempt = confirmation.retry {
                attempt = confirmedAttempt
            } else {
                guard !isStale(at: .now), sortedCredits.contains(where: {
                    $0.id == confirmation.creditID && $0.isUsable(at: .now)
                }) else {
                    throw WatcherError.message("所选重置卡或额度状态已变化，请刷新后重新确认。")
                }
                guard let created = try resetStore.prepareNew(creditID: confirmation.creditID, owner: storageKey) else {
                    pendingRedemption = try resetStore.pending(for: storageKey)
                    notice = "操作已变化，请重新打开确认页。"
                    return
                }
                attempt = created
                pendingRedemption = attempt
            }
            let result: ResetResult = try await client.request("account/rateLimitResetCredit/consume", params: [
                "creditId": attempt.creditID, "idempotencyKey": attempt.idempotencyKey
            ])
            switch result.outcome {
            case "reset", "alreadyRedeemed": notice = "重置已完成。"
            case "nothingToReset": notice = "当前没有符合条件的额度可重置。"
            case "noCredit": notice = "当前没有可用的重置卡。"
            default: throw WatcherError.message("重置结果未知，请重试原重置操作。")
            }
            try resetStore.clear(owner: storageKey, idempotencyKey: attempt.idempotencyKey)
            pendingRedemption = nil
            try await readAccountAndUsage()
            errorMessage = nil
        } catch {
            notice = nil
            errorMessage = pendingRedemption == nil ? error.localizedDescription
                : "尚未确认重置结果。可重试原重置操作；若此前尚未完成，可能消耗 1 张卡。同一请求标识用于避免重复消费，操作无法撤销。"
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
        defaults.set(url.path, forKey: "codexExecutablePath")
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
