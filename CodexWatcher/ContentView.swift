import SwiftUI
import AppKit

struct ContentView: View {
    @Environment(\.openWindow) private var openWindow
    @Environment(\.locale) private var locale
    @Environment(\.timeZone) private var timeZone
    private var format: PresentationFormat { PresentationFormat(locale: locale, timeZone: timeZone) }
    @Bindable var monitor: UsageMonitor
    @State private var confirmingReset = false
    @State private var selectedCredit: ResetCredit?

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    header
                    if let account = monitor.account, account.type == "chatgpt" {
                        accountRow(account)
                        if let window = monitor.selectedWindow {
                            usageCard(window, date: context.date)
                        } else {
                            ContentUnavailableView("暂无额度数据", systemImage: "gauge.with.dots.needle.0percent",
                                                   description: Text("刷新后将显示账号提供的额度窗口。"))
                        }
                        creditsSection(date: context.date)
                    } else {
                        welcome
                    }
                    if let error = monitor.errorMessage {
                        message(error, symbol: "exclamationmark.triangle", color: .orange)
                    }
                    if let notice = monitor.notice {
                        message(notice, symbol: "checkmark.circle", color: .teal)
                    }
                    footer
                }
                .padding(22)
            }
            .frame(width: 410, height: monitor.account == nil ? 490 : 710)
            .background(Color(nsColor: .windowBackgroundColor))
        }
        .alert("使用一张重置卡？", isPresented: $confirmingReset) {
            Button("取消", role: .cancel) { selectedCredit = nil }
            Button(monitor.pendingRedemption == nil ? "消耗 1 张并重置" : "重试确认", role: .destructive) {
                let credit = selectedCredit
                Task { await monitor.redeem(credit) }
                selectedCredit = nil
            }
            .disabled(!monitor.canConfirmRedemption(selectedCredit, at: .now))
        } message: {
            Text(resetConfirmationMessage)
        }
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didWakeNotification)) { _ in
            Task { await monitor.refresh() }
        }
        .task { await monitor.refresh() }
    }

    private var resetConfirmationMessage: String {
        // Read the same clock that updates the menu, so an open alert rechecks freshness.
        let now = max(monitor.displayDate, Date())
        var sections: [String] = []
        if let email = monitor.account?.email { sections.append("当前账号：\(email)") }
        if let window = monitor.selectedWindow {
            sections.append("当前用量（\(window.name) · \(format.quotaDuration(window.quota.windowDurationMins))）：\n已用 \(format.percent(window.quota.usedPercent, decimals: 1))，剩余 \(format.percent(max(0, 100 - window.quota.usedPercent), decimals: 1))")
        } else { sections.append("当前用量：暂无数据") }
        if let updated = monitor.lastUpdated {
            sections.append("用量更新于：\(format.date(updated, precise: true))")
        }
        if let credit = selectedCredit {
            var card = "所选重置卡：\(format.creditTitle(credit.title))\n"
            if let expiry = credit.expiryDate {
                card += "到期时间：\(format.date(expiry, precise: true))"
                if expiry <= now { card += "（已到期）" }
            } else { card += "到期时间：服务器未提供" }
            sections.append(card)
        } else { sections.append("所选重置卡：详情暂不可用") }
        if monitor.pendingRedemption != nil {
            sections.append("将核实上次操作的结果，复用同一请求标识，不会重复消耗重置卡。")
        } else {
            if monitor.isStale(at: now) {
                sections.append("用量数据已失效，请取消并刷新后再使用。")
            } else if !monitor.canConfirmRedemption(selectedCredit, at: now), !monitor.isBusy {
                sections.append("所选卡片当前不可用，请取消并刷新后重试。")
            }
            sections.append("将消耗 1 张重置卡，重置服务器允许的额度窗口。实际范围可能包含其他额度窗口。此操作无法撤销。")
        }
        return sections.joined(separator: "\n\n")
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "gauge.with.dots.needle.50percent")
                .font(.title2).foregroundStyle(.teal)
                .frame(width: 40, height: 40)
                .background(.teal.opacity(0.1), in: RoundedRectangle(cornerRadius: 12))
            VStack(alignment: .leading, spacing: 3) {
                Text("Codex Watcher").font(.system(size: 18, weight: .semibold, design: .rounded))
                Text("掌握额度，安排节奏").font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if monitor.isBusy { ProgressView().controlSize(.small) }
            Button { Task { await monitor.refresh() } } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.borderless).disabled(monitor.isBusy)
            .help("刷新额度")
        }
    }

    private func accountRow(_ account: WatcherAccount) -> some View {
        HStack {
            Label(account.email ?? "已连接账号", systemImage: "person.crop.circle")
                .lineLimit(1).truncationMode(.middle)
            Spacer()
            Text(account.planDisplayName)
                .font(.caption2.weight(.semibold)).padding(.horizontal, 8).padding(.vertical, 4)
                .background(.teal.opacity(0.1), in: Capsule())
        }
        .font(.caption).foregroundStyle(.secondary)
    }

    private var welcome: some View {
        VStack(spacing: 18) {
            Image(systemName: "chart.line.uptrend.xyaxis.circle")
                .font(.system(size: 64, weight: .ultraLight)).foregroundStyle(.teal)
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
                }
                .buttonStyle(.borderedProminent).tint(.teal).disabled(monitor.isBusy)
            }
            Text("在官方页面登录 · 凭证保存在本机")
                .font(.caption2).foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity).padding(.vertical, 22)
    }

    private func usageCard(_ window: UsageWindow, date: Date) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Text(format.quotaDuration(window.quota.windowDurationMins)).font(.headline)
                Spacer()
                if monitor.isStale(at: date) {
                    Label("待更新", systemImage: "clock").foregroundStyle(.orange)
                } else { Text("自然时间基准").foregroundStyle(.secondary) }
            }.font(.caption)
            if monitor.windows.count > 1 {
                Picker("额度", selection: Binding(get: { monitor.selectedWindow?.id ?? "" },
                                                set: { monitor.selectedWindowID = $0 })) {
                    ForEach(monitor.windows) { item in
                        Text("\(item.name) · \(format.quotaDuration(item.quota.windowDurationMins))").tag(item.id)
                    }
                }.labelsHidden()
            }
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(format.percent(window.quota.usedPercent))
                    .font(.system(size: 54, weight: .light, design: .rounded))
                Text("已用").font(.callout).foregroundStyle(.secondary)
                Spacer()
                VStack(alignment: .trailing, spacing: 4) {
                    Text(format.percent(max(0, 100 - window.quota.usedPercent)))
                        .font(.title2.weight(.medium)).foregroundStyle(.teal)
                    Text("剩余额度").font(.caption).foregroundStyle(.secondary)
                }
            }.monospacedDigit()

            let standard = window.quota.standardPercent(at: date)
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule().fill(.teal.opacity(0.1))
                    Capsule().fill(.teal.gradient)
                        .frame(width: geometry.size.width * min(100, max(0, window.quota.usedPercent)) / 100)
                    if let standard {
                        RoundedRectangle(cornerRadius: 2).fill(Color.primary)
                            .frame(width: 3, height: 16)
                            .offset(x: min(geometry.size.width - 3, geometry.size.width * standard / 100))
                    }
                }
            }.frame(height: 10)

            HStack(alignment: .top) {
                metric("标准用量", value: standard.map { format.percent($0, decimals: 1) } ?? "暂不可算")
                Spacer()
                let deviation = monitor.isStale(at: date) ? nil : window.quota.deviation(at: date)
                metric("用量偏移", value: deviation.map { format.deviation($0) } ?? "待更新",
                       color: (deviation ?? 0) > 5 ? .orange : .teal)
            }
            Divider()
            if let reset = window.quota.resetDate {
                HStack {
                    Label("下次重置", systemImage: "arrow.clockwise")
                    Spacer()
                    Text(format.date(reset))
                }.font(.caption).foregroundStyle(.secondary)
                if reset > date {
                    Text("剩余 \(format.duration(reset.timeIntervalSince(date)))")
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }
            Text("标准用量按重置时间与窗口长度推算。正偏移表示用得偏快，包含睡眠和休息时间。")
                .font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .padding(18)
        .background(.background, in: RoundedRectangle(cornerRadius: 18))
        .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(.primary.opacity(0.05)))
    }

    private func metric(_ label: String, value: String, color: Color = .primary) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.system(.title3, design: .rounded).weight(.medium))
                .monospacedDigit().foregroundStyle(color)
        }
    }

    private func creditsSection(date: Date) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("重置卡", systemImage: "rectangle.stack").font(.headline)
                Spacer()
                Text(monitor.snapshot?.rateLimitResetCredits.map { "\(format.number(Double($0.availableCount))) 张可用" } ?? "信息未提供")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if monitor.pendingRedemption != nil {
                Text("上次重置结果尚未确认，请先核实。")
                    .font(.caption).foregroundStyle(.orange)
                Button("重试上次重置") {
                    selectedCredit = monitor.pendingCredit
                    confirmingReset = true
                }.disabled(monitor.isBusy)
            }
            ForEach(monitor.sortedCredits) { credit in
                HStack(spacing: 10) {
                    Image(systemName: "ticket").foregroundStyle(.teal)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(format.creditTitle(credit.title)).font(.callout.weight(.medium))
                        if let expiry = credit.expiryDate {
                            Text(expiry > date ? "\(format.date(expiry)) 到期" : "已到期，等待刷新")
                                .foregroundStyle(expiry.timeIntervalSince(date) < 86400 ? .orange : .secondary)
                        } else { Text("有效期未提供").foregroundStyle(.secondary) }
                    }.font(.caption2)
                    Spacer()
                    Button("使用") { selectedCredit = credit; confirmingReset = true }
                        .disabled(monitor.isBusy || !monitor.canRedeem || !credit.isUsable(at: date)
                                  || monitor.pendingRedemption != nil || monitor.isStale(at: date))
                }
                .padding(12).background(.background, in: RoundedRectangle(cornerRadius: 12))
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

    private func message(_ text: String, symbol: String, color: Color) -> some View {
        Label(text, systemImage: symbol).font(.caption).foregroundStyle(color)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let updated = monitor.lastUpdated {
                Text("更新于 \(format.date(updated, timeOnly: Calendar.autoupdatingCurrent.isDateInToday(updated))) · 每 5 分钟自动刷新")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            Divider()
            HStack {
                Menu {
                    Button("打开独立窗口") { openWindow(id: "dashboard") }
                    Divider()
                    Button("选择 Codex CLI…") { Task { await monitor.chooseExecutable() } }
                    Text(monitor.executablePath)
                    if monitor.account != nil {
                        Divider()
                        Button("退出账号") { Task { await monitor.logout() } }
                    }
                } label: { Image(systemName: "gearshape") }
                .menuStyle(.borderlessButton).fixedSize().disabled(monitor.isBusy || monitor.loginID != nil)
                Text("独立第三方工具").font(.caption2).foregroundStyle(.tertiary)
                Spacer()
                Button("退出") { NSApplication.shared.terminate(nil) }.buttonStyle(.borderless)
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

}
