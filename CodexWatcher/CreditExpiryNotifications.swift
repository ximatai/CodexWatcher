import AppKit
import UserNotifications

/// Notification clicks only open the existing confirmation flow; never redeem here.
@MainActor
final class CreditExpiryNotifications: NSObject, CreditExpiryNotificationService, UNUserNotificationCenterDelegate {
    private let center = UNUserNotificationCenter.current()
    private let openReview: (String, String) -> Void

    init(openReview: @escaping (String, String) -> Void) {
        self.openReview = openReview
        super.init()
        center.delegate = self
        let review = UNNotificationAction(identifier: "review-expiry", title: "查看并确认", options: [.foreground])
        center.setNotificationCategories([UNNotificationCategory(identifier: "credit-expiry",
            actions: [review], intentIdentifiers: [], options: [])])
    }

    func requestPermission() async -> Bool {
        (try? await center.requestAuthorization(options: [.alert, .sound])) == true
    }

    func deliver(_ reminder: CreditExpiryReminder) async throws {
        let settings = await center.notificationSettings()
        guard settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional else {
            throw WatcherError.message("通知权限不可用。")
        }
        let content = UNMutableNotificationContent()
        content.title = "重置卡即将到期"
        content.body = "有重置卡将在 15 分钟内到期。点击查看用量与有效期，确认后使用。"
        content.sound = .default
        content.categoryIdentifier = "credit-expiry"
        content.userInfo = ["accountKey": reminder.accountKey, "creditID": reminder.creditID]
        try await center.add(UNNotificationRequest(identifier: reminder.identifier, content: content, trigger: nil))
    }

    func clear() {
        center.removeAllPendingNotificationRequests()
        center.removeAllDeliveredNotifications()
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
        willPresent notification: UNNotification, withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound, .list])
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse, withCompletionHandler completionHandler: @escaping () -> Void) {
        let values = response.notification.request.content.userInfo
        let owner = values["accountKey"] as? String
        let credit = values["creditID"] as? String
        let action = response.actionIdentifier
        Task { @MainActor [weak self] in
            if action == UNNotificationDefaultActionIdentifier || action == "review-expiry",
               let owner, let credit {
                self?.openReview(owner, credit)
            }
            completionHandler()
        }
    }
}
