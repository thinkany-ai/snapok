import AppKit

enum AppAppearance: String, CaseIterable, Sendable {
    case system
    case light
    case dark

    private static let preferenceKey = "app.appearance"

    static func saved(in defaults: UserDefaults = .standard) -> AppAppearance {
        AppAppearance(rawValue: defaults.string(forKey: preferenceKey) ?? "") ?? .system
    }

    var title: String {
        switch self {
        case .system: return L("System", "跟随系统")
        case .light: return L("Light", "浅色")
        case .dark: return L("Dark", "深色")
        }
    }

    @MainActor
    func apply() {
        switch self {
        case .system: NSApp.appearance = nil
        case .light: NSApp.appearance = NSAppearance(named: .aqua)
        case .dark: NSApp.appearance = NSAppearance(named: .darkAqua)
        }
    }

    @MainActor
    func select(in defaults: UserDefaults = .standard) {
        defaults.set(rawValue, forKey: Self.preferenceKey)
        apply()
    }
}
