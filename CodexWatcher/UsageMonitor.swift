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
    private(set) var expiryConfiguration: CreditExpiryConfiguration
    private(set) var expiryHandlingMessage: String?
    private(set) var isConfiguringExpiry = false
    private(set) var expiryReview: CreditExpiryReview?
    @ObservationIgnored var requestExpiryNotificationPermission: (() async -> Bool)?
    @ObservationIgnored var deliverExpiryReminder: ((CreditExpiryReminder) async throws -> Void)?
    @ObservationIgnored var clearExpiryNotifications: (() -> Void)?
    @ObservationIgnored private let expiryStore: CreditExpiryActionStore
    @ObservationIgnored private var expiryTask: Task<Void, Never>?
    @ObservationIgnored private var isCheckingExpiry = false
    @ObservationIgnored private var expiryChecksStopped = false
    @ObservationIgnored private let expiryNow: () -> Date
    private static let expiryPreferenceKey = "creditExpiryConfiguration"

    private(set) var executablePath: String
    @ObservationIgnored private let client: AppServerClient
    @ObservationIgnored private let resetStore: ResetAttemptStore
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var started = false
    @ObservationIgnored private var pollTask: Task<Void, Never>?
    @ObservationIgnored private var notificationTask: Task<Void, Never>?
    @ObservationIgnored private var loginTimeout: Task<Void, Never>?

    init(client suppliedClient: AppServerClient? = nil, defaults: UserDefaults = .standard,
         expiryNow: @escaping () -> Date = Date.init) {
        self.defaults = defaults
        self.expiryNow = expiryNow
        expiryConfiguration = Self.readExpiryConfiguration(defaults)
        let path = defaults.string(forKey: "codexExecutablePath")
            ?? AppServerClient.defaultExecutablePath
        client = suppliedClient ?? AppServerClient(executablePath: path)
        executablePath = client.executablePath
        selectedWindowID = defaults.string(forKey: "selectedWindowID")
        resetStore = ResetAttemptStore(directory: client.runtimeDirectory.deletingLastPathComponent()
            .appendingPathComponent("State", isDirectory: true))
        expiryStore = CreditExpiryActionStore(directory: client.runtimeDirectory.deletingLastPathComponent()
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
        expiryTask = Task { @MainActor [weak self] in
            await self?.processExpiringCredits()
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(30)) } catch { break }
                await self?.processExpiringCredits()
            }
        }
        pollTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(300)) } catch { break }
                await self?.refresh()
            }
        }
    }

    func shutdown() {
        expiryChecksStopped = true
        expiryTask?.cancel()
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
    func redeem(_ confirmation: ResetConfirmation, automatically: Bool = false) async {
        if automatically && !automaticExpiryAllowed(confirmation, at: expiryNow()) { return }
        guard isResetConfirmationCurrent(confirmation) else {
            notice = "操作已变化，请重新打开确认页。"
            return
        }
        guard canConfirmRedemption(confirmation, at: .now) else { return }
        let storageKey = confirmation.accountKey
        var automaticReservation: PendingRedemption?
        isBusy = true
        notice = nil
        defer {
            if let reservation = automaticReservation {
                // A missing record means success already cleared this operation.
                // A failed write keeps the lease, preventing an immediate concurrent retry.
                try? resetStore.finishAutomaticAttempt(owner: storageKey, expected: reservation, at: expiryNow())
                if pendingRedemption?.idempotencyKey == reservation.idempotencyKey,
                   let updated = try? resetStore.pending(for: storageKey) {
                    pendingRedemption = updated
                }
            }
            isBusy = false
        }
        do {
            try await client.connect()
            // The dialog may have remained open across expiry, reconnection or an account change.
            try await readAccountAndUsage()
            guard isResetConfirmationCurrent(confirmation) else {
                notice = "操作已变化，请重新打开确认页。"
                return
            }
            if automatically {
                guard automaticExpiryAllowed(confirmation, at: expiryNow()) else { return }
                if confirmation.retry == nil {
                    guard let expiry = sortedCredits.first(where: { $0.id == confirmation.creditID })?.expiryDate else { return }
                    let reminder = CreditExpiryReminder(accountKey: storageKey, creditID: confirmation.creditID, expiresAt: expiry)
                    guard try expiryStore.claim(reminder, mode: .automatic) else { return }
                }
            }
            var attempt: PendingRedemption
            if let confirmedAttempt = confirmation.retry {
                attempt = confirmedAttempt
            } else {
                guard !isStale(at: .now), sortedCredits.contains(where: {
                    $0.id == confirmation.creditID && $0.isUsable(at: .now)
                }) else {
                    throw WatcherError.message("所选重置卡或额度状态已变化，请刷新后重新确认。")
                }
                guard let created = try resetStore.prepareNew(creditID: confirmation.creditID, owner: storageKey,
                    automaticExpiresAt: automatically ? confirmation.credit?.expiresAt : nil) else {
                    pendingRedemption = try resetStore.pending(for: storageKey)
                    notice = "操作已变化，请重新打开确认页。"
                    return
                }
                attempt = created
                pendingRedemption = attempt
            }
            if automatically {
                guard let reserved = try resetStore.reserveAutomaticAttempt(owner: storageKey,
                    expected: attempt, at: expiryNow()) else {
                    pendingRedemption = try resetStore.pending(for: storageKey)
                    return
                }
                attempt = reserved
                automaticReservation = reserved
                pendingRedemption = reserved
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

    private static func readExpiryConfiguration(_ defaults: UserDefaults) -> CreditExpiryConfiguration {
        guard let data = defaults.data(forKey: expiryPreferenceKey),
              let config = try? JSONDecoder().decode(CreditExpiryConfiguration.self, from: data) else {
            return CreditExpiryConfiguration()
        }
        return config
    }

    var expiryConfigurationMatchesAccount: Bool {
        account?.type == "chatgpt" && redemptionStorageKey != nil
            && expiryConfiguration.accountKey == redemptionStorageKey
    }

    func configureExpiryHandling(_ mode: CreditExpiryMode) async {
        guard !isConfiguringExpiry else { return }
        isConfiguringExpiry = true
        defer { isConfiguringExpiry = false }
        expiryHandlingMessage = nil
        let owner = redemptionStorageKey
        if mode != .off {
            guard account?.type == "chatgpt", let owner, !isBusy, loginID == nil else {
                expiryHandlingMessage = "请先连接账号并刷新用量，再开启临期处理。"
                return
            }
            if mode == .automatic && snapshot?.accountId?.isEmpty != false {
                expiryHandlingMessage = "服务端未提供稳定账号标识，无法开启自动使用。"
                return
            }
            if mode == .remind {
                // Switching away from automatic must stop writes even if permission is denied.
                let off = CreditExpiryConfiguration()
                if expiryConfiguration.mode == .automatic,
                   let data = try? JSONEncoder().encode(off) {
                    defaults.set(data, forKey: Self.expiryPreferenceKey)
                    expiryConfiguration = off
                }
                guard await requestExpiryNotificationPermission?() == true else {
                    expiryHandlingMessage = "未获得通知权限。请在系统设置中允许 Codex Watcher 通知后重试。"
                    return
                }
            }
            guard owner == redemptionStorageKey, account?.type == "chatgpt", loginID == nil else {
                expiryHandlingMessage = "账号已变化，请重新设置。"
                return
            }
        }
        let config = CreditExpiryConfiguration(mode: mode, accountKey: mode == .off ? nil : owner)
        do {
            defaults.set(try JSONEncoder().encode(config), forKey: Self.expiryPreferenceKey)
            expiryConfiguration = config
            expiryReview = nil
            clearExpiryNotifications?()
        } catch { expiryHandlingMessage = "无法保存临期处理设置。" }
    }

    private func automaticExpiryAllowed(_ confirmation: ResetConfirmation, at date: Date) -> Bool {
        expiryConfiguration = Self.readExpiryConfiguration(defaults)
        guard !expiryChecksStopped, !isConfiguringExpiry, expiryConfiguration.mode == .automatic,
              expiryConfigurationMatchesAccount, snapshot?.accountId?.isEmpty == false,
              confirmation.accountKey == redemptionStorageKey, loginID == nil,
              !isStale(at: date),
              let credit = sortedCredits.first(where: { $0.id == confirmation.creditID }),
              CreditExpiryPolicy.candidate(in: [credit], at: date) != nil else { return false }
        if let retry = confirmation.retry {
            guard let automatic = retry.automatic,
                  pendingRedemption?.idempotencyKey == retry.idempotencyKey,
                  pendingRedemption?.creditID == retry.creditID,
                  automatic.expiresAt == credit.expiresAt else { return false }
            return true
        }
        return pendingRedemption == nil && confirmation.credit?.expiresAt == credit.expiresAt
    }

    /// A 30-second awake-time check; always refresh from the server before deciding.
    /// Retry only the exact automatic operation, within its persisted three-attempt budget.
    func processExpiringCredits() async {
        expiryConfiguration = Self.readExpiryConfiguration(defaults)
        guard !expiryChecksStopped, !isCheckingExpiry, !isConfiguringExpiry, !isBusy, loginID == nil,
              expiryConfiguration.mode != .off else { return }
        isCheckingExpiry = true
        defer { isCheckingExpiry = false }
        await refresh()
        expiryConfiguration = Self.readExpiryConfiguration(defaults)
        let mode = expiryConfiguration.mode
        guard !expiryChecksStopped, !isConfiguringExpiry, mode != .off, expiryConfigurationMatchesAccount,
              !isBusy, loginID == nil, !isStale(at: expiryNow()),
              let owner = redemptionStorageKey else { return }
        do {
            if let pending = pendingRedemption {
                guard mode == .automatic, let automatic = pending.automatic else {
                    expiryHandlingMessage = "已有待确认重置，请先核实原请求。"
                    return
                }
                guard automatic.attempts < CreditExpiryPolicy.maximumAttempts else {
                    expiryHandlingMessage = "自动使用已尝试 3 次，请核实原请求。"
                    return
                }
                guard let confirmation = makeResetConfirmation(for: nil),
                      automaticExpiryAllowed(confirmation, at: expiryNow()) else {
                    expiryHandlingMessage = "原卡片状态或到期时间已变化，已停止自动重试。"
                    return
                }
                let now = expiryNow().timeIntervalSince1970
                guard automatic.nextAttemptAt <= now, (automatic.leaseUntil ?? 0) <= now else { return }
                await redeem(confirmation, automatically: true)
                updateAutomaticExpiryMessage()
                return
            }
            // Filter handled cards before selection, so the next card can be checked later.
            let unhandled = try sortedCredits.filter { credit in
                guard let expiry = credit.expiryDate else { return false }
                return try !expiryStore.contains(CreditExpiryReminder(accountKey: owner,
                    creditID: credit.id, expiresAt: expiry), mode: mode)
            }
            guard let card = CreditExpiryPolicy.candidate(in: unhandled, at: expiryNow()),
                  let expiry = card.expiryDate else { return }
            let reminder = CreditExpiryReminder(accountKey: owner, creditID: card.id, expiresAt: expiry)
            if mode == .automatic {
                guard let confirmation = makeResetConfirmation(for: card) else { return }
                await redeem(confirmation, automatically: true)
                updateAutomaticExpiryMessage()
            } else {
                guard let deliverExpiryReminder else {
                    expiryHandlingMessage = "通知暂不可用，请重新开启提醒模式。"
                    return
                }
                guard try expiryStore.claim(reminder, mode: .remind) else { return }
                do {
                    try await deliverExpiryReminder(reminder)
                    expiryConfiguration = Self.readExpiryConfiguration(defaults)
                    guard !expiryChecksStopped, expiryConfiguration.mode == .remind,
                          expiryConfigurationMatchesAccount, owner == redemptionStorageKey else {
                        clearExpiryNotifications?()
                        return
                    }
                    expiryHandlingMessage = "已发送临期提醒，确认后才会使用卡片。"
                } catch {
                    try expiryStore.releaseReminder(reminder)
                    expiryHandlingMessage = "临期通知未发送，请检查系统通知权限。"
                }
            }
        } catch { expiryHandlingMessage = "临期处理记录不可用，已跳过操作。请检查本地状态文件。" }
    }

    private func updateAutomaticExpiryMessage() {
        if let automatic = pendingRedemption?.automatic {
            expiryHandlingMessage = automatic.attempts >= CreditExpiryPolicy.maximumAttempts
                ? "自动使用已尝试 3 次，请核实原请求。"
                : "自动使用结果未确认，将重试原卡片（\(automatic.attempts)/3）。"
        } else if let errorMessage { expiryHandlingMessage = errorMessage }
        else { expiryHandlingMessage = notice }
    }

    func reviewExpiringCredit(accountKey: String, creditID: String) async {
        // The newly opened dashboard may already be refreshing; wait for its read.
        let deadline = Date().addingTimeInterval(30)
        while isBusy && Date() < deadline {
            do { try await Task.sleep(for: .milliseconds(100)) } catch { return }
        }
        guard !isBusy else {
            expiryHandlingMessage = "正在更新，请稍后在面板查看重置卡。"
            return
        }
        await refresh()
        guard accountKey == redemptionStorageKey, !isStale(at: .now),
              let card = sortedCredits.first(where: { $0.id == creditID }),
              makeResetConfirmation(for: card) != nil else {
            expiryHandlingMessage = "提醒对应的账号或卡片已变化，请在面板重新查看。"
            return
        }
        expiryReview = CreditExpiryReview(accountKey: accountKey, creditID: creditID)
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
