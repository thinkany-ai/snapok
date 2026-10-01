import Foundation

/// An explicit app preference; a fresh installation always starts in English.
enum AppLanguage: String, CaseIterable, Sendable {
    case english = "en"
    case simplifiedChinese = "zh-Hans"

    static let preferenceKey = "app.language"

    static func saved(in defaults: UserDefaults = .standard) -> AppLanguage {
        AppLanguage(rawValue: defaults.string(forKey: preferenceKey) ?? "") ?? .english
    }

    func save(in defaults: UserDefaults = .standard) {
        defaults.set(rawValue, forKey: Self.preferenceKey)
        // Let AppKit's standard dialogs use the same language on the next launch.
        defaults.set([rawValue], forKey: "AppleLanguages")
    }

    // Keep one language throughout a session, including already-open editors.
    static let current = saved()

    var locale: Locale { Locale(identifier: rawValue) }

    func text(_ english: String, _ chinese: String) -> String {
        self == .simplifiedChinese ? chinese : english
    }
}

func L(_ english: String, _ chinese: String) -> String {
    AppLanguage.current.text(english, chinese)
}
