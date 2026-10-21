// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "CodexWatcherCore",
    defaultLocalization: "en",
    platforms: [.macOS(.v14)],
    targets: [
        .target(name: "WatcherCore", path: "CodexWatcher",
                exclude: ["MyApp.swift", "ContentView.swift", "PrivacyMask.swift", "MenuBarSettingsView.swift", "ResetConfirmationView.swift", "ResetConfirmationContent.swift", "StatusBarController.swift", "CreditExpirySettingsView.swift", "CreditExpiryNotifications.swift", "Assets.xcassets"],
                sources: ["UsageModels.swift", "UsageMonitor.swift", "AppServerClient.swift", "ResetAttemptStore.swift", "PresentationFormat.swift", "MenuBarLabelRenderer.swift", "MenuBarConfiguration.swift", "AppTheme.swift", "LoginItemController.swift", "CreditExpiryHandling.swift"],
                resources: [.process("en.lproj"), .process("zh-Hans.lproj")]),
        .testTarget(name: "WatcherCoreTests", dependencies: ["WatcherCore"], path: "Tests")
    ],
    swiftLanguageModes: [.v5]
)
