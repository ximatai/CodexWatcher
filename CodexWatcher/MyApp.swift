import SwiftUI

@main struct CodexWatcherApp: App {
    @NSApplicationDelegateAdaptor(WatcherAppDelegate.self) private var delegate

    private var monitor: UsageMonitor { delegate.monitor }

    var body: some Scene {
        Window("Codex Watcher", id: "dashboard") {
            ContentView(monitor: monitor)
                .task { await monitor.start() }
        }
        .windowResizability(.contentSize)

        MenuBarExtra {
            ContentView(monitor: monitor)
                .task { await monitor.start() }
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Image(systemName: "gauge.with.dots.needle.50percent")
                    // This circular symbol sits optically below the digits despite sharing a baseline.
                    .offset(y: -1)
                Text(monitor.menuTitle()).monospacedDigit()
            }
            .font(.system(size: 13))
        }
        .menuBarExtraStyle(.window)
    }
}

final class WatcherAppDelegate: NSObject, NSApplicationDelegate {
    let monitor = UsageMonitor()
    private var clockTimer: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApplication.shared.activate(ignoringOtherApps: true)
        clockTimer = Timer.scheduledTimer(timeInterval: 30, target: self,
                                         selector: #selector(updateClock), userInfo: nil, repeats: true)
        Task { await monitor.start() }
    }

    @objc private func updateClock() { monitor.updateClock() }

    func applicationWillTerminate(_ notification: Notification) {
        clockTimer?.invalidate()
        monitor.shutdown()
    }
}
