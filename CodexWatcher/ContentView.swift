import SwiftUI
import AppKit

enum DashboardSettingsPage {
    case menuBar, creditExpiry, automaticHello
}

struct ContentView: View {
    @Bindable var monitor: UsageMonitor
    var updates: ReleaseUpdateChecker? = nil
    var dismissForUpdate: () -> Void = {}
    var handlesExpiryReminders = false
    var openDashboard: () -> Void = {}
    var presentSettings: ((DashboardSettingsPage) -> Void)?
    var presentReset: ((ResetConfirmation) -> Void)?
    var flexibleSize = false
    var maximumHeight: CGFloat = 660
    var initiallyShowingTrend = false
    var initiallyHoveringProgress = false
    private let presentationID = UUID()
    @AppStorage("appearance") private var appearance = AppAppearance.system.rawValue

    var body: some View {
        DashboardContent(monitor: monitor, updates: updates, dismissForUpdate: dismissForUpdate, appearance: $appearance, handlesExpiryReminders: handlesExpiryReminders, openDashboard: openDashboard, presentSettings: presentSettings, presentReset: presentReset, flexibleSize: flexibleSize, maximumHeight: maximumHeight, presentationID: presentationID, showingUsageTrend: initiallyShowingTrend, hoveringProgress: initiallyHoveringProgress)
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
    var updates: ReleaseUpdateChecker?
    let dismissForUpdate: () -> Void
    @Binding var appearance: String
    @AppStorage("privacyMode") private var privacyMode = false
    let handlesExpiryReminders: Bool
    let openDashboard: () -> Void
    let presentSettings: ((DashboardSettingsPage) -> Void)?
    let presentReset: ((ResetConfirmation) -> Void)?
    let flexibleSize: Bool
    let maximumHeight: CGFloat
    let presentationID: UUID
    @State var showingUsageTrend = false
    @State var hoveringProgress = false
    @State private var hoveringReturnProgress = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @FocusState private var usageControlFocused: Bool
    @State private var usageFocusGeneration = UUID()
    @State private var contentHeights: [DashboardRegion: CGFloat] = [:]
    @State private var resetConfirmation: ResetConfirmation?
    @State private var showingMenuBarSettings = false
    @State private var showingExpirySettings = false
    @State private var showingHelloSettings = false
    @State private var expiryReviewQueue = CreditExpiryReviewQueue()
    @FocusState private var quitButtonFocused: Bool
    private let loginItem = LoginItemController.shared
    private var format: PresentationFormat { PresentationFormat(locale: locale, timeZone: timeZone) }
    private var palette: AppPalette { AppPalette(dark: colorScheme == .dark) }

    private var fittedHeight: CGFloat {
        let header = contentHeights[.header] ?? 100
        let body = contentHeights[.body] ?? 400
        let footer = contentHeights[.footer] ?? 49
        return min(maximumHeight, max(280, header + body + footer))
    }

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            VStack(spacing: 0) {
                VStack(spacing: 12) {
                    header
                    feedback
                    separator
                }
                .padding(.horizontal, 22).padding(.top, 20).padding(.bottom, 14)
                .fixedSize(horizontal: false, vertical: true)
                .dashboardHeight(.header)
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        if monitor.account?.type == "chatgpt" {
                            if let window = monitor.selectedWindow {
                                usageSection(window, date: context.date)
                            } else {
                                ContentUnavailableView("暂无额度数据", systemImage: "gauge.with.dots.needle.0percent")
                            }
                            separator
                            creditsSection(date: context.date)
                        } else {
                            welcome
                        }
                    }
                    .padding(.horizontal, 22).padding(.bottom, 16)
                    .fixedSize(horizontal: false, vertical: true)
                    .dashboardHeight(.body)
                }
                footer
                    .fixedSize(horizontal: false, vertical: true)
                    .dashboardHeight(.footer)
            }
            .frame(minWidth: 390, maxWidth: flexibleSize ? .infinity : 390)
            .frame(height: flexibleSize ? nil : fittedHeight)
            .frame(minHeight: flexibleSize ? 360 : nil)
            .background(palette.background)
            .foregroundStyle(.primary)
            .tint(palette.accent)
        }
        .onChange(of: presentationID) { _, _ in
            showingUsageTrend = false
            hoveringProgress = false
            hoveringReturnProgress = false
            usageControlFocused = false
            usageFocusGeneration = UUID()
        }
        .onPreferenceChange(DashboardHeightPreference.self) { heights in
            if !flexibleSize { contentHeights = heights }
        }
        .sheet(isPresented: $showingMenuBarSettings, onDismiss: finishExpiryReviewDismissal) {
            MenuBarSettingsView(monitor: monitor)
        }
        .sheet(isPresented: $showingExpirySettings, onDismiss: finishExpiryReviewDismissal) {
            CreditExpirySettingsView(monitor: monitor)
        }
        .sheet(isPresented: $showingHelloSettings, onDismiss: finishExpiryReviewDismissal) {
            AutomaticHelloSettingsView(monitor: monitor)
        }
        .onChange(of: monitor.expiryReview, initial: true) { _, review in
            guard handlesExpiryReminders, let review else { return }
            expiryReviewQueue.enqueue(review, dismissingSheet:
                showingExpirySettings || showingMenuBarSettings || showingHelloSettings || resetConfirmation != nil)
            if showingExpirySettings { showingExpirySettings = false }
            else if showingMenuBarSettings { showingMenuBarSettings = false }
            else if showingHelloSettings { showingHelloSettings = false }
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
        .task { await monitor.refresh(); monitor.scheduleAutomaticHelloCheck() }
    }

    private func finishExpiryReviewDismissal() {
        expiryReviewQueue.isDismissingSheet = false
        showPendingExpiryReview()
    }

    private func showPendingExpiryReview() {
        guard handlesExpiryReminders, !showingExpirySettings, !showingMenuBarSettings, !showingHelloSettings,
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
                if let account = monitor.account {
                    HStack(spacing: 7) {
                        if let email = account.email {
                            Text(email)
                                .font(.caption).foregroundStyle(.secondary)
                                .lineLimit(1).truncationMode(.middle)
                                .privacyMasked(privacyMode)
                        }
                        Text(account.planDisplayName)
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 7).padding(.vertical, 3)
                            .background(Color.primary.opacity(0.055), in: Capsule())
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
            if !monitor.executableAvailable {
                HStack(spacing: 16) {
                    Button("选择 Codex CLI…") { Task { await monitor.chooseExecutable() } }
                        .disabled(monitor.isBusy || monitor.loginID != nil)
                    Link("安装帮助", destination: URL(string: "https://github.com/ximatai/CodexWatcher#下载与安装")!)
                }.font(.callout)
            }
        }.frame(maxWidth: .infinity).padding(.vertical, 16)
    }

    private func windowTitle(_ window: UsageWindow) -> String {
        let duration = format.quotaDuration(window.quota.windowDurationMins)
        return Set(monitor.windows.map(\.bucketID)).count > 1 ? "\(window.name) · \(duration)" : duration
    }

    private func usageSection(_ window: UsageWindow, date: Date) -> some View {
        let stale = monitor.isStale(at: date)
        let standard = window.quota.standardPercent(at: date)
        let deviation = stale ? nil : window.quota.deviation(at: date)
        return VStack(alignment: .leading, spacing: 14) {
            if monitor.windows.count > 1 {
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)], spacing: 8) {
                    ForEach(monitor.windows) { item in
                        let selected = item.id == window.id
                        Button { monitor.selectedWindowID = item.id } label: {
                            HStack(spacing: 8) {
                                VStack(alignment: .leading, spacing: 5) {
                                    Text(windowTitle(item)).font(.system(size: 11, weight: .medium))
                                        .lineLimit(2).multilineTextAlignment(.leading)
                                    if !selected {
                                        Text(format.percent(item.quota.usedPercent))
                                            .font(.system(size: 18, weight: .semibold)).monospacedDigit()
                                    }
                                }
                                .frame(minHeight: 40, alignment: .leading)
                                Spacer(minLength: 0)
                                if selected {
                                    Image(systemName: "checkmark").font(.caption.weight(.semibold))
                                        .foregroundStyle(palette.accent)
                                }
                            }
                            .foregroundStyle(.primary)
                            .padding(10).frame(maxWidth: .infinity, alignment: .leading)
                            .background(selected ? palette.selectedSurface : palette.surface,
                                        in: RoundedRectangle(cornerRadius: 10))
                            .overlay(RoundedRectangle(cornerRadius: 10)
                                .strokeBorder(selected ? palette.selectedBorder : palette.separator))
                        }
                        .buttonStyle(.plain)
                        .help("\(windowTitle(item))，已用 \(format.percent(item.quota.usedPercent))")
                        .accessibilityLabel("\(windowTitle(item))，已用 \(format.percent(item.quota.usedPercent))")
                        .accessibilityAddTraits(selected ? [.isSelected] : [])
                    }
                }
            } else {
                Text(windowTitle(window)).font(.headline)
            }
            HStack(alignment: .firstTextBaseline) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(format.percent(window.quota.usedPercent))
                        .font(.system(size: 42, weight: .semibold)).monospacedDigit()
                        .lineLimit(1).minimumScaleFactor(0.8)
                    Text("已用").font(.callout).foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                Text("剩余 \(format.percent(max(0, 100 - window.quota.usedPercent)))")
                    .font(.callout.weight(.medium)).foregroundStyle(.secondary)
            }
            if showingUsageTrend {
                UsageTrendView(samples: monitor.trendHistory[window.id] ?? [], quota: window.quota,
                               date: date, stale: stale, storageFailed: monitor.trendStorageFailed,
                               recoveredHistory: monitor.trendStorageRecovered, headerAction: AnyView(
                    Button {
                        changeUsagePresentation(false)
                    } label: {
                        Label("返回进度", systemImage: "arrow.left")
                            .font(.system(size: 11, weight: .medium))
                            .padding(.horizontal, 6).padding(.vertical, 5)
                            .background(hoveringReturnProgress ? palette.selectedSurface : .clear,
                                        in: RoundedRectangle(cornerRadius: 8))
                            .overlay(RoundedRectangle(cornerRadius: 8)
                                .strokeBorder(usageControlFocused ? palette.accent.opacity(0.3) : .clear, lineWidth: 0.75))
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(palette.accent)
                    .focused($usageControlFocused)
                    .focusEffectDisabled()
                    .onHover { hoveringReturnProgress = $0 }
                    .background {
                        if CommandLine.arguments.contains("--release-smoke-test") {
                            UsageInteractionAnchor(name: "quota-trend-return", focused: usageControlFocused,
                                                   requestFocus: { usageControlFocused = true })
                        }
                    }
                ))
                .transition(.opacity)
            } else {
                Button {
                    changeUsagePresentation(true)
                } label: {
                    HStack(spacing: 10) {
                        GeometryReader { geometry in
                            ZStack(alignment: .leading) {
                                Capsule().fill(palette.track).frame(height: 7)
                                Capsule().fill(palette.accent)
                                    .frame(width: geometry.size.width * min(100, max(0, window.quota.usedPercent)) / 100, height: 7)
                                if let standard {
                                    Capsule().fill(Color.primary.opacity(0.8)).frame(width: 2, height: 15)
                                        .offset(x: min(geometry.size.width - 2, geometry.size.width * standard / 100))
                                }
                            }
                            .frame(width: geometry.size.width, height: geometry.size.height)
                        }
                        .frame(height: 24)
                    }
                    .padding(.horizontal, 8).padding(.vertical, 6)
                    .background(hoveringProgress ? palette.selectedSurface : .clear,
                                in: RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(usageControlFocused ? palette.accent.opacity(0.3) : .clear, lineWidth: 0.75))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .focused($usageControlFocused)
                .focusEffectDisabled()
                .onHover { hoveringProgress = $0 }
                .background {
                    if CommandLine.arguments.contains("--release-smoke-test") {
                        UsageInteractionAnchor(name: "quota-progress", focused: usageControlFocused,
                                               requestFocus: { usageControlFocused = true })
                    }
                }
                .help("点击查看趋势；刻度为参考进度，按额度周期的自然时间计算。")
                .accessibilityLabel("查看额度趋势")
                .accessibilityValue("已用 \(format.percent(window.quota.usedPercent))；参考进度 \(standard.map { format.percent($0) } ?? "未知")；较参考进度 \(deviation.map { format.deviation($0) } ?? "待更新")")
                .accessibilityHint("切换到剩余额度趋势面板")
                // Expand the hit area outward; keep the track aligned with the content edges.
                .padding(.horizontal, -8)
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 5) {
                        Text("参考进度").font(.caption).foregroundStyle(.secondary)
                            .help("按额度周期的自然时间计算，包含睡眠和休息时间。")
                        Text(standard.map { format.percent($0, decimals: 1) } ?? "—")
                            .font(.system(size: 20, weight: .semibold)).monospacedDigit()
                    }
                    Spacer()
                    VStack(alignment: .trailing, spacing: 5) {
                        Text(deviation.map { $0 >= 0 ? "消耗超前" : "消耗滞后" } ?? "较参考进度")
                            .font(.caption).foregroundStyle(.secondary)
                        Text(deviation.map { format.deviation(abs($0), signed: false) } ?? "待更新")
                            .font(.system(size: 16, weight: .semibold)).monospacedDigit()
                            .foregroundStyle(palette.deviationColor(deviation))
                    }
                }
                .help("实际用量减去参考进度，单位为百分点。")
            }
            if let reset = window.quota.resetDate {
                HStack(alignment: .firstTextBaseline) {
                    Label(reset > date ? "\(format.duration(reset.timeIntervalSince(date)))后重置" : "等待重置更新",
                          systemImage: "arrow.clockwise")
                        .font(.system(size: 12, weight: .medium))
                    Spacer(minLength: 8)
                    Text(format.compactDate(reset)).font(.system(size: 11)).foregroundStyle(.secondary)
                }.help(format.date(reset, precise: true))
            }
            if stale && monitor.errorMessage == nil {
                HStack {
                    Label("数据待更新", systemImage: "clock").foregroundStyle(palette.warning)
                    Spacer()
                    Button("刷新") { Task { await monitor.refresh() } }.disabled(monitor.isBusy)
                }.font(.caption)
            }
        }
    }

    private func changeUsagePresentation(_ trend: Bool) {
        let pointerEvents: Set<NSEvent.EventType> = [.leftMouseDown, .leftMouseUp, .rightMouseDown,
                                                    .rightMouseUp, .otherMouseDown, .otherMouseUp]
        let pointerActivation = NSApp.currentEvent.map { pointerEvents.contains($0.type) } ?? false
        let restoreKeyboardFocus = usageControlFocused && !pointerActivation
        usageControlFocused = false
        hoveringProgress = false
        hoveringReturnProgress = false
        let focusGeneration = UUID()
        usageFocusGeneration = focusGeneration
        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.16), completionCriteria: .removed) {
            showingUsageTrend = trend
        } completion: {
            // Restoring during the outgoing view's animation can leave the binding
            // focused while AppKit has already discarded its actual responder.
            guard restoreKeyboardFocus else { return }
            Task { @MainActor in
                await Task.yield()
                guard usageFocusGeneration == focusGeneration, showingUsageTrend == trend else { return }
                usageControlFocused = true
            }
        }
    }

    private func creditsSection(date: Date) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("重置卡").font(.headline)
                Spacer()
                Button { showSettings(.creditExpiry) } label: {
                    Image(systemName: monitor.expiryConfiguration.mode == .automatic ? "bolt.badge.clock" : "bell")
                }
                .buttonStyle(.plain).foregroundStyle(.secondary)
                .help(monitor.expiryStatusTitle).accessibilityLabel("重置卡临期处理，\(monitor.expiryStatusTitle)")
                Text(monitor.snapshot?.rateLimitResetCredits.map { "\(format.number(Double($0.availableCount))) 张可用" } ?? "信息未提供")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if monitor.expiryConfiguration.mode != .off {
                HStack {
                    Text(monitor.expiryStatusTitle)
                    Spacer()
                    if let retryDate = monitor.automaticRetryDate {
                        Text("最早 \(format.date(retryDate, timeOnly: true))")
                    }
                }.font(.caption).foregroundStyle(.secondary)
            }
            if monitor.pendingRedemption != nil {
                statusMessage("上次重置结果未确认", symbol: "exclamationmark.circle", color: palette.warning)
                Button("重试上次重置") {
                    showReset(monitor.makeResetConfirmation(for: nil))
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
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(color)
                            .padding(.horizontal, 5).padding(.vertical, 2)
                            .background(color.opacity(0.12), in: Capsule())
                            .fixedSize()
                    }
                }
                if let expiry = credit.expiryDate {
                    Text(expiry > date ? "\(format.compactDate(expiry)) 到期" : "已到期，等待刷新")
                        .foregroundStyle(.secondary)
                        .help(format.date(expiry, precise: true))
                } else { Text("有效期未提供").foregroundStyle(.secondary) }
            }.font(.system(size: 11)).frame(maxWidth: .infinity, alignment: .leading)
            Button("使用") { showReset(monitor.makeResetConfirmation(for: credit)) }
                .font(.system(size: 11, weight: .medium))
                .buttonStyle(.bordered).controlSize(.small).tint(.secondary)
                .modifier(ControlHoverFeedback(color: palette.accent))
                .disabled(monitor.redemptionBlockingReason(for: credit, at: date) != nil)
                .help(monitor.redemptionBlockingReason(for: credit, at: date) ?? "查看并确认使用")
                .accessibilityLabel("使用\(format.creditTitle(credit.title))")
                .accessibilityHint(monitor.redemptionBlockingReason(for: credit, at: date) ?? "打开确认页")
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
    }

    private func statusMessage(_ text: String, symbol: String, color: Color) -> some View {
        Label(text, systemImage: symbol).font(.caption).foregroundStyle(color)
            .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder private var feedback: some View {
        if monitor.isRedeeming {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("正在重置…").font(.callout)
                Spacer()
            }
        }
        if let notice = monitor.notice {
            HStack(alignment: .top) {
                statusMessage(notice,
                              symbol: monitor.noticeKind == .success ? "checkmark.circle" : (monitor.noticeKind == .warning ? "exclamationmark.circle" : "info.circle"),
                              color: monitor.noticeKind == .success ? palette.accent : (monitor.noticeKind == .warning ? palette.warning : .secondary))
                Spacer(minLength: 8)
                Button { monitor.dismissNotice() } label: {
                    Image(systemName: "xmark").font(.caption).frame(width: 20, height: 20)
                }.buttonStyle(.plain).foregroundStyle(.secondary).accessibilityLabel("关闭提示")
            }
        }
        if let error = monitor.errorMessage {
            VStack(alignment: .leading, spacing: 8) {
                statusMessage(error, symbol: "exclamationmark.triangle", color: palette.warning)
                HStack(spacing: 14) {
                    if !monitor.executableAvailable {
                        Button("选择 CLI…") { Task { await monitor.chooseExecutable() } }
                            .disabled(monitor.isBusy || monitor.loginID != nil)
                    } else {
                        Button("重新读取") { Task { await monitor.refresh() } }.disabled(monitor.isBusy)
                    }
                }.font(.caption)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(10).background(palette.warning.opacity(0.07), in: RoundedRectangle(cornerRadius: 8))
        }
    }

    private func showSettings(_ page: DashboardSettingsPage) {
        if let presentSettings { presentSettings(page); return }
        switch page {
        case .menuBar: showingMenuBarSettings = true
        case .creditExpiry: showingExpirySettings = true
        case .automaticHello: showingHelloSettings = true
        }
    }

    private func showReset(_ confirmation: ResetConfirmation?) {
        guard let confirmation else { return }
        if let presentReset { presentReset(confirmation) }
        else { resetConfirmation = confirmation }
    }

    private var footer: some View {
        VStack(spacing: 0) {
            separator.padding(.horizontal, 22)
            HStack(alignment: .center, spacing: 8) {
                Group {
                    if let updated = monitor.lastUpdated {
                        Text("更新于 \(format.date(updated, timeOnly: Calendar.autoupdatingCurrent.isDateInToday(updated)))")
                    } else {
                        Text(monitor.isBusy ? "正在连接…" : "尚未连接")
                    }
                }
                .font(.system(size: 11)).foregroundStyle(.secondary)
                .help(monitor.expiryConfiguration.mode == .off && !monitor.automaticHelloConfiguration.enabled ? "每 5 分钟刷新" : "自动处理每 30 秒检查并刷新")
                Spacer(minLength: 0)
                Menu {
                    Button("状态栏显示…") { showSettings(.menuBar) }
                    Button("重置卡临期处理…") { showSettings(.creditExpiry) }
                    Button("满额自动 hello…") { showSettings(.automaticHello) }
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
                        .disabled(monitor.isBusy || monitor.loginID != nil)
                    if monitor.account != nil {
                        Divider()
                        Button("退出账号") { Task { await monitor.logout() } }
                            .disabled(monitor.isBusy || monitor.loginID != nil)
                    }
                    Divider()
                    if let updates {
                        if updates.availableVersion != nil {
                            Button(updates.menuTitle) { dismissForUpdate(); updates.openAvailableRelease() }
                        }
                        Button(updates.isChecking ? "正在检查更新…" : "检查更新…") {
                            dismissForUpdate()
                            Task { await updates.checkInteractively() }
                        }
                            .disabled(updates.isChecking)
                    }
                    Button("使用帮助") { NSWorkspace.shared.open(URL(string: "https://github.com/ximatai/CodexWatcher/blob/main/docs/USAGE.md")!) }
                    Button("关于 Codex Watcher") { NSApp.orderFrontStandardAboutPanel(nil) }
                } label: {
                    Image(systemName: "gearshape").font(.system(size: 14)).foregroundStyle(.secondary)
                }
                .menuStyle(.borderlessButton).tint(.secondary).fixedSize()
                .accessibilityIdentifier("dashboard-settings")
                .modifier(ControlHoverFeedback(color: palette.accent))
                .help("设置与外观").accessibilityLabel("设置与外观")
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
            .frame(height: 48)
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

// Measure intrinsic content inside the scroll view, never the viewport itself.
// This lets card counts, quota summaries and feedback all contribute to height.
private enum DashboardRegion: Hashable { case header, body, footer }

private struct DashboardHeightPreference: PreferenceKey {
    static var defaultValue: [DashboardRegion: CGFloat] = [:]
    static func reduce(value: inout [DashboardRegion: CGFloat], nextValue: () -> [DashboardRegion: CGFloat]) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
    }
}

private extension View {
    func dashboardHeight(_ region: DashboardRegion) -> some View {
        background(GeometryReader { geometry in
            Color.clear.preference(key: DashboardHeightPreference.self, value: [region: geometry.size.height])
        })
    }
}

// In-process geometry/focus probes for the isolated release fixture. Events still
// travel through the real SwiftUI buttons; the probes never intercept hit testing.
struct UsageInteractionAnchor: NSViewRepresentable {
    let name: String
    let focused: Bool
    let requestFocus: () -> Void
    func makeNSView(context: Context) -> UsageInteractionProbe { UsageInteractionProbe() }
    func updateNSView(_ view: UsageInteractionProbe, context: Context) {
        view.identifier = NSUserInterfaceItemIdentifier(name)
        view.controlFocused = focused
        view.requestControlFocus = requestFocus
    }
}

final class UsageInteractionProbe: NSView {
    var controlFocused = false
    var requestControlFocus: (() -> Void)?
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
