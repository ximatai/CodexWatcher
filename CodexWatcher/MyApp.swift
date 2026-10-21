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
    let monitor = UsageMonitor()
    private var clockTimer: Timer?
    private var statusController: StatusBarController?
    private var dashboard: NSWindow?

    func applicationWillFinishLaunching(_ notification: Notification) {
        let saved = UserDefaults.standard.string(forKey: "appearance") ?? AppAppearance.system.rawValue
        (AppAppearance(rawValue: saved) ?? .system).apply(to: NSApplication.shared)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusController = StatusBarController(monitor: monitor) { [weak self] in self?.showDashboard() }
        showDashboard()
        clockTimer = Timer.scheduledTimer(timeInterval: 30, target: self,
                                         selector: #selector(updateClock), userInfo: nil, repeats: true)
        Task { await monitor.start() }
    }

    @objc private func updateClock() { monitor.updateClock() }

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
