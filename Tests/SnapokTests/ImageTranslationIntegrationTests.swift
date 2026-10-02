import AppKit

extension Bundle { static var module: Bundle { .main } }

@main
@MainActor
struct ImageTranslationIntegrationTests {
    static func main() async throws {
        _ = NSApplication.shared
        let provider = ModelProvider(id: "translation-test", name: "Mock", kind: .openai,
            apiBase: "http://127.0.0.1:\(CommandLine.arguments[1])/v1", models: [ModelEntry(id: "text-only")])
        let client = try AIClient(provider: provider, model: "text-only", apiKey: "mock")
        let context = CGContext(data: nil, width: 500, height: 300, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        NSColor.white.setFill(); CGRect(x: 0, y: 0, width: 500, height: 300).fill()
        ("Settings" as NSString).draw(at: CGPoint(x: 40, y: 200), withAttributes: [.font: NSFont.systemFont(ofSize: 30), .foregroundColor: NSColor.black])
        ("Save image" as NSString).draw(at: CGPoint(x: 40, y: 100), withAttributes: [.font: NSFont.systemFont(ofSize: 30), .foregroundColor: NSColor.black])
        NSGraphicsContext.restoreGraphicsState()
        let source = context.makeImage()!
        let scan = await TextScanner.scan(source)
        precondition(scan.blocks.count >= 2 && scan.text.contains("Settings"), "Real Vision OCR must find screenshot labels")
        for vision in [false, true] {
            let blocks = try await AIAssistant.translateImage(source, to: "日本語", useVision: vision, client: client)
            precondition(blocks.count == scan.blocks.count)
            precondition(blocks.allSatisfy { $0.text == "翻訳 \($0.id)" })
            precondition(ImageTranslationRenderer.png(source: source, blocks: blocks) != nil)
        }
        print("Real OCR → mock text-only / optional vision API → image export passed")
    }
}
