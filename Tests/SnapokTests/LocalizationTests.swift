import Foundation

@main
struct LocalizationTests {
    static func main() {
        let suite = "Snapok.LocalizationTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        precondition(AppLanguage.saved(in: defaults) == .english)
        defaults.set("invalid-language", forKey: AppLanguage.preferenceKey)
        precondition(AppLanguage.saved(in: defaults) == .english)
        for language in AppLanguage.allCases {
            language.save(in: defaults)
            precondition(AppLanguage.saved(in: UserDefaults(suiteName: suite)!) == language)
            precondition(defaults.stringArray(forKey: "AppleLanguages") == [language.rawValue])
        }
        // Use a process-local override, never touching the real app's preferences.
        let language = CommandLine.arguments.contains("--chinese") ? AppLanguage.simplifiedChinese : .english
        UserDefaults.standard.setVolatileDomain([AppLanguage.preferenceKey: language.rawValue], forName: UserDefaults.argumentDomain)
        precondition(AppLanguage.current == language)
        precondition(L("Settings", "设置") == (language == .english ? "Settings" : "设置"))
        precondition(L("Deleted \(3) screenshots", "删除 \(3) 张截图").contains("3"))
        // Changing the preference must not partially translate already-open windows.
        UserDefaults.standard.setVolatileDomain([AppLanguage.preferenceKey: "unsupported"], forName: UserDefaults.argumentDomain)
        precondition(AppLanguage.current == language)
        print("Passed localization checks (\(language.rawValue)): default, fallback, persistence, interpolation, session stability")
    }
}
