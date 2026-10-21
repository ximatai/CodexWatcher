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
                Text("提醒后人工确认").tag(CreditExpiryMode.remind)
                Text("自动使用").tag(CreditExpiryMode.automatic)
            }
            .disabled(monitor.isConfiguringExpiry || monitor.isBusy)
            if enabled {
                Text(monitor.expiryConfiguration.mode == .automatic
                     ? "临期后直接尝试使用，包括已用额度为 0% 的情况。每张卡自动尝试一次；结果未知时转为人工核实。"
                     : "发送系统通知，点击后进入原有二次确认页；不会直接使用卡片。")
                    .font(.callout).fixedSize(horizontal: false, vertical: true)
                if !monitor.expiryConfigurationMatchesAccount {
                    Label("当前账号与启用时不同，临期处理已暂停。请关闭后为当前账号重新开启。", systemImage: "pause.circle")
                        .font(.caption).foregroundStyle(.orange)
                }
            }
            if let message = monitor.expiryHandlingMessage {
                Text(message).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Divider()
            Text("仅在应用运行且 Mac 唤醒时检查，每 30 秒检查一次。休眠或退出期间不会执行；唤醒后仅处理尚未到期的卡片。")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Text("设置仅用于启用时的账号。自动使用会消耗重置卡且无法撤销。")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
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
            Button("启用自动使用", role: .destructive) {
                Task {
                    await monitor.configureExpiryHandling(.automatic)
                    if enabled { selectedMode = monitor.expiryConfiguration.mode }
                }
            }
        } message: {
            Text("重置卡到期前 15 分钟内会直接尝试使用，即使已用额度为 0%。每张卡自动尝试一次，消费后无法撤销。")
        }
    }
}
