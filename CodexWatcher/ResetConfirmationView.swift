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
                cardTitle: credit.map { format.creditTitle($0.title) } ?? String(localized: "上次选择的重置卡"),
                account: hideEmail ? String(localized: "已隐藏") : (confirmation.email ?? String(localized: "未提供邮箱")),
                quotaTitle: window.map { format.quotaDuration($0.quota.windowDurationMins) } ?? String(localized: "当前用量"),
                usage: window.map { String(format: String(localized: "已用 %@ · 剩余 %@"), format.percent($0.quota.usedPercent), format.percent(max(0, 100 - $0.quota.usedPercent))) } ?? String(localized: "暂无数据"),
                expiry: credit?.expiryDate.map { format.date($0, precise: true) + ($0 <= now ? String(localized: "（已到期）") : "") } ?? (credit == nil ? String(localized: "详情暂不可用") : String(localized: "未提供")),
                updated: current ? monitor.lastUpdated.map { format.date($0, timeOnly: Calendar.autoupdatingCurrent.isDateInToday($0)) } : nil,
                blockingReason: !current ? String(localized: "操作已变化，请取消后重新打开。") : (canConfirm ? nil : (monitor.isBusy ? String(localized: "正在更新，请稍候。") : (!retry && monitor.isStale(at: now) ? String(localized: "用量已失效，请取消并刷新。") : String(localized: "当前不可用，请取消并刷新。")))),
                canConfirm: canConfirm,
                cancel: cancel,
                confirm: {
                    guard monitor.canConfirmRedemption(confirmation, at: .now) else { return }
                    confirm()
                })
        }
    }
}
