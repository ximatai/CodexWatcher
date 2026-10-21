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
    private var clockTimer: Timer?
    private var statusController: StatusBarController?
    private var dashboard: NSWindow?

    func applicationWillFinishLaunching(_ notification: Notification) {
        if Self.smokeRoot != nil {
            UserDefaults.standard.setVolatileDomain([
                "appearance": "system", "privacyMode": false,
                "menuBarIcon": "gauge", "menuBarShowUsage": true,
                "menuBarShowTimeProgress": false, "menuBarShowDeviation": false
            ], forName: UserDefaults.argumentDomain)
        }
        let saved = UserDefaults.standard.string(forKey: "appearance") ?? AppAppearance.system.rawValue
        (AppAppearance(rawValue: saved) ?? .system).apply(to: NSApplication.shared)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusController = StatusBarController(monitor: monitor) { [weak self] in self?.showDashboard() }
        let event = NSAppleEventManager.shared().currentAppleEvent
        let launchedAtLogin = event?.eventID == kAEOpenApplication
            && event?.paramDescriptor(forKeyword: keyAEPropData)?.enumCodeValue == keyAELaunchedAsLogInItem
        if !launchedAtLogin { showDashboard() }
        clockTimer = Timer.scheduledTimer(timeInterval: 30, target: self,
                                         selector: #selector(updateClock), userInfo: nil, repeats: true)
        if let root = Self.smokeRoot {
            Task { await runReleaseSmokeTest(root: root) }
        } else {
            Task { await monitor.start() }
        }
    }

    // Executes inside the actual packaged app; the fixture rejects all writes and
    // cannot reach Codex or the user's account. A missing report fails the runner.
    private func runReleaseSmokeTest(root: URL) async {
        await monitor.refresh()
        while monitor.isBusy {
            try? await Task.sleep(for: .milliseconds(20))
        }
        guard monitor.account?.email == "smoke@example.invalid", monitor.snapshot != nil,
              monitor.errorMessage == nil, statusController?.isReadyForSmokeTest == true,
              let dashboard, dashboard.isVisible, dashboard.contentView != nil,
              dashboard.frame.width > 0, dashboard.frame.height > 0 else {
            NSApp.terminate(nil)
            return
        }
        for appearance in [AppAppearance.light, .dark, .system] { appearance.apply(to: NSApp) }
        do {
            try Data("passed\n".utf8).write(to: root.appendingPathComponent("result.txt"), options: .atomic)
        } catch { /* Missing report is a failed smoke test. */ }
        NSApp.terminate(nil)
    }

    @objc private func updateClock() { monitor.updateClock() }

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
            let hosting = NSHostingController(rootView: ContentView(monitor: monitor) { [weak self] in
                self?.showDashboard()
            })
            hosting.sizingOptions = [.minSize, .maxSize]
            let window = NSWindow(contentViewController: hosting)
            window.title = "Codex Watcher"
            window.identifier = NSUserInterfaceItemIdentifier("dashboard")
            window.styleMask = [.titled, .closable, .miniaturizable]
            window.isReleasedWhenClosed = false
            window.center()
            dashboard = window
        }
        NSApplication.shared.activate(ignoringOtherApps: true)
        dashboard?.makeKeyAndOrderFront(nil)
    }

    func applicationWillTerminate(_ notification: Notification) {
        clockTimer?.invalidate()
        statusController?.stop()
        monitor.shutdown()
    }
}
