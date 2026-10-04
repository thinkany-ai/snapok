import AppKit
import UniformTypeIdentifiers

@MainActor
final class ImageTranslationWindowController: NSWindowController, NSWindowDelegate, NSTextViewDelegate, NSTextFieldDelegate {
    private static var open: [ImageTranslationWindowController] = []
    private let canvas: ImageTranslationCanvas
    private let target: String
    private let useVision: Bool
    private var task: Task<Void, Never>?
    private var initial: [ImageTranslationBlock] = []
    private let status = NSTextField(wrappingLabelWithString: "")
    private let operationFeedback = WindowFeedback()
    private let originalText = NSTextField(wrappingLabelWithString: "")
    private let input = NSTextView(usingTextLayoutManager: false)
    private let fontSize = NSSlider(value: 16, minValue: 6, maxValue: 100, target: nil, action: nil)
    private let foreground = NSColorWell()
    private let background = NSColorWell()
    private let enabled = NSButton(checkboxWithTitle: L("Translate this block", "翻译此文字块"), target: nil, action: nil)
    private let width = NSTextField(string: "")
    private let height = NSTextField(string: "")
    private let spinner = NSProgressIndicator()
    private var copyButton: NSButton!
    private var saveButton: NSButton!
    private var retryButton: NSButton!
    private var updating = false
    private var libraryID: UUID?
    private var libraryDirty = false
    private var libraryTask: Task<Void, Never>?
    private var libraryButton: NSButton!
    private let libraryStatus = NSTextField(labelWithString: "")

    static func show(image: CGImage, target: String, useVision: Bool, near parent: NSWindow?) {
        let controller = ImageTranslationWindowController(image: image, target: target, useVision: useVision)
        open.append(controller)
        controller.window?.center()
        controller.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
        controller.run()
    }

    private init(image: CGImage, target: String, useVision: Bool) {
        canvas = ImageTranslationCanvas(source: image)
        self.target = target
        self.useVision = useVision
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 1080, height: 700),
            styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
        window.title = L("Translate Image to \(target)", "图片翻译成\(target)")
        window.minSize = CGSize(width: 820, height: 580)
        window.isReleasedWhenClosed = false
        window.contentView = ImageTranslationRoot(frame: CGRect(x: 0, y: 0, width: 1080, height: 700))
        super.init(window: window)
        window.delegate = self
        build()
        canvas.onChange = { [weak self] in self?.refreshInspector() }
        canvas.onEdit = { [weak self] in self?.scheduleLibraryUpdate() }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func button(_ title: String, _ action: Selector) -> NSButton {
        let button = NSButton(title: title, target: self, action: action)
        button.bezelStyle = .rounded
        return button
    }

    private func build() {
        guard let root = window?.contentView else { return }
        let compare = NSButton(checkboxWithTitle: L("Show Original", "查看原图"), target: self, action: #selector(compareImage(_:)))
        retryButton = button(L("Retry", "重试"), #selector(retry))
        copyButton = button(L("Copy Image", "复制图片"), #selector(copyImage))
        saveButton = button(L("Save PNG…", "保存 PNG…"), #selector(saveImage))
        copyButton.isEnabled = false; saveButton.isEnabled = false
        libraryButton = button(L("Save to Library", "保存到图库"), #selector(saveLibraryWithFeedback))
        libraryButton.isEnabled = false
        let undo = button(L("Undo", "撤销"), #selector(undoEdit))
        let reset = button(L("Reset Edits", "重置修改"), #selector(resetEdits))
        let toolbar = NSStackView(views: [compare, undo, reset, NSView(), retryButton, libraryButton, copyButton, saveButton])
        toolbar.spacing = 8

        let title = NSTextField(labelWithString: L("Edit Translation", "编辑译文"))
        title.font = .systemFont(ofSize: 16, weight: .semibold)
        let hint = NSTextField(wrappingLabelWithString: L("Click text in the image to edit it. Drag to reposition.", "点击图片中的文字编辑，拖动可调整位置。"))
        hint.textColor = .secondaryLabelColor
        hint.font = .systemFont(ofSize: 12)
        originalText.textColor = .secondaryLabelColor
        originalText.maximumNumberOfLines = 3
        originalText.font = .systemFont(ofSize: 12)
        input.isRichText = false
        input.font = .systemFont(ofSize: 14)
        input.textContainerInset = CGSize(width: 6, height: 6)
        input.isVerticallyResizable = true
        input.autoresizingMask = [.width]
        input.textContainer?.widthTracksTextView = true
        input.delegate = self
        let scroll = NSScrollView()
        scroll.borderType = .bezelBorder
        scroll.hasVerticalScroller = true
        scroll.documentView = input
        fontSize.target = self; fontSize.action = #selector(changeStyle)
        [foreground, background].forEach { $0.useCompactSwatch() }
        foreground.target = self; foreground.action = #selector(changeStyle)
        background.target = self; background.action = #selector(changeStyle)
        enabled.target = self; enabled.action = #selector(changeEnabled)
        for field in [width, height] { field.target = self; field.action = #selector(changeDimensions); field.delegate = self }
        let sizeRow = NSStackView(views: [NSTextField(labelWithString: L("Width", "宽")), width,
                                        NSTextField(labelWithString: L("Height", "高")), height])
        sizeRow.spacing = 8
        let colors = NSStackView(views: [NSTextField(labelWithString: L("Text", "文字")), foreground,
                                       NSTextField(labelWithString: L("Fill", "填充")), background])
        colors.spacing = 10
        let note = NSTextField(wrappingLabelWithString: L("Backgrounds use sampled flat colors. Check complex backgrounds and long translations before exporting.", "背景使用取样纯色填充。复杂背景和较长译文请检查、调整后导出。"))
        note.textColor = .secondaryLabelColor
        note.font = .systemFont(ofSize: 12)
        let fit = button(L("Fit Text to Box", "字号适配文字框"), #selector(fitText))
        let inspector = NSStackView(views: [title, hint, originalText, scroll, enabled,
            NSTextField(labelWithString: L("Font Size", "字号")), fontSize, sizeRow, colors, fit, note, NSView()])
        inspector.orientation = .vertical
        inspector.alignment = .leading
        inspector.spacing = 12
        for view in [hint, originalText, scroll, fontSize, sizeRow, note] {
            view.widthAnchor.constraint(equalTo: inspector.widthAnchor).isActive = true
        }
        scroll.heightAnchor.constraint(equalToConstant: 110).isActive = true
        width.widthAnchor.constraint(equalToConstant: 55).isActive = true
        height.widthAnchor.constraint(equalToConstant: 55).isActive = true
        spinner.style = .spinning; spinner.controlSize = .small
        status.font = .systemFont(ofSize: 12)
        status.textColor = .secondaryLabelColor
        libraryStatus.font = .systemFont(ofSize: 12)
        libraryStatus.textColor = .secondaryLabelColor
        let footer = NSStackView(views: [spinner, status, NSView(), libraryStatus])
        footer.spacing = 8
        for view in [toolbar, canvas, inspector, footer] {
            view.translatesAutoresizingMaskIntoConstraints = false; root.addSubview(view)
        }
        NSLayoutConstraint.activate([
            toolbar.topAnchor.constraint(equalTo: root.topAnchor, constant: 12),
            toolbar.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 16),
            toolbar.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -16),
            inspector.topAnchor.constraint(equalTo: toolbar.bottomAnchor, constant: 16),
            inspector.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -16),
            inspector.widthAnchor.constraint(equalToConstant: 260),
            inspector.bottomAnchor.constraint(equalTo: footer.topAnchor, constant: -12),
            canvas.topAnchor.constraint(equalTo: inspector.topAnchor),
            canvas.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 16),
            canvas.trailingAnchor.constraint(equalTo: inspector.leadingAnchor, constant: -16),
            canvas.bottomAnchor.constraint(equalTo: inspector.bottomAnchor),
            footer.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 16),
            footer.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -16),
            footer.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -12)
        ])
        refreshInspector()
    }

    private func run() {
        task?.cancel()
        retryButton.isEnabled = false
        spinner.isHidden = false; spinner.startAnimation(nil)
        status.textColor = .secondaryLabelColor
        status.stringValue = L("Recognizing and translating image…", "正在识别并翻译图片…")
        task = Task { [weak self] in
            guard let self else { return }
            do {
                let blocks = try await AIAssistant.translateImage(canvas.source, to: target, useVision: useVision)
                try Task.checkCancellation()
                initial = blocks
                canvas.replace(blocks)
                copyButton.isEnabled = true; saveButton.isEnabled = true; libraryButton.isEnabled = true
                refreshInspector()
                if AppSettings.autoSave || libraryID != nil { saveToLibrary() }
            } catch is CancellationError { return }
            catch {
                guard !Task.isCancelled else { return }
                log("image translation failed", error: error)
                status.textColor = .systemRed
                status.stringValue = error.localizedDescription
            }
            spinner.stopAnimation(nil); spinner.isHidden = true
            retryButton.isEnabled = true
        }
    }

    private func refreshInspector() {
        updating = true
        defer { updating = false }
        let block = canvas.selectedIndex.map { canvas.blocks[$0] }
        input.isEditable = block != nil
        for control in [fontSize, foreground, background, enabled, width, height] as [NSControl] { control.isEnabled = block != nil }
        if input.string != block?.text ?? "" { input.string = block?.text ?? "" }
        originalText.stringValue = block.map { L("Original: \($0.original)", "原文：\($0.original)") } ?? ""
        fontSize.doubleValue = Double(block?.fontSize ?? 16)
        foreground.color = block?.foreground ?? .black
        background.color = block?.background ?? .white
        width.stringValue = block.map { String(Int($0.rect.width)) } ?? ""
        height.stringValue = block.map { String(Int($0.rect.height)) } ?? ""
        enabled.state = block?.enabled == true ? .on : .off
        guard !canvas.blocks.isEmpty else { return }
        let overflow = canvas.blocks.filter { $0.enabled && ImageTranslationRenderer.overflows($0) }.count
        status.textColor = overflow > 0 ? .systemOrange : .secondaryLabelColor
        status.stringValue = overflow > 0
            ? L("\(overflow) text blocks may be clipped. Enlarge their boxes or reduce the font size.", "\(overflow) 个文字块可能被裁切，请扩大文字框或减小字号。")
            : L("\(canvas.blocks.count) blocks translated. Review the image before exporting.", "已翻译 \(canvas.blocks.count) 个文字块，请检查后导出。")
    }

    func textDidChange(_ notification: Notification) {
        guard !updating else { return }
        canvas.updateSelected { $0.text = input.string }
    }
    func controlTextDidEndEditing(_ notification: Notification) {
        guard !updating, let field = notification.object as? NSTextField,
              field === width || field === height else { return }
        changeDimensions()
    }
    @objc private func changeStyle() {
        canvas.updateSelected { $0.fontSize = CGFloat(fontSize.doubleValue); $0.foreground = foreground.color; $0.background = background.color }
    }
    @objc private func changeEnabled() { canvas.updateSelected { $0.enabled = enabled.state == .on } }
    @objc private func changeDimensions() {
        canvas.updateSelected {
            $0.rect.size = CGSize(width: min(CGFloat(canvas.source.width), max(1, CGFloat(width.doubleValue))),
                                  height: min(CGFloat(canvas.source.height), max(1, CGFloat(height.doubleValue))))
        }
    }
    @objc private func fitText() { canvas.updateSelected { ImageTranslationRenderer.fit(&$0) } }
    @objc private func compareImage(_ sender: NSButton) { canvas.showOriginal = sender.state == .on; canvas.needsDisplay = true }
    @objc private func retry() { run() }
    @objc private func undoEdit() { canvas.undoEdit() }
    @objc private func resetEdits() { if !initial.isEmpty { canvas.reset(initial) } }
    private func scheduleLibraryUpdate() {
        guard libraryID != nil else { return }
        libraryDirty = true
        libraryTask?.cancel()
        libraryTask = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(600)) } catch { return }
            guard let self else { return }
            // A deletion from the library should not be undone by a background save.
            guard let id = libraryID, HistoryStore.shared.item(id) != nil else {
                libraryID = nil; libraryDirty = false
                libraryStatus.stringValue = ""
                return
            }
            saveToLibrary()
        }
    }

    @objc private func saveLibraryWithFeedback() { saveToLibrary(showFeedback: true) }

    private func saveToLibrary(showFeedback: Bool = false) {
        guard !canvas.blocks.isEmpty else { return }
        libraryTask?.cancel(); libraryTask = nil
        do {
            guard let data = ImageTranslationRenderer.png(source: canvas.source, blocks: canvas.blocks) else {
                throw CocoaError(.fileWriteUnknown)
            }
            let text = canvas.blocks.map { $0.enabled ? $0.text : $0.original }.joined(separator: "\n")
            libraryID = try HistoryStore.shared.saveTranslation(png: data, target: target, text: text, replacing: libraryID)
            libraryDirty = false
            libraryStatus.textColor = .secondaryLabelColor
            libraryStatus.stringValue = L("Saved to Library", "已保存到图库")
            if showFeedback { operationFeedback.show(L("Saved to Library", "已保存到图库"), in: window) }
        } catch {
            log("translated image library save failed", error: error)
            libraryStatus.textColor = .systemRed
            libraryStatus.stringValue = L("Library save failed. Try Save to Library again.", "图库保存失败，请再次点击保存到图库。")
            if showFeedback { operationFeedback.showError(libraryStatus.stringValue, in: window) }
        }
    }

    @objc private func copyImage() {
        guard let data = ImageTranslationRenderer.png(source: canvas.source, blocks: canvas.blocks) else {
            operationFeedback.showError(L("Could not render the image. Try again.", "无法生成图片，请重试。"), in: window)
            return
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setData(data, forType: .png)
        operationFeedback.show(L("Image copied.", "图片已复制。"), in: window)
    }
    @objc private func saveImage() {
        guard let window else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.nameFieldStringValue = "Snapok-\(target).png"
        panel.beginSheetModal(for: window) { [weak self] response in
            guard let self, response == .OK, let url = panel.url else { return }
            do {
                guard let data = ImageTranslationRenderer.png(source: canvas.source, blocks: canvas.blocks) else { throw AIError.emptyResponse }
                try data.write(to: url, options: .atomic)
                operationFeedback.show(L("Image saved.", "图片已保存。"), in: window)
            } catch { operationFeedback.showError(error.localizedDescription, in: window) }
        }
    }
    func windowWillClose(_ notification: Notification) {
        operationFeedback.dismiss()
        task?.cancel(); task = nil
        libraryTask?.cancel(); libraryTask = nil
        if libraryDirty, let id = libraryID, HistoryStore.shared.item(id) != nil { saveToLibrary() }
        Self.open.removeAll { $0 === self }
    }
}

@MainActor
final class ImageTranslationCanvas: NSView {
    let source: CGImage
    var blocks: [ImageTranslationBlock] = []
    var selectedIndex: Int?
    var showOriginal = false
    var onChange: (() -> Void)?
    var onEdit: (() -> Void)?
    private var history: [[ImageTranslationBlock]] = []
    private var lastPoint: CGPoint?
    init(source: CGImage) { self.source = source; super.init(frame: .zero) }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override var acceptsFirstResponder: Bool { true }
    private var zoom: CGFloat { min(max(1, bounds.width - 32) / CGFloat(source.width), max(1, bounds.height - 32) / CGFloat(source.height)) }
    private var origin: CGPoint { CGPoint(x: (bounds.width - CGFloat(source.width) * zoom) / 2, y: (bounds.height - CGFloat(source.height) * zoom) / 2) }
    override func draw(_ dirtyRect: NSRect) {
        NSColor.windowBackgroundColor.setFill(); bounds.fill()
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        context.saveGState()
        context.translateBy(x: origin.x, y: origin.y); context.scaleBy(x: zoom, y: zoom)
        ImageTranslationRenderer.draw(source: source, blocks: blocks, original: showOriginal)
        if !showOriginal, let index = selectedIndex {
            NSColor.systemPink.setStroke()
            let path = NSBezierPath(rect: blocks[index].rect)
            path.lineWidth = 1.5 / zoom
            path.stroke()
        }
        context.restoreGState()
    }
    private func changed(edited: Bool = false) { needsDisplay = true; onChange?(); if edited { onEdit?() } }
    private func record() { history.append(blocks); if history.count > 100 { history.removeFirst() } }
    func replace(_ new: [ImageTranslationBlock]) { blocks = new; history = []; selectedIndex = nil; changed() }
    func reset(_ new: [ImageTranslationBlock]) { record(); blocks = new; selectedIndex = nil; changed(edited: true) }
    func updateSelected(_ edit: (inout ImageTranslationBlock) -> Void) {
        guard let index = selectedIndex else { return }
        record(); edit(&blocks[index]); changed(edited: true)
    }
    func undoEdit() { guard let previous = history.popLast() else { return }; blocks = previous; selectedIndex = nil; changed(edited: true) }
    private func point(_ event: NSEvent) -> CGPoint {
        let local = convert(event.locationInWindow, from: nil)
        return CGPoint(x: (local.x - origin.x) / zoom, y: (local.y - origin.y) / zoom)
    }
    override func mouseDown(with event: NSEvent) {
        guard !showOriginal else { return }
        window?.makeFirstResponder(self)
        let p = point(event)
        selectedIndex = blocks.indices.reversed().first { blocks[$0].rect.contains(p) || blocks[$0].eraseRect.contains(p) }
        if selectedIndex != nil { record(); lastPoint = p }
        changed()
    }
    override func mouseDragged(with event: NSEvent) {
        guard let index = selectedIndex, let previous = lastPoint else { return }
        let p = point(event)
        let rect = blocks[index].rect
        blocks[index].rect.origin = CGPoint(x: min(max(0, rect.minX + p.x - previous.x), max(0, CGFloat(source.width) - rect.width)),
                                           y: min(max(0, rect.minY + p.y - previous.y), max(0, CGFloat(source.height) - rect.height)))
        lastPoint = p; changed(edited: true)
    }
    override func mouseUp(with event: NSEvent) { lastPoint = nil }
    override func keyDown(with event: NSEvent) {
        if event.modifierFlags.contains(.command), event.charactersIgnoringModifiers == "z" { undoEdit() }
        else { super.keyDown(with: event) }
    }
}

@MainActor
private final class ImageTranslationRoot: NSView {
    override func draw(_ dirtyRect: NSRect) {
        NSColor.windowBackgroundColor.setFill()
        bounds.fill()
    }
}
