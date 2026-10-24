import AppKit
import Foundation

@MainActor
protocol CreditExpiryNotificationService: AnyObject {
    func requestPermission() async -> Bool
    func deliver(_ reminder: CreditExpiryReminder) async throws
    func clear()
}

/// Shared by ordinary startup and packaged-app smoke tests. Only the adapters differ.
@MainActor
final class CreditExpiryRuntime {
    private let monitor: UsageMonitor
    private let notifications: any CreditExpiryNotificationService
    private let wakeNotifications: NotificationCenter
    private var wakeObserver: NSObjectProtocol?

    init(monitor: UsageMonitor, notifications: any CreditExpiryNotificationService,
         wakeNotifications: NotificationCenter = NSWorkspace.shared.notificationCenter) {
        self.monitor = monitor
        self.notifications = notifications
        self.wakeNotifications = wakeNotifications
        monitor.requestExpiryNotificationPermission = { [weak notifications] in
            await notifications?.requestPermission() ?? false
        }
        monitor.deliverExpiryReminder = { [weak notifications] reminder in
            guard let notifications else { throw WatcherError.message("通知不可用。") }
            try await notifications.deliver(reminder)
        }
        monitor.clearExpiryNotifications = { [weak notifications] in notifications?.clear() }
        wakeObserver = wakeNotifications.addObserver(forName: NSWorkspace.didWakeNotification,
            object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                await self?.monitor.processExpiringCredits()
                if self?.monitor.automaticHelloConfiguration.enabled == true {
                    await self?.monitor.refresh()
                }
                self?.monitor.scheduleAutomaticHelloCheck()
            }
        }
    }

    func start() async { await monitor.start() }

    func stop() {
        if let wakeObserver { wakeNotifications.removeObserver(wakeObserver) }
        wakeObserver = nil
        monitor.shutdown()
    }
}
