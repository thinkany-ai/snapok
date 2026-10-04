import AppKit

enum CaptureBorderStyle: String, Codable, CaseIterable {
    case solid, dashed, dotted

    var title: String {
        switch self {
        case .solid: return L("Solid", "实线")
        case .dashed: return L("Dashed", "虚线")
        case .dotted: return L("Dotted", "点线")
        }
    }
}

/// Capture overlays only; these preferences never become image annotations.
struct CaptureAppearance: Codable, Equatable {
    static let key = "capture.appearance"
    static let borderWidthRange = 1...10
    var color = [236.0 / 255, 72.0 / 255, 153.0 / 255]
    var borderStyle: CaptureBorderStyle = .solid
    var borderWidth = 2

    private enum CodingKeys: String, CodingKey { case color, borderStyle, borderWidth }

    init() {}

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        color = try values.decodeIfPresent([Double].self, forKey: .color) ?? color
        borderStyle = try values.decodeIfPresent(CaptureBorderStyle.self, forKey: .borderStyle) ?? borderStyle
        borderWidth = try values.decodeIfPresent(Int.self, forKey: .borderWidth) ?? borderWidth
    }

    var nsColor: NSColor {
        NSColor(srgbRed: color[0], green: color[1], blue: color[2], alpha: 1)
    }

    mutating func setColor(_ value: NSColor) {
        guard let rgb = value.usingColorSpace(.sRGB) else { return }
        color = [rgb.redComponent, rgb.greenComponent, rgb.blueComponent]
    }

    static func load(in defaults: UserDefaults = .standard) -> Self {
        guard let data = defaults.data(forKey: key),
              var saved = try? JSONDecoder().decode(Self.self, from: data) else { return Self() }
        if saved.color.count != 3 || !saved.color.allSatisfy(\.isFinite) {
            saved.color = Self().color
        }
        saved.color = saved.color.map { min(max($0, 0), 1) }
        saved.borderWidth = min(max(saved.borderWidth, Self.borderWidthRange.lowerBound), Self.borderWidthRange.upperBound)
        return saved
    }

    func save(in defaults: UserDefaults = .standard) {
        if let data = try? JSONEncoder().encode(self) { defaults.set(data, forKey: Self.key) }
    }

    func stroke(_ rect: CGRect, width: CGFloat) {
        let path = NSBezierPath(rect: rect)
        path.lineWidth = width
        switch borderStyle {
        case .solid: break
        case .dashed: path.setLineDash([8, 5], count: 2, phase: 0)
        case .dotted:
            path.lineCapStyle = .round
            path.setLineDash([0, max(4, width * 2.5)], count: 2, phase: 0)
        }
        nsColor.setStroke()
        path.stroke()
    }
}

@MainActor
final class CaptureAppearancePreview: NSView {
    var appearanceSettings = CaptureAppearance() { didSet { needsDisplay = true } }

    override var intrinsicContentSize: NSSize { NSSize(width: 110, height: 34) }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.controlBackgroundColor.setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 5, yRadius: 5).fill()
        let rect = bounds.insetBy(dx: 9, dy: 8)
        appearanceSettings.stroke(rect, width: CGFloat(appearanceSettings.borderWidth) / (window?.backingScaleFactor ?? 1))
        appearanceSettings.nsColor.setFill()
        for point in [CGPoint(x: rect.minX, y: rect.minY), CGPoint(x: rect.maxX, y: rect.maxY)] {
            CGRect(x: point.x - 2, y: point.y - 2, width: 4, height: 4).fill()
        }
    }
}
