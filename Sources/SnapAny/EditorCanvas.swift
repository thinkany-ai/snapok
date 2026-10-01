import AppKit
import Carbon

@MainActor
final class BackgroundPreview: NSView {
    let source: CGImage
    let sourceImage: NSImage
    var background: EditorBackground = .gradient(0)
    var composition = BackgroundLayout()
    var annotations: [Annotation]
    var selectedTool: ToolKind?
    var selectedColor: NSColor = Style.colors[0]
    var sizeLevel = 1
    var onChange: (() -> Void)?
    var onCommand: ((ToolbarAction) -> Void)?
    private var selectedIndex: Int?
    private var draft: Annotation?
    private var start: CGPoint?
    private var lastPoint: CGPoint?
    private var history: [[Annotation]] = []

    init(image: NSImage, annotations: [Annotation] = []) {
        sourceImage = image
        source = image.cgImage(forProposedRect: nil, context: nil, hints: nil)!
        self.annotations = annotations
        super.init(frame: .zero)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override var acceptsFirstResponder: Bool { true }

    private var pixelScale: CGFloat { CGFloat(source.width) / sourceImage.size.width }
    private var canvasSize: CGSize { composition.canvasSize(for: CGSize(width: source.width, height: source.height)) }
    private var zoom: CGFloat { min(max(1, bounds.width - 64) / canvasSize.width, max(1, bounds.height - 64) / canvasSize.height) }
    private var canvasOrigin: CGPoint { CGPoint(x: (bounds.width - canvasSize.width * zoom) / 2, y: (bounds.height - canvasSize.height * zoom) / 2) }

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
        for annotation in annotations + (editing ? draft.map { [$0] } ?? [] : []) {
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
        if let previous = history.popLast() { annotations = previous }
        else if !annotations.isEmpty { annotations.removeLast() }
        selectedIndex = nil
        changed()
    }
    func deleteSelected() {
        guard let index = selectedIndex else { return }
        record(); annotations.remove(at: index); selectedIndex = nil; changed()
    }
    func applyStyle() {
        if let index = selectedIndex {
            record()
            annotations[index].color = selectedColor
            annotations[index].sizeLevel = sizeLevel
            if annotations[index].kind == .text {
                let font = NSFont.systemFont(ofSize: Style.lineWidth(for: .text, level: sizeLevel), weight: .medium)
                annotations[index].rect.size = (annotations[index].text as NSString).size(withAttributes: [.font: font])
            }
        }
        changed()
    }
    func chooseTool(_ tool: ToolKind?) {
        selectedTool = tool
        selectedIndex = nil
        window?.makeFirstResponder(self)
        changed()
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        let point = imagePoint(from: convert(event.locationInWindow, from: nil))
        guard CGRect(origin: .zero, size: sourceImage.size).contains(point) else { selectedIndex = nil; changed(); return }
        let hit = annotations.indices.reversed().first { annotations[$0].hitTest(point) }
        if let hit, selectedTool == nil || (selectedTool == .text && annotations[hit].kind == .text) {
            selectedIndex = hit
            selectedColor = annotations[hit].color
            sizeLevel = annotations[hit].sizeLevel
            if annotations[hit].kind == .text, event.clickCount == 2 || selectedTool == .text {
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
        guard let window else { return }
        let alert = NSAlert()
        alert.messageText = index == nil ? "添加文字" : "编辑文字"
        let input = NSTextField(frame: CGRect(x: 0, y: 0, width: 320, height: 26))
        input.stringValue = index.map { annotations[$0].text } ?? ""
        alert.accessoryView = input
        alert.addButton(withTitle: "确定")
        alert.addButton(withTitle: "取消")
        alert.window.initialFirstResponder = input
        alert.beginSheetModal(for: window) { [weak self] response in
            guard let self, response == .alertFirstButtonReturn, !input.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
            self.record()
            let origin = index.map { self.annotations[$0].rect.origin } ?? point
            let font = NSFont.systemFont(ofSize: Style.lineWidth(for: .text, level: self.sizeLevel), weight: .medium)
            let size = (input.stringValue as NSString).size(withAttributes: [.font: font])
            let annotation = Annotation(kind: .text, rect: CGRect(origin: origin, size: size), points: [], text: input.stringValue,
                                        color: self.selectedColor, sizeLevel: self.sizeLevel)
            if let index { self.annotations[index] = annotation } else { self.annotations.append(annotation) }
            self.changed()
        }
    }

    override func keyDown(with event: NSEvent) {
        if event.modifierFlags.contains(.command) {
            switch Int(event.keyCode) {
            case kVK_ANSI_Z: undoEdit()
            case kVK_ANSI_C: onCommand?(.done)
            case kVK_ANSI_S: onCommand?(.save)
            default: super.keyDown(with: event)
            }
        } else if event.keyCode == UInt16(kVK_Delete) || event.keyCode == UInt16(kVK_ForwardDelete) { deleteSelected() }
        else if event.keyCode == UInt16(kVK_Escape) { chooseTool(nil) }
        else { super.keyDown(with: event) }
    }
}
