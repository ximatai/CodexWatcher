import AppKit
import SwiftUI

// Documentation-only executable. All account data comes from an isolated local
// fake process that rejects every method except initialization and reads.
@main
struct DocumentationPreview {
    private static var previewLocale: Locale {
        Locale(identifier: UserDefaults.standard.string(forKey: "AppleLocale") ?? "zh_CN")
    }

    @MainActor static func main() async throws {
        let arguments = CommandLine.arguments
        guard arguments.count >= 2 else { fatalError("Pass the screenshot output directory") }
        let output = URL(fileURLWithPath: arguments[1], isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("WatcherDocs-\(UUID())")
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        let suite = "WatcherDocs-\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: temporary)
        }
        defaults.set(false, forKey: "privacyMode")
        let executable = temporary.appendingPathComponent("fake-codex")
        let script = #"""
        #!/bin/sh
        fixture_dir=$(/usr/bin/dirname "$0")
        while IFS= read -r line; do
          id=$(printf '%s' "$line" | /usr/bin/sed -n 's/.*"id":\([0-9][0-9]*\).*/\1/p')
          case "$line" in
            *initialized*) continue ;;
            *initialize*) result='{}' ;;
            *account*rateLimits*read*)
              if [ -f "$fixture_dir/reject-usage" ]; then
                printf '{"id":%s,"error":{"code":-32000}}\n' "$id"
                continue
              fi
              result=$(/bin/cat "$fixture_dir/usage.json") ;;
            *account*read*) result=$(/bin/cat "$fixture_dir/account.json") ;;
            *) printf '{"id":%s,"error":{"code":-32601}}\n' "$id"; continue ;;
          esac
          printf '{"id":%s,"result":%s}\n' "$id" "$result"
        done
        """#
        try Data(script.utf8).write(to: executable)
        try Data(#"{"account":{"type":"chatgpt","email":"demo@example.com","planType":"pro"}}"#.utf8)
            .write(to: temporary.appendingPathComponent("account.json"))
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        let now = Date().timeIntervalSince1970
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        let midnight = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: Date()))!
        let todayExpiry = (now + midnight.timeIntervalSince1970) / 2
        let quota = QuotaWindow(usedPercent: 35, windowDurationMins: 10080, resetsAt: now + 10080 * 60 * 0.72)
        let credits = ResetCredits(availableCount: 3, credits: [
            .init(id: "demo-card-1", resetType: "codexRateLimits", status: "available",
                  grantedAt: now - 86400, expiresAt: todayExpiry, title: "Full reset", description: nil),
            .init(id: "demo-card-2", resetType: "codexRateLimits", status: "available",
                  grantedAt: now - 86400, expiresAt: midnight.timeIntervalSince1970 + 43200, title: "Full reset", description: nil),
            .init(id: "demo-card-3", resetType: "codexRateLimits", status: "available",
                  grantedAt: now - 86400, expiresAt: now + 2 * 86400, title: "Full reset", description: nil)
        ])
        let shortQuota = QuotaWindow(usedPercent: 84, windowDurationMins: 300, resetsAt: now + 5400)
        let bucket = LimitBucket(limitId: "codex", limitName: "Codex", planType: "pro", primary: shortQuota, secondary: quota)
        let snapshot = UsageSnapshot(accountId: "documentation-demo", rateLimits: bucket,
                                     rateLimitsByLimitId: nil, rateLimitResetCredits: credits)
        try JSONEncoder().encode(snapshot).write(to: temporary.appendingPathComponent("usage.json"))
        let client = AppServerClient(executablePath: executable.path,
                                     runtimeDirectory: temporary.appendingPathComponent("Runtime"))
        let monitor = UsageMonitor(client: client, defaults: defaults)
        defer { monitor.shutdown() }
        let trendStore = UsageTrendStore(directory: temporary.appendingPathComponent("State"))
        for minute in stride(from: -60, through: -5, by: 5) {
            let used = 84 + Double(minute) * 0.6 + (minute % 10 == 0 ? 0 : 1)
            let demoWindow = UsageWindow(id: "codex.primary", bucketID: "codex", name: "Codex",
                quota: QuotaWindow(usedPercent: used, windowDurationMins: 300, resetsAt: shortQuota.resetsAt))
            _ = try trendStore.record(account: "documentation-demo", windows: [demoWindow],
                                      at: Date(timeIntervalSince1970: now + Double(minute * 60)))
        }
        await monitor.refresh()
        await monitor.waitForTrendPersistence()
        guard monitor.account?.email == "demo@example.com", monitor.snapshot != nil else {
            fatalError("Demo fixture failed to load")
        }
        for dark in [false, true] {
            defaults.set(dark ? "dark" : "light", forKey: "appearance")
            try await render(ContentView(monitor: monitor).defaultAppStorage(defaults),
                             size: NSSize(width: 390, height: 660), dark: dark,
                             to: output.appendingPathComponent(dark ? "dashboard-dark.png" : "dashboard-light.png"))
        }
        for dark in [false, true] {
            defaults.set(dark ? "dark" : "light", forKey: "appearance")
            try await render(ContentView(monitor: monitor, initiallyHoveringProgress: true).defaultAppStorage(defaults),
                size: NSSize(width: 390, height: 660), dark: dark,
                to: output.appendingPathComponent(dark ? "dashboard-progress-hover-dark.png" : "dashboard-progress-hover-light.png"))
        }
        for dark in [false, true] {
            try await render(UsageTrendView(samples: monitor.trendHistory["codex.primary"] ?? [],
                quota: shortQuota, date: Date(), stale: false, storageFailed: false).padding(16),
                size: NSSize(width: 390, height: 330), dark: dark,
                to: output.appendingPathComponent(dark ? "usage-trend-dark.png" : "usage-trend-light.png"))
        }
        // Long durations exercise the summary row at normal and constrained widths.
        let longReset = Date(timeIntervalSince1970: now + 149 * 3600)
        let segment = UUID()
        let longSamples = stride(from: -60, through: 0, by: 10).map { minute in
            UsageTrendSample(date: Date(timeIntervalSince1970: now + Double(minute * 60)),
                             remaining: 70 - Double(minute) / 30, reset: longReset, segment: segment)
        }
        for width in [390, 350, 280] {
            try await render(UsageTrendView(samples: longSamples,
                quota: QuotaWindow(usedPercent: 30, windowDurationMins: 10080, resetsAt: longReset.timeIntervalSince1970),
                date: Date(timeIntervalSince1970: now), stale: false, storageFailed: false).padding(16),
                size: NSSize(width: width, height: 300), dark: true,
                to: output.appendingPathComponent("usage-trend-long-summary-\(width).png"))
        }
        monitor.selectedWindowID = "codex.primary"
        for dark in [false, true] {
            defaults.set(dark ? "dark" : "light", forKey: "appearance")
            try await render(ContentView(monitor: monitor, flexibleSize: true, initiallyShowingTrend: true).defaultAppStorage(defaults),
                size: NSSize(width: 390, height: 850), dark: dark,
                to: output.appendingPathComponent(dark ? "dashboard-trend-full-dark.png" : "dashboard-trend-full-light.png"))
        }
        let shortOnly = UsageSnapshot(accountId: "documentation-demo",
            rateLimits: LimitBucket(limitId: "codex", limitName: "Codex", planType: "pro", primary: shortQuota, secondary: nil),
            rateLimitsByLimitId: nil, rateLimitResetCredits: credits)
        monitor.selectedWindowID = "codex.secondary"
        defaults.set("light", forKey: "appearance")
        try JSONEncoder().encode(shortOnly).write(to: temporary.appendingPathComponent("usage.json"))
        await monitor.refresh()
        await monitor.waitForTrendPersistence()
        try await render(ContentView(monitor: monitor).defaultAppStorage(defaults),
                         size: NSSize(width: 390, height: 660), dark: false,
                         to: output.appendingPathComponent("dashboard-pro-short-only.png"))
        try JSONEncoder().encode(snapshot).write(to: temporary.appendingPathComponent("usage.json"))
        await monitor.refresh()
        await monitor.waitForTrendPersistence()
        defaults.set("light", forKey: "appearance")
        try await render(MenuBarSettingsView(monitor: monitor).defaultAppStorage(defaults),
                         size: NSSize(width: 380, height: 280), dark: false,
                         to: output.appendingPathComponent("menu-bar-settings.png"))
        let resetStore = ResetAttemptStore(directory: temporary.appendingPathComponent("State"))
        let pending = try resetStore.prepareNew(creditID: "demo-card-1", owner: "documentation-demo")!
        await monitor.refresh()
        await monitor.waitForTrendPersistence()
        try await render(ContentView(monitor: monitor, flexibleSize: true).defaultAppStorage(defaults),
                         size: NSSize(width: 390, height: 850), dark: false,
                         to: output.appendingPathComponent("dashboard-pending-reset.png"))
        try resetStore.clear(owner: "documentation-demo", idempotencyKey: pending.idempotencyKey)
        await monitor.refresh()
        await monitor.waitForTrendPersistence()
        let format = PresentationFormat(locale: previewLocale, timeZone: TimeZone(identifier: "Asia/Shanghai")!)
        try await render(ResetConfirmationContent(isRetry: false, cardTitle: format.creditTitle("Full reset"),
                         account: "demo@example.com", quotaTitle: format.quotaDuration(10080),
                         usage: String(format: String(localized: "已用 %@ · 剩余 %@"), format.percent(35), format.percent(65)),
                         expiry: format.date(Date(timeIntervalSince1970: todayExpiry), precise: true),
                         updated: format.date(Date(), timeOnly: true), blockingReason: nil, canConfirm: true,
                         cancel: {}, confirm: {}), size: NSSize(width: 370, height: 316), dark: false,
                         to: output.appendingPathComponent("reset-confirmation.png"))
        monitor.requestExpiryNotificationPermission = { true }
        await monitor.configureExpiryHandling(.remind)
        try await render(CreditExpirySettingsView(monitor: monitor).defaultAppStorage(defaults),
                         size: NSSize(width: 380, height: 250), dark: false,
                         to: output.appendingPathComponent("credit-expiry-reminder.png"))
        await monitor.configureExpiryHandling(.automatic, authorization: monitor.makeAutomaticExpiryAuthorization())
        try await render(CreditExpirySettingsView(monitor: monitor).defaultAppStorage(defaults),
                         size: NSSize(width: 380, height: 250), dark: true,
                         to: output.appendingPathComponent("credit-expiry-automatic.png"))
        await monitor.configureExpiryHandling(.off)
        defaults.set("light", forKey: "appearance")
        try await render(AutomaticHelloSettingsView(monitor: monitor).defaultAppStorage(defaults),
                         size: NSSize(width: 380, height: 240), dark: false,
                         to: output.appendingPathComponent("automatic-hello-off.png"))
        if let target = monitor.defaultHelloWindow,
           let authorization = monitor.makeAutomaticHelloAuthorization(windowID: target.id) {
            monitor.configureAutomaticHello(true, authorization: authorization)
        }
        defaults.set("dark", forKey: "appearance")
        try await render(AutomaticHelloSettingsView(monitor: monitor).defaultAppStorage(defaults),
                         size: NSSize(width: 380, height: 260), dark: true,
                         to: output.appendingPathComponent("automatic-hello-on.png"))
        monitor.configureAutomaticHello(false)
        defaults.set("light", forKey: "appearance")
        try await render(ContentView(monitor: monitor, maximumHeight: 440).defaultAppStorage(defaults),
                         size: NSSize(width: 390, height: 440), dark: false,
                         to: output.appendingPathComponent("dashboard-compact.png"))
        try await render(ContentView(monitor: monitor, flexibleSize: true).defaultAppStorage(defaults),
                         size: NSSize(width: 600, height: 740), dark: false,
                         to: output.appendingPathComponent("dashboard-expanded.png"))
        try Data().write(to: temporary.appendingPathComponent("reject-usage"))
        await monitor.refresh()
        await monitor.waitForTrendPersistence()
        try await render(ContentView(monitor: monitor).defaultAppStorage(defaults),
                         size: NSSize(width: 390, height: 660), dark: false,
                         to: output.appendingPathComponent("dashboard-offline.png"))
        try Data(#"{"account":null}"#.utf8).write(to: temporary.appendingPathComponent("account.json"))
        await monitor.refresh()
        await monitor.waitForTrendPersistence()
        try await render(ContentView(monitor: monitor).defaultAppStorage(defaults),
                         size: NSSize(width: 390, height: 440), dark: false,
                         to: output.appendingPathComponent("welcome.png"))
        print("Exported previews with fictional data; no real account, model call, notification permission or reset was used.")
    }

    @MainActor static func render<V: View>(_ view: V, size: NSSize, dark: Bool, to url: URL) async throws {
        let appearance = NSAppearance(named: dark ? .darkAqua : .aqua)!
        NSApplication.shared.appearance = appearance
        let hosting = NSHostingView(rootView: view
            .environment(\.locale, previewLocale)
            .environment(\.timeZone, TimeZone(identifier: "Asia/Shanghai")!)
            .preferredColorScheme(dark ? .dark : .light)
            .frame(width: size.width, height: size.height)
            .background(AppPalette(dark: dark).background))
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = appearance
        window.contentView = hosting
        hosting.frame = NSRect(origin: .zero, size: size)
        hosting.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(250))
        hosting.layoutSubtreeIfNeeded()
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * 2),
                                      pixelsHigh: Int(size.height * 2), bitsPerSample: 8, samplesPerPixel: 4,
                                      hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                      bytesPerRow: 0, bitsPerPixel: 0)!
        bitmap.size = size
        hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
        guard let png = bitmap.representation(using: .png, properties: [:]) else {
            fatalError("Unable to render \(url.lastPathComponent)")
        }
        try png.write(to: url, options: .atomic)
        window.close()
    }
}
