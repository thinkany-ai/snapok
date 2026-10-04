import AppKit
import Carbon

@MainActor
final class BackgroundPreview: NSView, NSTextFieldDelegate {
    let source: CGImage
    let sourceImage: NSImage
    var background: EditorBackground = .gradient(0)
    var composition = BackgroundLayout() { didSet { viewportChanged() } }
    var annotations: [Annotation]
    var selectedTool: ToolKind?
    var selectedColor: NSColor = Style.colors[0]
    var textStyle = AnnotationTextStyle()
    var usesTextStyle: Bool { selectedTool == .text || selectedIndex.map { annotations[$0].kind == .text } == true }
    var sizeLevel = 1 { didSet { if oldValue != sizeLevel { textStyle.pointSize = Style.lineWidth(for: .text, level: sizeLevel) } } }
    var onChange: (() -> Void)?
    var onCommand: ((ToolbarAction) -> Void)?
    var onViewportChange: (() -> Void)?
    private var manualZoom: CGFloat?
    private var pan = CGPoint.zero
    private var selectedIndex: Int?
    private var draft: Annotation?
    private var start: CGPoint?
    private var lastPoint: CGPoint?
    private var history: [[Annotation]] = []
    private var activeTextField: NSTextField?
    private var editingTextIndex: Int?
    private var textOrigin = CGPoint.zero
    private static weak var textEditingPreview: BackgroundPreview?
    private static let outsideClickMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { event in
        if let preview = textEditingPreview {
            // Canvas clicks are handled by mouseDown, so finishing a line does not create another.
            if event.window !== preview.window || !preview.bounds.contains(preview.convert(event.locationInWindow, from: nil)) {
                preview.commitTextEditing(restoreFocus: false)
            }
        }
        return event
    }

    init(image: NSImage, annotations: [Annotation] = []) {
        sourceImage = image
        source = image.cgImage(forProposedRect: nil, context: nil, hints: nil)!
        self.annotations = annotations
        super.init(frame: .zero)
        clipsToBounds = true
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override var acceptsFirstResponder: Bool { true }

    var pixelScale: CGFloat { CGFloat(source.width) / sourceImage.size.width }
    private var canvasSize: CGSize { composition.canvasSize(for: CGSize(width: source.width, height: source.height)) }
    private var fitZoom: CGFloat { min(max(1, bounds.width - 64) / canvasSize.width, max(1, bounds.height - 64) / canvasSize.height) }
    var zoom: CGFloat { manualZoom ?? fitZoom }
    private var canvasOrigin: CGPoint { CGPoint(x: (bounds.width - canvasSize.width * zoom) / 2 + pan.x, y: (bounds.height - canvasSize.height * zoom) / 2 + pan.y) }

    func fitToWindow() {
        manualZoom = nil
        pan = .zero
        viewportChanged()
    }

    /// Keep the image point under the pointer fixed while changing the display scale.
    func setZoom(_ value: CGFloat, around anchor: CGPoint? = nil) {
        let anchor = anchor ?? CGPoint(x: bounds.midX, y: bounds.midY)
        let oldOrigin = canvasOrigin
        let oldZoom = zoom
        manualZoom = min(8, max(min(fitZoom, 1) / 4, value))
        pan = CGPoint(x: anchor.x - (anchor.x - oldOrigin.x) * zoom / oldZoom - (bounds.width - canvasSize.width * zoom) / 2,
                      y: anchor.y - (anchor.y - oldOrigin.y) * zoom / oldZoom - (bounds.height - canvasSize.height * zoom) / 2)
        viewportChanged()
    }

    func zoomBy(_ factor: CGFloat) { setZoom(zoom * factor) }

    func panBy(dx: CGFloat, dy: CGFloat) {
        pan.x += dx
        pan.y += dy
        viewportChanged()
    }

    private func constrainPan() {
        let limitX = max(0, (canvasSize.width * zoom - bounds.width) / 2 + 32)
        let limitY = max(0, (canvasSize.height * zoom - bounds.height) / 2 + 32)
        pan.x = min(limitX, max(-limitX, pan.x))
        pan.y = min(limitY, max(-limitY, pan.y))
    }

    private func viewportChanged() {
        constrainPan()
        layoutTextEditor()
        needsDisplay = true
        onViewportChange?()
    }

    override func layout() {
        super.layout()
        viewportChanged()
    }

    override func magnify(with event: NSEvent) {
        setZoom(zoom * max(0.1, 1 + event.magnification), around: convert(event.locationInWindow, from: nil))
    }

    override func scrollWheel(with event: NSEvent) {
        let multiplier: CGFloat = event.hasPreciseScrollingDeltas ? 1 : 16
        if event.modifierFlags.contains(.command) {
            setZoom(zoom * exp(event.scrollingDeltaY * multiplier / 200), around: convert(event.locationInWindow, from: nil))
        } else if event.modifierFlags.contains(.shift), event.scrollingDeltaX == 0 {
            panBy(dx: event.scrollingDeltaY * multiplier, dy: 0)
        } else {
            panBy(dx: event.scrollingDeltaX * multiplier, dy: -event.scrollingDeltaY * multiplier)
        }
    }

    func imagePoint(from point: CGPoint) -> CGPoint {
        CGPoint(x: ((point.x - canvasOrigin.x) / zoom - composition.horizontalPadding) / pixelScale,
                y: ((point.y - canvasOrigin.y) / zoom - composition.verticalPadding) / pixelScale)
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor(srgbRed: 0.10, green: 0.10, blue: 0.13, alpha: 1).setFill()
        bounds.fill()
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        context.saveGState()
        context.translateBy(x: canvasOrigin.x, y: canvasOrigin.y)
        context.scaleBy(x: zoom, y: zoom)
        NSGraphicsContext.current?.imageInterpolation = .high
        BackgroundRenderer.draw(source: source, background: background, layout: composition) { context in
            self.drawAnnotations(in: context, editing: true)
        }
        context.restoreGState()
    }

    func drawAnnotations(in context: CGContext, editing: Bool = false) {
        context.saveGState()
        context.scaleBy(x: pixelScale, y: pixelScale)
        for (index, annotation) in (annotations + (editing ? draft.map { [$0] } ?? [] : [])).enumerated() {
            if editing && index == editingTextIndex { continue }
            AnnotationRenderer.draw(annotation, in: context, sourceImage: sourceImage, origin: .zero, localImage: true)
        }
        if editing, let index = selectedIndex, annotations.indices.contains(index) {
            context.setStrokeColor(Brand.accent.cgColor)
            context.setLineWidth(1 / (zoom * pixelScale))
            context.setLineDash(phase: 0, lengths: [4 / (zoom * pixelScale), 3 / (zoom * pixelScale)])
            context.stroke(annotations[index].rect.insetBy(dx: -3, dy: -3))
        }
        context.restoreGState()
    }

    private func changed() { needsDisplay = true; onChange?() }
    private func record() { history.append(annotations); if history.count > 100 { history.removeFirst() } }
    func undoEdit() {
        commitTextEditing()
        if let previous = history.popLast() { annotations = previous }
        else if !annotations.isEmpty { annotations.removeLast() }
        selectedIndex = nil
        changed()
    }
    /// Adds annotations as one undoable step.
    func append(_ newAnnotations: [Annotation]) {
        commitTextEditing()
        guard !newAnnotations.isEmpty else { return }
        record()
        annotations += newAnnotations
        changed()
    }
    func deleteSelected() {
        commitTextEditing()
        guard let index = selectedIndex else { return }
        record(); annotations.remove(at: index); selectedIndex = nil; changed()
    }
    func applyStyle() {
        if activeTextField != nil { layoutTextEditor(); changed(); return }
        if let index = selectedIndex {
            record()
            annotations[index].color = selectedColor
            annotations[index].sizeLevel = sizeLevel
            if annotations[index].kind == .text {
                annotations[index].textStyle = textStyle
                let font = annotations[index].textFont
                annotations[index].rect.size = (annotations[index].text as NSString).size(withAttributes: [.font: font])
            }
        }
        changed()
    }
    func chooseTool(_ tool: ToolKind?) {
        commitTextEditing()
        selectedTool = tool
        selectedIndex = nil
        window?.makeFirstResponder(self)
        changed()
    }

    override func mouseDown(with event: NSEvent) {
        if activeTextField != nil { commitTextEditing(); return }
        window?.makeFirstResponder(self)
        let point = imagePoint(from: convert(event.locationInWindow, from: nil))
        guard CGRect(origin: .zero, size: sourceImage.size).contains(point) else { selectedIndex = nil; changed(); return }
        let hit = annotations.indices.reversed().first { annotations[$0].hitTest(point) }
        if let hit, selectedTool == nil || (selectedTool == .text && annotations[hit].kind == .text) {
            selectedIndex = hit
            selectedColor = annotations[hit].color
            sizeLevel = annotations[hit].sizeLevel
            if annotations[hit].kind == .text { textStyle = annotations[hit].effectiveTextStyle }
            if annotations[hit].kind == .text, event.clickCount == 2 {
                editText(at: point, index: hit)
            } else { record(); lastPoint = point }
            changed()
            return
        }
        selectedIndex = nil
        guard let tool = selectedTool else { changed(); return }
        if tool == .text { editText(at: point, index: nil); return }
        start = point
        draft = Annotation(kind: tool, rect: CGRect(origin: point, size: .zero), points: [point, point], color: selectedColor, sizeLevel: sizeLevel)
        changed()
    }

    override func mouseDragged(with event: NSEvent) {
        let raw = imagePoint(from: convert(event.locationInWindow, from: nil))
        let point = CGPoint(x: min(max(raw.x, 0), sourceImage.size.width), y: min(max(raw.y, 0), sourceImage.size.height))
        if let lastPoint, let index = selectedIndex {
            annotations[index] = annotations[index].offsetBy(dx: point.x - lastPoint.x, dy: point.y - lastPoint.y)
            self.lastPoint = point
        } else if let start, var draft {
            if draft.kind == .pen || draft.kind == .mosaic { draft.points.append(point) }
            else { draft.points = [start, point] }
            let xs = draft.points.map(\.x), ys = draft.points.map(\.y)
            draft.rect = CGRect(x: xs.min()!, y: ys.min()!, width: xs.max()! - xs.min()!, height: ys.max()! - ys.min()!)
            if draft.kind == .pen || draft.kind == .mosaic { draft.rect = draft.rect.insetBy(dx: -draft.lineWidth / 2, dy: -draft.lineWidth / 2) }
            self.draft = draft
        }
        changed()
    }

    override func mouseUp(with event: NSEvent) {
        if let draft, draft.rect.width + draft.rect.height >= 2 {
            record(); annotations.append(draft)
        }
        draft = nil; start = nil; lastPoint = nil
        changed()
    }

    private func editText(at point: CGPoint, index: Int?) {
        guard window != nil else { return }
        editingTextIndex = index
        selectedIndex = nil
        lastPoint = nil
        let height = ("Ag" as NSString).size(withAttributes: [.font: textStyle.font]).height
        textOrigin = index.map { annotations[$0].rect.origin } ?? CGPoint(x: point.x, y: point.y - height / 2)
        let field = NSTextField(frame: .zero)
        field.stringValue = index.map { annotations[$0].text } ?? ""
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.cell?.wraps = false
        field.cell?.isScrollable = true
        field.delegate = self
        field.setAccessibilityLabel(L("Annotation text", "标注文字"))
        activeTextField = field
        addSubview(field)
        layoutTextEditor()
        window?.makeFirstResponder(field)
        Self.textEditingPreview = self
        _ = Self.outsideClickMonitor
        changed()
    }

    private func layoutTextEditor() {
        guard let field = activeTextField else { return }
        let scale = pixelScale * zoom
        let font = NSFontManager.shared.convert(textStyle.font, toSize: textStyle.font.pointSize * scale)
        field.font = font
        field.textColor = selectedColor
        if let editor = field.currentEditor() {
            editor.font = font
            editor.textColor = selectedColor
        }
        let size = (field.stringValue as NSString).size(withAttributes: [.font: font])
        let height = ("Ag" as NSString).size(withAttributes: [.font: font]).height
        field.frame = CGRect(x: canvasOrigin.x + (composition.horizontalPadding + textOrigin.x * pixelScale) * zoom - 2,
                             y: canvasOrigin.y + (composition.verticalPadding + textOrigin.y * pixelScale) * zoom - 1,
                             width: max(40, ceil(size.width) + 16), height: ceil(height) + 2)
        needsDisplay = true
    }

    func controlTextDidChange(_ notification: Notification) { layoutTextEditor() }

    func controlTextDidEndEditing(_ notification: Notification) {
        commitTextEditing(restoreFocus: false)
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        guard control === activeTextField, !textView.hasMarkedText() else { return false }
        if commandSelector == #selector(NSResponder.insertNewline(_:)) || commandSelector == #selector(NSResponder.cancelOperation(_:)) {
            commitTextEditing()
            return true
        }
        return false
    }

    /// Store image coordinates and the unscaled font, independent of preview zoom.
    func commitTextEditing(restoreFocus: Bool = true) {
        guard let field = activeTextField else { return }
        let text = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        activeTextField = nil
        if Self.textEditingPreview === self { Self.textEditingPreview = nil }
        let index = editingTextIndex
        editingTextIndex = nil
        field.removeFromSuperview()
        selectedIndex = nil
        if !text.isEmpty {
            record()
            let size = (text as NSString).size(withAttributes: [.font: textStyle.font])
            let annotation = Annotation(kind: .text, rect: CGRect(origin: textOrigin, size: size), points: [], text: text,
                                        color: selectedColor, sizeLevel: sizeLevel, textStyle: textStyle)
            if let index { annotations[index] = annotation } else { annotations.append(annotation) }
            selectedIndex = index ?? annotations.count - 1
        } else if let index {
            record()
            annotations.remove(at: index)
        }
        if restoreFocus { window?.makeFirstResponder(self) }
        changed()
    }

    override func keyDown(with event: NSEvent) {
        if event.modifierFlags.intersection([.command, .option, .control, .shift]).isEmpty {
            if let tool = ToolKind.matchingShortcut(event) { chooseTool(tool); return }
            switch Int(event.keyCode) {
            case kVK_ANSI_V: chooseTool(nil); return
            case kVK_ANSI_1: sizeLevel = 0; applyStyle(); return
            case kVK_ANSI_2: sizeLevel = 1; applyStyle(); return
            case kVK_ANSI_3: sizeLevel = 2; applyStyle(); return
            case kVK_ANSI_LeftBracket: sizeLevel = max(0, sizeLevel - 1); applyStyle(); return
            case kVK_ANSI_RightBracket: sizeLevel = min(Style.sizeLevels - 1, sizeLevel + 1); applyStyle(); return
            default: break
            }
        }
        if event.modifierFlags.contains(.command) {
            switch Int(event.keyCode) {
            case kVK_ANSI_Equal: zoomBy(1.25)
            case kVK_ANSI_Minus: zoomBy(0.8)
            case kVK_ANSI_0: fitToWindow()
            case kVK_ANSI_Z: undoEdit()
            case kVK_ANSI_C: onCommand?(.done)
            case kVK_ANSI_S: onCommand?(.save)
            case kVK_ANSI_T: onCommand?(.pin)
            default: super.keyDown(with: event)
            }
        } else if event.keyCode == UInt16(kVK_Delete) || event.keyCode == UInt16(kVK_ForwardDelete) { deleteSelected() }
        else if event.keyCode == UInt16(kVK_Escape) { chooseTool(nil) }
        else { super.keyDown(with: event) }
    }
}
