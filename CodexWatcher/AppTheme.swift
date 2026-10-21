import SwiftUI
import AppKit

enum AppAppearance: String, CaseIterable, Identifiable {
    case system, light, dark
    var id: String { rawValue }
    var title: String {
        switch self {
        case .system: return "跟随系统"
        case .light: return "亮色"
        case .dark: return "暗色"
        }
    }
    var nativeAppearance: NSAppearance? {
        switch self {
        case .system: return nil
        case .light: return NSAppearance(named: .aqua)
        case .dark: return NSAppearance(named: .darkAqua)
        }
    }

    @MainActor
    func apply(to application: NSApplication) {
        // Nil restores live system inheritance; SwiftUI's preferredColorScheme(nil)
        // can leave a previous window override in place on macOS.
        for window in application.windows { window.appearance = nil }
        application.appearance = nativeAppearance
    }
}

struct AppPalette {
    let dark: Bool
    var background: Color { dark ? Color(red: 0.075, green: 0.087, blue: 0.102) : Color(red: 0.98, green: 0.985, blue: 0.99) }
    var surface: Color { dark ? Color(red: 0.107, green: 0.122, blue: 0.14) : .white }
    var accent: Color { dark ? Color(red: 0.29, green: 0.88, blue: 0.85) : Color(red: 0, green: 0.56, blue: 0.49) }
    var warning: Color { dark ? Color(red: 1, green: 0.75, blue: 0.36) : Color(red: 0.74, green: 0.36, blue: 0.04) }
    var separator: Color { Color.primary.opacity(dark ? 0.10 : 0.08) }
    var track: Color { dark ? Color(red: 0.19, green: 0.22, blue: 0.26) : Color(red: 0.90, green: 0.92, blue: 0.94) }
    var urgentSurface: Color { warning.opacity(dark ? 0.075 : 0.055) }
}
