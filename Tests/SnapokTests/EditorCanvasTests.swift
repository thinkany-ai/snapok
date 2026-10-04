import AppKit
import Carbon
extension Bundle { static var module: Bundle { .main } }

@main @MainActor
struct EditorCanvasTests {
    static func main() throws {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        let appearanceSuite = "SnapokCaptureAppearance-" + UUID().uuidString
        let appearanceDefaults = UserDefaults(suiteName: appearanceSuite)!
        defer { appearanceDefaults.removePersistentDomain(forName: appearanceSuite) }
        precondition(CaptureAppearance.load(in: appearanceDefaults) == CaptureAppearance())
        var customAppearance = CaptureAppearance()
        customAppearance.setColor(NSColor(srgbRed: 0, green: 1, blue: 1, alpha: 0.2))
        customAppearance.borderStyle = .dotted
        customAppearance.borderWidth = 5
        customAppearance.save(in: appearanceDefaults)
        precondition(CaptureAppearance.load(in: appearanceDefaults) == customAppearance)
        precondition(CaptureAppearance.load(in: appearanceDefaults).nsColor.alphaComponent == 1)
        appearanceDefaults.set(Data("{\"color\":[2,-1,0.5],\"borderStyle\":\"dashed\"}".utf8), forKey: CaptureAppearance.key)
        precondition(CaptureAppearance.load(in: appearanceDefaults).color == [1, 0, 0.5])
        precondition(CaptureAppearance.load(in: appearanceDefaults).borderWidth == 2, "Older preferences must preserve color/style and use default thickness")
        appearanceDefaults.set(Data("{\"color\":[0,1,1],\"borderStyle\":\"dotted\",\"borderWidth\":99}".utf8), forKey: CaptureAppearance.key)
        precondition(CaptureAppearance.load(in: appearanceDefaults).borderWidth == 10)
        customAppearance.borderWidth = 10
        customAppearance.save(in: appearanceDefaults)
        precondition(CaptureAppearance.load(in: appearanceDefaults).borderWidth == 10, "Border thickness must persist across launches")
        customAppearance.borderWidth = 999
        customAppearance.save(in: appearanceDefaults)
        precondition(CaptureAppearance.load(in: appearanceDefaults).borderWidth == 10)
        customAppearance.borderWidth = 5
        appearanceDefaults.set(Data("{\"color\":[1],\"borderStyle\":\"dotted\"}".utf8), forKey: CaptureAppearance.key)
        precondition(CaptureAppearance.load(in: appearanceDefaults).color == CaptureAppearance().color)
        appearanceDefaults.set(Data("{\"color\":[1,1,1],\"borderStyle\":\"unknown\"}".utf8), forKey: CaptureAppearance.key)
        precondition(CaptureAppearance.load(in: appearanceDefaults) == CaptureAppearance())
        var renderedStyles: [Data] = []
        let appearanceSample = NSView(frame: CGRect(x: 0, y: 0, width: 420, height: 150))
        let appearanceWindow = NSWindow(contentRect: appearanceSample.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        appearanceWindow.contentView = appearanceSample
        for (index, style) in CaptureBorderStyle.allCases.enumerated() {
            let preview = CaptureAppearancePreview(frame: CGRect(x: index * 140, y: 20, width: 130, height: 50))
            customAppearance.borderStyle = style
            preview.appearanceSettings = customAppearance
            appearanceSample.addSubview(preview)
            let rep = preview.bitmapImageRepForCachingDisplay(in: preview.bounds)!
            preview.cacheDisplay(in: preview.bounds, to: rep)
            renderedStyles.append(rep.representation(using: .png, properties: [:])!)
        }
        precondition(Set(renderedStyles).count == 3, "Solid, dashed and dotted borders must render differently")
        var renderedWidths: [Data] = []
        for (index, width) in [1, 3, 5].enumerated() {
            let preview = CaptureAppearancePreview(frame: CGRect(x: index * 140, y: 80, width: 130, height: 50))
            customAppearance.borderStyle = .solid
            customAppearance.borderWidth = width
            preview.appearanceSettings = customAppearance
            appearanceSample.addSubview(preview)
            let rep = preview.bitmapImageRepForCachingDisplay(in: preview.bounds)!
            preview.cacheDisplay(in: preview.bounds, to: rep)
            renderedWidths.append(rep.representation(using: .png, properties: [:])!)
        }
        precondition(Set(renderedWidths).count == 3, "Border thickness must change the rendered preview")
        if CommandLine.arguments.count > 1 {
            let rep = appearanceSample.bitmapImageRepForCachingDisplay(in: appearanceSample.bounds)!
            appearanceSample.cacheDisplay(in: appearanceSample.bounds, to: rep)
            try rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1] + "-selection-styles.png"))
        }
        let general = GeneralSettingsPane()
        let generalWindow = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 780, height: 620), styleMask: [.borderless], backing: .buffered, defer: false)
        generalWindow.contentView = general
        general.layoutSubtreeIfNeeded()
        let settingsScroll = general.subviews.compactMap { $0 as? NSScrollView }.first!
        precondition(settingsScroll.documentView!.frame.height > settingsScroll.contentView.bounds.height,
                     "General settings must scroll so new appearance controls do not hide existing settings")
        if CommandLine.arguments.count > 1 {
            let rep = general.bitmapImageRepForCachingDisplay(in: general.bounds)!
            general.cacheDisplay(in: general.bounds, to: rep)
            try rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1] + "-settings.png"))
        }
        let context = CGContext(data: nil, width: 600, height: 400, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(red: 1, green: 1, blue: 1, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: 600, height: 400))
        let image = NSImage(cgImage: context.makeImage()!, size: CGSize(width: 300, height: 200))
        // Desktop capture flips AppKit coordinates around the main display, not around the union's bottom.
        let primary = CGRect(x: 0, y: 0, width: 300, height: 200)
        let secondaryLayouts = [
            CGRect(x: 0, y: 200, width: 300, height: 200),
            CGRect(x: 0, y: -200, width: 300, height: 200),
            CGRect(x: -300, y: 0, width: 300, height: 200),
            CGRect(x: 300, y: 0, width: 300, height: 300),
            CGRect(x: 300, y: -80, width: 300, height: 200)
        ]
        let expectedCaptureBounds = [
            CGRect(x: 0, y: -200, width: 300, height: 400),
            CGRect(x: 0, y: 0, width: 300, height: 400),
            CGRect(x: -300, y: 0, width: 600, height: 200),
            CGRect(x: 0, y: -100, width: 600, height: 300),
            CGRect(x: 0, y: 0, width: 600, height: 280)
        ]
        for (secondary, expectedBounds) in zip(secondaryLayouts, expectedCaptureBounds) {
            let bounds = primary.union(secondary)
            let captureBounds = DesktopGeometry.captureRect(for: bounds, primaryHeight: primary.height)
            precondition(captureBounds == expectedBounds, "Capture must include offset displays in Quartz coordinates")
            for scale: CGFloat in [1, 2] {
                let cg = CGContext(data: nil, width: Int(bounds.width * scale), height: Int(bounds.height * scale),
                                   bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                   bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
                cg.scaleBy(x: scale, y: scale)
                cg.translateBy(x: -bounds.minX, y: -bounds.minY)
                cg.setFillColor(red: 1, green: 0, blue: 0, alpha: 1); cg.fill(primary)
                cg.setFillColor(red: 0, green: 0, blue: 1, alpha: 1); cg.fill(secondary)
                let desktop = NSImage(cgImage: cg.makeImage()!, size: bounds.size)
                for (index, frame) in [primary, secondary].enumerated() {
                    let cropped = ScreenCapture.crop(image: desktop, to: frame, desktopBounds: bounds)!
                    let bitmap = NSBitmapImageRep(cgImage: cropped.cgImage(forProposedRect: nil, context: nil, hints: nil)!)
                    precondition(bitmap.pixelsWide == Int(frame.width * scale) && bitmap.pixelsHigh == Int(frame.height * scale))
                    let color = bitmap.colorAt(x: bitmap.pixelsWide / 2, y: bitmap.pixelsHigh / 2)!
                    precondition(index == 0 ? color.redComponent > 0.99 : color.blueComponent > 0.99,
                                 "Both screens must retain their own desktop, including above/below and unequal heights")
                    let output = ScreenCapture.render(image: desktop, result: CaptureResult(globalRect: frame, annotations: []), desktopBounds: bounds)!
                    precondition(output.pngData == cropped.pngData, "Preview and export must use the same frozen desktop bounds")
                }
            }
        }
        // Step markers place immediately, remain editable, and resume numbering after undo/reopen.
        let steps = BackgroundPreview(image: image)
        let stepsWindow = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 720, height: 520), styleMask: [.borderless], backing: .buffered, defer: false)
        steps.frame = stepsWindow.contentView!.bounds
        stepsWindow.contentView = steps
        steps.chooseTool(.step)
        func stepEvent(_ type: NSEvent.EventType, _ point: CGPoint) -> NSEvent {
            NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: 0,
                              windowNumber: stepsWindow.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1)!
        }
        let firstStepPoint = CGPoint(x: 310, y: 260)
        let secondStepPoint = CGPoint(x: 410, y: 260)
        steps.mouseDown(with: stepEvent(.leftMouseDown, firstStepPoint))
        precondition(steps.annotations.map(\.text) == ["1"], "A single click must place step 1 without dragging")
        steps.mouseUp(with: stepEvent(.leftMouseUp, firstStepPoint))
        steps.mouseDown(with: stepEvent(.leftMouseDown, secondStepPoint))
        steps.mouseUp(with: stepEvent(.leftMouseUp, secondStepPoint))
        precondition(steps.annotations.map(\.text) == ["1", "2"], "Each click must add exactly one consecutive step")
        steps.undoEdit()
        precondition(steps.annotations.map(\.text) == ["1"])
        steps.mouseDown(with: stepEvent(.leftMouseDown, secondStepPoint))
        steps.mouseUp(with: stepEvent(.leftMouseUp, secondStepPoint))
        precondition(steps.annotations.last!.text == "2", "Undo must also restore the next step number")
        let markerRect = steps.annotations[0].rect
        steps.mouseDown(with: stepEvent(.leftMouseDown, firstStepPoint))
        steps.mouseDragged(with: stepEvent(.leftMouseDragged, CGPoint(x: 320, y: 270)))
        steps.mouseUp(with: stepEvent(.leftMouseUp, CGPoint(x: 320, y: 270)))
        precondition(steps.annotations.count == 2 && steps.annotations[0].rect.origin != markerRect.origin,
                     "Dragging a step must move it without creating another number")
        let stepCenter = CGPoint(x: steps.annotations[0].rect.midX, y: steps.annotations[0].rect.midY)
        steps.sizeLevel = 2
        steps.selectedColor = .blue
        steps.applyStyle()
        precondition(steps.annotations[0].rect.width == 48 && steps.annotations[0].color.matches(.blue))
        precondition(CGPoint(x: steps.annotations[0].rect.midX, y: steps.annotations[0].rect.midY) == stepCenter,
                     "Changing size must preserve a step's center")
        let savedSteps = try JSONDecoder().decode([Annotation].self, from: JSONEncoder().encode(steps.annotations))
        precondition(savedSteps.map(\.text) == ["1", "2"] && savedSteps.allSatisfy { $0.kind == .step })
        precondition(StepMarkers.nextNumber(in: savedSteps) == 3 && StepMarkers.nextNumber(in: []) == 1)
        steps.deleteSelected()
        precondition(steps.annotations.map(\.text) == ["2"] && StepMarkers.nextNumber(in: steps.annotations) == 3,
                     "Deleting an earlier step must not renumber existing steps")
        let stepExport = HistoryRenderer.render(original: image, annotations: savedSteps)!
        precondition(stepExport.size == image.size && stepExport.pngData != image.pngData,
                     "Step circles and numbers must appear in Retina exports")
        var styleExports: [Data] = []
        for style in StepMarkerStyle.allCases {
            var annotation = savedSteps[0]
            annotation.stepStyle = style
            let restored = try JSONDecoder().decode(Annotation.self, from: JSONEncoder().encode(annotation))
            precondition(restored.stepStyle == style)
            let output = HistoryRenderer.render(original: image, annotations: [annotation])!
            styleExports.append(output.pngData!)
            if CommandLine.arguments.count > 1 {
                try output.pngData!.write(to: URL(fileURLWithPath: CommandLine.arguments[1] + "-step-" + style.rawValue + ".png"))
            }
        }
        precondition(Set(styleExports).count == StepMarkerStyle.allCases.count, "All three step styles must render differently")
        var legacyStep = try JSONSerialization.jsonObject(with: JSONEncoder().encode(savedSteps[0])) as! [String: Any]
        legacyStep.removeValue(forKey: "stepStyle")
        let restoredLegacyStep = try JSONDecoder().decode(Annotation.self, from: JSONSerialization.data(withJSONObject: legacyStep))
        precondition(restoredLegacyStep.stepStyle == nil && restoredLegacyStep.text == "1", "Old number markers must reopen as filled circles")
        steps.chooseTool(.rect)
        steps.setNumberRect(true)
        steps.stepStyle = .roundedSquare
        steps.mouseDown(with: stepEvent(.leftMouseDown, CGPoint(x: 300, y: 220)))
        steps.mouseDragged(with: stepEvent(.leftMouseDragged, CGPoint(x: 420, y: 300)))
        steps.mouseUp(with: stepEvent(.leftMouseUp, CGPoint(x: 420, y: 300)))
        precondition(steps.annotations.last!.kind == .rect && steps.annotations.last!.stepNumber == "3")
        precondition(steps.annotations.last!.stepStyle == .roundedSquare && StepMarkers.nextNumber(in: steps.annotations) == 4,
                     "Automatic rectangle numbering must share the marker sequence and style")
        let numberedBox = steps.annotations.last!
        let shiftedBox = numberedBox.offsetBy(dx: 20, dy: -10)
        precondition(StepMarkers.badgeRect(for: shiftedBox).origin == CGPoint(x: StepMarkers.badgeRect(for: numberedBox).minX + 20,
                                                                           y: StepMarkers.badgeRect(for: numberedBox).minY - 10))
        precondition(shiftedBox.stepNumber == "3", "Moving a numbered rectangle must preserve and move its number")
        let restoredBox = try JSONDecoder().decode(Annotation.self, from: JSONEncoder().encode(numberedBox))
        precondition(restoredBox.stepNumber == "3" && restoredBox.stepStyle == .roundedSquare)
        steps.undoEdit()
        precondition(steps.annotations.last!.text == "2" && StepMarkers.nextNumber(in: steps.annotations) == 3)
        steps.setNumberRect(false)
        steps.mouseDown(with: stepEvent(.leftMouseDown, CGPoint(x: 300, y: 220)))
        steps.mouseDragged(with: stepEvent(.leftMouseDragged, CGPoint(x: 420, y: 300)))
        steps.mouseUp(with: stepEvent(.leftMouseUp, CGPoint(x: 420, y: 300)))
        precondition(steps.annotations.last!.stepNumber == nil, "Ordinary rectangles must remain unnumbered when the switch is off")
        // Image editing types directly on the image, preserving original coordinates at any zoom.
        let inline = BackgroundPreview(image: image)
        let inlineWindow = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 720, height: 520), styleMask: [.borderless], backing: .buffered, defer: false)
        inline.frame = inlineWindow.contentView!.bounds
        inlineWindow.contentView = inline
        func textClick(_ count: Int = 1) -> NSEvent {
            NSEvent.mouseEvent(with: .leftMouseDown, location: CGPoint(x: 360, y: 260), modifierFlags: [], timestamp: 0,
                              windowNumber: inlineWindow.windowNumber, context: nil, eventNumber: 1, clickCount: count, pressure: 1)!
        }
        inline.chooseTool(.text)
        inline.mouseDown(with: textClick())
        let inlineField = inline.subviews.compactMap { $0 as? NSTextField }.first!
        precondition(inlineWindow.attachedSheet == nil && inlineWindow.firstResponder is NSTextView)
        let inlineEditor = inlineWindow.firstResponder as! NSTextView
        inlineEditor.string = "直接输入 Text"
        inlineEditor.didChangeText()
        let originalFontSize = inline.textStyle.pointSize
        inline.setZoom(1.5)
        precondition(abs(inlineField.font!.pointSize - originalFontSize * 3) < 0.001)
        precondition(inline.control(inlineField, textView: inlineEditor, doCommandBy: #selector(NSResponder.insertNewline(_:))))
        precondition(inline.annotations.count == 1 && inline.annotations[0].text == "直接输入 Text")
        precondition(inline.annotations[0].textFont.pointSize == originalFontSize)
        precondition(inline.annotations[0].rect.minX == 150)
        let firstTextRect = inline.annotations[0].rect
        inline.mouseDown(with: textClick(2))
        let editingField = inline.subviews.compactMap { $0 as? NSTextField }.first!
        editingField.stringValue = "Edited"
        inline.mouseDown(with: textClick())
        precondition(inline.annotations.count == 1 && inline.annotations[0].text == "Edited")
        precondition(inline.annotations[0].rect.origin == firstTextRect.origin)
        precondition(inline.subviews.compactMap { $0 as? NSTextField }.isEmpty)
        inline.undoEdit()
        precondition(inline.annotations[0].text == "直接输入 Text")
        inline.mouseDown(with: textClick(2))
        inline.subviews.compactMap { $0 as? NSTextField }.first!.stringValue = ""
        inline.commitTextEditing()
        precondition(inline.annotations.isEmpty)
        inline.undoEdit()
        precondition(inline.annotations.count == 1)
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
        // Text stays draggable while the text tool is selected, including at Retina scale.
        let textAnnotation = Annotation(kind: .text, rect: CGRect(x: 140, y: 90, width: 80, height: 30), points: [], text: "Move me", color: .red, sizeLevel: 1)
        canvas.append([textAnnotation])
        canvas.chooseTool(.text)
        canvas.mouseDown(with: event(.leftMouseDown, 360, 260))
        precondition(window.attachedSheet == nil, "Single-clicking text must not reopen the input dialog")
        canvas.mouseDragged(with: event(.leftMouseDragged, 380, 270))
        canvas.mouseUp(with: event(.leftMouseUp, 380, 270))
        let movedText = canvas.annotations.last!
        precondition(abs(movedText.rect.minX - textAnnotation.rect.minX - 20 / (scale * 2)) < 0.001)
        precondition(abs(movedText.rect.minY - textAnnotation.rect.minY - 10 / (scale * 2)) < 0.001)
        precondition(movedText.text == textAnnotation.text)
        var pixelStyle = AnnotationTextStyle(pointSize: 20)
        precondition(pixelStyle.pixelSize(at: 1) == 20 && pixelStyle.pixelSize(at: 2) == 40)
        pixelStyle.setPixelSize(24, scale: 2)
        precondition(pixelStyle.font.pointSize == 12 && pixelStyle.pixelSize(at: 2) == 24, "Pixel sizes must account for Retina export scale")
        let oldStyle = try JSONDecoder().decode(AnnotationTextStyle.self, from: Data(#"{"family":"Helvetica","pointSize":20}"#.utf8))
        precondition(!oldStyle.bold && oldStyle.pointSize == 20, "Previously saved fonts must load without a bold field")
        let fontControls = AnnotationTextControls(frame: CGRect(x: 0, y: 0, width: 256, height: 26))
        fontControls.update(oldStyle, pixelScale: 2)
        let sizeInput = fontControls.subviews.compactMap { $0 as? PixelNumberControl }.first!
        precondition(sizeInput.value == 40)
        var changedStyle: AnnotationTextStyle?
        fontControls.onChange = { changedStyle = $0 }
        let fontControlWindow = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 288, height: 80), styleMask: [.borderless], backing: .buffered, defer: false)
        fontControlWindow.contentView = fontControls
        fontControls.layoutSubtreeIfNeeded()
        fontControlWindow.makeFirstResponder(sizeInput.input)
        let numberEditor = fontControlWindow.firstResponder as! NSTextView
        numberEditor.string = "25"
        numberEditor.didChangeText()
        precondition(sizeInput.value == 40 && changedStyle == nil, "Typing must not apply a partial number")
        func numberClick(at point: CGPoint) -> NSEvent {
            NSEvent.mouseEvent(with: .leftMouseDown, location: point, modifierFlags: [], timestamp: 0,
                windowNumber: fontControlWindow.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1)!
        }
        let insideNumber = sizeInput.input.convert(CGPoint(x: 10, y: 10), to: nil)
        var endedNumberEditing = false
        sizeInput.onEndEditing = { endedNumberEditing = true }
        sizeInput.finishEditingIfClickedOutside(numberClick(at: insideNumber))
        precondition(sizeInput.isEditing && changedStyle == nil, "Clicking inside a number must preserve editing")
        sizeInput.finishEditingIfClickedOutside(numberClick(at: CGPoint(x: 270, y: 65)))
        precondition(!sizeInput.isEditing, "Clicking blank space must end editing without another focusable control")
        precondition(endedNumberEditing, "Ending input with a click must restore the host's keyboard handling")
        precondition(changedStyle?.pointSize == 12.5, "Typed pixel sizes must convert to drawing points")
        sizeInput.adjust(by: 1)
        precondition(changedStyle?.pointSize == 13, "Buttons must change font size by one pixel")
        sizeInput.input.stringValue = "invalid"
        sizeInput.commitInput()
        precondition(sizeInput.value == 26 && sizeInput.input.stringValue == "26")
        precondition(sizeInput.validationMessage != nil, "Invalid numbers must explain why the previous value was kept")
        sizeInput.input.stringValue = "999"
        sizeInput.commitInput()
        precondition(sizeInput.value == 288, "Font size must clamp to its supported range")
        precondition(sizeInput.validationMessage?.contains("288") == true, "Clamping must show the range and adjusted value")
        let borderInput = PixelNumberControl(value: 2, range: CaptureAppearance.borderWidthRange, label: "Border")
        borderInput.input.stringValue = "10"
        borderInput.commitInput()
        precondition(borderInput.value == 10 && borderInput.validationMessage == nil)
        borderInput.input.stringValue = "200"
        borderInput.commitInput()
        precondition(borderInput.value == 10 && borderInput.validationMessage?.contains("10") == true)
        borderInput.commitInput()
        precondition(borderInput.validationMessage != nil, "A second end-editing callback must not immediately hide the warning")
        borderInput.input.stringValue = "5"
        borderInput.commitInput()
        precondition(borderInput.value == 5 && borderInput.validationMessage == nil)
        borderInput.adjust(by: -100)
        precondition(borderInput.value == 1)
        let wheel = CGEvent(scrollWheelEvent2Source: nil, units: .line, wheelCount: 1, wheel1: 1, wheel2: 0, wheel3: 0)!
        borderInput.input.scrollWheel(with: NSEvent(cgEvent: wheel)!)
        precondition(borderInput.value == 2, "Scrolling over the numeric field must increment the value")
        let boldButton = fontControls.subviews.compactMap { $0 as? NSButton }.first { $0.title == "B" }!
        boldButton.performClick(nil)
        precondition(changedStyle?.bold == true, "The bold button must update the text style")
        let customTextStyle = AnnotationTextStyle(family: "Helvetica", pointSize: 36, bold: true)
        canvas.textStyle = customTextStyle
        canvas.applyStyle()
        let styledText = canvas.annotations.last!
        precondition(styledText.textStyle == customTextStyle && styledText.textFont.pointSize == 36)
        precondition(NSFontManager.shared.traits(of: styledText.textFont).contains(.boldFontMask), "Text rendering must resolve a bold font")
        precondition(styledText.rect.size == (styledText.text as NSString).size(withAttributes: [.font: styledText.textFont]), "Font changes must update text hit bounds")
        let restoredText = try JSONDecoder().decode(Annotation.self, from: JSONEncoder().encode(styledText))
        precondition(restoredText.textStyle == customTextStyle, "Font family and exact size must survive saving")
        let legacyText = try JSONDecoder().decode(Annotation.self, from: JSONEncoder().encode(textAnnotation))
        precondition(legacyText.textStyle == nil && legacyText.textFont.pointSize == 20, "Old screenshots must retain their original text size")
        canvas.undoEdit()
        precondition(canvas.annotations.last!.rect == movedText.rect && canvas.annotations.last!.textStyle == nil, "Undo must restore the previous font and bounds")
        canvas.undoEdit()
        precondition(canvas.annotations.last!.rect == textAnnotation.rect, "Undo must restore the text position")
        canvas.undoEdit()
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
        func colorWells(in view: NSView) -> [NSColorWell] {
            (view as? NSColorWell).map { [$0] } ?? view.subviews.flatMap { colorWells(in: $0) }
        }
        for well in colorWells(in: root) {
            precondition(well.frame.width == 34 && well.frame.height == 22, "Color entries must remain compact native swatches")
        }
        var gradientPreferences = BackgroundPreferences()
        gradientPreferences.backgroundType = 4
        gradientPreferences.customGradient = .init(start: [1, 0, 0, 1], end: [0, 0, 1, 1], angle: 135)
        let gradientEditor = BackgroundEditorController(image: image, screen: nil, style: gradientPreferences)
        let gradientRoot = gradientEditor.window!.contentView!
        gradientRoot.layoutSubtreeIfNeeded()
        precondition(gradientEditor.captureStyle.preferences.customGradient == gradientPreferences.customGradient)
        guard case .customGradient(_, _, let restoredAngle) = gradientEditor.captureStyle.background else {
            preconditionFailure("Custom gradients must restore directly in the editor")
        }
        precondition(restoredAngle == 135)
        if CommandLine.arguments.count > 1 {
            let rep = gradientRoot.bitmapImageRepForCachingDisplay(in: gradientRoot.bounds)!
            gradientRoot.cacheDisplay(in: gradientRoot.bounds, to: rep)
            try rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1] + "-custom-gradient.png"))
        }
        func descendants(of view: NSView) -> [NSView] {
            [view] + view.subviews.flatMap { descendants(of: $0) }
        }
        let gradientViews = descendants(of: gradientRoot)
        let backgroundPicker = gradientViews.compactMap { $0 as? NSPopUpButton }.first { $0.itemTitles.first == L("Gradient", "渐变") }!
        precondition(backgroundPicker.numberOfItems == 4 && backgroundPicker.indexOfSelectedItem == 0,
                     "Custom gradients must use the single Gradient entry")
        let presets = gradientViews.compactMap { $0 as? NSButton }.filter { $0.action == NSSelectorFromString("selectPreset:") }
        precondition(presets.count == 6, "The editor must offer exactly six built-in gradients")
        let angle = gradientViews.compactMap { $0 as? NSSlider }.first { $0.action == NSSelectorFromString("changeCustomGradient") }!
        precondition(!angle.isHiddenOrHasHiddenAncestor, "Gradient editing must be visible in the Gradient section")
        presets.first { $0.tag == 1 }!.performClick(nil)
        guard case .gradient(let presetIndex) = gradientEditor.captureStyle.background else {
            preconditionFailure("Selecting a preset must preserve its original color stops")
        }
        precondition(presetIndex == 1 && angle.doubleValue == 35)
        precondition(!angle.isHiddenOrHasHiddenAncestor)
        angle.doubleValue = 90
        NSApp.sendAction(angle.action!, to: angle.target, from: angle)
        precondition(backgroundPicker.indexOfSelectedItem == 0)
        guard case .customGradient(_, _, let editedAngle) = gradientEditor.captureStyle.background else {
            preconditionFailure("Editing a preset must create a custom gradient within the same entry")
        }
        precondition(editedAngle == 90)
        backgroundPicker.selectItem(at: 2)
        NSApp.sendAction(backgroundPicker.action!, to: backgroundPicker.target, from: backgroundPicker)
        precondition(angle.isHiddenOrHasHiddenAncestor)
        backgroundPicker.selectItem(at: 0)
        NSApp.sendAction(backgroundPicker.action!, to: backgroundPicker.target, from: backgroundPicker)
        guard case .customGradient(_, _, let returnedAngle) = gradientEditor.captureStyle.background else {
            preconditionFailure("Returning to Gradient must preserve the edited colors and direction")
        }
        precondition(returnedAngle == 90 && !angle.isHiddenOrHasHiddenAncestor)
        var oldGradientPreferences = BackgroundPreferences()
        oldGradientPreferences.gradient = 8
        let oldGradientEditor = BackgroundEditorController(image: image, screen: nil, style: oldGradientPreferences)
        guard case .gradient(let compatiblePreset) = oldGradientEditor.captureStyle.background else {
            preconditionFailure("Old gradient entries must restore to an available preset")
        }
        precondition(compatiblePreset == 5)
        let operationFeedback = WindowFeedback()
        let initialResponder = editor.window!.firstResponder
        operationFeedback.show("Copied to clipboard.", in: editor.window)
        root.layoutSubtreeIfNeeded()
        let firstToast = root.subviews.compactMap { $0 as? FeedbackToast }.first!
        precondition(firstToast.frame.height >= 44 && firstToast.frame.width <= root.bounds.width - 48)
        precondition(firstToast.hitTest(.zero) == nil && editor.window!.firstResponder === initialResponder,
                     "Feedback must not intercept canvas input or take keyboard focus")
        if CommandLine.arguments.count > 1 {
            let rep = root.bitmapImageRepForCachingDisplay(in: root.bounds)!
            root.cacheDisplay(in: root.bounds, to: rep)
            try rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1] + "-feedback.png"))
        }
        operationFeedback.show("Image saved.", in: editor.window)
        root.layoutSubtreeIfNeeded()
        let toasts = root.subviews.compactMap { $0 as? FeedbackToast }
        precondition(toasts.count == 1 && firstToast.superview == nil && toasts[0].messageLabel.stringValue == "Image saved.",
                     "Repeated operations must replace rather than stack feedback")
        operationFeedback.dismiss()
        precondition(root.subviews.compactMap { $0 as? FeedbackToast }.isEmpty)
        func editorPreview(in view: NSView) -> BackgroundPreview? {
            if let preview = view as? BackgroundPreview { return preview }
            return view.subviews.compactMap { editorPreview(in: $0) }.first
        }
        if CommandLine.arguments.count > 1 {
            for (suffix, size) in [("", CGSize(width: 1060, height: 720)), ("-small", CGSize(width: 880, height: 618))] {
                editor.window!.setContentSize(size)
                root.layoutSubtreeIfNeeded()
                let rep = root.bitmapImageRepForCachingDisplay(in: root.bounds)!
                root.cacheDisplay(in: root.bounds, to: rep)
                try rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1] + suffix + ".png"))
            }
            editorPreview(in: root)!.chooseTool(.text)
            root.layoutSubtreeIfNeeded()
            let rep = root.bitmapImageRepForCachingDisplay(in: root.bounds)!
            root.cacheDisplay(in: root.bounds, to: rep)
            try rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1] + "-text.png"))
        }
        // Capture-window command routing must win over a menu shortcut using the same key.
        if let screen = NSScreen.main {
            let captureWindow = CaptureWindow(screen: screen, desktopImage: image, windowFrames: [])
            let delegate = CaptureEditDelegate()
            captureWindow.captureDelegate = delegate
            let view = captureWindow.contentView as! CaptureView
            // An untouched display must retain its original desktop brightness during capture.
            view.mouseExited(with: NSEvent.mouseEvent(with: .mouseMoved, location: .zero, modifierFlags: [], timestamp: 0,
                windowNumber: captureWindow.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 0)!)
            let untouchedRegion = CGRect(x: 40, y: 40, width: 20, height: 20)
            let untouchedBitmap = view.bitmapImageRepForCachingDisplay(in: untouchedRegion)!
            view.cacheDisplay(in: untouchedRegion, to: untouchedBitmap)
            let untouchedColor = untouchedBitmap.colorAt(x: 5, y: 5)!
            precondition(untouchedColor.redComponent > 0.99 && untouchedColor.greenComponent > 0.99 && untouchedColor.blueComponent > 0.99,
                         "Inactive displays must not be dimmed or blacked out")
            func captureEvent(_ type: NSEvent.EventType, _ x: CGFloat, _ y: CGFloat, clicks: Int = 1) -> NSEvent {
                NSEvent.mouseEvent(with: type, location: CGPoint(x: x, y: y), modifierFlags: [], timestamp: 0,
                    windowNumber: captureWindow.windowNumber, context: nil, eventNumber: 1, clickCount: clicks, pressure: 1)!
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
            for tool in ToolKind.allCases {
                precondition(captureWindow.performKeyEquivalent(with: toolKey(Int(tool.shortcutKeyCode))))
                view.mouseDown(with: captureEvent(.leftMouseDown, 280, 230, clicks: 2))
                guard case .copy? = delegate.mode else { preconditionFailure("Double-click must finish an annotated capture while \(tool) remains selected") }
                precondition(delegate.result?.annotations.count == 1 && delegate.result?.annotations.first?.kind == .rect,
                             "Double-click completion must preserve the drawn rectangle without adding an annotation")
                delegate.mode = nil
                delegate.result = nil
            }
            precondition(captureWindow.performKeyEquivalent(with: toolKey(kVK_ANSI_T)), "T must switch directly from rectangle to text")
            let captureSize = view.subviews.compactMap { $0 as? PixelNumberControl }.first!
            precondition(!captureSize.isHidden, "Text mode must show the editable size control before drawing")
            captureWindow.makeFirstResponder(captureSize.input)
            precondition(view.isEditingText && !view.handleAnnotationShortcut(toolKey(kVK_ANSI_3)), "Typing sizes must not trigger annotation shortcuts")
            captureWindow.makeFirstResponder(view)
            if CommandLine.arguments.count > 1 {
                let crop = CGRect(x: 0, y: 0, width: min(600, view.bounds.width), height: min(350, view.bounds.height))
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
            precondition(captureWindow.performKeyEquivalent(with: toolKey(kVK_ANSI_R)))
            view.mouseDown(with: captureEvent(.leftMouseDown, 185, 170, clicks: 2))
            precondition(view.isEditingText && delegate.mode == nil, "Double-clicking text must edit it even with a drawing tool selected")
            let reopenedInput = view.subviews.compactMap { $0 as? NSTextField }.first!
            precondition(view.control(reopenedInput, textView: captureWindow.firstResponder as! NSTextView,
                                      doCommandBy: #selector(NSResponder.cancelOperation(_:))))
            precondition(captureWindow.performKeyEquivalent(with: toolKey(kVK_ANSI_T)))
            view.mouseDown(with: captureEvent(.leftMouseDown, 185, 170))
            precondition(!view.isEditingText, "Single-clicking finished text must allow dragging while T is selected")
            view.mouseDragged(with: captureEvent(.leftMouseDragged, 205, 180))
            view.mouseUp(with: captureEvent(.leftMouseUp, 205, 180))
            precondition(captureWindow.performKeyEquivalent(with: toolKey(kVK_ANSI_R)), "Rectangle shortcut must work after text input")
            precondition(captureWindow.performKeyEquivalent(with: toolKey(kVK_ANSI_T)))
            view.mouseDown(with: captureEvent(.leftMouseDown, 240, 200))
            view.mouseUp(with: captureEvent(.leftMouseUp, 240, 200))
            let emptyInput = view.subviews.compactMap { $0 as? NSTextField }.first!
            precondition(view.control(emptyInput, textView: captureWindow.firstResponder as! NSTextView, doCommandBy: #selector(NSResponder.cancelOperation(_:))))
            precondition(!view.isEditingText && captureWindow.firstResponder === view, "Esc must leave text input without cancelling the screenshot")
            precondition(captureWindow.performKeyEquivalent(with: toolKey(kVK_ANSI_A)), "Arrow shortcut must work after Esc")
            precondition(captureWindow.performKeyEquivalent(with: toolKey(kVK_ANSI_V)), "V must activate selection after a drawing tool")
            precondition(ToolbarAction.select.symbol == "cursorarrow")
            precondition(ToolbarAction.select.title?.contains("V") == true)
            view.mouseDown(with: captureEvent(.leftMouseDown, 150, 155))
            view.mouseDragged(with: captureEvent(.leftMouseDragged, 160, 155))
            view.mouseUp(with: captureEvent(.leftMouseUp, 160, 155))
            view.copyCurrentContent(to: colorClipboard)
            guard case .copy? = delegate.mode else { preconditionFailure("Copy must finish the screenshot after a region is selected") }
            precondition(delegate.result?.globalRect.size == CGSize(width: 200, height: 150))
            precondition(delegate.result?.annotations.first?.kind == .rect, "R must enable rectangle drawing during capture")
            precondition(delegate.result?.annotations.first?.rect.minX == 60, "Selection must move an existing rectangle regardless of the previous drawing tool")
            precondition(delegate.result?.annotations.last?.text == "RTAP", "T must create an editable text annotation after drawing a rectangle")
            precondition(delegate.result?.annotations.last?.rect.minX == 100, "Dragging finished text must move it 20 points in the captured image")
            precondition(AppChannel.editImageHotKey(forRelease: true).menuModifiers == .command)
            precondition(AppChannel.editImageHotKey(forRelease: false).menuModifiers == .option)
            let edit = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: AppChannel.editImageHotKey.menuModifiers, timestamp: 0,
                windowNumber: captureWindow.windowNumber, context: nil, characters: "e", charactersIgnoringModifiers: "e",
                isARepeat: false, keyCode: UInt16(kVK_ANSI_E))!
            precondition(captureWindow.performKeyEquivalent(with: edit))
            guard case .editImage? = delegate.mode else { preconditionFailure("The channel edit shortcut must open the selected image in the editor") }
            precondition(delegate.result?.globalRect.size == CGSize(width: 200, height: 150))
            precondition(ToolbarAction.editImage.title?.contains(AppChannel.editImageHotKey.symbol) == true)
            precondition(captureWindow.performKeyEquivalent(with: toolKey(kVK_ANSI_N)))
            view.mouseDown(with: captureEvent(.leftMouseDown, 140, 125))
            view.mouseUp(with: captureEvent(.leftMouseUp, 140, 125))
            view.mouseDown(with: captureEvent(.leftMouseDown, 270, 125))
            view.mouseUp(with: captureEvent(.leftMouseUp, 270, 125))
            view.editImage()
            let captureSteps = delegate.result!.annotations.filter { $0.kind == .step }
            precondition(captureSteps.map(\.text) == ["1", "2"], "Capture overlay must place sequential markers using N and single clicks")
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
