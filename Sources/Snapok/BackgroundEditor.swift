import AppKit
import UniformTypeIdentifiers

@MainActor
final class BackgroundEditorController: NSWindowController, NSWindowDelegate, NSTextFieldDelegate {
    var onClose: (() -> Void)?
    var onPin: ((NSImage) -> Void)?
    /// The library entry this editor writes its annotations back to on close.
    var historyID: UUID?
    var annotations: [Annotation] { preview.annotations }
    private var toolButtons: [NSButton] = []
    private let strokePicker = NSPopUpButton()
    private let annotationColor = NSColorWell()
    private let quickActions: [ToolbarAction] = ToolKind.allCases.map { .tool($0) } + [.undo, .pin, .save, .cancel, .done]
    private let preview: BackgroundPreview
    private let backgroundPicker = NSPopUpButton()
    private let colorWell = NSColorWell()
    private let dimensions = NSTextField(labelWithString: "")
    private let feedback = NSTextField(wrappingLabelWithString: "")
    private var sliders: [NSSlider] = []
    private var values: [NSTextField] = []
    private let shadowButton = NSButton(checkboxWithTitle: L("Soft shadow", "柔和阴影"), target: nil, action: nil)
    private var wallpaper: NSImage?
    private var customImage: NSImage?
    private var selectedBackground = 0

    init(image: NSImage, screen: NSScreen?, annotations: [Annotation] = []) {
        preview = BackgroundPreview(image: image, annotations: annotations)
        if let screen = screen ?? NSScreen.main, let url = NSWorkspace.shared.desktopImageURL(for: screen) {
            wallpaper = NSImage(contentsOf: url)
        }
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 1060, height: 720),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = AppChannel.displayName + L(" · Edit Image", " · 编辑图片")
        window.minSize = CGSize(width: 880, height: 640)
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self
        buildInterface()
        preview.onChange = { [weak self] in self?.syncTools() }
        preview.onCommand = { [weak self] action in self?.performQuickAction(action) }
        window.makeFirstResponder(preview)
        window.center()
        refresh()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func label(_ text: String, size: CGFloat = 13, weight: NSFont.Weight = .regular) -> NSTextField {
        let field = NSTextField(labelWithString: text)
        field.font = .systemFont(ofSize: size, weight: weight)
        return field
    }

    private func button(_ title: String, action: Selector) -> NSButton {
        let button = NSButton(title: title, target: self, action: action)
        button.bezelStyle = .rounded
        button.controlSize = .large
        return button
    }

    private func buildInterface() {
        guard let root = window?.contentView else { return }
        let header = NSView()
        header.wantsLayer = true
        header.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        let toolbar = makeQuickToolbar()
        toolbar.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(toolbar)
        let sidebar = NSView()
        [header, sidebar, preview].forEach { $0.translatesAutoresizingMaskIntoConstraints = false; root.addSubview($0) }
        sidebar.wantsLayer = true
        sidebar.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        let title = label(L("Edit Image", "编辑图片"), size: 19, weight: .semibold)
        let subtitle = label(L("Annotate your image and adjust the background and padding.", "标注图片，调整背景与留白。"), size: 12)
        subtitle.textColor = .secondaryLabelColor
        let titleStack = NSStackView(views: [title, subtitle])
        titleStack.orientation = .vertical
        titleStack.alignment = .leading
        titleStack.spacing = 5
        let copy = button(L("Copy Image", "复制图片"), action: #selector(copyOutput))
        copy.keyEquivalent = "c"
        copy.keyEquivalentModifierMask = .command
        let save = button(L("Save PNG", "保存 PNG"), action: #selector(saveOutput))
        save.keyEquivalent = "s"
        save.keyEquivalentModifierMask = .command
        save.bezelColor = Brand.accent
        let actions = NSStackView(views: [makeAIMenu(), copy, save])
        actions.spacing = 10
        [titleStack, actions].forEach { $0.translatesAutoresizingMaskIntoConstraints = false; header.addSubview($0) }
        let controls = NSStackView()
        controls.orientation = .vertical
        controls.alignment = .leading
        controls.spacing = 16
        controls.translatesAutoresizingMaskIntoConstraints = false
        sidebar.addSubview(controls)
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: root.topAnchor), header.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            header.trailingAnchor.constraint(equalTo: root.trailingAnchor), header.heightAnchor.constraint(equalToConstant: 82),
            titleStack.leadingAnchor.constraint(equalTo: header.leadingAnchor, constant: 24), titleStack.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            actions.trailingAnchor.constraint(equalTo: header.trailingAnchor, constant: -20), actions.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            sidebar.topAnchor.constraint(equalTo: header.bottomAnchor), sidebar.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            sidebar.trailingAnchor.constraint(equalTo: root.trailingAnchor), sidebar.widthAnchor.constraint(equalToConstant: 280),
            preview.topAnchor.constraint(equalTo: header.bottomAnchor), preview.bottomAnchor.constraint(equalTo: toolbar.topAnchor),
            preview.leadingAnchor.constraint(equalTo: root.leadingAnchor), preview.trailingAnchor.constraint(equalTo: sidebar.leadingAnchor),
            toolbar.leadingAnchor.constraint(equalTo: root.leadingAnchor), toolbar.trailingAnchor.constraint(equalTo: sidebar.leadingAnchor),
            toolbar.bottomAnchor.constraint(equalTo: root.bottomAnchor), toolbar.heightAnchor.constraint(equalToConstant: 96),
            controls.topAnchor.constraint(equalTo: sidebar.topAnchor, constant: 24), controls.leadingAnchor.constraint(equalTo: sidebar.leadingAnchor, constant: 20),
            controls.trailingAnchor.constraint(equalTo: sidebar.trailingAnchor, constant: -20)
        ])
        func add(_ view: NSView) {
            controls.addArrangedSubview(view)
            view.widthAnchor.constraint(equalTo: controls.widthAnchor).isActive = true
        }
        add(label(L("Background", "背景"), size: 14, weight: .semibold))
        backgroundPicker.addItems(withTitles: [L("Berry Pink", "莓粉渐变"), L("Coastal Blue", "海岸蓝"), L("Twilight Purple", "暮光紫"), L("Desktop Wallpaper", "当前桌面壁纸"), L("Solid Color", "纯色"), L("Custom Image", "自定义图片")])
        backgroundPicker.target = self
        backgroundPicker.action = #selector(changeBackground)
        add(backgroundPicker)
        let swatches = NSStackView()
        swatches.spacing = 8
        swatches.distribution = .fillEqually
        for index in 0..<3 {
            let swatch = NSButton(image: NSImage(size: CGSize(width: 72, height: 42), flipped: false) { rect in
                EditorBackground.gradient(index).draw(in: rect)
                return true
            }, target: self, action: #selector(selectPreset(_:)))
            swatch.tag = index
            swatch.isBordered = false
            swatch.imageScaling = .scaleAxesIndependently
            swatch.toolTip = backgroundPicker.itemTitle(at: index)
            swatch.setAccessibilityLabel(backgroundPicker.itemTitle(at: index))
            swatch.heightAnchor.constraint(equalToConstant: 42).isActive = true
            swatches.addArrangedSubview(swatch)
        }
        add(swatches)
        let importButton = button(L("Choose Background Image…", "选择背景图片…"), action: #selector(importBackground))
        add(importButton)
        colorWell.color = NSColor(srgbRed: 0.96, green: 0.90, blue: 0.94, alpha: 1)
        colorWell.target = self
        colorWell.action = #selector(changeColor)
        colorWell.heightAnchor.constraint(equalToConstant: 28).isActive = true
        colorWell.setAccessibilityLabel(L("Custom background color", "自定义背景颜色"))
        let colorRow = NSStackView(views: [label(L("Custom color", "自选颜色"), size: 12), colorWell])
        colorRow.spacing = 12
        add(colorRow)
        add(label(L("Padding", "留白"), size: 14, weight: .semibold))
        add(controlRow(L("Horizontal", "左右"), value: 120, maximum: 600, tag: 0))
        add(controlRow(L("Vertical", "上下"), value: 120, maximum: 600, tag: 1))
        add(label(L("Appearance", "截图外观"), size: 14, weight: .semibold))
        add(controlRow(L("Corner radius", "圆角"), value: 16, maximum: 80, tag: 2))
        shadowButton.state = .on
        shadowButton.target = self
        shadowButton.action = #selector(updateComposition)
        add(shadowButton)
        dimensions.font = .monospacedDigitSystemFont(ofSize: 11, weight: .medium)
        dimensions.textColor = .secondaryLabelColor
        add(dimensions)
        feedback.font = .systemFont(ofSize: 11)
        feedback.textColor = .secondaryLabelColor
        add(feedback)
        controls.setCustomSpacing(24, after: colorRow)
    }

    private func makeQuickToolbar() -> NSView {
        let bar = NSView()
        bar.wantsLayer = true
        bar.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        let tools = NSStackView()
        tools.spacing = 6
        let select = NSButton(image: NSImage(systemSymbolName: "cursorarrow", accessibilityDescription: L("Select and move annotations", "选择和移动标注"))!, target: self, action: #selector(selectAnnotation))
        select.toolTip = L("Select and move · Double-click to edit text · Delete to remove", "选择和移动标注 · 双击编辑文字 · Delete 删除")
        select.bezelStyle = .rounded
        select.widthAnchor.constraint(equalToConstant: 32).isActive = true
        tools.addArrangedSubview(select)
        for (index, action) in quickActions.enumerated() {
            let title = action == .cancel ? L("Close Editor", "关闭编辑") : action == .done ? L("Copy Image", "复制图片") : action.title ?? ""
            let item = NSButton(image: NSImage(systemSymbolName: action.symbol!, accessibilityDescription: title)!, target: self, action: #selector(quickAction(_:)))
            item.tag = index
            item.toolTip = title
            item.bezelStyle = .rounded
            item.widthAnchor.constraint(equalToConstant: 32).isActive = true
            if action == .cancel { item.keyEquivalent = "w"; item.keyEquivalentModifierMask = .command }
            tools.addArrangedSubview(item)
            toolButtons.append(item)
        }
        strokePicker.addItems(withTitles: [L("Thin / Small", "细 / 小"), L("Medium", "中"), L("Thick / Large", "粗 / 大")])
        strokePicker.selectItem(at: 1)
        strokePicker.target = self
        strokePicker.action = #selector(changeAnnotationStyle)
        strokePicker.setAccessibilityLabel(L("Annotation stroke or text size", "标注线宽或文字大小"))
        annotationColor.color = preview.selectedColor
        annotationColor.target = self
        annotationColor.action = #selector(changeAnnotationStyle)
        annotationColor.widthAnchor.constraint(equalToConstant: 42).isActive = true
        annotationColor.heightAnchor.constraint(equalToConstant: 24).isActive = true
        annotationColor.setAccessibilityLabel(L("Annotation color", "标注颜色"))
        let options = NSStackView(views: [label(L("Size", "大小"), size: 11), strokePicker, label(L("Color", "颜色"), size: 11), annotationColor])
        options.spacing = 10
        for (index, color) in Style.colors.enumerated() {
            let image = NSImage(size: CGSize(width: 22, height: 22), flipped: false) { rect in
                let circle = NSBezierPath(ovalIn: rect.insetBy(dx: 3, dy: 3))
                color.setFill()
                circle.fill()
                NSColor.gray.withAlphaComponent(0.45).setStroke()
                circle.lineWidth = 0.7
                circle.stroke()
                return true
            }
            let swatch = NSButton(image: image, target: self, action: #selector(selectAnnotationColor(_:)))
            swatch.tag = index
            swatch.isBordered = false
            swatch.widthAnchor.constraint(equalToConstant: 22).isActive = true
            swatch.setAccessibilityLabel([L("Red", "红色"), L("Yellow", "黄色"), L("Green", "绿色"), L("Blue", "蓝色"), L("Black", "黑色"), L("White", "白色")][index])
            options.addArrangedSubview(swatch)
        }
        [tools, options].forEach { $0.translatesAutoresizingMaskIntoConstraints = false; bar.addSubview($0) }
        NSLayoutConstraint.activate([
            tools.centerXAnchor.constraint(equalTo: bar.centerXAnchor), tools.topAnchor.constraint(equalTo: bar.topAnchor, constant: 12),
            options.centerXAnchor.constraint(equalTo: bar.centerXAnchor), options.topAnchor.constraint(equalTo: tools.bottomAnchor, constant: 10)
        ])
        return bar
    }

    @objc private func selectAnnotation() { preview.chooseTool(nil) }
    @objc private func quickAction(_ sender: NSButton) { performQuickAction(quickActions[sender.tag]) }
    private func performQuickAction(_ action: ToolbarAction) {
        switch action {
        case .tool(let tool): preview.chooseTool(preview.selectedTool == tool ? nil : tool)
        case .undo: preview.undoEdit()
        case .pin: if let image = output() { onPin?(image) }
        case .save: saveOutput()
        case .done: copyOutput()
        case .cancel: window?.close()
        default: break
        }
    }
    @objc private func changeAnnotationStyle() {
        preview.sizeLevel = strokePicker.indexOfSelectedItem
        preview.selectedColor = annotationColor.color
        preview.applyStyle()
    }
    @objc private func selectAnnotationColor(_ sender: NSButton) {
        annotationColor.color = Style.colors[sender.tag]
        changeAnnotationStyle()
    }
    private func syncTools() {
        for (index, button) in toolButtons.enumerated() {
            if case .tool(let tool) = quickActions[index] {
                button.contentTintColor = preview.selectedTool == tool ? Brand.accent : .labelColor
                button.state = preview.selectedTool == tool ? .on : .off
            }
        }
        strokePicker.selectItem(at: preview.sizeLevel)
        annotationColor.color = preview.selectedColor
    }

    private func controlRow(_ title: String, value: Double, maximum: Double, tag: Int) -> NSView {
        let slider = NSSlider(value: value, minValue: 0, maxValue: maximum, target: self, action: #selector(sliderChanged(_:)))
        slider.tag = tag
        slider.isContinuous = true
        slider.setAccessibilityLabel(title + L(" (pixels)", "（像素）"))
        let field = NSTextField(string: String(Int(value)))
        field.tag = tag
        field.alignment = .right
        field.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        field.widthAnchor.constraint(equalToConstant: 44).isActive = true
        field.target = self
        field.action = #selector(valueChanged(_:))
        field.delegate = self
        field.setAccessibilityLabel(title + L(" (pixels)", "（像素）"))
        let row = NSStackView(views: [label(title, size: 12), slider, field, label("px", size: 11)])
        row.spacing = 7
        sliders.append(slider)
        values.append(field)
        return row
    }

    @objc private func sliderChanged(_ sender: NSSlider) {
        sender.doubleValue = sender.doubleValue.rounded()
        values[sender.tag].integerValue = sender.integerValue
        updateComposition()
    }

    @objc private func valueChanged(_ sender: NSTextField) {
        let slider = sliders[sender.tag]
        let entered = Double(sender.stringValue) ?? slider.doubleValue
        slider.doubleValue = entered.isFinite ? min(max(entered.rounded(), 0), slider.maxValue) : slider.doubleValue
        sender.integerValue = slider.integerValue
        updateComposition()
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        if let field = obj.object as? NSTextField, values.contains(field) { valueChanged(field) }
    }

    @objc private func updateComposition() {
        preview.composition = BackgroundLayout(horizontalPadding: CGFloat(sliders[0].integerValue),
                                               verticalPadding: CGFloat(sliders[1].integerValue),
                                               cornerRadius: CGFloat(sliders[2].integerValue), shadow: shadowButton.state == .on)
        refresh()
    }

    @objc private func selectPreset(_ sender: NSButton) {
        backgroundPicker.selectItem(at: sender.tag)
        changeBackground()
    }

    @objc private func changeBackground() {
        let index = backgroundPicker.indexOfSelectedItem
        switch index {
        case 0...2: preview.background = .gradient(index)
        case 3:
            guard let wallpaper else {
                backgroundPicker.selectItem(at: selectedBackground)
                feedback.stringValue = L("Unable to read the desktop wallpaper. Choose a local background image.", "无法读取当前壁纸，请选择本地背景图片。")
                return
            }
            preview.background = .image(wallpaper)
        case 4: preview.background = .color(colorWell.color)
        default:
            guard let customImage else { importBackground(); return }
            preview.background = .image(customImage)
        }
        selectedBackground = index
        refresh()
    }

    @objc private func changeColor() {
        backgroundPicker.selectItem(at: 4)
        changeBackground()
    }

    @objc private func importBackground() {
        guard let window else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.message = L("Choose a background image. It will be centered and fill the canvas.", "选择一张背景图片，图片会居中铺满画布。")
        panel.beginSheetModal(for: window) { [weak self] response in
            guard let self else { return }
            guard response == .OK, let url = panel.url else {
                self.backgroundPicker.selectItem(at: self.selectedBackground)
                return
            }
            guard let image = NSImage(contentsOf: url), image.isValid,
                  image.size.width > 0, image.size.height > 0 else {
                self.backgroundPicker.selectItem(at: self.selectedBackground)
                self.feedback.stringValue = L("Unable to read this image. Choose a PNG, JPEG, or HEIC file.", "无法读取这张图片，请选择 PNG、JPEG 或 HEIC。")
                return
            }
            self.customImage = image
            self.backgroundPicker.selectItem(at: 5)
            self.changeBackground()
        }
    }

    private func refresh() {
        preview.needsDisplay = true
        let size = preview.composition.canvasSize(for: CGSize(width: preview.source.width, height: preview.source.height))
        dimensions.stringValue = L("Export size  \(Int(size.width)) × \(Int(size.height)) px", "导出尺寸  \(Int(size.width)) × \(Int(size.height)) px")
        feedback.stringValue = L("Exports at the original resolution. Padding is measured in pixels.", "按原始截图分辨率导出，留白以像素计算。")
    }

    private func output() -> NSImage? {
        window?.makeFirstResponder(nil)
        let image = BackgroundRenderer.render(source: preview.source, background: preview.background, layout: preview.composition) { context in
            self.preview.drawAnnotations(in: context)
        }
        if image == nil { feedback.stringValue = L("Image too large or insufficient memory. Reduce padding and try again.", "图片尺寸过大或内存不足，请减小留白后重试。") }
        return image
    }

    @objc private func copyOutput() {
        guard let image = output() else { return }
        ImageExport.copy(image)
        feedback.stringValue = L("Copied to clipboard.", "已复制到剪贴板。")
    }

    @objc private func saveOutput() {
        guard let image = output() else { return }
        switch ImageExport.save(image) {
        case .saved: feedback.stringValue = L("Image saved.", "图片已保存。")
        case .cancelled: break
        case .failed: feedback.stringValue = L("Could not save. Choose another location and try again.", "保存失败，请选择其他位置后重试。")
        }
    }

    func windowWillClose(_ notification: Notification) { onClose?() }

    // MARK: AI tools

    private func makeAIMenu() -> NSPopUpButton {
        let menu = NSPopUpButton(frame: .zero, pullsDown: true)
        menu.controlSize = .large
        menu.addItem(withTitle: L("AI Tools", "AI 工具"))
        menu.item(at: 0)?.image = NSImage(systemSymbolName: "sparkles", accessibilityDescription: nil)
        let entries: [(String, String, Selector)] = [
            (L("Recognize Text", "识别文字"), "text.viewfinder", #selector(recognizeText)),
            (L("Redact Sensitive Information", "敏感信息打码"), "eye.slash", #selector(redactSensitive)),
            (L("Translate", "翻译"), "character.bubble", #selector(translateText)),
            (L("Ask a Question…", "提问…"), "questionmark.bubble", #selector(askQuestion))
        ]
        for (title, symbol, action) in entries {
            menu.addItem(withTitle: title)
            menu.lastItem?.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
            menu.lastItem?.target = self
            menu.lastItem?.action = action
        }
        menu.toolTip = L("Recognition and redaction run locally. Translation and questions send the screenshot to the AI service.", "文字识别和打码在本机完成；翻译和提问会把截图发送给 AI 服务")
        return menu
    }

    /// What AI features see: the screenshot with the current annotations, so anything already masked stays masked.
    private var annotatedSource: CGImage? {
        HistoryRenderer.render(original: preview.sourceImage, annotations: preview.annotations)?
            .cgImage(forProposedRect: nil, context: nil, hints: nil)
    }

    @objc private func recognizeText() {
        Telemetry.capture("ai_used", ["feature": "ocr"])
        guard let image = annotatedSource else { return }
        AIResultWindowController.show(title: L("Recognized Text", "识别出的文字"), near: window) {
            let text = await TextScanner.scan(image).text
            return text.isEmpty ? L("No text recognized.", "没有识别到文字。") : text
        }
    }

    @objc private func redactSensitive() {
        Telemetry.capture("ai_used", ["feature": "redact"])
        feedback.stringValue = L("Finding sensitive information…", "正在查找敏感信息…")
        let source = preview.source
        let size = preview.sourceImage.size
        Task { @MainActor in
            let boxes = await TextScanner.scan(source).sensitiveBoxes
            let masks = boxes.map { box in
                SensitiveDetector.mosaic(covering: CGRect(
                    x: box.minX * size.width, y: box.minY * size.height,
                    width: box.width * size.width, height: box.height * size.height
                ))
            }
            preview.append(masks)
            feedback.stringValue = masks.isEmpty
                ? L("No sensitive phone numbers, emails, ID numbers, or keys found.", "没有发现手机号、邮箱、证件号或密钥等敏感信息。")
                : L("Redacted \(masks.count) sensitive regions. Use Undo to restore them.", "已给 \(masks.count) 处敏感信息打码，可用撤销恢复。")
        }
    }

    @objc private func translateText() {
        Telemetry.capture("ai_used", ["feature": "translate"])
        guard let image = annotatedSource else { return }
        AIResultWindowController.show(title: L("Translate to \(AppSettings.translateTarget)", "翻译成\(AppSettings.translateTarget)"), near: window) {
            try await AIAssistant.translate(image)
        }
    }

    @objc private func askQuestion() {
        Telemetry.capture("ai_used", ["feature": "ask"])
        guard let window, let image = annotatedSource else { return }
        let alert = NSAlert()
        alert.messageText = L("What would you like to ask about this screenshot?", "关于这张截图，你想问什么？")
        alert.informativeText = L("The screenshot will be sent to the AI service.", "截图会发送给 AI 服务。")
        let field = NSTextField(frame: CGRect(x: 0, y: 0, width: 340, height: 24))
        field.placeholderString = L("For example: What does this error mean?", "例如：这个报错是什么意思？")
        alert.accessoryView = field
        alert.addButton(withTitle: L("Ask", "提问"))
        alert.addButton(withTitle: L("Cancel", "取消"))
        alert.window.initialFirstResponder = field
        alert.beginSheetModal(for: window) { [weak self] response in
            let question = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard response == .alertFirstButtonReturn, !question.isEmpty else { return }
            AIResultWindowController.show(title: question, near: self?.window) {
                try await AIAssistant.ask(question, about: image)
            }
        }
    }
}
