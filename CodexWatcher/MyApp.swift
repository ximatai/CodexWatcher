import SwiftUI

@main struct CodexWatcherApp: App {
    @NSApplicationDelegateAdaptor(WatcherAppDelegate.self) private var delegate
    var body: some Scene {
        Settings {
            MenuBarSettingsView(monitor: delegate.monitor,
                                onClose: { NSApp.keyWindow?.close() })
        }
    }
}

@MainActor
final class WatcherAppDelegate: NSObject, NSApplicationDelegate {
    private static let smokeRoot: URL? = {
        guard CommandLine.arguments.contains("--release-smoke-test") else { return nil }
        guard let path = ProcessInfo.processInfo.environment["WATCHER_SMOKE_ROOT"], path.hasPrefix("/"),
              FileManager.default.fileExists(atPath: path + "/fake-codex") else {
            fatalError("Smoke test requires an isolated fixture directory")
        }
        return URL(fileURLWithPath: path, isDirectory: true)
    }()
    let monitor: UsageMonitor = {
        guard let root = smokeRoot else { return UsageMonitor() }
        let defaults = UserDefaults(suiteName: "WatcherSmoke-\(UUID())")!
        return UsageMonitor(client: AppServerClient(executablePath: root.appendingPathComponent("fake-codex").path,
            runtimeDirectory: root.appendingPathComponent("Runtime"), requestTimeout: .seconds(5)), defaults: defaults)
    }()
    private let updates: ReleaseUpdateChecker = {
        guard smokeRoot != nil else { return ReleaseUpdateChecker() }
        return ReleaseUpdateChecker(version: "0.3.1", defaults: UserDefaults(suiteName: "WatcherUpdateSmoke-\(UUID())")!,
            fetch: { GitHubRelease(tag_name: "v999.0.0", draft: false, prerelease: false) })
    }()
    private var clockTimer: Timer?
    private var statusController: StatusBarController?
    private var dashboard: NSWindow?
    private var expiryRuntime: CreditExpiryRuntime?

    func applicationWillFinishLaunching(_ notification: Notification) {
        if Self.smokeRoot != nil {
            // Preserve per-process language arguments used by bilingual smoke checks.
            var preferences = UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)
            let fixturePreferences: [String: Any] = [
                "appearance": "system", "privacyMode": false,
                "menuBarIcon": "gauge", "menuBarShowUsage": true, "menuBarShowRemaining": false,
                "menuBarShowTimeProgress": false, "menuBarShowDeviation": false
            ]
            preferences.merge(fixturePreferences) { _, fixture in fixture }
            UserDefaults.standard.setVolatileDomain(preferences, forName: UserDefaults.argumentDomain)
        }
        let saved = UserDefaults.standard.string(forKey: "appearance") ?? AppAppearance.system.rawValue
        (AppAppearance(rawValue: saved) ?? .system).apply(to: NSApplication.shared)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusController = StatusBarController(monitor: monitor, updates: updates, observesExternalEvents: Self.smokeRoot == nil) { [weak self] in self?.showDashboard() }
        if Self.smokeRoot == nil {
            Task { await updates.check() }
        }
        let event = NSAppleEventManager.shared().currentAppleEvent
        let launchedAtLogin = event?.eventID == kAEOpenApplication
            && event?.paramDescriptor(forKeyword: keyAEPropData)?.enumCodeValue == keyAELaunchedAsLogInItem
        if !launchedAtLogin { showDashboard() }
        clockTimer = Timer.scheduledTimer(timeInterval: 30, target: self,
                                         selector: #selector(updateClock), userInfo: nil, repeats: true)
        let openReview: (String, String) -> Void = { [weak self] owner, creditID in
            self?.showDashboard()
            Task { await self?.monitor.reviewExpiringCredit(accountKey: owner, creditID: creditID) }
        }
        let smokeNotifications = Self.smokeRoot.map { _ in SmokeExpiryNotifications(openReview: openReview) }
        let notifications: any CreditExpiryNotificationService
        if let smokeNotifications { notifications = smokeNotifications }
        else { notifications = CreditExpiryNotifications(openReview: openReview) }
        let wakeNotifications = Self.smokeRoot == nil
            ? NSWorkspace.shared.notificationCenter : NotificationCenter()
        let runtime = CreditExpiryRuntime(monitor: monitor, notifications: notifications,
                                          wakeNotifications: wakeNotifications)
        expiryRuntime = runtime
        Task {
            await runtime.start()
            if let root = Self.smokeRoot, let smokeNotifications {
                await runReleaseSmokeTest(root: root, notifications: smokeNotifications,
                                          wakeNotifications: wakeNotifications)
            }
        }
    }

    // Executes inside the actual packaged app; the fixture rejects all writes and
    // cannot reach Codex or the user's account. A missing report fails the runner.
    private func runReleaseSmokeTest(root: URL, notifications: SmokeExpiryNotifications,
                                     wakeNotifications: NotificationCenter) async {
        while monitor.isBusy {
            try? await Task.sleep(for: .milliseconds(20))
        }
        let updateResult = await updates.check(force: true)
        guard updateResult == .available, updates.availableVersion == ReleaseVersion("999.0.0") else {
            finishReleaseSmokeTest(); return
        }
        guard monitor.account?.email == "smoke@example.invalid", monitor.snapshot != nil,
              monitor.errorMessage == nil, statusController?.isReadyForSmokeTest == true,
              let dashboard, dashboard.isVisible, dashboard.contentView != nil,
              dashboard.frame.width > 0, dashboard.frame.height > 0 else {
            finishReleaseSmokeTest()
            return
        }
        guard monitor.expiryConfiguration.mode == .off, !monitor.automaticHelloConfiguration.enabled,
              notifications.permissionRequests == 0,
              notifications.delivered.isEmpty else { finishReleaseSmokeTest(); return }
        for appearance in [AppAppearance.light, .dark, .system] { appearance.apply(to: NSApp) }
        guard await statusController?.verifyPopoverSizingForSmokeTest(root: root) == true,
              await statusController?.verifyUsagePresentationForSmokeTest() == true,
              await statusController?.verifyPopoverForSmokeTest() == true else {
            finishReleaseSmokeTest(); return
        }
        // Exercise the real runtime callbacks and wake observer using only local fakes.
        await monitor.configureExpiryHandling(.remind)
        let previousUpdate = monitor.lastUpdated
        wakeNotifications.post(name: NSWorkspace.didWakeNotification, object: nil)
        let deadline = Date().addingTimeInterval(10)
        while notifications.delivered.isEmpty && Date() < deadline {
            try? await Task.sleep(for: .milliseconds(20))
        }
        guard let reminder = notifications.delivered.first, notifications.permissionRequests == 1,
              notifications.delivered.count == 1, monitor.lastUpdated != previousUpdate else {
            finishReleaseSmokeTest(); return
        }
        notifications.openReview(reminder.accountKey, reminder.creditID)
        while (monitor.expiryReview?.creditID != reminder.creditID || dashboard.sheets.isEmpty) && Date() < deadline {
            try? await Task.sleep(for: .milliseconds(20))
        }
        guard monitor.expiryReview?.creditID == reminder.creditID, !dashboard.sheets.isEmpty,
              monitor.pendingRedemption == nil,
              !FileManager.default.fileExists(atPath: root.appendingPathComponent("State/pending-resets.json").path) else {
            finishReleaseSmokeTest(); return
        }
        do {
            try Data("passed\n".utf8).write(to: root.appendingPathComponent("result.txt"), options: .atomic)
        } catch { /* Missing report is a failed smoke test. */ }
        finishReleaseSmokeTest()
    }

    private func finishReleaseSmokeTest() {
        // AppKit can defer termination while a confirmation sheet is open.
        for sheet in dashboard?.sheets ?? [] {
            dashboard?.endSheet(sheet, returnCode: .cancel)
            sheet.orderOut(nil)
        }
        NSApp.terminate(nil)
    }

    @objc private func updateClock() {
        monitor.updateClock()
        if Self.smokeRoot == nil { Task { await updates.check() } }
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        if Self.smokeRoot == nil { LoginItemController.shared.refresh() }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showDashboard()
        return true
    }

    private func showDashboard() {
        statusController?.closePopover()
        if dashboard == nil {
            let hosting = NSHostingController(rootView: ContentView(monitor: monitor, updates: updates,
                handlesExpiryReminders: true, openDashboard: { [weak self] in self?.showDashboard() }, flexibleSize: true))
            hosting.sizingOptions = [.minSize]
            let window = NSWindow(contentViewController: hosting)
            window.title = "Codex Watcher"
            window.identifier = NSUserInterfaceItemIdentifier("dashboard")
            window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
            let height = min(680, (NSScreen.main?.visibleFrame.height ?? 760) - 60)
            window.setContentSize(NSSize(width: 420, height: max(360, height)))
            window.isReleasedWhenClosed = false
            window.center()
            dashboard = window
        }
        if let dashboard, !dashboard.isVisible,
           let hosting = dashboard.contentViewController as? NSHostingController<ContentView> {
            hosting.rootView = ContentView(monitor: monitor, updates: updates,
                handlesExpiryReminders: true, openDashboard: { [weak self] in self?.showDashboard() }, flexibleSize: true)
        }
        NSApplication.shared.activate(ignoringOtherApps: true)
        dashboard?.makeKeyAndOrderFront(nil)
    }

    func applicationWillTerminate(_ notification: Notification) {
        clockTimer?.invalidate()
        statusController?.stop()
        expiryRuntime?.stop()
    }
}

/// In-process test adapter: never initializes UNUserNotificationCenter or sends notifications.
@MainActor
private final class SmokeExpiryNotifications: CreditExpiryNotificationService {
    private(set) var permissionRequests = 0
    private(set) var delivered: [CreditExpiryReminder] = []
    let openReview: (String, String) -> Void
    init(openReview: @escaping (String, String) -> Void) { self.openReview = openReview }
    func requestPermission() async -> Bool { permissionRequests += 1; return true }
    func deliver(_ reminder: CreditExpiryReminder) async throws { delivered.append(reminder) }
    func clear() { delivered.removeAll() }
}
