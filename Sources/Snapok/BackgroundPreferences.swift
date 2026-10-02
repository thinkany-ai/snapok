import Foundation

/// Last-used editor defaults, independent of an individual screenshot.
struct BackgroundPreferences: Codable, Equatable {
    static let key = "editor.background.preferences"
    var backgroundType = 0
    var gradient = 0
    var horizontalPadding = 120
    var verticalPadding = 120
    var cornerRadius = 16
    var shadow = true
    var borderWidth = 0
    var borderColor = [1.0, 1.0, 1.0, 1.0]
    var backgroundColor = [0.96, 0.90, 0.94, 1.0]
    var customImagePath: String?

    static func load(in defaults: UserDefaults = .standard) -> Self {
        guard let data = defaults.data(forKey: key),
              var saved = try? JSONDecoder().decode(Self.self, from: data) else { return Self() }
        saved.backgroundType = min(max(saved.backgroundType, 0), 3)
        saved.gradient = min(max(saved.gradient, 0), 2)
        saved.horizontalPadding = min(max(saved.horizontalPadding, 0), 600)
        saved.verticalPadding = min(max(saved.verticalPadding, 0), 600)
        saved.cornerRadius = min(max(saved.cornerRadius, 0), 80)
        saved.borderWidth = min(max(saved.borderWidth, 0), 20)
        let fallback = Self()
        saved.backgroundColor = normalized(saved.backgroundColor, fallback: fallback.backgroundColor)
        saved.borderColor = normalized(saved.borderColor, fallback: fallback.borderColor)
        return saved
    }

    func save(in defaults: UserDefaults = .standard) {
        if let data = try? JSONEncoder().encode(self) { defaults.set(data, forKey: Self.key) }
    }

    private static func normalized(_ color: [Double], fallback: [Double]) -> [Double] {
        guard color.count == 4, color.allSatisfy(\.isFinite) else { return fallback }
        return color.map { min(max($0, 0), 1) }
    }
}
