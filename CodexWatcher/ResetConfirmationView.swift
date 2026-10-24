import SwiftUI

struct ResetConfirmationView: View {
    @Bindable var monitor: UsageMonitor
    let confirmation: ResetConfirmation
    let cancel: () -> Void
    let confirm: () -> Void
    @AppStorage("privacyMode") private var hideEmail = false
    @Environment(\.locale) private var locale
    @Environment(\.timeZone) private var timeZone

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            let now = max(context.date, max(monitor.displayDate, Date()))
            let format = PresentationFormat(locale: locale, timeZone: timeZone)
            let retry = confirmation.retry != nil
            let current = monitor.isResetConfirmationCurrent(confirmation)
            let credit = current ? (monitor.sortedCredits.first { $0.id == confirmation.creditID } ?? confirmation.credit) : confirmation.credit
            let window = current ? monitor.windows.first { $0.id == confirmation.windowID } : nil
            let canConfirm = monitor.canConfirmRedemption(confirmation, at: now)
            ResetConfirmationContent(
                isRetry: retry,
                cardTitle: credit.map { format.creditTitle($0.title) } ?? "上次选择的重置卡",
                account: hideEmail ? "已隐藏" : (confirmation.email ?? "未提供邮箱"),
                quotaTitle: window.map { format.quotaDuration($0.quota.windowDurationMins) } ?? "当前用量",
                usage: window.map { "已用 \(format.percent($0.quota.usedPercent)) · 剩余 \(format.percent(max(0, 100 - $0.quota.usedPercent)))" } ?? "暂无数据",
                expiry: credit?.expiryDate.map { format.date($0, precise: true) + ($0 <= now ? "（已到期）" : "") } ?? (credit == nil ? "详情暂不可用" : "未提供"),
                updated: current ? monitor.lastUpdated.map { format.date($0, timeOnly: Calendar.autoupdatingCurrent.isDateInToday($0)) } : nil,
                blockingReason: !current ? "操作已变化，请取消后重新打开。" : (canConfirm ? nil : (monitor.isBusy ? "正在更新，请稍候。" : (!retry && monitor.isStale(at: now) ? "用量已失效，请取消并刷新。" : "当前不可用，请取消并刷新。"))),
                canConfirm: canConfirm,
                cancel: cancel,
                confirm: {
                    guard monitor.canConfirmRedemption(confirmation, at: .now) else { return }
                    confirm()
                })
        }
    }
}
