import SwiftUI

/// Presentation only. The live wrapper validates state; previews supply inert actions.
struct ResetConfirmationContent: View {
    let isRetry: Bool
    let cardTitle: String
    let account: String
    let quotaTitle: String
    let usage: String
    let expiry: String
    let updated: String?
    let blockingReason: String?
    let canConfirm: Bool
    let cancel: () -> Void
    let confirm: () -> Void
    @Environment(\.colorScheme) private var colorScheme
    private var palette: AppPalette { AppPalette(dark: colorScheme == .dark) }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 10) {
                Image(systemName: "ticket")
                    .font(.system(size: 18)).foregroundStyle(palette.warning)
                    .frame(width: 38, height: 38)
                    .background(palette.warning.opacity(0.1), in: RoundedRectangle(cornerRadius: 10))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    Text(isRetry ? "重试重置" : "使用重置卡").font(.system(size: 17, weight: .semibold))
                    Text(isRetry ? "可能消耗 1 张 · 操作无法撤销" : "消耗 1 张 · 操作无法撤销")
                        .font(.caption).foregroundStyle(palette.warning)
                }
            }

            VStack(alignment: .leading, spacing: 12) {
                Text(cardTitle).font(.system(size: 12, weight: .semibold))
                Divider()
                detail(String(localized: "账号"), account)
                VStack(alignment: .leading, spacing: 5) {
                    detail(quotaTitle, usage)
                    if let updated {
                        Text("更新于 \(updated)").font(.system(size: 10)).foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .trailing)
                    }
                }
                detail(String(localized: "卡片到期"), expiry)
            }
            .padding(14)
            .background(palette.surface, in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(palette.separator))

            Text(isRetry
                 ? L10n.text("将重试原操作，同一请求标识用于避免重复消费。重置范围由服务器决定。")
                 : L10n.text("重置范围由服务器决定，可能包含其他额度窗口。"))
                .font(.system(size: 11)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true).lineSpacing(3)

            if let blockingReason {
                Label(blockingReason, systemImage: "exclamationmark.circle")
                    .font(.system(size: 11)).foregroundStyle(palette.warning)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: 10) {
                Spacer(minLength: 0)
                Button("取消", action: cancel).keyboardShortcut(.cancelAction)
                Button(isRetry ? "重试重置" : "消耗 1 张并重置", role: .destructive, action: confirm)
                    .buttonStyle(.borderedProminent).tint(palette.danger)
                    .disabled(!canConfirm)
            }
            .controlSize(.regular)
        }
        .padding(20).frame(width: 370)
        .background(palette.background)
    }

    private func detail(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(label).foregroundStyle(.secondary).fixedSize()
            Spacer(minLength: 0)
            Text(value).fontWeight(.medium).multilineTextAlignment(.trailing)
                .fixedSize(horizontal: false, vertical: true)
        }.font(.system(size: 11))
    }
}
