import SwiftUI
import AppKit

enum AppAppearance: String, CaseIterable, Identifiable {
    case system, light, dark
    var id: String { rawValue }
    var title: String { L10n.text(titleResource) }

    var titleResource: String.LocalizationValue {
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
    var background: Color { dark ? color(0x13161A) : color(0xFAFBFC) }
    var surface: Color { dark ? color(0x1B1F24) : .white }
    var accent: Color { dark ? color(0x62CFC3) : color(0x4B6484) }
    var warning: Color { dark ? color(0xE6B86A) : color(0xA65B16) }
    var danger: Color { dark ? color(0xED8B92) : color(0xB83E48) }
    var selectedSurface: Color { dark ? accent.opacity(0.06) : color(0xF0F3F7) }
    var selectedBorder: Color { dark ? accent.opacity(0.45) : color(0xA9B7CA) }
    var separator: Color { Color.primary.opacity(dark ? 0.10 : 0.08) }
    var track: Color { dark ? color(0x303842) : color(0xE6EBF0) }
    // Presentation only; a pace difference does not predict quota exhaustion.
    func deviationColor(_ deviation: Double?) -> Color {
        guard let deviation else { return .secondary }
        return deviation > 10 ? warning : .primary
    }
    func creditExpiryColor(_ urgency: CreditExpiryUrgency) -> Color {
        switch urgency {
        case .withinThreeDays: return .secondary
        case .tomorrow: return warning
        case .today: return danger
        }
    }

    private func color(_ hex: UInt32) -> Color {
        Color(red: Double((hex >> 16) & 0xFF) / 255,
              green: Double((hex >> 8) & 0xFF) / 255,
              blue: Double(hex & 0xFF) / 255)
    }
}
