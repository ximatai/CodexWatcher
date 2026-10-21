import Foundation

/// Keep server values unchanged; adapt only their presentation to system preferences.
struct PresentationFormat {
    var locale: Locale = .autoupdatingCurrent
    var timeZone: TimeZone = .autoupdatingCurrent

    private func text(_ key: String) -> String {
        #if SWIFT_PACKAGE
        let resources = Bundle.module
        #else
        let resources = Bundle.main
        #endif
        let language = locale.language.languageCode?.identifier == "zh" ? "zh-Hans" : "en"
        let bundle = resources.path(forResource: language, ofType: "lproj")
            .flatMap(Bundle.init(path:)) ?? resources
        return bundle.localizedString(forKey: key, value: key, table: nil)
    }

    func date(_ date: Date, precise: Bool = false, timeOnly: Bool = false) -> String {
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.timeZone = timeZone
        // `j` respects the user's preferred 12/24-hour clock; templates preserve regional order.
        formatter.setLocalizedDateFormatFromTemplate(timeOnly ? "jm" : (precise ? "yMMMdjmmsszzz" : "yMMMdjm"))
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

    func deviation(_ value: Double) -> String {
        "\(number(value, decimals: 1, signed: true)) \(text("percentage points"))"
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
        return String(format: text("%@ quota"), locale: locale, duration(minutes * 60))
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
