import AppKit

@MainActor
enum EditorBackground {
    case gradient(Int)
    case color(NSColor)
    case image(NSImage)

    static let palettes: [[NSColor]] = [
        [NSColor(srgbRed: 0.25, green: 0.12, blue: 0.42, alpha: 1), NSColor(srgbRed: 0.91, green: 0.30, blue: 0.58, alpha: 1), NSColor(srgbRed: 1, green: 0.75, blue: 0.60, alpha: 1)],
        [NSColor(srgbRed: 0.05, green: 0.20, blue: 0.44, alpha: 1), NSColor(srgbRed: 0.16, green: 0.58, blue: 0.77, alpha: 1), NSColor(srgbRed: 0.62, green: 0.88, blue: 0.87, alpha: 1)],
        [NSColor(srgbRed: 0.15, green: 0.12, blue: 0.38, alpha: 1), NSColor(srgbRed: 0.47, green: 0.36, blue: 0.77, alpha: 1), NSColor(srgbRed: 0.91, green: 0.71, blue: 0.86, alpha: 1)]
    ]

    func draw(in rect: CGRect) {
        switch self {
        case .gradient(let index):
            NSGradient(colors: Self.palettes[index])?.draw(in: rect, angle: 35)
        case .color(let color):
            color.setFill()
            rect.fill()
        case .image(let image):
            guard image.size.width > 0, image.size.height > 0 else { return }
            let scale = max(rect.width / image.size.width, rect.height / image.size.height)
            let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
            NSGraphicsContext.saveGraphicsState()
            NSBezierPath(rect: rect).addClip()
            image.draw(in: CGRect(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2, width: size.width, height: size.height))
            NSGraphicsContext.restoreGraphicsState()
        }
    }
}

struct BackgroundLayout {
    var horizontalPadding: CGFloat = 120
    var verticalPadding: CGFloat = 120
    var cornerRadius: CGFloat = 16
    var shadow = true

    func canvasSize(for source: CGSize) -> CGSize {
        CGSize(width: source.width + horizontalPadding * 2, height: source.height + verticalPadding * 2)
    }
}

/// One renderer serves both the scaled live preview and the full-resolution PNG.
@MainActor
enum BackgroundRenderer {
    static func draw(source: CGImage, background: EditorBackground, layout: BackgroundLayout, overlay: ((CGContext) -> Void)? = nil) {
        let sourceSize = CGSize(width: source.width, height: source.height)
        let canvas = CGRect(origin: .zero, size: layout.canvasSize(for: sourceSize))
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(rect: canvas).addClip()
        background.draw(in: canvas)
        let photo = CGRect(x: layout.horizontalPadding, y: layout.verticalPadding, width: sourceSize.width, height: sourceSize.height)
        let radius = min(layout.cornerRadius, min(photo.width, photo.height) / 2)
        let outline = NSBezierPath(roundedRect: photo, xRadius: radius, yRadius: radius)
        if layout.shadow {
            NSGraphicsContext.saveGraphicsState()
            let shadow = NSShadow()
            shadow.shadowColor = NSColor.black.withAlphaComponent(0.35)
            shadow.shadowBlurRadius = 32
            shadow.shadowOffset = CGSize(width: 0, height: -12)
            shadow.set()
            NSColor.black.setFill()
            outline.fill()
            NSGraphicsContext.restoreGraphicsState()
        }
        NSGraphicsContext.saveGraphicsState()
        outline.addClip()
        if let context = NSGraphicsContext.current?.cgContext {
            context.draw(source, in: photo)
            context.saveGState()
            context.translateBy(x: photo.minX, y: photo.minY)
            overlay?(context)
            context.restoreGState()
        }
        NSGraphicsContext.restoreGraphicsState()
        NSGraphicsContext.restoreGraphicsState()
    }

    static func render(source: CGImage, background: EditorBackground, layout: BackgroundLayout, overlay: ((CGContext) -> Void)? = nil) -> NSImage? {
        let size = layout.canvasSize(for: CGSize(width: source.width, height: source.height))
        guard size.width.isFinite, size.height.isFinite, size.width > 0, size.height > 0,
              size.width <= 16384, size.height <= 16384, size.width * size.height <= 80_000_000,
              let context = CGContext(data: nil, width: Int(size.width), height: Int(size.height), bitsPerComponent: 8,
                                      bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        draw(source: source, background: background, layout: layout, overlay: overlay)
        NSGraphicsContext.restoreGraphicsState()
        guard let output = context.makeImage() else { return nil }
        return NSImage(cgImage: output, size: size)
    }
}
