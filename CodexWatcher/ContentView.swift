import SwiftUI
import AppKit

struct ContentView: View {
    @Bindable var monitor: UsageMonitor
    var handlesExpiryReminders = false
    var openDashboard: () -> Void = {}
    @AppStorage("appearance") private var appearance = AppAppearance.system.rawValue

    var body: some View {
        DashboardContent(monitor: monitor, appearance: $appearance, handlesExpiryReminders: handlesExpiryReminders, openDashboard: openDashboard)
            .onAppear { applyAppearance() }
            .onChange(of: appearance) { _, _ in applyAppearance() }
    }

    private func applyAppearance() {
        (AppAppearance(rawValue: appearance) ?? .system).apply(to: NSApplication.shared)
    }
}

private struct DashboardContent: View {
    @Environment(\.locale) private var locale
    @Environment(\.timeZone) private var timeZone
    @Environment(\.colorScheme) private var colorScheme
    @Bindable var monitor: UsageMonitor
    @Binding var appearance: String
    @AppStorage("privacyMode") private var privacyMode = false
    let handlesExpiryReminders: Bool
    let openDashboard: () -> Void
    @State private var resetConfirmation: ResetConfirmation?
    @State private var showingMenuBarSettings = false
    @State private var showingExpirySettings = false
    @State private var expiryReviewQueue = CreditExpiryReviewQueue()
    @FocusState private var quitButtonFocused: Bool
    private let loginItem = LoginItemController.shared
    private var format: PresentationFormat { PresentationFormat(locale: locale, timeZone: timeZone) }
    private var palette: AppPalette { AppPalette(dark: colorScheme == .dark) }

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            VStack(spacing: 0) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        header
                        separator
                        if monitor.account?.type == "chatgpt" {
                            if let window = monitor.selectedWindow {
                                usageSection(window, date: context.date)
                            } else {
                                ContentUnavailableView("暂无额度数据", systemImage: "gauge.with.dots.needle.0percent",
                                                       description: Text("刷新后将显示账号提供的额度窗口。"))
                            }
                            separator
                            creditsSection(date: context.date)
                        } else {
                            welcome
                        }
                        if let error = monitor.errorMessage {
                            statusMessage(error, symbol: "exclamationmark.triangle", color: palette.warning)
                        }
                        if let notice = monitor.notice {
                            statusMessage(notice, symbol: "checkmark.circle", color: palette.accent)
                        }
                    }
                    .padding(.horizontal, 22)
                    .padding(.top, 20)
                    .padding(.bottom, 12)
                }
                footer
            }
            .frame(width: 390, height: monitor.account == nil ? 440 : 660)
            .background(palette.background)
            .foregroundStyle(.primary)
            .tint(palette.accent)
        }
        .sheet(isPresented: $showingMenuBarSettings, onDismiss: finishExpiryReviewDismissal) {
            MenuBarSettingsView(monitor: monitor)
        }
        .sheet(isPresented: $showingExpirySettings, onDismiss: finishExpiryReviewDismissal) {
            CreditExpirySettingsView(monitor: monitor)
        }
        .onChange(of: monitor.expiryReview, initial: true) { _, review in
            guard handlesExpiryReminders, let review else { return }
            expiryReviewQueue.enqueue(review, dismissingSheet:
                showingExpirySettings || showingMenuBarSettings || resetConfirmation != nil)
            if showingExpirySettings { showingExpirySettings = false }
            else if showingMenuBarSettings { showingMenuBarSettings = false }
            else if resetConfirmation != nil { resetConfirmation = nil }
            else { showPendingExpiryReview() }
        }
        .onChange(of: monitor.isBusy) { _, busy in
            if !busy { showPendingExpiryReview() }
        }
        .sheet(item: $resetConfirmation, onDismiss: finishExpiryReviewDismissal) { confirmation in
            ResetConfirmationView(monitor: monitor, confirmation: confirmation,
                cancel: { resetConfirmation = nil },
                confirm: {
                    resetConfirmation = nil
                    Task { await monitor.redeem(confirmation) }
                })
        }
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didWakeNotification)) { _ in
            Task { await monitor.refresh() }
        }
        .task { await monitor.refresh() }
    }

    private func finishExpiryReviewDismissal() {
        expiryReviewQueue.isDismissingSheet = false
        showPendingExpiryReview()
    }

    private func showPendingExpiryReview() {
        guard handlesExpiryReminders, !showingExpirySettings, !showingMenuBarSettings,
              resetConfirmation == nil else { return }
        if let target = expiryReviewQueue.nextConfirmation(using: monitor) {
            resetConfirmation = target
        }
    }

    private var separator: some View {
        Rectangle().fill(palette.separator).frame(height: 1)
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image("AppBrand")
                .resizable()
                .interpolation(.high)
                .frame(width: 42, height: 42)
                .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 5) {
                Text("Codex Watcher").font(.system(size: 19, weight: .semibold))
                HStack(spacing: 7) {
                    Text(monitor.account?.email ?? "掌握额度，安排节奏")
                        .font(.caption).foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.middle)
                        .privacyMasked(privacyMode && monitor.account != nil)
                    if let account = monitor.account {
                        Text(account.planDisplayName)
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(palette.accent)
                            .padding(.horizontal, 7).padding(.vertical, 3)
                            .background(palette.accent.opacity(0.12), in: Capsule())
                    }
                }
            }
            Spacer(minLength: 0)
            Button { Task { await monitor.refresh() } } label: {
                ZStack {
                    if monitor.isBusy { ProgressView().controlSize(.small) }
                    else { Image(systemName: "arrow.clockwise").font(.system(size: 15, weight: .medium)) }
                }
                .frame(width: 30, height: 30)
                .background(palette.surface, in: Circle())
            }
            .buttonStyle(.plain)
            .modifier(ControlHoverFeedback(color: palette.accent, cornerRadius: 15))
            .disabled(monitor.isBusy)
            .help("刷新额度").accessibilityLabel("刷新额度")
        }
    }

    private var welcome: some View {
        VStack(spacing: 18) {
            Image(systemName: "chart.line.uptrend.xyaxis.circle")
                .font(.system(size: 56, weight: .ultraLight)).foregroundStyle(palette.accent)
            Text("让用量跟上你的节奏").font(.title3.weight(.semibold))
            Text("连接 ChatGPT 账号，查看剩余额度、\n时间进度与重置卡有效期。")
                .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
            if monitor.loginID != nil {
                Label("等待浏览器完成登录…", systemImage: "safari").font(.callout)
                HStack {
                    Button("重新打开浏览器") {
                        if let url = monitor.loginURL { NSWorkspace.shared.open(url) }
                    }
                    Button("取消") { Task { await monitor.cancelLogin() } }
                }
            } else {
                Button { Task { await monitor.login() } } label: {
                    Label("使用 ChatGPT 连接", systemImage: "arrow.up.right.square")
                        .frame(maxWidth: .infinity).padding(.vertical, 5)
                }.buttonStyle(.borderedProminent).disabled(monitor.isBusy)
            }
            Text("在官方页面登录 · 凭证保存在本机")
                .font(.caption2).foregroundStyle(.secondary)
        }.frame(maxWidth: .infinity).padding(.vertical, 16)
    }

    private func usageSection(_ window: UsageWindow, date: Date) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text(format.quotaDuration(window.quota.windowDurationMins)).font(.headline)
                Spacer()
                if monitor.isStale(at: date) {
                    Label("待更新", systemImage: "clock").font(.caption).foregroundStyle(palette.warning)
                }
                if monitor.windows.count > 1 {
                    Picker("额度", selection: Binding(get: { monitor.selectedWindow?.id ?? "" },
                                                     set: { monitor.selectedWindowID = $0 })) {
                        ForEach(monitor.windows) { item in
                            Text("\(item.name) · \(format.quotaDuration(item.quota.windowDurationMins))").tag(item.id)
                        }
                    }.labelsHidden().frame(maxWidth: 210)
                }
            }
            HStack(spacing: 20) {
                quotaNumber("已用", value: format.percent(window.quota.usedPercent), color: .primary)
                Rectangle().fill(palette.separator).frame(width: 1, height: 54)
                quotaNumber("剩余额度", value: format.percent(max(0, 100 - window.quota.usedPercent)), color: palette.accent)
            }
            let standard = window.quota.standardPercent(at: date)
            VStack(alignment: .leading, spacing: 7) {
                GeometryReader { geometry in
                    ZStack(alignment: .leading) {
                        Capsule().fill(palette.track).frame(height: 8)
                        Capsule().fill(palette.accent)
                            .frame(width: geometry.size.width * min(100, max(0, window.quota.usedPercent)) / 100, height: 8)
                        if let standard {
                            Capsule().fill(Color.primary.opacity(0.8)).frame(width: 2, height: 15)
                                .offset(x: min(geometry.size.width - 2, geometry.size.width * standard / 100))
                        }
                    }.frame(height: 16)
                }.frame(height: 16)
                Text("刻度表示自然时间进度")
                    .font(.system(size: 10)).foregroundStyle(.secondary)
            }
            HStack(alignment: .top, spacing: 20) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("标准用量").font(.caption).foregroundStyle(.secondary)
                    Text(standard.map { format.percent($0, decimals: 1) } ?? "暂不可算")
                        .font(.system(size: 22, weight: .semibold)).monospacedDigit()
                }.frame(maxWidth: .infinity, alignment: .leading)
                let deviation = monitor.isStale(at: date) ? nil : window.quota.deviation(at: date)
                VStack(alignment: .leading, spacing: 5) {
                    Text("用量偏移").font(.caption).foregroundStyle(.secondary)
                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                        Text(deviation.map { format.number($0, decimals: 1, signed: true) } ?? "待更新")
                            .font(.system(size: 22, weight: .semibold)).monospacedDigit()
                        if deviation != nil { Text("个百分点").font(.system(size: 10)) }
                    }.foregroundStyle((deviation ?? 0) > 5 ? palette.warning : palette.accent)
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
            .help("标准用量按自然时间均匀分配，包含睡眠和休息时间。正偏移表示消耗超前。")
            separator
            if let reset = window.quota.resetDate {
                HStack(alignment: .top, spacing: 20) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("下次重置时间").font(.caption).foregroundStyle(.secondary)
                        Text(format.date(reset)).font(.system(size: 12, weight: .medium))
                            .lineLimit(1).minimumScaleFactor(0.8)
                            .help(format.date(reset, precise: true))
                    }.frame(maxWidth: .infinity, alignment: .leading)
                    VStack(alignment: .leading, spacing: 6) {
                        Text("距离重置还有").font(.caption).foregroundStyle(.secondary)
                        Text(reset > date ? format.duration(reset.timeIntervalSince(date)) : "等待更新")
                            .font(.system(size: 13, weight: .semibold)).foregroundStyle(palette.accent)
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    private func quotaNumber(_ title: String, value: String, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.system(size: 46, weight: .semibold))
                .monospacedDigit().foregroundStyle(color).lineLimit(1).minimumScaleFactor(0.7)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }

    private func creditsSection(date: Date) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("重置卡").font(.headline)
                Spacer()
                Text(monitor.snapshot?.rateLimitResetCredits.map { "\(format.number(Double($0.availableCount))) 张可用" } ?? "信息未提供")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let message = monitor.expiryHandlingMessage {
                Text(message).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if monitor.pendingRedemption != nil {
                statusMessage("上次重置结果尚未确认，请先核实。", symbol: "exclamationmark.circle", color: palette.warning)
                Button("重试上次重置") {
                    resetConfirmation = monitor.makeResetConfirmation(for: nil)
                }.disabled(monitor.isBusy)
            }
            if !monitor.sortedCredits.isEmpty {
                VStack(spacing: 0) {
                    ForEach(Array(monitor.sortedCredits.enumerated()), id: \.element.id) { index, credit in
                        creditRow(credit, date: date)
                        if index < monitor.sortedCredits.count - 1 { separator.padding(.leading, 48) }
                    }
                }
                .background(palette.surface, in: RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(palette.separator))
                .clipShape(RoundedRectangle(cornerRadius: 12))
            }
            if let summary = monitor.snapshot?.rateLimitResetCredits {
                if summary.availableCount == 0 {
                    Text("暂无可用重置卡").font(.caption).foregroundStyle(.secondary)
                } else if summary.credits == nil || monitor.sortedCredits.count < summary.availableCount {
                    Text("服务器未提供全部卡片详情。").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    private func creditRow(_ credit: ResetCredit, date: Date) -> some View {
        let urgency = format.creditExpiryUrgency(credit.expiryDate, at: date)
        return HStack(spacing: 10) {
            ResetTicketShape()
                .stroke(style: StrokeStyle(lineWidth: 1.8, lineCap: .round, lineJoin: .round))
                .frame(width: 21, height: 15)
                .rotationEffect(.degrees(-18))
                .foregroundStyle(.secondary)
                .frame(width: 26, height: 28)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 5) {
                    Text(format.creditTitle(credit.title)).font(.system(size: 12, weight: .medium))
                        .lineLimit(1)
                    if let urgency {
                        let color = palette.creditExpiryColor(urgency)
                        Text(urgency.title)
                            .font(.system(size: 8, weight: .medium))
                            .foregroundStyle(color)
                            .padding(.horizontal, 5).padding(.vertical, 2)
                            .background(color.opacity(0.12), in: Capsule())
                            .fixedSize()
                    }
                }
                if let expiry = credit.expiryDate {
                    Text(expiry > date ? "\(format.date(expiry)) 到期" : "已到期，等待刷新")
                        .foregroundStyle(.secondary)
                        .help(format.date(expiry, precise: true))
                } else { Text("有效期未提供").foregroundStyle(.secondary) }
            }.font(.system(size: 10)).frame(maxWidth: .infinity, alignment: .leading)
            Button("使用") { resetConfirmation = monitor.makeResetConfirmation(for: credit) }
                .font(.system(size: 11, weight: .medium))
                .buttonStyle(.bordered).controlSize(.small).tint(.secondary)
                .modifier(ControlHoverFeedback(color: palette.accent))
                .disabled(monitor.isBusy || !monitor.canRedeem || !credit.isUsable(at: date)
                          || monitor.pendingRedemption != nil || monitor.isStale(at: date))
                .help("查看当前用量与卡片有效期，确认后使用")
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
    }

    private func statusMessage(_ text: String, symbol: String, color: Color) -> some View {
        Label(text, systemImage: symbol).font(.caption).foregroundStyle(color)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var footer: some View {
        VStack(spacing: 0) {
            separator.padding(.horizontal, 22)
            HStack(alignment: .center, spacing: 8) {
                VStack(alignment: .leading, spacing: 3) {
                    if let updated = monitor.lastUpdated {
                        Text("更新于 \(format.date(updated, timeOnly: Calendar.autoupdatingCurrent.isDateInToday(updated)))")
                    }
                    Text("每 5 分钟刷新 · 独立第三方工具")
                }.font(.system(size: 10)).foregroundStyle(.secondary)
                Spacer(minLength: 0)
                Menu {
                    Button("状态栏显示…") { showingMenuBarSettings = true }
                    Button("重置卡临期处理…") { showingExpirySettings = true }
                    Toggle(isOn: $privacyMode) { Label("隐藏邮箱", systemImage: "eye.slash") }
                    Picker("外观", selection: $appearance) {
                        ForEach(AppAppearance.allCases) { option in
                            Text(option.title).tag(option.rawValue)
                        }
                    }
                    Divider()
                    Toggle(loginItem.title, isOn: Binding(
                        get: { loginItem.isRequested }, set: { loginItem.requestEnabled($0) }))
                    if loginItem.needsApproval {
                        Button("在系统设置中允许…") { loginItem.openSystemSettings() }
                    }
                    Divider()
                    Button("打开独立窗口", action: openDashboard)
                    Button("选择 Codex CLI…") { Task { await monitor.chooseExecutable() } }
                    if monitor.account != nil {
                        Divider()
                        Button("退出账号") { Task { await monitor.logout() } }
                    }
                } label: {
                    Image(systemName: "gearshape").font(.system(size: 14))
                }
                .menuStyle(.borderlessButton).fixedSize()
                .accessibilityIdentifier("dashboard-settings")
                .modifier(ControlHoverFeedback(color: palette.accent))
                .disabled(monitor.isBusy || monitor.loginID != nil).help("设置与外观")
                Button { NSApplication.shared.terminate(nil) } label: {
                    Image(systemName: "power").font(.system(size: 14)).frame(width: 28, height: 28)
                }.buttonStyle(.plain).foregroundStyle(.secondary).help("退出应用").accessibilityLabel("退出应用")
                    .focused($quitButtonFocused)
                    .focusEffectDisabled()
                    .modifier(ControlHoverFeedback(color: palette.accent))
                    .overlay {
                        RoundedRectangle(cornerRadius: 6)
                            .strokeBorder(palette.accent, lineWidth: 2)
                            .opacity(quitButtonFocused ? 1 : 0)
                            .allowsHitTesting(false)
                    }
            }
            .padding(.horizontal, 22)
            .frame(height: 54)
        }
        .background(palette.background)
    }
}

private struct ControlHoverFeedback: ViewModifier {
    let color: Color
    var cornerRadius: CGFloat = 6
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hovering = false

    func body(content: Content) -> some View {
        content
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius)
                    .fill(color.opacity(hovering && isEnabled ? 0.09 : 0))
                    .overlay {
                        RoundedRectangle(cornerRadius: cornerRadius)
                            .strokeBorder(color.opacity(hovering && isEnabled ? 0.35 : 0))
                    }
                    .allowsHitTesting(false)
            }
            .onHover { hovering = $0 }
            .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: hovering && isEnabled)
    }
}

private struct ResetTicketShape: Shape {
    func path(in rect: CGRect) -> Path {
        let corner: CGFloat = 2
        let notch: CGFloat = 2.5
        let midY = rect.midY
        return Path { path in
            path.move(to: CGPoint(x: corner, y: 0))
            path.addLine(to: CGPoint(x: rect.width - corner, y: 0))
            path.addQuadCurve(to: CGPoint(x: rect.width, y: corner), control: CGPoint(x: rect.width, y: 0))
            path.addLine(to: CGPoint(x: rect.width, y: midY - notch))
            path.addCurve(to: CGPoint(x: rect.width, y: midY + notch),
                          control1: CGPoint(x: rect.width - notch * 1.4, y: midY - notch),
                          control2: CGPoint(x: rect.width - notch * 1.4, y: midY + notch))
            path.addLine(to: CGPoint(x: rect.width, y: rect.height - corner))
            path.addQuadCurve(to: CGPoint(x: rect.width - corner, y: rect.height), control: CGPoint(x: rect.width, y: rect.height))
            path.addLine(to: CGPoint(x: corner, y: rect.height))
            path.addQuadCurve(to: CGPoint(x: 0, y: rect.height - corner), control: CGPoint(x: 0, y: rect.height))
            path.addLine(to: CGPoint(x: 0, y: midY + notch))
            path.addCurve(to: CGPoint(x: 0, y: midY - notch),
                          control1: CGPoint(x: notch * 1.4, y: midY + notch),
                          control2: CGPoint(x: notch * 1.4, y: midY - notch))
            path.addLine(to: CGPoint(x: 0, y: corner))
            path.addQuadCurve(to: CGPoint(x: corner, y: 0), control: .zero)
            path.closeSubpath()
        }
    }
}
