import AppKit
import SwiftUI
import Observation

/// One native status item handles both mouse buttons; dismissal observers exist only while its popover is visible.
@MainActor
final class StatusBarController: NSObject, NSPopoverDelegate {
    private let monitor: UsageMonitor
    private let openDashboard: () -> Void
    private let observesExternalEvents: Bool
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let popover = NSPopover()
    private var settingsWindow: NSWindow?
    private var expirySettingsWindow: NSWindow?
    private var defaultsObserver: NSObjectProtocol?
    private var stopped = false
    private var clearFocusAfterMouseOpen = false
    private var outsideClickMonitor: Any?
    private var localEventMonitor: Any?
    private var dismissalObservers: [NSObjectProtocol] = []
    private var activationObserver: NSObjectProtocol?
    private var dismissalState = PopoverDismissalState()

    init(monitor: UsageMonitor, observesExternalEvents: Bool = true, openDashboard: @escaping () -> Void) {
        self.monitor = monitor
        self.openDashboard = openDashboard
        self.observesExternalEvents = observesExternalEvents
        super.init()
        if let button = item.button {
            button.target = self
            button.action = #selector(clicked)
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
            button.setAccessibilityLabel("Codex Watcher")
        }
        // Own dismissal completely: native transient dismissal can race menu tracking.
        popover.behavior = .applicationDefined
        popover.delegate = self
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
        stopDismissalMonitoring()
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
            showPopover(clearInitialFocus: event?.type == .leftMouseUp)
        }
    }

    private func showPopover(clearInitialFocus: Bool) {
        guard let button = item.button else { return }
        clearFocusAfterMouseOpen = clearInitialFocus
        NSApp.activate(ignoringOtherApps: true)
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
    }

    func popoverDidShow(_ notification: Notification) {
        startDismissalMonitoring()
        guard clearFocusAfterMouseOpen else { return }
        clearFocusAfterMouseOpen = false
        // Clear only the initial mouse-open focus; Tab navigation remains available.
        popover.contentViewController?.view.window?.makeFirstResponder(nil)
    }

    func popoverDidClose(_ notification: Notification) {
        stopDismissalMonitoring()
    }

    private func startDismissalMonitoring() {
        stopDismissalMonitoring()
        guard !stopped, popover.isShown else { return }
        let clicks: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        if observesExternalEvents {
            outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: clicks) { [weak self] event in
                // AppKit delivers event monitors on the main thread. Observe only;
                // never consume or modify another application's click.
                MainActor.assumeIsolated { self?.handleOutsideClick(at: Self.screenPoint(for: event)) }
            }
        }
        localEventMonitor = NSEvent.addLocalMonitorForEvents(matching: clicks.union(.keyDown)) { [weak self] event in
            let consumed = MainActor.assumeIsolated {
                guard let self else { return false }
                return self.handleLocalEvent(event) == nil
            }
            return consumed ? nil : event
        }
        let center = NotificationCenter.default
        dismissalObservers.append(center.addObserver(forName: NSMenu.didBeginTrackingNotification,
            object: nil, queue: .main) { [weak self] notification in
            MainActor.assumeIsolated {
                if let menu = notification.object as? NSMenu { self?.dismissalState.menuBegan(menu) }
            }
        })
        dismissalObservers.append(center.addObserver(forName: NSMenu.didEndTrackingNotification,
            object: nil, queue: .main) { [weak self] notification in
            MainActor.assumeIsolated {
                guard let self, let menu = notification.object as? NSMenu else { return }
                if self.dismissalState.menuEnded(menu) { self.closePopover() }
            }
        })
        // Opening a SwiftUI Menu can temporarily resign application focus before
        // NSMenu's tracking notification arrives. Only an actual app switch is external.
        if observesExternalEvents {
            activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
                forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
            ) { [weak self] notification in
                MainActor.assumeIsolated {
                    guard let application = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                          application.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return }
                    self?.handleOtherApplicationActivation()
                }
            }
        }
    }

    private func handleLocalEvent(_ event: NSEvent) -> NSEvent? {
        guard popover.isShown else { return event }
        if event.type == .keyDown {
            // Escape closes only this panel. Menus and sheets retain their own cancellation.
            guard event.keyCode == 53,
                  event.modifierFlags.intersection([.command, .control, .option]).isEmpty,
                  !dismissalState.isTrackingMenu,
                  let window = popover.contentViewController?.view.window,
                  event.window === window, window.attachedSheet == nil else { return event }
            closePopover()
            return nil
        }
        // The status-item action owns toggling, so do not close then reopen it.
        guard event.window !== item.button?.window else { return event }
        var window = event.window
        while let current = window {
            if current === popover.contentViewController?.view.window { return event }
            window = current.sheetParent ?? current.parent
        }
        // Local menu-item clicks belong to menu tracking, not to an external app.
        if dismissalState.isTrackingMenu {
            guard let window = event.window, window.level < .popUpMenu else { return event }
        }
        handleOutsideClick(at: Self.screenPoint(for: event))
        return event
    }

    private static func screenPoint(for event: NSEvent) -> NSPoint {
        // For a windowless/global event, locationInWindow already uses screen coordinates.
        event.window?.convertPoint(toScreen: event.locationInWindow) ?? event.locationInWindow
    }

    private func handleOutsideClick(at point: NSPoint) {
        guard popover.isShown, let window = popover.contentViewController?.view.window,
              !window.frame.contains(point) else { return }
        if dismissalState.outsideInteraction() { closePopover() }
    }

    private func handleOtherApplicationActivation() {
        guard popover.isShown else { return }
        if dismissalState.outsideInteraction() { closePopover() }
    }

    private func stopDismissalMonitoring() {
        if let outsideClickMonitor { NSEvent.removeMonitor(outsideClickMonitor) }
        if let localEventMonitor { NSEvent.removeMonitor(localEventMonitor) }
        outsideClickMonitor = nil
        localEventMonitor = nil
        dismissalObservers.forEach { NotificationCenter.default.removeObserver($0) }
        dismissalObservers.removeAll()
        if let activationObserver { NSWorkspace.shared.notificationCenter.removeObserver(activationObserver) }
        activationObserver = nil
        dismissalState.reset()
    }

    /// Runs only with the isolated CLI fixture. Opens the actual SwiftUI gear menu;
    /// cancellation selects no item. External interactions are injected into the same handlers.
    func verifyPopoverForSmokeTest() async -> Bool {
        guard CommandLine.arguments.contains("--release-smoke-test") else { return fail(#line) }
        func fail(_ line: Int = #line) -> Bool {
            FileHandle.standardError.write(Data("Popover smoke failed at line \(line)\n".utf8))
            return false
        }
        let animated = popover.animates
        popover.animates = false
        defer { closePopover(); popover.animates = animated }

        func waitFor(_ condition: () -> Bool) async -> Bool {
            let deadline = Date().addingTimeInterval(4)
            while !condition() && Date() < deadline {
                try? await Task.sleep(for: .milliseconds(20))
            }
            return condition()
        }
        func settingsButton(in element: any NSAccessibilityProtocol, depth: Int = 0) -> (any NSAccessibilityProtocol)? {
            guard depth < 30 else { return nil }
            if element.accessibilityIdentifier() == "dashboard-settings" { return element }
            for child in element.accessibilityChildren() ?? [] {
                if let child = child as? any NSAccessibilityProtocol,
                   let found = settingsButton(in: child, depth: depth + 1) { return found }
            }
            return nil
        }

        for cycle in 0..<4 {
            showPopover(clearInitialFocus: true)
            var gear: (any NSAccessibilityProtocol)?
            guard await waitFor({
                guard self.popover.isShown, self.localEventMonitor != nil, !self.monitor.isBusy,
                      let view = self.popover.contentViewController?.view else { return false }
                gear = settingsButton(in: view)
                return gear != nil
            }), let gear else { return fail(#line) }
            @MainActor final class MenuProbe {
                var sawMenu = false
                var stayedOpen = false
                var cancellation: Timer?
            }
            let probe = MenuProbe()
            let observer = NotificationCenter.default.addObserver(forName: NSMenu.didBeginTrackingNotification,
                object: nil, queue: .main) { [weak self] notification in
                MainActor.assumeIsolated {
                    guard let menu = notification.object as? NSMenu, !probe.sawMenu else { return }
                    probe.sawMenu = true
                    if cycle == 1 { self?.handleOtherApplicationActivation() }
                    if cycle == 2, let window = self?.popover.contentViewController?.view.window {
                        self?.handleOutsideClick(at: NSPoint(x: window.frame.minX - 20, y: window.frame.minY - 20))
                    }
                    probe.stayedOpen = self?.popover.isShown == true
                    let timer = Timer(timeInterval: 0.1, repeats: false) { _ in
                        MainActor.assumeIsolated {
                            menu.cancelTracking()
                        }
                    }
                    probe.cancellation = timer
                    RunLoop.main.add(timer, forMode: .common)
                    RunLoop.main.add(timer, forMode: .eventTracking)
                }
            }
            // SwiftUI may return false after cancellation even when the menu opened.
            // Require observed native tracking and visibility instead of that return value.
            _ = gear.accessibilityPerformPress()
            let ended = await waitFor({ probe.sawMenu && !self.dismissalState.isTrackingMenu })
            NotificationCenter.default.removeObserver(observer)
            probe.cancellation?.invalidate()
            guard ended, probe.stayedOpen else {
                FileHandle.standardError.write(Data("Popover cycle \(cycle): sawMenu=\(probe.sawMenu), ended=\(ended), stayedOpen=\(probe.stayedOpen)\n".utf8))
                return fail(#line)
            }
            if cycle == 1 || cycle == 2 {
                guard await waitFor({ !self.popover.isShown }) else { return fail(#line) }
            } else if cycle == 3 {
                guard let window = popover.contentViewController?.view.window,
                      let escape = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                          timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                          context: nil, characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}",
                          isARepeat: false, keyCode: 53) else { return fail(#line) }
                NSApp.sendEvent(escape)
                guard await waitFor({ !self.popover.isShown }) else { return fail(#line) }
            } else {
                guard popover.isShown, let window = popover.contentViewController?.view.window else { return fail(#line) }
                // A captured inside position must stay internal, regardless of the live pointer.
                handleOutsideClick(at: NSPoint(x: window.frame.midX, y: window.frame.midY))
                guard popover.isShown else { return fail(#line) }
                handleOutsideClick(at: NSPoint(x: window.frame.minX - 20, y: window.frame.minY - 20))
                guard await waitFor({ !self.popover.isShown }) else { return fail(#line) }
            }
            guard outsideClickMonitor == nil, localEventMonitor == nil,
                  dismissalObservers.isEmpty, activationObserver == nil else { return fail(#line) }
        }
        return true
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
        _ = add("重置卡临期处理…", #selector(showExpirySettings))
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

    @objc private func showExpirySettings() {
        if expirySettingsWindow == nil {
            let hosting = NSHostingController(rootView: CreditExpirySettingsView(monitor: monitor,
                onClose: { [weak self] in self?.expirySettingsWindow?.close() }))
            hosting.sizingOptions = [.minSize, .maxSize]
            let window = NSWindow(contentViewController: hosting)
            window.title = "重置卡临期处理"
            window.styleMask = [.titled, .closable]
            window.isReleasedWhenClosed = false
            window.center()
            expirySettingsWindow = window
        }
        NSApp.activate(ignoringOtherApps: true)
        expirySettingsWindow?.makeKeyAndOrderFront(nil)
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
