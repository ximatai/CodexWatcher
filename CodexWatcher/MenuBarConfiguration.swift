import Foundation

enum MenuBarIcon: String, CaseIterable, Identifiable {
    case gauge, chart, bolt, circle, none
    var id: String { rawValue }
    var title: String { L10n.text(titleResource) }

    private var titleResource: String.LocalizationValue {
        switch self {
        case .gauge: return "仪表盘"
        case .chart: return "用量图表"
        case .bolt: return "闪电"
        case .circle: return "圆环"
        case .none: return "无图标"
        }
    }
    var symbol: String? {
        switch self {
        case .gauge: return "gauge.with.dots.needle.50percent"
        case .chart: return "chart.bar"
        case .bolt: return "bolt"
        case .circle: return "circle.dashed"
        case .none: return nil
        }
    }
}

struct MenuBarConfiguration {
    var icon: MenuBarIcon = .gauge
    var showUsage = true
    var showRemaining = false
    var showTimeProgress = false
    var showDeviation = false

    func title(quota: QuotaWindow?, at date: Date, format: PresentationFormat = .init(),
               isStale: Bool = false) -> String {
        var parts: [String] = []
        if showUsage { parts.append(quota.map { format.percent($0.usedPercent) } ?? "—%") }
        if showRemaining { parts.append(quota.map { format.percent(max(0, 100 - $0.usedPercent)) } ?? "—%") }
        if showTimeProgress {
            parts.append(quota?.standardPercent(at: date).map { format.percent($0) } ?? "—%")
        }
        if showDeviation {
            let deviation = isStale ? nil : quota?.deviation(at: date)
            parts.append((deviation.map { format.number($0, decimals: 1, signed: true) } ?? "—") + "pp")
        }
        return parts.joined(separator: " · ")
    }

    // Preserve access even if preferences were edited externally into an empty label.
    var effectiveSymbol: String? {
        icon.symbol ?? (!showUsage && !showRemaining && !showTimeProgress && !showDeviation ? MenuBarIcon.gauge.symbol : nil)
    }
}
