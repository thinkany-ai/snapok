import AppKit
extension Bundle { static var module: Bundle { .main } }

@main @MainActor
struct EditorCanvasTests {
    static func main() throws {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        let context = CGContext(data: nil, width: 600, height: 400, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(red: 1, green: 1, blue: 1, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: 600, height: 400))
        let image = NSImage(cgImage: context.makeImage()!, size: CGSize(width: 300, height: 200))
        let original = Annotation(kind: .rect, rect: CGRect(x: 30, y: 30, width: 100, height: 80), points: [], color: .red, sizeLevel: 1)
        let canvas = BackgroundPreview(image: image, annotations: [original])
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 720, height: 520), styleMask: [.borderless], backing: .buffered, defer: false)
        canvas.frame = window.contentView!.bounds
        window.contentView = canvas
        precondition(canvas.imagePoint(from: CGPoint(x: 360, y: 260)) == CGPoint(x: 150, y: 100), "Retina preview must map to screenshot points")
        func event(_ type: NSEvent.EventType, _ x: CGFloat, _ y: CGFloat) -> NSEvent {
            NSEvent.mouseEvent(with: type, location: CGPoint(x: x, y: y), modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber,
                              context: nil, eventNumber: 1, clickCount: 1, pressure: 1)!
        }
        canvas.chooseTool(.arrow)
        canvas.mouseDown(with: event(.leftMouseDown, 360, 260))
        canvas.mouseDragged(with: event(.leftMouseDragged, 430, 300))
        canvas.mouseUp(with: event(.leftMouseUp, 430, 300))
        precondition(canvas.annotations.count == 2 && canvas.annotations.last!.kind == .arrow)
        canvas.undoEdit()
        precondition(canvas.annotations.count == 1 && canvas.annotations[0].rect == original.rect)
        canvas.chooseTool(nil)
        // Rectangle's left edge, transformed from image point (30, 70).
        let scale = min((720.0 - 64) / 840, (520.0 - 64) / 640)
        let x = (720 - 840 * scale) / 2 + (120 + 30 * 2) * scale
        let y = (520 - 640 * scale) / 2 + (120 + 70 * 2) * scale
        canvas.mouseDown(with: event(.leftMouseDown, x, y))
        canvas.mouseDragged(with: event(.leftMouseDragged, x + 20, y + 10))
        canvas.mouseUp(with: event(.leftMouseUp, x + 20, y + 10))
        precondition(canvas.annotations[0].rect.minX > original.rect.minX, "Imported annotation must remain movable")
        canvas.selectedColor = .blue
        canvas.applyStyle()
        precondition(canvas.annotations[0].color.matches(.blue))
        canvas.undoEdit()
        precondition(canvas.annotations[0].color.matches(.red))
        canvas.undoEdit()
        precondition(canvas.annotations[0].rect == original.rect)
        let composite = BackgroundRenderer.render(source: canvas.source, background: .color(.white), layout: BackgroundLayout()) { cg in
            canvas.drawAnnotations(in: cg)
        }!
        let bitmap = NSBitmapImageRep(cgImage: composite.cgImage(forProposedRect: nil, context: nil, hints: nil)!)
        let color = bitmap.colorAt(x: 180, y: 380)!
        precondition(color.redComponent > 0.9 && color.greenComponent < 0.3, "Export must include source-space annotations at Retina scale")
        let editor = BackgroundEditorController(image: image, screen: nil, annotations: [original])
        let root = editor.window!.contentView!
        root.layoutSubtreeIfNeeded()
        if CommandLine.arguments.count > 1 {
            for (suffix, size) in [("", CGSize(width: 1060, height: 720)), ("-small", CGSize(width: 880, height: 618))] {
                editor.window!.setContentSize(size)
                root.layoutSubtreeIfNeeded()
                let rep = root.bitmapImageRepForCachingDisplay(in: root.bounds)!
                root.cacheDisplay(in: root.bounds, to: rep)
                try rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1] + suffix + ".png"))
            }
        }
        print("Passed editor checks: Retina coordinates, drawing/undo, imported annotation movement/style/undo, annotated export, editor layout")
    }
}
