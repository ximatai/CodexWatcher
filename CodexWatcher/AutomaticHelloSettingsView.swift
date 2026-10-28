import SwiftUI

struct AutomaticHelloSettingsView: View {
    @Bindable var monitor: UsageMonitor
    var onClose: (() -> Void)? = nil
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.locale) private var locale
    @Environment(\.timeZone) private var timeZone
    @AppStorage("privacyMode") private var hideEmail = false
    @State private var selectedWindowID = ""
    @State private var authorization: AutomaticHelloAuthorization?
    @State private var confirming = false
    private var palette: AppPalette { AppPalette(dark: colorScheme == .dark) }
    private var format: PresentationFormat { PresentationFormat(locale: locale, timeZone: timeZone) }
    private var enabled: Bool { monitor.automaticHelloConfiguration.enabled }
    private var target: String { selectedWindowID.isEmpty ? (monitor.defaultHelloWindow?.id ?? "") : selectedWindowID }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("满额自动 hello").font(.headline)
                Spacer()
                Button("完成") {
                    if let onClose { onClose() } else { dismiss() }
                }.keyboardShortcut(.defaultAction)
            }
            Toggle("满额时发送一次 hello", isOn: Binding(get: { enabled }, set: { value in
                if value {
                    authorization = monitor.makeAutomaticHelloAuthorization(windowID: target)
                    confirming = authorization != nil
                } else {
                    monitor.configureAutomaticHello(false)
                }
            }))
            .toggleStyle(.switch)
            .disabled(!enabled && (monitor.isBusy || monitor.helloWindows.isEmpty || monitor.loginID != nil))
            Picker("额度窗口", selection: Binding(get: { target }, set: { selectedWindowID = $0 })) {
                ForEach(monitor.helloWindows) { window in
                    Text(format.quotaDuration(window.quota.windowDurationMins)).tag(window.id)
                }
                if enabled, let id = monitor.automaticHelloConfiguration.windowID,
                   !monitor.helloWindows.contains(where: { $0.id == id }) {
                    Text("原额度窗口不可用").tag(id)
                }
            }
            .disabled(enabled || monitor.helloWindows.isEmpty)
            if enabled && !monitor.helloConfigurationMatchesAccount {
                Label("账号不匹配，已暂停。请关闭后重新开启。", systemImage: "pause.circle")
                    .font(.caption).foregroundStyle(palette.warning)
            } else if enabled, let email = monitor.account?.email {
                Text(email).font(.caption).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle).privacyMasked(hideEmail)
            }
            if monitor.isSendingHello {
                HStack {
                    ProgressView().controlSize(.small)
                    Text("正在发送…").font(.callout)
                }
            } else if let record = monitor.automaticHelloRecord, let attemptedAt = record.attemptedAt {
                HStack {
                    Label(record.outcome == "completed" ? String(localized: "hello 已完成") : String(localized: "本次不再补发"),
                          systemImage: record.outcome == "completed" ? "checkmark.circle" : "exclamationmark.circle")
                    Spacer()
                    Text(format.date(Date(timeIntervalSince1970: attemptedAt),
                                     timeOnly: Calendar.autoupdatingCurrent.isDateInToday(Date(timeIntervalSince1970: attemptedAt))))
                }.font(.caption).foregroundStyle(.secondary)
            }
            if let message = monitor.automaticHelloMessage {
                Text(message).font(.caption).foregroundStyle(palette.warning)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Divider()
            Text("会消耗模型额度，仅在应用运行且 Mac 唤醒时生效。")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                .help("每 30 秒检查。发送后以最新用量为基线，额外使用至少 1 个百分点、再恢复满额后才重新触发。关闭或重启不会清除去重记录；未知结果不补发。")
        }
        .padding(20).frame(width: 380).tint(palette.accent)
        .onAppear { selectedWindowID = monitor.automaticHelloConfiguration.windowID ?? monitor.defaultHelloWindow?.id ?? "" }
        .onChange(of: monitor.automaticHelloConfiguration) { _, config in
            if config.enabled { selectedWindowID = config.windowID ?? "" }
        }
        .alert("开启满额自动 hello？", isPresented: $confirming, presenting: authorization) { value in
            Button("取消", role: .cancel) {}
            Button("开启") { monitor.configureAutomaticHello(true, authorization: value) }
        } message: { _ in
            Text("将为此账号在所选额度恢复满额时自动发送一次 hello，会消耗模型额度。当前已满额时也会发送。")
        }
    }
}
