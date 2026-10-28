import Foundation

/// Preserve interpolation types until localization, using the correct resource bundle.
enum L10n {
    nonisolated static func text(_ value: String.LocalizationValue, locale: Locale? = nil) -> String {
        #if SWIFT_PACKAGE
        let resources = Bundle.module
        #else
        let resources = Bundle.main
        #endif
        // Foundation uses bundle language preferences for text; locale alone controls
        // formatting. Resolve explicit preview/test locales through Apple's language matching.
        let bundle: Bundle
        if let locale,
           let language = Bundle.preferredLocalizations(from: resources.localizations,
                                                        forPreferences: [locale.identifier]).first,
           let path = resources.path(forResource: language, ofType: "lproj"),
           let localized = Bundle(path: path) {
            bundle = localized
        } else {
            bundle = resources
        }
        return String(localized: value, bundle: bundle, locale: locale ?? .autoupdatingCurrent)
    }
}
