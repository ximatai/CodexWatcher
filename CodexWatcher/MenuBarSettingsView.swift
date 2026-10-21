import SwiftUI

struct MenuBarSettingsView: View {
    @Bindable var monitor: UsageMonitor
    var onClose: (() -> Void)? = nil
    @Environment(\.dismiss) private var dismiss
    @AppStorage("menuBarIcon") private var icon = MenuBarIcon.gauge.rawValue
    @AppStorage("menuBarShowUsage") private var showUsage = true
    @AppStorage("menuBarShowTimeProgress") private var showTimeProgress = false
    @AppStorage("menuBarShowDeviation") private var showDeviation = false

    private var configuration: MenuBarConfiguration {
        .init(icon: MenuBarIcon(rawValue: icon) ?? .gauge, showUsage: showUsage,
              showTimeProgress: showTimeProgress, showDeviation: showDeviation)
    }
    private var textCount: Int { [showUsage, showTimeProgress, showDeviation].filter { $0 }.count }
    private var previewTitle: String {
        configuration.title(quota: monitor.account == nil ? nil : monitor.selectedWindow?.quota,
                            at: monitor.displayDate,
                            isStale: monitor.isStale(at: monitor.displayDate))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("状态栏显示").font(.headline)
                Spacer()
                Button("完成") {
                    if let onClose { onClose() } else { dismiss() }
                }.keyboardShortcut(.defaultAction)
            }
            VStack(spacing: 8) {
                Text("实时预览").font(.caption).foregroundStyle(.secondary)
                Image(nsImage: MenuBarLabelRenderer.image(title: previewTitle, symbolName: configuration.effectiveSymbol))
                    .accessibilityLabel("状态栏预览 \(previewTitle)")
            }
            .frame(maxWidth: .infinity).frame(height: 60)
            .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 10))
            Form {
                Picker("图标", selection: $icon) {
                    ForEach(MenuBarIcon.allCases) { option in
                        if let symbol = option.symbol {
                            Label(option.title, systemImage: symbol).tag(option.rawValue)
                        } else {
                            Text(option.title).tag(option.rawValue).disabled(textCount == 0)
                        }
                    }
                }
                Divider().padding(.vertical, 4)
                Toggle("已用百分比", isOn: $showUsage)
                    .disabled(icon == MenuBarIcon.none.rawValue && showUsage && textCount == 1)
                Toggle("时间进度", isOn: $showTimeProgress)
                    .disabled(icon == MenuBarIcon.none.rawValue && showTimeProgress && textCount == 1)
                Toggle("用量偏移", isOn: $showDeviation)
                    .disabled(icon == MenuBarIcon.none.rawValue && showDeviation && textCount == 1)
            }
            .toggleStyle(.switch).controlSize(.small)
            Text("文本依次显示已用百分比、时间进度、用量偏移。偏移单位 pp 为百分点；正值表示用量超前，负值表示用量滞后。关闭的项目会跳过。")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Text("至少保留图标或一项文本。设置自动保存并即时生效。")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(20).frame(width: 380)
    }
}
