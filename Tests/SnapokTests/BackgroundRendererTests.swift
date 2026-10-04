import AppKit

@main
@MainActor
struct BackgroundRendererTests {
    static func main() throws {
        _ = NSApplication.shared
        let context = CGContext(data: nil, width: 600, height: 360, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(red: 1, green: 0, blue: 0, alpha: 1)
        context.fill(CGRect(x: 0, y: 180, width: 600, height: 180))
        context.setFillColor(red: 0, green: 0, blue: 1, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: 600, height: 180))
        let source = context.makeImage()!
        let layout = BackgroundLayout(horizontalPadding: 80, verticalPadding: 40, cornerRadius: 0, shadow: false)
        let output = BackgroundRenderer.render(source: source, background: .color(.green), layout: layout)!
        let bitmap = NSBitmapImageRep(cgImage: output.cgImage(forProposedRect: nil, context: nil, hints: nil)!)
        precondition(bitmap.pixelsWide == 760 && bitmap.pixelsHigh == 440, "Padding must expand the canvas in source pixels")
        expect(bitmap, 10, 220, .green)
        expect(bitmap, 400, 10, .green)
        expect(bitmap, 400, 80, .red)
        expect(bitmap, 400, 360, .blue)
        let zero = BackgroundRenderer.render(source: source, background: .color(.green),
                                             layout: BackgroundLayout(horizontalPadding: 0, verticalPadding: 0, cornerRadius: 0, shadow: false))!
        let zeroBitmap = NSBitmapImageRep(cgImage: zero.cgImage(forProposedRect: nil, context: nil, hints: nil)!)
        precondition(zeroBitmap.pixelsWide == 600 && zeroBitmap.pixelsHigh == 360)
        expect(zeroBitmap, 1, 1, .red)
        expect(zeroBitmap, 1, 358, .blue)
        let bordered = BackgroundRenderer.render(source: source, background: .color(.green),
            layout: BackgroundLayout(horizontalPadding: 0, verticalPadding: 0, cornerRadius: 0,
                                     shadow: false, borderWidth: 8, borderColor: .white))!
        let borderBitmap = NSBitmapImageRep(cgImage: bordered.cgImage(forProposedRect: nil, context: nil, hints: nil)!)
        precondition(borderBitmap.pixelsWide == 600 && borderBitmap.pixelsHigh == 360)
        expect(borderBitmap, 2, 90, .white)
        expect(borderBitmap, 597, 90, .white)
        expect(borderBitmap, 300, 2, .white)
        expect(borderBitmap, 300, 357, .white)
        expect(borderBitmap, 12, 90, .red)
        let roundedBorder = BackgroundRenderer.render(source: source, background: .color(.green),
            layout: BackgroundLayout(horizontalPadding: 80, verticalPadding: 40, cornerRadius: 40,
                                     shadow: false, borderWidth: 8, borderColor: .white))!
        let roundedBorderBitmap = NSBitmapImageRep(cgImage: roundedBorder.cgImage(forProposedRect: nil, context: nil, hints: nil)!)
        expect(roundedBorderBitmap, 81, 41, .green)
        expect(roundedBorderBitmap, 400, 43, .white)
        let rounded = BackgroundRenderer.render(source: source, background: .color(.green),
                                                layout: BackgroundLayout(horizontalPadding: 80, verticalPadding: 40, cornerRadius: 40, shadow: false))!
        expect(NSBitmapImageRep(cgImage: rounded.cgImage(forProposedRect: nil, context: nil, hints: nil)!), 81, 41, .green)
        let bg = NSImage(cgImage: source, size: CGSize(width: 600, height: 360))
        let custom = BackgroundRenderer.render(source: source, background: .image(bg), layout: layout)!
        let customBitmap = NSBitmapImageRep(cgImage: custom.cgImage(forProposedRect: nil, context: nil, hints: nil)!)
        expect(customBitmap, 1, 1, .red)
        expect(customBitmap, 1, 438, .blue)
        precondition(BackgroundRenderer.render(source: source, background: .color(.white),
                     layout: BackgroundLayout(horizontalPadding: 20000, verticalPadding: 20000)) == nil)
        let preview = BackgroundRenderer.render(source: source, background: .gradient(0), layout: BackgroundLayout())!
        let previewBitmap = NSBitmapImageRep(cgImage: preview.cgImage(forProposedRect: nil, context: nil, hints: nil)!)
        precondition(EditorBackground.palettes.count == BackgroundPreferences.gradientPresetCount)
        var presets: [Data] = []
        for index in EditorBackground.palettes.indices {
            let preset = BackgroundRenderer.render(source: source, background: .gradient(index), layout: layout)!
            presets.append(NSBitmapImageRep(cgImage: preset.cgImage(forProposedRect: nil, context: nil, hints: nil)!).representation(using: .png, properties: [:])!)
        }
        precondition(Set(presets).count == 6, "All six presets must have distinct backgrounds")
        let horizontal = BackgroundRenderer.render(source: source, background: .customGradient(start: .red, end: .blue, angle: 0), layout: layout)!
        let horizontalBitmap = NSBitmapImageRep(cgImage: horizontal.cgImage(forProposedRect: nil, context: nil, hints: nil)!)
        expect(horizontalBitmap, 1, 220, .red)
        expect(horizontalBitmap, 758, 220, .blue)
        let vertical = BackgroundRenderer.render(source: source, background: .customGradient(start: .red, end: .blue, angle: 90), layout: layout)!
        let verticalBitmap = NSBitmapImageRep(cgImage: vertical.cgImage(forProposedRect: nil, context: nil, hints: nil)!)
        expect(verticalBitmap, 400, 1, .blue)
        expect(verticalBitmap, 400, 438, .red)
        if CommandLine.arguments.count > 1 {
            try previewBitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
        }
        try checkPreferences()
        print("Passed background checks: dimensions/orientation, zero padding, rounded corners, border pixels, custom image fill, export limits, preference restoration")
    }

    static func checkPreferences() throws {
        let suite = "Snapok.BackgroundPreferencesTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        precondition(BackgroundPreferences.load(in: defaults) == BackgroundPreferences())
        var saved = BackgroundPreferences()
        saved.backgroundType = 3
        saved.gradient = 2
        saved.horizontalPadding = 96
        saved.verticalPadding = 32
        saved.cornerRadius = 24
        saved.shadow = false
        saved.borderWidth = 5
        saved.borderColor = [0.2, 0.3, 0.4, 0.8]
        saved.backgroundColor = [0.1, 0.4, 0.5, 1]
        saved.customImagePath = "/tmp/background.tiff"
        saved.customGradient = .init(start: [0.2, 0.4, 0.6, 1], end: [0.9, 0.8, 0.7, 1], angle: 135)
        saved.save(in: defaults)
        precondition(BackgroundPreferences.load(in: UserDefaults(suiteName: suite)!) == saved)
        saved.horizontalPadding = -10
        saved.gradient = 99
        saved.borderWidth = 200
        saved.borderColor = [1, 2]
        saved.save(in: defaults)
        let clamped = BackgroundPreferences.load(in: defaults)
        precondition(clamped.horizontalPadding == 0 && clamped.gradient == 5 && clamped.borderWidth == 20)
        precondition(clamped.borderColor == BackgroundPreferences().borderColor)
        var legacy = try JSONSerialization.jsonObject(with: JSONEncoder().encode(saved)) as! [String: Any]
        legacy.removeValue(forKey: "customGradient")
        defaults.set(try JSONSerialization.data(withJSONObject: legacy), forKey: BackgroundPreferences.key)
        precondition(BackgroundPreferences.load(in: defaults).customGradient == nil, "Existing settings must decode without a custom gradient")
        defaults.set(Data("invalid".utf8), forKey: BackgroundPreferences.key)
        precondition(BackgroundPreferences.load(in: defaults) == BackgroundPreferences())
    }

    static func expect(_ bitmap: NSBitmapImageRep, _ x: Int, _ y: Int, _ expected: NSColor) {
        // Compare stored channels; colorAt returns calibrated colors even for an sRGB bitmap.
        let actual = bitmap.colorAt(x: x, y: y)!
        let expected = expected.usingColorSpace(.sRGB)!
        precondition(abs(actual.redComponent - expected.redComponent) < 0.03 &&
                     abs(actual.greenComponent - expected.greenComponent) < 0.03 &&
                     abs(actual.blueComponent - expected.blueComponent) < 0.03,
                     "Unexpected pixel at \(x), \(y): \(actual)")
    }
}
