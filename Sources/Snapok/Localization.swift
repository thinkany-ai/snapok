import Foundation

/// An explicit app preference; a fresh installation always starts in English.
enum AppLanguage: String, CaseIterable, Sendable {
    case english = "en"
    case simplifiedChinese = "zh-Hans"

    static let preferenceKey = "app.language"

    static func saved(in defaults: UserDefaults = .standard) -> AppLanguage {
        AppLanguage(rawValue: defaults.string(forKey: preferenceKey) ?? "") ?? .english
    }

    static let didChange = Notification.Name("AppLanguage.didChange")

    func save(in defaults: UserDefaults = .standard) {
        defaults.set(rawValue, forKey: Self.preferenceKey)
        // Let AppKit's standard dialogs use the same language on the next launch.
        defaults.set([rawValue], forKey: "AppleLanguages")
    }

    // Read once at launch; afterwards only `switchTo` changes it, so stray preference writes never
    // half-translate the UI. Written on the main thread only.
    nonisolated(unsafe) private static var active = saved()

    static var current: AppLanguage { active }

    /// Saves the choice and switches the running app; observers of `didChange` rebuild their text.
    static func switchTo(_ language: AppLanguage, in defaults: UserDefaults = .standard) {
        language.save(in: defaults)
        guard language != active else { return }
        active = language
        NotificationCenter.default.post(name: didChange, object: nil)
    }

    var locale: Locale { Locale(identifier: rawValue) }

    func text(_ english: String, _ chinese: String) -> String {
        self == .simplifiedChinese ? chinese : english
    }
}

func L(_ english: String, _ chinese: String) -> String {
    AppLanguage.current.text(english, chinese)
}
