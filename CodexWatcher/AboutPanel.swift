import AppKit

@MainActor
enum AboutPanel {
    static func show() {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        let style: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 12),
            .foregroundColor: NSColor.labelColor,
            .paragraphStyle: paragraph
        ]
        let credits = NSMutableAttributedString(string: "GitHub", attributes: style)
        credits.addAttribute(.link, value: URL(string: "https://github.com/ximatai/CodexWatcher")!,
                             range: NSRange(location: 0, length: credits.length))
        credits.append(NSAttributedString(string: "  ·  ", attributes: style))
        var websiteStyle = style
        websiteStyle[.link] = URL(string: "https://ximatai.net/apps")!
        credits.append(NSAttributedString(string: L10n.text("更多作品"), attributes: websiteStyle))
        NSApp.activate(ignoringOtherApps: true)
        // AppKit reads the version from this application's Info.plist.
        NSApp.orderFrontStandardAboutPanel(options: [
            .credits: credits,
            NSApplication.AboutPanelOptionKey(rawValue: "Copyright"): "© 2026 Rui Liu"
        ])
    }
}
