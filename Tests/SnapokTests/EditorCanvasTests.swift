import AppKit
import Carbon
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
        // Capture-window command routing must win over a menu shortcut using the same key.
        if let screen = NSScreen.main {
            let captureWindow = CaptureWindow(screen: screen, desktopImage: image, windowFrames: [])
            let delegate = CaptureEditDelegate()
            captureWindow.captureDelegate = delegate
            let view = captureWindow.contentView as! CaptureView
            func captureEvent(_ type: NSEvent.EventType, _ x: CGFloat, _ y: CGFloat) -> NSEvent {
                NSEvent.mouseEvent(with: type, location: CGPoint(x: x, y: y), modifierFlags: [], timestamp: 0,
                    windowNumber: captureWindow.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1)!
            }
            view.mouseDown(with: captureEvent(.leftMouseDown, 100, 100))
            view.mouseDragged(with: captureEvent(.leftMouseDragged, 300, 250))
            view.mouseUp(with: captureEvent(.leftMouseUp, 300, 250))
            precondition(AppChannel.editImageHotKey(forRelease: true).menuModifiers == .command)
            precondition(AppChannel.editImageHotKey(forRelease: false).menuModifiers == .option)
            let edit = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: AppChannel.editImageHotKey.menuModifiers, timestamp: 0,
                windowNumber: captureWindow.windowNumber, context: nil, characters: "e", charactersIgnoringModifiers: "e",
                isARepeat: false, keyCode: UInt16(kVK_ANSI_E))!
            precondition(captureWindow.performKeyEquivalent(with: edit))
            guard case .editImage? = delegate.mode else { preconditionFailure("The channel edit shortcut must open the selected image in the editor") }
            precondition(delegate.result?.globalRect.size == CGSize(width: 200, height: 150))
            precondition(ToolbarAction.editImage.title?.contains(AppChannel.editImageHotKey.symbol) == true)
        }
        // Repeated language changes must replace the library page, not stack old pages.
        let languageSuite = "SnapokLibraryRelocalization-" + UUID().uuidString
        let languageDefaults = UserDefaults(suiteName: languageSuite)!
        defer { languageDefaults.removePersistentDomain(forName: languageSuite) }
        let savedLanguage = AppLanguage.current
        defer { AppLanguage.switchTo(savedLanguage, in: languageDefaults) }
        let main = MainWindowController()
        let mainRoot = main.window!.contentView!
        func libraryPages(in view: NSView) -> [LibraryPane] {
            (view as? LibraryPane).map { [$0] } ?? view.subviews.flatMap { libraryPages(in: $0) }
        }
        for language in [AppLanguage.simplifiedChinese, .english, .simplifiedChinese, .english] {
            let previous = libraryPages(in: mainRoot).first!
            AppLanguage.switchTo(language, in: languageDefaults)
            main.relocalize()
            mainRoot.layoutSubtreeIfNeeded()
            let pages = libraryPages(in: mainRoot)
            precondition(pages.count == 1, "Language changes must leave exactly one library page")
            precondition(previous.superview == nil, "The previous page must be detached from the reused container")
            precondition(pages[0].titleLabel.stringValue == language.text("Library", "截图库"))
        }
        print("Passed editor checks: Retina coordinates, drawing/undo, imported annotation movement/style/undo, annotated export, editor layout, library language replacement")
    }
}

@MainActor
private final class CaptureEditDelegate: CaptureWindowDelegate {
    var mode: CaptureFinishMode?
    var result: CaptureResult?
    func captureWindowDidCancel(_ window: CaptureWindow) { }
    func captureWindow(_ window: CaptureWindow, didFinish result: CaptureResult, mode: CaptureFinishMode) {
        self.mode = mode
        self.result = result
    }
}
