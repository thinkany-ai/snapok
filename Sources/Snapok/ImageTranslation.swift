import AppKit

struct RecognizedImageText: Sendable {
    let id: Int
    let text: String
    /// Normalized, bottom-left origin, matching Vision.
    let box: CGRect
}

enum ImageTranslationError: LocalizedError {
    case noText, invalidResponse
    var errorDescription: String? {
        switch self {
        case .noText: return L("No text was detected in this image.", "没有在图片中识别到文字。")
        case .invalidResponse: return L("The model returned incomplete or invalid translations. Please try again.", "模型返回的翻译不完整或格式错误，请重试。")
        }
    }
}

enum ImageTranslationResponse {
    /// Never replace a source block with a missing, duplicated, or misassigned translation.
    static func decode(_ json: [String: Any], expectedIDs: [Int]) throws -> [Int: String] {
        guard let rows = json["translations"] as? [[String: Any]] else { throw ImageTranslationError.invalidResponse }
        let expected = Set(expectedIDs)
        var result: [Int: String] = [:]
        for row in rows {
            guard let number = row["id"] as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
                  number.doubleValue == Double(number.intValue),
                  expected.contains(number.intValue), result[number.intValue] == nil,
                  let text = row["text"] as? String,
                  !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw ImageTranslationError.invalidResponse }
            result[number.intValue] = text
        }
        guard Set(result.keys) == expected else { throw ImageTranslationError.invalidResponse }
        return result
    }
}

@MainActor
struct ImageTranslationBlock {
    let id: Int
    let original: String
    /// Erasure remains anchored to the original text when the translated layer moves.
    let eraseRect: CGRect
    var rect: CGRect
    var text: String
    var fontSize: CGFloat
    var foreground: NSColor
    var background: NSColor
    var enabled = true
}

@MainActor
enum ImageTranslationRenderer {
    static func blocks(from recognized: [RecognizedImageText], translations: [Int: String], source: CGImage) -> [ImageTranslationBlock] {
        // Normalize to 8-bit sRGB before reading raw pixels; colorAt() may otherwise
        // reinterpret an sRGB image as calibrated RGB and shift sampled fill colors.
        guard let sampling = CGContext(data: nil, width: source.width, height: source.height, bitsPerComponent: 8,
            bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return [] }
        sampling.draw(source, in: CGRect(x: 0, y: 0, width: source.width, height: source.height))
        guard let samplingImage = sampling.makeImage() else { return [] }
        let bitmap = NSBitmapImageRep(cgImage: samplingImage)
        let bounds = CGRect(x: 0, y: 0, width: source.width, height: source.height)
        return recognized.compactMap { item in
            guard let text = translations[item.id] else { return nil }
            let rect = CGRect(x: item.box.minX * bounds.width, y: item.box.minY * bounds.height,
                              width: item.box.width * bounds.width, height: item.box.height * bounds.height).intersection(bounds)
            guard rect.width > 0, rect.height > 0 else { return nil }
            let erase = rect.insetBy(dx: -2, dy: -2).intersection(bounds)
            let background = sampledBackground(bitmap, around: erase)
            let foreground = sampledForeground(bitmap, in: rect, background: background)
            // Vision bounds describe glyph ink, not the font's full line height.
            let estimatedFont = max(6, rect.height * 1.25)
            let lineHeight = estimatedFont * 1.35
            let textRect = CGRect(x: erase.minX, y: rect.midY - lineHeight / 2,
                                  width: erase.width, height: lineHeight).intersection(bounds)
            var block = ImageTranslationBlock(id: item.id, original: item.text, eraseRect: erase,
                rect: textRect, text: text, fontSize: estimatedFont, foreground: foreground, background: background,
                enabled: text.trimmingCharacters(in: .whitespacesAndNewlines) != item.text.trimmingCharacters(in: .whitespacesAndNewlines))
            fit(&block)
            return block
        }
    }

    private static func color(_ bitmap: NSBitmapImageRep, x: CGFloat, y: CGFloat) -> NSColor? {
        // Bitmap rows start at the top; editor coordinates start at the bottom.
        var pixel = [Int](repeating: 0, count: bitmap.samplesPerPixel)
        bitmap.getPixel(&pixel, atX: min(max(Int(x), 0), bitmap.pixelsWide - 1),
                        y: min(max(bitmap.pixelsHigh - 1 - Int(y), 0), bitmap.pixelsHigh - 1))
        return NSColor(srgbRed: CGFloat(pixel[0]) / 255, green: CGFloat(pixel[1]) / 255,
                       blue: CGFloat(pixel[2]) / 255, alpha: 1)
    }

    private static func sampledBackground(_ bitmap: NSBitmapImageRep, around rect: CGRect) -> NSColor {
        var buckets: [Int: [NSColor]] = [:]
        for i in 0..<24 {
            let t = CGFloat(i) / 23
            let points = [CGPoint(x: rect.minX + t * rect.width, y: rect.minY - 1),
                          CGPoint(x: rect.minX + t * rect.width, y: rect.maxY + 1),
                          CGPoint(x: rect.minX - 1, y: rect.minY + t * rect.height),
                          CGPoint(x: rect.maxX + 1, y: rect.minY + t * rect.height)]
            for point in points {
                guard let c = color(bitmap, x: point.x, y: point.y) else { continue }
                let key = Int(c.redComponent * 15) * 256 + Int(c.greenComponent * 15) * 16 + Int(c.blueComponent * 15)
                buckets[key, default: []].append(c)
            }
        }
        guard let colors = buckets.values.max(by: { $0.count < $1.count }), !colors.isEmpty else { return .white }
        let count = CGFloat(colors.count)
        return NSColor(srgbRed: colors.reduce(0) { $0 + $1.redComponent } / count,
                       green: colors.reduce(0) { $0 + $1.greenComponent } / count,
                       blue: colors.reduce(0) { $0 + $1.blueComponent } / count, alpha: 1)
    }

    private static func sampledForeground(_ bitmap: NSBitmapImageRep, in rect: CGRect, background: NSColor) -> NSColor {
        var best = NSColor.black
        var contrast: CGFloat = -1
        let step = max(1, Int(rect.width / 120))
        for y in stride(from: Int(rect.minY), to: Int(rect.maxY), by: 2) {
            for x in stride(from: Int(rect.minX), to: Int(rect.maxX), by: step) {
                guard let c = color(bitmap, x: CGFloat(x), y: CGFloat(y)) else { continue }
                let distance = pow(c.redComponent - background.redComponent, 2)
                    + pow(c.greenComponent - background.greenComponent, 2) + pow(c.blueComponent - background.blueComponent, 2)
                if distance > contrast { contrast = distance; best = c }
            }
        }
        return best
    }

    static func attributes(for block: ImageTranslationBlock) -> [NSAttributedString.Key: Any] {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byWordWrapping
        return [.font: NSFont.systemFont(ofSize: block.fontSize), .foregroundColor: block.foreground, .paragraphStyle: paragraph]
    }

    static func textSize(_ block: ImageTranslationBlock) -> CGSize {
        (block.text as NSString).boundingRect(with: CGSize(width: max(1, block.rect.width), height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading], attributes: attributes(for: block)).size
    }

    static func overflows(_ block: ImageTranslationBlock) -> Bool {
        let size = textSize(block)
        return size.height > block.rect.height + 0.5 || size.width > block.rect.width + 0.5
    }

    static func fit(_ block: inout ImageTranslationBlock) {
        while block.fontSize > 6 && overflows(block) { block.fontSize = max(6, block.fontSize - 0.5) }
    }

    static func draw(source: CGImage, blocks: [ImageTranslationBlock], original: Bool = false) {
        let bounds = CGRect(x: 0, y: 0, width: source.width, height: source.height)
        NSGraphicsContext.current?.cgContext.draw(source, in: bounds)
        guard !original else { return }
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(rect: bounds).addClip()
        // Erase all source text first; masks must not paint over other translated layers.
        for block in blocks where block.enabled {
            block.background.setFill()
            block.eraseRect.fill()
        }
        for block in blocks where block.enabled {
            NSGraphicsContext.saveGraphicsState()
            NSBezierPath(rect: block.rect).addClip()
            (block.text as NSString).draw(with: block.rect, options: [.usesLineFragmentOrigin, .usesFontLeading], attributes: attributes(for: block))
            NSGraphicsContext.restoreGraphicsState()
        }
        NSGraphicsContext.restoreGraphicsState()
    }

    static func png(source: CGImage, blocks: [ImageTranslationBlock]) -> Data? {
        guard let context = CGContext(data: nil, width: source.width, height: source.height, bitsPerComponent: 8,
            bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        draw(source: source, blocks: blocks)
        NSGraphicsContext.restoreGraphicsState()
        guard let image = context.makeImage() else { return nil }
        return NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
    }
}
