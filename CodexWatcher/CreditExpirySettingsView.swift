import SwiftUI

struct CreditExpirySettingsView: View {
    @Bindable var monitor: UsageMonitor
    var onClose: (() -> Void)? = nil
    @Environment(\.dismiss) private var dismiss
    @Environment(\.locale) private var locale
    @Environment(\.timeZone) private var timeZone
    @Environment(\.colorScheme) private var colorScheme
    @AppStorage("privacyMode") private var hideEmail = false
    @State private var confirmingAutomatic = false
    @State private var automaticAuthorization: AutomaticExpiryAuthorization?
    @State private var selectedMode = CreditExpiryMode.remind

    private var enabled: Bool { monitor.expiryConfiguration.mode != .off }
    private var palette: AppPalette { AppPalette(dark: colorScheme == .dark) }
    private func select(_ mode: CreditExpiryMode) {
        if mode == .automatic {
            guard let authorization = monitor.makeAutomaticExpiryAuthorization() else {
                if enabled { selectedMode = monitor.expiryConfiguration.mode }
                return
            }
            automaticAuthorization = authorization
            confirmingAutomatic = true
        }
        else {
            Task {
                await monitor.configureExpiryHandling(mode)
                if enabled { selectedMode = monitor.expiryConfiguration.mode }
            }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("重置卡临期处理").font(.headline)
                Spacer()
                Button("完成") {
                    if let onClose { onClose() } else { dismiss() }
                }.keyboardShortcut(.defaultAction)
            }
            Toggle("到期前 15 分钟处理", isOn: Binding(
                get: { enabled }, set: { select($0 ? selectedMode : .off) }))
                .toggleStyle(.switch)
                .disabled(monitor.isConfiguringExpiry)
            Picker("处理方式", selection: Binding(
                get: { selectedMode }, set: {
                    selectedMode = $0
                    if enabled { select($0) }
                })) {
                Text("提醒后确认").tag(CreditExpiryMode.remind)
                Text("自动使用").tag(CreditExpiryMode.automatic)
            }
            .disabled(monitor.isConfiguringExpiry || monitor.isBusy)
            if enabled {
                VStack(alignment: .leading, spacing: 10) {
                    if monitor.expiryConfigurationMatchesAccount {
                        HStack {
                            if let email = monitor.account?.email {
                                Text(email).lineLimit(1).truncationMode(.middle).privacyMasked(hideEmail)
                            }
                            Spacer()
                            if let checked = monitor.lastExpiryCheck {
                                Text(PresentationFormat(locale: locale, timeZone: timeZone).date(checked, timeOnly: true))
                                    .help("最近一次成功检查")
                            }
                        }.font(.caption).foregroundStyle(.secondary)
                        if monitor.pendingRedemption != nil || monitor.errorMessage != nil || monitor.isRedeeming {
                            Text(monitor.expiryStatusTitle).font(.callout).foregroundStyle(palette.warning)
                        }
                    } else {
                        Text("账号不匹配，已暂停。请关闭后重新开启。")
                            .font(.caption).foregroundStyle(palette.warning)
                    }
                }
            }
            if let message = monitor.expiryHandlingMessage {
                Text(message).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Divider()
            HStack {
                Text("仅 Mac 唤醒且应用运行时生效")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                if enabled && monitor.expiryConfiguration.mode == .automatic {
                    Image(systemName: "exclamationmark.triangle")
                        .foregroundStyle(palette.warning).accessibilityLabel("卡片消耗后无法撤销")
                        .help("卡片消耗后无法撤销；最多尝试 3 次，间隔至少 30 秒，始终复用原请求。")
                }
            }
        }
        .padding(20).frame(width: 380)
        .tint(palette.accent)
        .onAppear {
            if enabled { selectedMode = monitor.expiryConfiguration.mode }
        }
        .onChange(of: monitor.expiryConfiguration.mode) { _, mode in
            if mode != .off { selectedMode = mode }
        }
        .alert("启用自动使用？", isPresented: $confirmingAutomatic,
               presenting: automaticAuthorization) { authorization in
            Button("取消", role: .cancel) {
                if enabled { selectedMode = monitor.expiryConfiguration.mode }
            }
            Button("启用", role: .destructive) {
                Task {
                    await monitor.configureExpiryHandling(.automatic, authorization: authorization)
                    if enabled { selectedMode = monitor.expiryConfiguration.mode }
                }
            }
        } message: { _ in
            Text("到期前 15 分钟会自动使用重置卡，失败时最多重试 2 次。\n\n即使当前额度非常充裕，甚至没有使用，也会尝试使用重置卡。卡片消耗后无法恢复。")
        }
    }
}
