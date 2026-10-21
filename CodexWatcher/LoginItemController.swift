import AppKit
import Observation
import ServiceManagement

/// The system is the source of truth; no independent UserDefaults toggle.
@MainActor @Observable
final class LoginItemController {
    static let shared = LoginItemController(
        readStatus: { SMAppService.mainApp.status },
        register: { try SMAppService.mainApp.register() },
        unregister: { try SMAppService.mainApp.unregister() })

    private(set) var status: SMAppService.Status
    @ObservationIgnored private let readStatus: () -> SMAppService.Status
    @ObservationIgnored private let register: () throws -> Void
    @ObservationIgnored private let unregister: () throws -> Void

    init(readStatus: @escaping () -> SMAppService.Status,
         register: @escaping () throws -> Void, unregister: @escaping () throws -> Void) {
        self.readStatus = readStatus
        self.register = register
        self.unregister = unregister
        status = readStatus()
    }

    var needsApproval: Bool { status == .requiresApproval }
    var isRequested: Bool { status == .enabled || needsApproval }
    var title: String { needsApproval ? "登录时启动（待系统允许）" : "登录时启动" }

    func refresh() { status = readStatus() }

    func setEnabled(_ enabled: Bool) throws {
        refresh()
        defer { refresh() }
        if enabled && !isRequested { try register() }
        else if !enabled && isRequested { try unregister() }
    }

    func requestEnabled(_ enabled: Bool) {
        do {
            try setEnabled(enabled)
            if enabled && needsApproval { openSystemSettings() }
        } catch {
            let alert = NSAlert()
            alert.messageText = "无法更新登录启动设置"
            alert.informativeText = "请确认应用已正确签名并放在固定位置（建议“应用程序”文件夹），然后重试。也可在系统设置中管理登录项。"
            alert.alertStyle = .warning
            alert.addButton(withTitle: "好")
            alert.addButton(withTitle: "打开系统设置")
            NSApp.activate(ignoringOtherApps: true)
            if alert.runModal() == .alertSecondButtonReturn { openSystemSettings() }
        }
    }

    func openSystemSettings() { SMAppService.openSystemSettingsLoginItems() }
}
