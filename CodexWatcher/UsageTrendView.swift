import SwiftUI
import Charts

struct UsageTrendView: View {
    let samples: [UsageTrendSample]
    let quota: QuotaWindow
    let date: Date
    let stale: Bool
    let storageFailed: Bool
    var recoveredHistory = false
    var headerTitle: AnyView? = nil
    @Environment(\.locale) private var locale
    @Environment(\.timeZone) private var timeZone
    @Environment(\.colorScheme) private var colorScheme
    private var palette: AppPalette { AppPalette(dark: colorScheme == .dark) }
    private var format: PresentationFormat { PresentationFormat(locale: locale, timeZone: timeZone) }
    private var history: [UsageTrendSample] {
        samples.filter { $0.reset == quota.resetDate }
    }
    private var forecast: UsageTrendForecast? {
        guard !stale, quota.usedPercent.isFinite, (0...100).contains(quota.usedPercent),
              let last = history.last, abs(last.remaining - (100 - quota.usedPercent)) < 0.001 else { return nil }
        return UsageTrend.forecast(samples: history, at: date)
    }
    private var start: Date { history.first?.date ?? date.addingTimeInterval(-3600) }
    private var end: Date { max(quota.resetDate ?? date, date.addingTimeInterval(60)) }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                if let headerTitle {
                    headerTitle
                } else {
                    Text("剩余额度趋势").font(.headline)
                }
                Spacer()
                legend("历史", color: palette.accent, dashed: false)
                legend("预测", color: palette.warning, dashed: true)
            }
            Chart {
                ForEach(Array(history.enumerated()), id: \.offset) { _, sample in
                    LineMark(x: .value("时间", sample.date), y: .value("剩余额度", sample.remaining),
                             series: .value("采样分段", sample.segment.uuidString))
                        .foregroundStyle(palette.accent)
                        .lineStyle(StrokeStyle(lineWidth: 2))
                    PointMark(x: .value("时间", sample.date), y: .value("剩余额度", sample.remaining))
                        .foregroundStyle(palette.accent).symbolSize(8)
                }
                if let forecast {
                    ForEach(0..<25, id: \.self) { index in
                        let point = forecast.anchor.date.addingTimeInterval(end.timeIntervalSince(forecast.anchor.date) * Double(index) / 24)
                        AreaMark(x: .value("时间", point),
                                 yStart: .value("较快消耗", forecast.remaining(at: point, rate: forecast.fastRate)),
                                 yEnd: .value("较慢消耗", forecast.remaining(at: point, rate: forecast.slowRate)))
                            .foregroundStyle(palette.warning.opacity(0.10))
                    }
                    let finish = min(end, forecast.exhaustion ?? end)
                    ForEach([forecast.anchor.date, finish], id: \.self) { point in
                        LineMark(x: .value("时间", point), y: .value("预测剩余", forecast.remaining(at: point)),
                                 series: .value("预测", "forecast"))
                            .foregroundStyle(palette.warning)
                            .lineStyle(StrokeStyle(lineWidth: 2, dash: [5, 4]))
                    }
                }
                RuleMark(x: .value("现在", date))
                    .foregroundStyle(Color.secondary.opacity(0.5))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
                    .annotation(position: .top, alignment: .leading) {
                        Text("现在").font(.system(size: 9)).foregroundStyle(.secondary)
                    }
                if let reset = quota.resetDate, reset > date {
                    RuleMark(x: .value("重置", reset))
                        .foregroundStyle(Color.secondary.opacity(0.5))
                        .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
                        .annotation(position: .top, alignment: .trailing) {
                            Text("重置").font(.system(size: 9)).foregroundStyle(.secondary)
                        }
                }
            }
            .chartXScale(domain: start...end)
            .chartYScale(domain: 0...100)
            .chartYAxis {
                AxisMarks(position: .leading, values: [0, 50, 100]) { value in
                    AxisGridLine().foregroundStyle(palette.separator)
                    AxisValueLabel {
                        if let number = value.as(Double.self) { Text(format.percent(number)).font(.system(size: 9)) }
                    }
                }
            }
            .chartXAxis {
                AxisMarks(values: .automatic(desiredCount: 3)) { value in
                    AxisValueLabel {
                        if let point = value.as(Date.self) {
                            Text(end.timeIntervalSince(start) < 86400 ? format.date(point, timeOnly: true) : format.compactDate(point))
                                .font(.system(size: 9))
                        }
                    }
                }
            }
            .frame(height: 150)
            .padding(.top, 8)
            .accessibilityLabel("剩余额度趋势")
            .accessibilityValue([summary, secondarySummary].compactMap { $0 }.joined(separator: "，"))
            if let secondarySummary {
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        summaryLabel.fixedSize()
                        Spacer(minLength: 0)
                        Text(secondarySummary).font(.system(size: 11)).foregroundStyle(.secondary).fixedSize()
                    }
                    VStack(alignment: .trailing, spacing: 4) {
                        summaryLabel.frame(maxWidth: .infinity, alignment: .leading)
                        Text(secondarySummary).font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                }
            } else {
                summaryLabel
            }
        }
        .padding(12)
        .background(palette.surface, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(palette.separator))
        .help("按近一小时用量估算，阴影反映消耗速度差异，仅供参考。")
    }

    private var summaryLabel: some View {
        Label(summary, systemImage: warning ? "exclamationmark.circle" : "chart.xyaxis.line")
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(warning ? palette.warning : .secondary)
    }

    private var warning: Bool {
        guard let exhaustion = forecast?.exhaustion, let reset = quota.resetDate else { return false }
        return exhaustion < reset
    }

    private var summary: String {
        if storageFailed { return String(localized: "无法保存趋势数据，请检查本地存储。") }
        if stale { return String(localized: "数据待更新，预测已暂停。") }
        if recoveredHistory { return String(localized: "历史数据已恢复，正在重新采样") }
        if quota.usedPercent >= 100 { return String(localized: "当前额度已耗尽，等待重置。") }
        guard let forecast else { return String(localized: "正在积累数据") }
        guard let exhaustion = forecast.exhaustion else { return String(localized: "近期无消耗") }
        if let reset = quota.resetDate, exhaustion < reset {
            return L10n.text("约\(format.duration(max(0, exhaustion.timeIntervalSince(date)), compact: true))后耗尽", locale: locale)
        }
        return String(localized: "预计可用到本次重置")
    }

    private var secondarySummary: String? {
        guard let exhaustion = forecast?.exhaustion, let reset = quota.resetDate,
              exhaustion < reset else { return nil }
        return L10n.text("比重置早\(format.duration(reset.timeIntervalSince(exhaustion), compact: true))", locale: locale)
    }

    private func legend(_ text: LocalizedStringKey, color: Color, dashed: Bool) -> some View {
        HStack(spacing: 3) {
            Path { path in
                path.move(to: CGPoint(x: 0, y: 1))
                path.addLine(to: CGPoint(x: 14, y: 1))
            }
            .stroke(color, style: StrokeStyle(lineWidth: 2, dash: dashed ? [3, 2] : []))
            .frame(width: 14, height: 2)
            Text(text).font(.system(size: 9)).foregroundStyle(.secondary)
        }
    }
}
