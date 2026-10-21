import SwiftUI

struct CreditExpirySettingsView: View {
    @Bindable var monitor: UsageMonitor
    var onClose: (() -> Void)? = nil
    @Environment(\.dismiss) private var dismiss
    @State private var confirmingAutomatic = false
    @State private var selectedMode = CreditExpiryMode.remind

    private var enabled: Bool { monitor.expiryConfiguration.mode != .off }
    private func select(_ mode: CreditExpiryMode) {
        if mode == .automatic { confirmingAutomatic = true }
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
                Text(monitor.expiryConfiguration.mode == .automatic
                     ? "每张卡最多尝试 3 次，消耗后无法撤销。"
                     : "通知提醒，确认后使用。")
                    .font(.callout).fixedSize(horizontal: false, vertical: true)
                if !monitor.expiryConfigurationMatchesAccount {
                    Label("账号已切换，已暂停。请关闭后重新开启。", systemImage: "pause.circle")
                        .font(.caption).foregroundStyle(.orange)
                }
            }
            if let message = monitor.expiryHandlingMessage {
                Text(message).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Divider()
            Text("仅用于启用时的账号；应用运行且 Mac 未休眠时生效。")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                .help("每 30 秒检查一次。失败后间隔至少 30 秒重试原卡，固定原到期时间与请求标识；最多 3 次后转为人工核实。")
        }
        .padding(20).frame(width: 380)
        .onAppear {
            if enabled { selectedMode = monitor.expiryConfiguration.mode }
        }
        .onChange(of: monitor.expiryConfiguration.mode) { _, mode in
            if mode != .off { selectedMode = mode }
        }
        .alert("启用自动使用？", isPresented: $confirmingAutomatic) {
            Button("取消", role: .cancel) {
                if enabled { selectedMode = monitor.expiryConfiguration.mode }
            }
            Button("启用", role: .destructive) {
                Task {
                    await monitor.configureExpiryHandling(.automatic)
                    if enabled { selectedMode = monitor.expiryConfiguration.mode }
                }
            }
        } message: {
            Text("到期前 15 分钟最多尝试 3 次，用量为 0% 也执行。消耗后无法撤销。")
        }
    }
}
