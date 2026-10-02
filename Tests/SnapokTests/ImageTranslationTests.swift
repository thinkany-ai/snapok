import AppKit

func L(_ english: String, _ chinese: String) -> String { english }

@main
@MainActor
struct ImageTranslationTests {
    static func main() throws {
        _ = NSApplication.shared
        let valid: [String: Any] = ["translations": [["id": 4, "text": "设置"], ["id": 2, "text": "保存"]]]
        let result = try ImageTranslationResponse.decode(valid, expectedIDs: [2, 4])
        precondition(result[2] == "保存" && result[4] == "设置", "Translations must map by ID, not response order")
        for rows: [[String: Any]] in [
            [["id": 2, "text": "保存"]],
            [["id": 2, "text": "保存"], ["id": 2, "text": "重复"]],
            [["id": 2, "text": "保存"], ["id": 9, "text": "多余"]],
            [["id": 2, "text": "保存"], ["id": 4, "text": "  "]],
            [["id": true, "text": "错误"], ["id": 4, "text": "设置"]],
            [["id": 2.5, "text": "错误"], ["id": 4, "text": "设置"]]
        ] {
            do { _ = try ImageTranslationResponse.decode(["translations": rows], expectedIDs: [2, 4]); preconditionFailure("Invalid response accepted") }
            catch ImageTranslationError.invalidResponse { }
        }
        let context = CGContext(data: nil, width: 400, height: 240, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        NSColor.white.setFill(); CGRect(x: 0, y: 0, width: 400, height: 240).fill()
        NSColor.darkGray.setFill(); CGRect(x: 0, y: 0, width: 400, height: 100).fill()
        let top = CGRect(x: 30, y: 170, width: 120, height: 30)
        let bottom = CGRect(x: 30, y: 30, width: 120, height: 30)
        ("Settings" as NSString).draw(in: top, withAttributes: [.font: NSFont.systemFont(ofSize: 24), .foregroundColor: NSColor.black])
        ("Save" as NSString).draw(in: bottom, withAttributes: [.font: NSFont.systemFont(ofSize: 24), .foregroundColor: NSColor.white])
        NSGraphicsContext.restoreGraphicsState()
        let source = context.makeImage()!
        let recognized = [RecognizedImageText(id: 2, text: "Settings", box: CGRect(x: 30.0/400, y: 170.0/240, width: 120.0/400, height: 30.0/240)),
                          RecognizedImageText(id: 4, text: "Save", box: CGRect(x: 30.0/400, y: 30.0/240, width: 120.0/400, height: 30.0/240))]
        var blocks = ImageTranslationRenderer.blocks(from: recognized, translations: result, source: source)
        precondition(blocks.count == 2)
        precondition(blocks[0].background.redComponent > 0.9 && blocks[1].background.redComponent < 0.5, "Samples must respect image orientation")
        precondition(blocks[0].foreground.redComponent < 0.1 && blocks[1].foreground.redComponent > 0.9)
        precondition(!ImageTranslationRenderer.overflows(blocks[0]))
        let unchanged = ImageTranslationRenderer.blocks(from: recognized, translations: [2: "Settings", 4: "Save"], source: source)
        precondition(unchanged.allSatisfy { !$0.enabled }, "Unchanged brands and labels must preserve their original pixels")
        blocks[0].text = "A very long translation that must shrink or report overflow"
        ImageTranslationRenderer.fit(&blocks[0])
        precondition(blocks[0].fontSize >= 6)
        precondition(blocks[0].fontSize < 25.5)
        blocks[0].text = "设置"; blocks[0].fontSize = 24
        let data = ImageTranslationRenderer.png(source: source, blocks: blocks)!
        let rendered = NSBitmapImageRep(data: data)!
        precondition(rendered.pixelsWide == 400 && rendered.pixelsHigh == 240, "Export must preserve pixel dimensions")
        let original = NSBitmapImageRep(cgImage: source)
        precondition(rendered.colorAt(x: 28, y: 210)!.isEqual(rendered.colorAt(x: 300, y: 210)!), "A sampled flat fill must match the original background exactly")
        for point in [(300, 20), (300, 200)] {
            precondition(rendered.colorAt(x: point.0, y: point.1)!.isEqual(original.colorAt(x: point.0, y: point.1)!))
        }
        let eraseRect = blocks[0].eraseRect
        blocks[0].rect.origin = CGPoint(x: 200, y: 150)
        precondition(blocks[0].eraseRect == eraseRect, "Moving a layer must not move the original-text mask")
        blocks = blocks.map { var block = $0; block.enabled = false; return block }
        let disabled = NSBitmapImageRep(data: ImageTranslationRenderer.png(source: source, blocks: blocks)!)!
        for y in stride(from: 0, to: 240, by: 3) {
            for x in stride(from: 0, to: 400, by: 3) { precondition(disabled.colorAt(x: x, y: y)!.isEqual(original.colorAt(x: x, y: y)!)) }
        }
        if CommandLine.arguments.count > 1 { try data.write(to: URL(fileURLWithPath: CommandLine.arguments[1])) }
        print("Image translation response, color sampling, layout and export tests passed")
    }
}
