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
        if CommandLine.arguments.count > 1 {
            try previewBitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
        }
        print("Passed 5 background checks: pixel dimensions/orientation, zero padding, rounded corners, custom image fill, oversized export rejection")
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
