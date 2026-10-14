import Foundation

enum AppText {
    static func value(_ chinese: String, _ english: String, locale: Locale) -> String {
        let language = Bundle.main.preferredLocalizations.first ??
            Locale.preferredLanguages.first ?? locale.identifier
        return language.lowercased().hasPrefix("zh") ? chinese : english
    }
}
