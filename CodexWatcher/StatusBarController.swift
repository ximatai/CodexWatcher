import AppKit
import SwiftUI
import Observation

/// One native status item handles both mouse buttons without global event interception.
@MainActor
final class StatusBarController: NSObject {
    private let monitor: UsageMonitor
    private let openDashboard: () -> Void
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let popover = NSPopover()
    private var settingsWindow: NSWindow?
    private var defaultsObserver: NSObjectProtocol?
    private var stopped = false

    init(monitor: UsageMonitor, openDashboard: @escaping () -> Void) {
        self.monitor = monitor
        self.openDashboard = openDashboard
        super.init()
        if let button = item.button {
            button.target = self
            button.action = #selector(clicked)
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
            button.setAccessibilityLabel("Codex Watcher")
        }
        popover.behavior = .transient
        let hosting = NSHostingController(rootView: ContentView(monitor: monitor, openDashboard: openDashboard))
        hosting.sizingOptions = [.preferredContentSize]
        popover.contentViewController = hosting
        popover.contentSize = NSSize(width: 390, height: monitor.account == nil ? 440 : 660)
        defaultsObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.updateLabel() }
        }
        observeMonitor()
    }

    var isReadyForSmokeTest: Bool {
        !stopped && item.button?.image != nil && popover.contentViewController != nil
    }

    func closePopover() { popover.performClose(nil) }

    func stop() {
        stopped = true
        if let defaultsObserver { NotificationCenter.default.removeObserver(defaultsObserver) }
        defaultsObserver = nil
        closePopover()
        NSStatusBar.system.removeStatusItem(item)
    }

    private func observeMonitor() {
        guard !stopped else { return }
        withObservationTracking {
            updateLabel()
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in self?.observeMonitor() }
        }
    }

    private func updateLabel() {
        guard !stopped else { return }
        let defaults = UserDefaults.standard
        let config = MenuBarConfiguration(
            icon: MenuBarIcon(rawValue: defaults.string(forKey: "menuBarIcon") ?? "") ?? .gauge,
            showUsage: defaults.object(forKey: "menuBarShowUsage") as? Bool ?? true,
            showTimeProgress: defaults.bool(forKey: "menuBarShowTimeProgress"),
            showDeviation: defaults.bool(forKey: "menuBarShowDeviation"))
        let quota = monitor.account == nil ? nil : monitor.selectedWindow?.quota
        let isStale = monitor.isStale(at: monitor.displayDate)
        let title = config.title(quota: quota, at: monitor.displayDate, isStale: isStale)
        item.button?.image = MenuBarLabelRenderer.image(title: title, symbolName: config.effectiveSymbol)
        item.button?.toolTip = isStale
            ? "Codex Watcher · 用量待更新，偏移暂不可用。左键查看用量，右键打开设置"
            : "Codex Watcher · 左键查看用量，右键打开设置"
        item.button?.setAccessibilityLabel("Codex Watcher · \(title)")
        if let quota {
            let format = PresentationFormat()
            let deviation = isStale ? nil : quota.deviation(at: monitor.displayDate)
            item.button?.setAccessibilityValue("已用 \(format.percent(quota.usedPercent))；时间进度 \(quota.standardPercent(at: monitor.displayDate).map { format.percent($0) } ?? "未知")；偏移 \(deviation.map { format.deviation($0) } ?? "待更新")")
        } else {
            item.button?.setAccessibilityValue("暂无额度数据")
        }
    }

    @objc private func clicked() {
        guard let button = item.button else { return }
        let event = NSApp.currentEvent
        if event?.type == .rightMouseUp || event?.modifierFlags.contains(.control) == true {
            closePopover()
            let menu = settingsMenu()
            menu.popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.minY), in: button)
        } else if popover.isShown {
            closePopover()
        } else {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
        }
    }

    private func settingsMenu() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        func add(_ title: String, _ action: Selector) -> NSMenuItem {
            let entry = NSMenuItem(title: title, action: action, keyEquivalent: "")
            entry.target = self
            menu.addItem(entry)
            return entry
        }
        _ = add("状态栏显示…", #selector(showSettings))
        let hideEmail = add("隐藏邮箱", #selector(toggleEmailPrivacy))
        hideEmail.state = UserDefaults.standard.bool(forKey: "privacyMode") ? .on : .off
        hideEmail.image = NSImage(systemSymbolName: "eye.slash", accessibilityDescription: nil)
        let appearance = NSMenuItem(title: "外观", action: nil, keyEquivalent: "")
        let submenu = NSMenu()
        let selected = UserDefaults.standard.string(forKey: "appearance") ?? AppAppearance.system.rawValue
        for option in AppAppearance.allCases {
            let entry = NSMenuItem(title: option.title, action: #selector(changeAppearance(_:)), keyEquivalent: "")
            entry.target = self
            entry.representedObject = option.rawValue
            entry.state = selected == option.rawValue ? .on : .off
            submenu.addItem(entry)
        }
        appearance.submenu = submenu
        menu.addItem(appearance)
        menu.addItem(.separator())
        let loginItem = LoginItemController.shared
        loginItem.refresh()
        let startup = add(loginItem.title, #selector(toggleLoginItem))
        startup.state = loginItem.needsApproval ? .mixed : (loginItem.isRequested ? .on : .off)
        if loginItem.needsApproval {
            _ = add("在系统设置中允许…", #selector(openLoginItemSettings))
        }
        menu.addItem(.separator())
        _ = add("打开独立窗口", #selector(showDashboard))
        add("选择 Codex CLI…", #selector(chooseExecutable)).isEnabled = !monitor.isBusy && monitor.loginID == nil
        if monitor.account != nil {
            menu.addItem(.separator())
            add("退出账号", #selector(logout)).isEnabled = !monitor.isBusy && monitor.loginID == nil
        }
        menu.addItem(.separator())
        _ = add("退出应用", #selector(quit))
        return menu
    }

    @objc private func showSettings() {
        if settingsWindow == nil {
            let hosting = NSHostingController(rootView: MenuBarSettingsView(monitor: monitor,
                onClose: { [weak self] in self?.settingsWindow?.close() }))
            hosting.sizingOptions = [.minSize, .maxSize]
            let window = NSWindow(contentViewController: hosting)
            window.title = "状态栏显示"
            window.styleMask = [.titled, .closable]
            window.isReleasedWhenClosed = false
            window.center()
            settingsWindow = window
        }
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    @objc private func showDashboard() { openDashboard() }
    @objc private func toggleLoginItem() {
        let controller = LoginItemController.shared
        controller.refresh()
        controller.requestEnabled(!controller.isRequested)
    }
    @objc private func openLoginItemSettings() { LoginItemController.shared.openSystemSettings() }
    @objc private func chooseExecutable() { Task { await monitor.chooseExecutable() } }
    @objc private func logout() { Task { await monitor.logout() } }
    @objc private func quit() { NSApp.terminate(nil) }
    @objc private func toggleEmailPrivacy() {
        let defaults = UserDefaults.standard
        defaults.set(!defaults.bool(forKey: "privacyMode"), forKey: "privacyMode")
    }
    @objc private func changeAppearance(_ sender: NSMenuItem) {
        guard let value = sender.representedObject as? String, let option = AppAppearance(rawValue: value) else { return }
        UserDefaults.standard.set(value, forKey: "appearance")
        option.apply(to: NSApp)
    }
}
