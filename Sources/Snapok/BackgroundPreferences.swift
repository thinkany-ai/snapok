import Foundation

/// Last-used editor defaults, independent of an individual screenshot.
struct BackgroundPreferences: Codable, Equatable {
    static let gradientPresetCount = 6
    struct CustomGradient: Codable, Equatable {
        var start = [0.91, 0.30, 0.58, 1.0]
        var end = [0.16, 0.58, 0.77, 1.0]
        var angle = 35.0
    }
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
    var customGradient: CustomGradient?
    var usesCustomGradient: Bool?

    static func load(in defaults: UserDefaults = .standard) -> Self {
        guard let data = defaults.data(forKey: key),
              var saved = try? JSONDecoder().decode(Self.self, from: data) else { return Self() }
        saved.backgroundType = min(max(saved.backgroundType, 0), 4)
        saved.gradient = min(max(saved.gradient, 0), gradientPresetCount - 1)
        saved.horizontalPadding = min(max(saved.horizontalPadding, 0), 600)
        saved.verticalPadding = min(max(saved.verticalPadding, 0), 600)
        saved.cornerRadius = min(max(saved.cornerRadius, 0), 80)
        saved.borderWidth = min(max(saved.borderWidth, 0), 20)
        let fallback = Self()
        saved.backgroundColor = normalized(saved.backgroundColor, fallback: fallback.backgroundColor)
        saved.borderColor = normalized(saved.borderColor, fallback: fallback.borderColor)
        if var gradient = saved.customGradient {
            let fallback = CustomGradient()
            gradient.start = normalized(gradient.start, fallback: fallback.start)
            gradient.end = normalized(gradient.end, fallback: fallback.end)
            gradient.angle = gradient.angle.isFinite ? min(max(gradient.angle, 0), 360) : fallback.angle
            saved.customGradient = gradient
        }
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
