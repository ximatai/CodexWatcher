import AppKit

extension ReleaseUpdateChecker {
    /// User initiated only; automatic checks update the menu without opening windows.
    func checkInteractively() async {
        let result = await check(force: true)
        guard result != .busy else { return }
        let alert = NSAlert()
        switch result {
        case .available:
            guard let version = availableVersion else { return }
            alert.messageText = L10n.text("发现新版本 \(version.description)")
            alert.addButton(withTitle: L10n.text("前往下载"))
            alert.addButton(withTitle: L10n.text("取消"))
        case .current:
            alert.messageText = L10n.text("已是最新版本")
            alert.addButton(withTitle: L10n.text("好"))
        case .rateLimited:
            alert.messageText = L10n.text("暂时无法检查更新")
            alert.informativeText = L10n.text("GitHub 请求受限，请稍后重试。")
            alert.addButton(withTitle: L10n.text("好"))
        default:
            alert.messageText = L10n.text("暂时无法检查更新")
            alert.informativeText = L10n.text("请检查网络连接后重试。")
            alert.addButton(withTitle: L10n.text("好"))
        }
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn, result == .available, let releaseURL {
            NSWorkspace.shared.open(releaseURL)
        }
    }
    func openAvailableRelease() {
        if let releaseURL { NSWorkspace.shared.open(releaseURL) }
    }
}
