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
        // Display zoom and pan must preserve source-space coordinates and exports.
        let anchor = CGPoint(x: 420, y: 290)
        let anchoredPoint = canvas.imagePoint(from: anchor)
        canvas.setZoom(2, around: anchor)
        let afterZoom = canvas.imagePoint(from: anchor)
        precondition(abs(afterZoom.x - anchoredPoint.x) < 0.001 && abs(afterZoom.y - anchoredPoint.y) < 0.001)
        canvas.panBy(dx: 40, dy: -20)
        let afterPan = canvas.imagePoint(from: anchor)
        precondition(abs(afterPan.x - afterZoom.x + 10) < 0.001 && abs(afterPan.y - afterZoom.y - 5) < 0.001)
        canvas.chooseTool(.arrow)
        canvas.mouseDown(with: event(.leftMouseDown, 420, 290))
        canvas.mouseDragged(with: event(.leftMouseDragged, 460, 330))
        canvas.mouseUp(with: event(.leftMouseUp, 460, 330))
        precondition(canvas.annotations.last!.rect.size == CGSize(width: 10, height: 10), "Zoomed drawing must use image coordinates")
        canvas.undoEdit()
        canvas.panBy(dx: 100000, dy: -100000)
        let clampedPoint = canvas.imagePoint(from: anchor)
        canvas.panBy(dx: 100000, dy: -100000)
        precondition(canvas.imagePoint(from: anchor) == clampedPoint, "Panning must stop at canvas edges")
        canvas.fitToWindow()
        func toolKey(_ code: Int, modifiers: NSEvent.ModifierFlags = []) -> NSEvent {
            NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0,
                windowNumber: window.windowNumber, context: nil, characters: "", charactersIgnoringModifiers: "",
                isARepeat: false, keyCode: UInt16(code))!
        }
        for tool in ToolKind.allCases {
            let key = toolKey(Int(tool.shortcutKeyCode))
            canvas.keyDown(with: key)
            precondition(canvas.selectedTool == tool, "Tool key must switch the editor to \(tool)")
            canvas.keyDown(with: key)
            precondition(canvas.selectedTool == tool, "Repeated tool keys must keep the tool selected")
            precondition(ToolKind.matchingShortcut(toolKey(Int(tool.shortcutKeyCode), modifiers: .command)) == nil)
        }
        canvas.keyDown(with: toolKey(kVK_ANSI_3))
        precondition(canvas.sizeLevel == 2)
        canvas.keyDown(with: toolKey(kVK_ANSI_LeftBracket))
        precondition(canvas.sizeLevel == 1)
        canvas.keyDown(with: toolKey(kVK_ANSI_V))
        precondition(canvas.selectedTool == nil)
        precondition(canvas.imagePoint(from: CGPoint(x: 360, y: 260)) == CGPoint(x: 150, y: 100))
        canvas.setZoom(2)
        let composite = BackgroundRenderer.render(source: canvas.source, background: .color(.white), layout: BackgroundLayout()) { cg in
            canvas.drawAnnotations(in: cg)
        }!
        let bitmap = NSBitmapImageRep(cgImage: composite.cgImage(forProposedRect: nil, context: nil, hints: nil)!)
        let color = bitmap.colorAt(x: 180, y: 380)!
        precondition(color.redComponent > 0.9 && color.greenComponent < 0.3, "Export must include source-space annotations at Retina scale")
        precondition(composite.size == CGSize(width: 840, height: 640), "Display zoom must not change exported dimensions")
        canvas.fitToWindow()
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
            let colorClipboard = NSPasteboard.withUniqueName()
            defer { colorClipboard.releaseGlobally() }
            view.mouseMoved(with: captureEvent(.mouseMoved, 100, 100))
            precondition(!view.handleAnnotationShortcut(toolKey(kVK_ANSI_R)), "Do not switch annotation tools before selecting a region")
            precondition(view.copyColorValue(to: colorClipboard) == "#FFFFFF")
            precondition(view.copyColorValue(format: .rgb, to: colorClipboard) == "rgb(255, 255, 255)")
            precondition(colorClipboard.string(forType: .string) == "rgb(255, 255, 255)")
            colorClipboard.clearContents()
            view.copyCurrentContent(to: colorClipboard)
            precondition(colorClipboard.string(forType: .string) == "#FFFFFF")
            precondition(delegate.mode == nil, "Copying a color must keep the screenshot session open")
            let copyColor = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.command, .shift], timestamp: 0,
                windowNumber: captureWindow.windowNumber, context: nil, characters: "C", charactersIgnoringModifiers: "c",
                isARepeat: false, keyCode: UInt16(kVK_ANSI_C))!
            precondition(CaptureView.matchesCopyColorShortcut(copyColor))
            precondition(CaptureView.colorCopyFormat(for: copyColor) == .rgb)
            let hexShortcut = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.command, .option], timestamp: 0,
                windowNumber: captureWindow.windowNumber, context: nil, characters: "c", charactersIgnoringModifiers: "c",
                isARepeat: false, keyCode: UInt16(kVK_ANSI_C))!
            precondition(CaptureView.colorCopyFormat(for: hexShortcut) == .hex)
            view.mouseMoved(with: captureEvent(.mouseMoved, -10, -10))
            precondition(view.copyColorValue(to: colorClipboard) == nil, "Do not sample outside this display")
            precondition(captureWindow.performKeyEquivalent(with: copyColor), "Color shortcut must be consumed before Copy Image menu actions")
            view.mouseDown(with: captureEvent(.leftMouseDown, 100, 100))
            view.mouseDragged(with: captureEvent(.leftMouseDragged, 300, 250))
            view.mouseUp(with: captureEvent(.leftMouseUp, 300, 250))
            precondition(captureWindow.performKeyEquivalent(with: toolKey(kVK_ANSI_R)))
            view.mouseDown(with: captureEvent(.leftMouseDown, 150, 150))
            view.mouseDragged(with: captureEvent(.leftMouseDragged, 220, 190))
            view.mouseUp(with: captureEvent(.leftMouseUp, 220, 190))
            precondition(captureWindow.performKeyEquivalent(with: toolKey(kVK_ANSI_T)), "T must switch directly from rectangle to text")
            if CommandLine.arguments.count > 1 {
                let crop = CGRect(x: 0, y: 50, width: min(600, view.bounds.width), height: min(300, view.bounds.height - 50))
                let rep = view.bitmapImageRepForCachingDisplay(in: crop)!
                view.cacheDisplay(in: crop, to: rep)
                try rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1] + "-capture-mode.png"))
            }
            view.mouseDown(with: captureEvent(.leftMouseDown, 180, 170))
            view.mouseUp(with: captureEvent(.leftMouseUp, 180, 170))
            let input = view.subviews.compactMap { $0 as? NSTextField }.first!
            precondition(captureWindow.firstResponder is NSTextView, "Clicking after T must focus the text input")
            precondition(!view.handleAnnotationShortcut(toolKey(kVK_ANSI_R)), "Letters must remain text while input is active")
            input.stringValue = "RTAP"
            let fieldEditor = captureWindow.firstResponder as! NSTextView
            precondition(!view.control(input, textView: fieldEditor, doCommandBy: #selector(NSResponder.deleteBackward(_:))))
            precondition(view.control(input, textView: fieldEditor, doCommandBy: #selector(NSResponder.insertNewline(_:))))
            precondition(!view.isEditingText && captureWindow.firstResponder === view, "Enter must finish text and restore canvas focus")
            precondition(delegate.mode == nil, "Finishing text must not finish the screenshot")
            precondition(captureWindow.performKeyEquivalent(with: toolKey(kVK_ANSI_R)), "Rectangle shortcut must work after text input")
            precondition(captureWindow.performKeyEquivalent(with: toolKey(kVK_ANSI_T)))
            view.mouseDown(with: captureEvent(.leftMouseDown, 240, 200))
            view.mouseUp(with: captureEvent(.leftMouseUp, 240, 200))
            let emptyInput = view.subviews.compactMap { $0 as? NSTextField }.first!
            precondition(view.control(emptyInput, textView: captureWindow.firstResponder as! NSTextView, doCommandBy: #selector(NSResponder.cancelOperation(_:))))
            precondition(!view.isEditingText && captureWindow.firstResponder === view, "Esc must leave text input without cancelling the screenshot")
            precondition(captureWindow.performKeyEquivalent(with: toolKey(kVK_ANSI_A)), "Arrow shortcut must work after Esc")
            view.copyCurrentContent(to: colorClipboard)
            guard case .copy? = delegate.mode else { preconditionFailure("Copy must finish the screenshot after a region is selected") }
            precondition(delegate.result?.globalRect.size == CGSize(width: 200, height: 150))
            precondition(delegate.result?.annotations.first?.kind == .rect, "R must enable rectangle drawing during capture")
            precondition(delegate.result?.annotations.last?.text == "RTAP", "T must create an editable text annotation after drawing a rectangle")
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
