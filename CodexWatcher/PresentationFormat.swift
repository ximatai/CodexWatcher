import Foundation

enum CreditExpiryUrgency {
    case withinThreeDays, tomorrow, today

    var title: String.LocalizationValue {
        switch self {
        case .withinThreeDays: return "三天内"
        case .tomorrow: return "明日到期"
        case .today: return "今日到期"
        }
    }
}

/// Keep server values unchanged; adapt only their presentation to system preferences.
struct PresentationFormat {
    var locale: Locale = .autoupdatingCurrent
    var timeZone: TimeZone = .autoupdatingCurrent

    func creditExpiryUrgency(_ expiry: Date?, at now: Date) -> CreditExpiryUrgency? {
        guard let expiry, expiry > now else { return nil }
        var calendar = Calendar.autoupdatingCurrent
        calendar.locale = locale
        calendar.timeZone = timeZone
        if calendar.isDate(expiry, inSameDayAs: now) { return .today }
        if let tomorrow = calendar.date(byAdding: .day, value: 1, to: now),
           calendar.isDate(expiry, inSameDayAs: tomorrow) { return .tomorrow }
        if let cutoff = calendar.date(byAdding: .day, value: 3, to: now), expiry <= cutoff {
            return .withinThreeDays
        }
        return nil
    }

    func creditExpiryTitle(_ urgency: CreditExpiryUrgency) -> String {
        text(urgency.title)
    }

    private func text(_ resource: String.LocalizationValue) -> String {
        L10n.text(resource, locale: locale)
    }

    func date(_ date: Date, precise: Bool = false, timeOnly: Bool = false) -> String {
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.timeZone = timeZone
        // `j` respects the user's preferred 12/24-hour clock; templates preserve regional order.
        formatter.setLocalizedDateFormatFromTemplate(timeOnly ? "jm" : (precise ? "yMMMdjmmsszzz" : "yMMMdjm"))
        return formatter.string(from: date)
    }

    func compactDate(_ date: Date, relativeTo reference: Date = .now) -> String {
        var calendar = Calendar.autoupdatingCurrent
        calendar.timeZone = timeZone
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.timeZone = timeZone
        let sameYear = calendar.component(.year, from: date) == calendar.component(.year, from: reference)
        formatter.setLocalizedDateFormatFromTemplate(sameYear ? "MMMdjm" : "yMMMdjm")
        return formatter.string(from: date)
    }

    func number(_ value: Double, decimals: Int = 0, signed: Bool = false) -> String {
        let formatter = NumberFormatter()
        formatter.locale = locale
        formatter.numberStyle = .decimal
        formatter.minimumFractionDigits = decimals
        formatter.maximumFractionDigits = decimals
        if signed { formatter.positivePrefix = formatter.plusSign }
        return formatter.string(from: NSNumber(value: value)) ?? "—"
    }

    func percent(_ value: Double, decimals: Int = 0) -> String {
        let formatter = NumberFormatter()
        formatter.locale = locale
        formatter.numberStyle = .percent
        formatter.minimumFractionDigits = decimals
        formatter.maximumFractionDigits = decimals
        return formatter.string(from: NSNumber(value: value / 100)) ?? "—"
    }

    func deviation(_ value: Double, signed: Bool = true) -> String {
        text("\(number(value, decimals: 1, signed: signed)) percentage points")
    }

    func duration(_ seconds: TimeInterval) -> String {
        if seconds > 0 && seconds < 60 { return text("Less than a minute") }
        let formatter = DateComponentsFormatter()
        var calendar = Calendar.autoupdatingCurrent
        calendar.locale = locale
        calendar.timeZone = timeZone
        formatter.calendar = calendar
        formatter.unitsStyle = .full
        formatter.allowedUnits = [.day, .hour, .minute]
        formatter.maximumUnitCount = 2
        formatter.zeroFormattingBehavior = .dropAll
        return formatter.string(from: max(0, floor(seconds / 60) * 60)) ?? "—"
    }

    func quotaDuration(_ minutes: Double?) -> String {
        guard let minutes, minutes > 0 else { return text("Quota window") }
        return text("\(duration(minutes * 60)) quota")
    }

    func creditTitle(_ title: String?) -> String {
        guard let title, !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return text("Rate-limit reset")
        }
        // Translate known service labels; preserve future or custom labels verbatim.
        switch title.lowercased() {
        case "full reset": return text("Full reset")
        case "rate-limit reset", "rate limit reset": return text("Rate-limit reset")
        default: return title
        }
    }
}
