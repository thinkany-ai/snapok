import AppKit

enum StepMarkerStyle: String, Codable, CaseIterable {
    case filledCircle, outlinedCircle, roundedSquare

    var title: String {
        switch self {
        case .filledCircle: return L("Filled Circle", "实心圆")
        case .outlinedCircle: return L("Outlined Circle", "空心圆")
        case .roundedSquare: return L("Rounded Square", "圆角方形")
        }
    }
}

/// Numbering is derived from the current annotations, including reopened captures and undo.
@MainActor
enum StepMarkers {
    static func make(at point: CGPoint, annotations: [Annotation], color: NSColor, sizeLevel: Int, style: StepMarkerStyle = .filledCircle) -> Annotation {
        let number = nextNumber(in: annotations)
        var marker = Annotation(kind: .step, rect: CGRect(origin: point, size: .zero), points: [],
                                text: String(number), color: color, sizeLevel: sizeLevel, stepStyle: style)
        resize(&marker)
        return marker
    }

    static func nextNumber(in annotations: [Annotation]) -> Int {
        let highest = annotations.compactMap { annotation in
            Int(annotation.kind == .step ? annotation.text : annotation.stepNumber ?? "")
        }.max() ?? 0
        return highest < Int.max ? highest + 1 : highest
    }

    static func resize(_ marker: inout Annotation) {
        let center = CGPoint(x: marker.rect.midX, y: marker.rect.midY)
        let diameter: CGFloat = [28, 36, 48][min(max(marker.sizeLevel, 0), 2)]
        marker.rect = CGRect(x: center.x - diameter / 2, y: center.y - diameter / 2, width: diameter, height: diameter)
    }

    nonisolated static func badgeRect(for rectangle: Annotation) -> CGRect {
        let diameter: CGFloat = [28, 36, 48][min(max(rectangle.sizeLevel, 0), 2)]
        return CGRect(x: rectangle.rect.minX, y: rectangle.rect.maxY - diameter, width: diameter, height: diameter)
    }

    static func drawRectangleNumber(_ rectangle: Annotation, in context: CGContext) {
        guard let number = rectangle.stepNumber else { return }
        let marker = Annotation(kind: .step, rect: badgeRect(for: rectangle), points: [], text: number,
                                color: rectangle.color, sizeLevel: rectangle.sizeLevel, stepStyle: rectangle.stepStyle)
        draw(marker, in: context)
    }

    static func draw(_ marker: Annotation, in context: CGContext) {
        let rect = marker.rect
        let style = marker.stepStyle ?? .filledCircle
        let shape: NSBezierPath = style == .roundedSquare
            ? NSBezierPath(roundedRect: rect, xRadius: rect.width * 0.22, yRadius: rect.height * 0.22)
            : NSBezierPath(ovalIn: rect)
        let color = marker.color.usingColorSpace(.sRGB) ?? .black
        let luminance = color.redComponent * 0.2126 + color.greenComponent * 0.7152 + color.blueComponent * 0.0722
        let foreground: NSColor = style == .outlinedCircle ? marker.color : luminance > 0.6 ? .black : .white
        if style == .outlinedCircle {
            (luminance > 0.6 ? NSColor.black : NSColor.white).withAlphaComponent(0.92).setFill()
            shape.fill()
            marker.color.setStroke()
            shape.lineWidth = max(2, rect.width / 12)
            shape.stroke()
        } else {
            marker.color.setFill()
            shape.fill()
            foreground.withAlphaComponent(0.85).setStroke()
            shape.lineWidth = 1
            shape.stroke()
        }
        var font = NSFont.monospacedDigitSystemFont(ofSize: rect.height * 0.55, weight: .bold)
        let width = (marker.text as NSString).size(withAttributes: [.font: font]).width
        if width > rect.width * 0.72 {
            font = NSFont.monospacedDigitSystemFont(ofSize: font.pointSize * rect.width * 0.72 / width, weight: .bold)
        }
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: foreground]
        let size = (marker.text as NSString).size(withAttributes: attributes)
        marker.text.draw(at: CGPoint(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2), withAttributes: attributes)
    }
}
