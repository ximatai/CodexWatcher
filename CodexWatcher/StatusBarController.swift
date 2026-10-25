import AppKit
import SwiftUI
import Observation

/// One native status item handles both mouse buttons; dismissal observers exist only while its popover is visible.
@MainActor
final class StatusBarController: NSObject, NSPopoverDelegate {
    private let monitor: UsageMonitor
    private let updates: ReleaseUpdateChecker?
    private let openDashboard: () -> Void
    private let observesExternalEvents: Bool
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let popover = NSPopover()
    private var settingsWindow: NSWindow?
    private var expirySettingsWindow: NSWindow?
    private var helloSettingsWindow: NSWindow?
    private var resetWindow: NSWindow?
    private var defaultsObserver: NSObjectProtocol?
    private var stopped = false
    private var clearFocusAfterMouseOpen = false
    private var outsideClickMonitor: Any?
    private var localEventMonitor: Any?
    private var dismissalObservers: [NSObjectProtocol] = []
    private var activationObserver: NSObjectProtocol?
    private var dismissalState = PopoverDismissalState()

    init(monitor: UsageMonitor, updates: ReleaseUpdateChecker? = nil, observesExternalEvents: Bool = true, openDashboard: @escaping () -> Void) {
        self.monitor = monitor
        self.updates = updates
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
        let hosting = NSHostingController(rootView: popoverContent())
        hosting.sizingOptions = [.preferredContentSize]
        popover.contentViewController = hosting
        popover.contentSize = NSSize(width: 390, height: 440)
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
            item.button?.setAccessibilityValue("已用 \(format.percent(quota.usedPercent))；参考进度 \(quota.standardPercent(at: monitor.displayDate).map { format.percent($0) } ?? "未知")；偏移 \(deviation.map { format.deviation($0) } ?? "待更新")")
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

    // Popovers can disappear independently of SwiftUI's sheet lifecycle. Route every
    // modal action to an owned window so no invisible attached sheet can block clicks.
    private func popoverContent(maximumHeight: CGFloat = 660) -> ContentView {
        ContentView(monitor: monitor, updates: updates, dismissForUpdate: { [weak self] in self?.closePopover() }, openDashboard: openDashboard,
            presentSettings: { [weak self] page in
                switch page {
                case .menuBar: self?.showSettings()
                case .creditExpiry: self?.showExpirySettings()
                case .automaticHello: self?.showHelloSettings()
                }
            }, presentReset: { [weak self] in self?.showReset($0) }, maximumHeight: maximumHeight)
    }

    private func showPopover(clearInitialFocus: Bool) {
        guard let button = item.button else { return }
        let availableHeight = max(280, (button.window?.screen?.visibleFrame.height ?? 760) - 48)
        if let hosting = popover.contentViewController as? NSHostingController<ContentView> {
            hosting.rootView = popoverContent(maximumHeight: availableHeight)
        }
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

    /// Verify real preferred-content-size propagation while the popover stays open.
    func verifyPopoverSizingForSmokeTest(root: URL) async -> Bool {
        guard CommandLine.arguments.contains("--release-smoke-test"),
              ProcessInfo.processInfo.environment["WATCHER_SMOKE_ROOT"] == root.path else { return false }
        let usage = root.appendingPathComponent("usage.json")
        guard let original = try? Data(contentsOf: usage),
              let snapshot = try? JSONSerialization.jsonObject(with: original) as? [String: Any],
              let summary = snapshot["rateLimitResetCredits"] as? [String: Any],
              let cards = summary["credits"] as? [[String: Any]], let card = cards.first else { return false }
        let animated = popover.animates
        popover.animates = false
        defer { try? original.write(to: usage); closePopover(); popover.animates = animated }
        var heights: [Int: CGFloat] = [:]
        for count in [0, 1, 3, 20, 1] {
            var updated = snapshot
            var credits = summary
            credits["availableCount"] = count
            credits["credits"] = (0..<count).map { index in
                var copy = card
                copy["id"] = "sizing-card-\(index)"
                return copy
            }
            updated["rateLimitResetCredits"] = credits
            guard let data = try? JSONSerialization.data(withJSONObject: updated),
                  (try? data.write(to: usage)) != nil else { return false }
            await monitor.refresh()
            if !popover.isShown { showPopover(clearInitialFocus: true) }
            var last: CGFloat = -1
            var stable = 0
            for _ in 0..<60 {
                try? await Task.sleep(for: .milliseconds(30))
                popover.contentViewController?.view.layoutSubtreeIfNeeded()
                let height = popover.contentSize.height
                stable = abs(height - last) < 0.5 ? stable + 1 : 0
                last = height
                if stable >= 8 { break }
            }
            let cap = max(280, (item.button?.window?.screen?.visibleFrame.height ?? 760) - 48)
            guard stable >= 8, last >= 280, last <= cap + 1 else { return false }
            FileHandle.standardError.write(Data("Adaptive popover: cards=\(count), height=\(last), cap=\(cap)\n".utf8))
            if let previous = heights[count], abs(previous - last) > 1 { return false }
            heights[count] = last
            if let view = popover.contentViewController?.view,
               let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                view.cacheDisplay(in: view.bounds, to: bitmap)
                if let png = bitmap.representation(using: .png, properties: [:]) {
                    try? png.write(to: root.appendingPathComponent("popover-cards-\(count).png"))
                }
            }
        }
        guard let empty = heights[0], let single = heights[1], let three = heights[3], let many = heights[20],
              empty <= single, single <= three, three <= many else { return false }
        let cap = max(280, (item.button?.window?.screen?.visibleFrame.height ?? 760) - 48)
        if empty < cap - 1 && empty >= single { return false }
        if single < cap - 1 && single >= three { return false }
        closePopover()
        showPopover(clearInitialFocus: true)
        try? await Task.sleep(for: .milliseconds(300))
        guard abs(popover.contentSize.height - single) < 1 else { return false }
        try? original.write(to: usage)
        await monitor.refresh()
        return true
    }

    /// Runs only with the isolated CLI fixture. Opens the actual native gear control;
    /// cancellation selects no item. External interactions are injected into the same handlers.
    func verifyPopoverForSmokeTest() async -> Bool {
        guard CommandLine.arguments.contains("--release-smoke-test") else { return fail(#line) }
        func fail(_ line: Int = #line) -> Bool {
            FileHandle.standardError.write(Data("Popover smoke failed at line \(line)\n".utf8))
            return false
        }
        guard updates?.releaseURL?.absoluteString == "https://github.com/ximatai/CodexWatcher/releases/tag/v999.0.0",
              settingsMenu().items.contains(where: { $0.title == "新版本 999.0.0…" }),
              settingsMenu().items.contains(where: { $0.title == "检查更新…" }) else { return fail(#line) }
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
        func menuButtons(in view: NSView) -> [NSPopUpButton] {
            if let button = view as? NSPopUpButton { return [button] }
            return view.subviews.flatMap { menuButtons(in: $0) }
        }

        for cycle in 0..<4 {
            showPopover(clearInitialFocus: true)
            var gear: NSPopUpButton?
            guard await waitFor({
                guard self.popover.isShown, self.localEventMonitor != nil, !self.monitor.isBusy,
                      NSApp.isActive, let view = self.popover.contentViewController?.view,
                      view.window?.isKeyWindow == true else { return false }
                view.layoutSubtreeIfNeeded()
                // The one-window fixture has exactly one native menu button: Settings.
                // SwiftUI's accessibility tree may not exist on a CI desktop without an AX client.
                let buttons = menuButtons(in: view)
                gear = buttons.count == 1 ? buttons.first : nil
                return gear?.isEnabled == true
            }), let gear else {
                let count = popover.contentViewController.map { menuButtons(in: $0.view).count } ?? 0
                FileHandle.standardError.write(Data("Popover readiness: cycle=\(cycle), shown=\(popover.isShown), observing=\(localEventMonitor != nil), busy=\(monitor.isBusy), nativeMenus=\(count)\n".utf8))
                return fail(#line)
            }
            @MainActor final class MenuProbe {
                var sawMenu = false
                var stayedOpen = false
                var cancellation: Timer?
            }
            let probe = MenuProbe()
            let observer = NotificationCenter.default.addObserver(forName: NSMenu.didBeginTrackingNotification,
                object: nil, queue: .main) { [weak self] notification in
                MainActor.assumeIsolated {
                    guard let menu = notification.object as? NSMenu, !probe.sawMenu,
                          menu.items.contains(where: { $0.title == "状态栏显示…" }) else { return }
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
            // Exercise the actual menu control without requiring an external AX client.
            gear.performClick(nil)
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
        // Exercise SwiftUI menu actions as well as menu tracking. A hidden attached
        // sheet may allow performClick while blocking real mouse delivery entirely.
        let pages: [(String, () -> NSWindow?)] = [
            ("状态栏显示…", { self.settingsWindow }),
            ("重置卡临期处理…", { self.expirySettingsWindow }),
            ("满额自动 hello…", { self.helloSettingsWindow })
        ]
        for (title, destination) in pages {
            showPopover(clearInitialFocus: true)
            guard await waitFor({
                guard let view = self.popover.contentViewController?.view else { return false }
                view.layoutSubtreeIfNeeded()
                return menuButtons(in: view).count == 1
            }), let view = popover.contentViewController?.view,
                let gear = menuButtons(in: view).first, let menu = gear.menu,
                let index = menu.items.firstIndex(where: { $0.title == title }) else { return fail(#line) }
            menu.performActionForItem(at: index)
            guard await waitFor({ destination()?.isVisible == true && !self.popover.isShown }),
                  view.window?.attachedSheet == nil else { return fail(#line) }
            // Reopening while the settings window exists must never restore a sheet.
            showPopover(clearInitialFocus: true)
            guard await waitFor({ self.popover.isShown }),
                  let window = view.window, window.attachedSheet == nil,
                  NSApp.modalWindow == nil else { return fail(#line) }
            view.layoutSubtreeIfNeeded()
            guard let reopenedGear = menuButtons(in: view).first else { return fail(#line) }
            let point = reopenedGear.convert(NSPoint(x: reopenedGear.bounds.midX, y: reopenedGear.bounds.midY), to: view.superview)
            guard let hit = view.hitTest(point), hit === reopenedGear || hit.isDescendant(of: reopenedGear) else {
                FileHandle.standardError.write(Data("Gear hit: frame=\(reopenedGear.frame), host=\(view.frame), point=\(point), hit=\(String(describing: view.hitTest(point)))\n".utf8))
                return fail(#line)
            }
            closePopover()
            destination()?.close()
        }
        // Open and cancel a fake reset confirmation; never confirm or send a write.
        guard let credit = monitor.sortedCredits.first,
              let confirmation = monitor.makeResetConfirmation(for: credit) else { return fail(#line) }
        showPopover(clearInitialFocus: true)
        showReset(confirmation)
        guard await waitFor({ self.resetWindow?.isVisible == true && !self.popover.isShown }),
              popover.contentViewController?.view.window?.attachedSheet == nil else { return fail(#line) }
        resetWindow?.close()
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
        _ = add("满额自动 hello…", #selector(showHelloSettings))
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
        if let updates {
            if updates.availableVersion != nil { _ = add(updates.menuTitle, #selector(openUpdate)) }
            add(updates.isChecking ? "正在检查更新…" : "检查更新…", #selector(checkUpdates)).isEnabled = !updates.isChecking
        }
        _ = add("使用帮助", #selector(showHelp))
        _ = add("关于 Codex Watcher", #selector(showAbout))
        menu.addItem(.separator())
        _ = add("退出应用", #selector(quit))
        return menu
    }

    @objc private func showSettings() {
        closePopover()
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
        closePopover()
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

    @objc private func showHelloSettings() {
        closePopover()
        if helloSettingsWindow == nil {
            let hosting = NSHostingController(rootView: AutomaticHelloSettingsView(monitor: monitor,
                onClose: { [weak self] in self?.helloSettingsWindow?.close() }))
            hosting.sizingOptions = [.minSize, .maxSize]
            let window = NSWindow(contentViewController: hosting)
            window.title = "满额自动 hello"
            window.styleMask = [.titled, .closable]
            window.isReleasedWhenClosed = false
            window.center()
            helloSettingsWindow = window
        }
        NSApp.activate(ignoringOtherApps: true)
        helloSettingsWindow?.makeKeyAndOrderFront(nil)
    }

    private func showReset(_ confirmation: ResetConfirmation) {
        closePopover()
        resetWindow?.close()
        let hosting = NSHostingController(rootView: ResetConfirmationView(monitor: monitor,
            confirmation: confirmation,
            cancel: { [weak self] in self?.resetWindow?.close() },
            confirm: { [weak self] in
                guard let self else { return }
                self.resetWindow?.close()
                Task { await self.monitor.redeem(confirmation) }
            }))
        hosting.sizingOptions = [.minSize, .maxSize]
        let window = NSWindow(contentViewController: hosting)
        window.title = confirmation.retry == nil ? "使用重置卡" : "重试重置"
        window.styleMask = [.titled, .closable]
        window.isReleasedWhenClosed = false
        window.center()
        resetWindow = window
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
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
    @objc private func openUpdate() { closePopover(); updates?.openAvailableRelease() }
    @objc private func checkUpdates() {
        closePopover()
        Task { await updates?.checkInteractively() }
    }
    @objc private func showHelp() {
        NSWorkspace.shared.open(URL(string: "https://github.com/ximatai/CodexWatcher/blob/main/docs/USAGE.md")!)
    }
    @objc private func showAbout() {
        NSApp.activate(ignoringOtherApps: true)
        NSApp.orderFrontStandardAboutPanel(nil)
    }
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
