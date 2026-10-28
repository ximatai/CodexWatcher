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
                Image(nsImage: MenuBarLabelRenderer.image(title: previewTitle, symbolName: configuration.effectiveSymbol))
                    .accessibilityLabel("状态栏预览 \(previewTitle)")
            }
            .frame(maxWidth: .infinity).frame(height: 60)
            .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 10))
            Form {
                Picker("图标", selection: $icon) {
                    ForEach(MenuBarIcon.allCases) { option in
                        if let symbol = option.symbol {
                            Label(LocalizedStringKey(option.title), systemImage: symbol).tag(option.rawValue)
                        } else {
                            Text(LocalizedStringKey(option.title)).tag(option.rawValue).disabled(textCount == 0)
                        }
                    }
                }
                Divider().padding(.vertical, 4)
                Toggle("已用百分比", isOn: $showUsage)
                    .disabled(icon == MenuBarIcon.none.rawValue && showUsage && textCount == 1)
                Toggle("参考进度", isOn: $showTimeProgress)
                    .help("按额度周期的自然时间计算，包含睡眠和休息时间。")
                    .disabled(icon == MenuBarIcon.none.rawValue && showTimeProgress && textCount == 1)
                Toggle("用量偏移", isOn: $showDeviation)
                    .disabled(icon == MenuBarIcon.none.rawValue && showDeviation && textCount == 1)
                    .help("实际用量减去参考进度，pp 表示百分点。")
            }
            .toggleStyle(.switch).controlSize(.small)
        }
        .padding(20).frame(width: 380)
    }
}
