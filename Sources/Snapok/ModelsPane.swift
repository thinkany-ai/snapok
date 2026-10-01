import AppKit

/// Settings → Models: the default model, the providers that supply models (bring your own key), and AI features.
@MainActor
final class ModelsPane: SectionedPageView {
    private let defaultModel = NSPopUpButton()
    private var providerList: NSStackView!
    private let translateTarget = NSPopUpButton()
    private let targets = ["简体中文", "繁體中文", "English", "日本語", "한국어"]
    private let autoName = NSButton(checkboxWithTitle: L("Automatically title and tag new screenshots (sends images to the default model)",
                                                         "截图后自动起标题、打标签（会把截图发送给默认模型）"), target: nil, action: nil)
    private var editor: ProviderEditor?

    init() {
        super.init(title: L("Models", "模型"))
        defaultModel.target = self
        defaultModel.action = #selector(chooseDefault)
        let defaultRow = Self.formRow(L("Default Model", "默认模型"), control: defaultModel)
        add(Self.card(defaultRow, inset: NSEdgeInsets(top: 4, left: 0, bottom: 4, right: 0)))
        add(Self.footnote(L("Translate, Ask, and automatic naming use the default model. Bring your own key: keys are stored only in this Mac's Keychain and are sent only to their provider.",
                            "翻译、提问和自动命名使用默认模型。自带 Key（BYOK）：Key 只保存在本机钥匙串里，只会发送给对应的服务商。")), spacingBefore: 8)

        let addButton = NSButton(title: L("Add Provider", "添加服务商"), image: NSImage(systemSymbolName: "plus", accessibilityDescription: nil)!,
                                 target: self, action: #selector(addProvider))
        addButton.isBordered = false
        addButton.imagePosition = .imageLeading
        addButton.contentTintColor = Brand.accent
        addButton.attributedTitle = NSAttributedString(string: addButton.title, attributes: [.foregroundColor: Brand.accent, .font: NSFont.systemFont(ofSize: 13)])
        providerList = addSection(L("Providers", "服务商"), accessory: addButton, rows: [])

        translateTarget.addItems(withTitles: targets)
        translateTarget.target = self
        translateTarget.action = #selector(saveFeatures)
        autoName.target = self
        autoName.action = #selector(saveFeatures)
        autoName.cell?.wraps = true
        let autoNameRow = NSStackView(views: [autoName])
        autoNameRow.edgeInsets = NSEdgeInsets(top: 12, left: 18, bottom: 12, right: 18)
        addSection(L("AI Features", "AI 功能"), rows: [Self.formRow(L("Translate to", "翻译成"), control: translateTarget), autoNameRow])
        add(Self.footnote(L("Text recognition and redaction always run on this Mac.", "文字识别和敏感信息打码始终在本机完成。")), spacingBefore: 8)

        reload()
        NotificationCenter.default.addObserver(forName: ModelsStore.didChange, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.reload() }
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func load() { reload() }

    private func reload() {
        let config = ModelsStore.config
        defaultModel.removeAllItems()
        if config.allModels.isEmpty {
            defaultModel.addItem(withTitle: L("No models yet — add a provider below", "还没有模型，请先在下方添加服务商"))
            defaultModel.isEnabled = false
        } else {
            defaultModel.isEnabled = true
            // Listed as "provider ID/model ID", with the model's title in gray.
            for (provider, model) in config.allModels {
                let reference = ModelsConfig.reference(provider, model)
                defaultModel.addItem(withTitle: reference)
                let title = NSMutableAttributedString(string: reference, attributes: [.font: NSFont.systemFont(ofSize: 13)])
                if !model.title.isEmpty {
                    title.append(NSAttributedString(string: "  \(model.title)", attributes: [.font: NSFont.systemFont(ofSize: 12), .foregroundColor: NSColor.secondaryLabelColor]))
                }
                defaultModel.lastItem?.attributedTitle = title
                defaultModel.lastItem?.representedObject = reference
            }
            if let current = config.resolvedDefault {
                defaultModel.selectItem(at: defaultModel.indexOfItem(withRepresentedObject: ModelsConfig.reference(current.provider, current.model)))
            }
        }

        let rows: [NSView] = config.providers.isEmpty
            ? [Self.emptyRow(L("No providers yet. Add one to use translation, questions, and automatic naming.",
                               "还没有服务商。添加一个即可使用翻译、提问和自动命名。"))]
            : config.providers.map { provider in
                ProviderRow(provider: provider, isDefault: config.resolvedDefault?.provider.id == provider.id,
                            onEdit: { [weak self] in self?.edit(provider) },
                            onDelete: { [weak self] in self?.confirmDelete(provider) })
            }
        Self.fill(providerList, with: rows)

        translateTarget.selectItem(withTitle: AppSettings.translateTarget)
        autoName.state = AppSettings.autoName ? .on : .off
    }

    @objc private func chooseDefault() {
        guard let id = defaultModel.selectedItem?.representedObject as? String else { return }
        var config = ModelsStore.config
        config.defaultModel = id
        ModelsStore.config = config
    }

    @objc private func saveFeatures() {
        AppSettings.translateTarget = translateTarget.titleOfSelectedItem ?? "简体中文"
        AppSettings.autoName = autoName.state == .on
    }

    @objc private func addProvider() {
        let preset = ModelsConfig.presets[0]
        edit(ModelProvider(id: ModelsStore.config.uniqueID(for: preset.id), name: preset.label, kind: preset.kind,
                           apiBase: preset.apiBase, models: [preset.model]), isNew: true)
    }

    private func edit(_ provider: ModelProvider, isNew: Bool = false) {
        guard let window else { return }
        let editor = ProviderEditor(provider: provider, isNew: isNew)
        self.editor = editor
        editor.onFinish = { [weak self] in self?.editor = nil }
        window.beginSheet(editor.sheet)
    }

    private func confirmDelete(_ provider: ModelProvider) {
        guard let window else { return }
        let alert = NSAlert()
        alert.messageText = L("Delete \(provider.name)?", "删除 \(provider.name)？")
        alert.informativeText = L("Its \(provider.models.count) models and API key will be removed from Snapok.", "它的 \(provider.models.count) 个模型和 API Key 会从 Snapok 中移除。")
        alert.addButton(withTitle: L("Delete", "删除"))
        alert.addButton(withTitle: L("Cancel", "取消"))
        alert.buttons.first?.hasDestructiveAction = true
        alert.beginSheetModal(for: window) { response in
            if response == .alertFirstButtonReturn { ModelsStore.remove(provider.id) }
        }
    }

    private static func formRow(_ title: String, control: NSView) -> NSView {
        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: 14)
        let row = NSStackView(views: [label, NSView(), control])
        row.alignment = .centerY
        row.edgeInsets = NSEdgeInsets(top: 10, left: 18, bottom: 10, right: 18)
        return row
    }

    private static func emptyRow(_ text: String) -> NSView {
        let row = NSStackView(views: [footnote(text)])
        row.edgeInsets = NSEdgeInsets(top: 16, left: 18, bottom: 16, right: 18)
        return row
    }
}

/// One provider: icon, name, format badge, a warning without a key, host and model count, then edit and delete.
@MainActor
private final class ProviderRow: NSView {
    private let onEdit: () -> Void

    init(provider: ModelProvider, isDefault: Bool, onEdit: @escaping () -> Void, onDelete: @escaping () -> Void) {
        self.onEdit = onEdit
        super.init(frame: .zero)
        let anthropic = provider.kind == .anthropic
        let tile = IconTile(symbol: anthropic ? "a.circle.fill" : "o.circle.fill", tint: anthropic ? .systemBrown : .systemGreen)

        let name = NSTextField(labelWithString: provider.name.isEmpty ? L("Untitled", "未命名") : provider.name)
        name.font = .systemFont(ofSize: 14, weight: .medium)
        var badges: [NSView] = [name, Badge(text: ProviderEditor.kindTitle(provider.kind), color: .secondaryLabelColor)]
        if isDefault { badges.append(Badge(text: L("Default", "默认"), color: Brand.accent)) }
        if !provider.hasKey { badges.append(Badge(text: L("No API key", "未填 Key"), color: .systemOrange)) }
        let titleRow = NSStackView(views: badges)
        titleRow.spacing = 6
        let count = L("\(provider.models.count) models", "\(provider.models.count) 个模型")
        let detail = NSTextField(labelWithString: "\(provider.id) · \(provider.endpoint?.host ?? "—") · \(count)")
        detail.font = .systemFont(ofSize: 12)
        detail.textColor = .secondaryLabelColor
        detail.lineBreakMode = .byTruncatingTail
        let text = NSStackView(views: [titleRow, detail])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 3

        let edit = Self.iconButton("pencil", help: L("Edit", "编辑"), tint: Brand.accent)
        edit.target = self
        edit.action = #selector(editTapped)
        let delete = Self.iconButton("trash", help: L("Delete", "删除"), tint: .secondaryLabelColor)
        delete.target = self
        delete.action = #selector(deleteTapped)
        self.onDelete = onDelete

        let row = NSStackView(views: [tile, text, NSView(), edit, delete])
        row.spacing = 12
        row.alignment = .centerY
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        NSLayoutConstraint.activate([
            row.topAnchor.constraint(equalTo: topAnchor, constant: 12),
            row.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -12),
            row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 18),
            row.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -18)
        ])
    }

    private var onDelete: () -> Void = {}

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    @objc private func editTapped() { onEdit() }
    @objc private func deleteTapped() { onDelete() }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 { onEdit() }
    }

    private static func iconButton(_ symbol: String, help: String, tint: NSColor) -> NSButton {
        let button = NSButton(image: NSImage(systemSymbolName: symbol, accessibilityDescription: help)!, target: nil, action: nil)
        button.isBordered = false
        button.contentTintColor = tint
        button.toolTip = help
        button.symbolConfiguration = .init(pointSize: 14, weight: .regular)
        return button
    }
}

/// A small rounded label, such as "OpenAI-compatible" or "No API key".
@MainActor
private final class Badge: NSView {
    init(text: String, color: NSColor) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 4
        layer?.backgroundColor = color.withAlphaComponent(0.12).cgColor
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 11, weight: .medium)
        label.textColor = color
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.topAnchor.constraint(equalTo: topAnchor, constant: 1),
            label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -1),
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6)
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}

/// Sheet for adding or editing a provider: preset, format, ID and name, base URL, key, models, and a connection test.
/// Nothing is saved until Add/Done, and only when the provider and model IDs are valid and unique.
@MainActor
final class ProviderEditor: NSObject, NSTextFieldDelegate {
    let sheet: NSWindow
    var onFinish: (() -> Void)?

    private let original: ModelProvider
    private let isNew: Bool
    /// A new provider's ID follows the chosen preset until the user types their own.
    private var idEdited = false
    private let preset = NSPopUpButton()
    private let kind = NSSegmentedControl(labels: ModelProvider.Kind.allCases.map(ProviderEditor.kindTitle), trackingMode: .selectOne, target: nil, action: nil)
    private let providerID = NSTextField()
    private let name = NSTextField()
    private let base = NSTextField()
    private let endpoint = NSTextField(labelWithString: "")
    private let key = NSSecureTextField()
    private let modelRows = NSStackView()
    private let status = NSTextField(wrappingLabelWithString: "")
    private let spinner = NSProgressIndicator()
    private let testButton = NSButton(title: L("Test Connection", "测试连接"), target: nil, action: nil)

    private static let fieldWidth: CGFloat = 420

    nonisolated static func kindTitle(_ kind: ModelProvider.Kind) -> String {
        kind == .anthropic ? "Anthropic" : L("OpenAI-compatible", "OpenAI 兼容")
    }

    init(provider: ModelProvider, isNew: Bool) {
        original = provider
        self.isNew = isNew
        sheet = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 600, height: 10), styleMask: [.titled], backing: .buffered, defer: false)
        super.init()
        build()
        fill()
    }

    private func build() {
        for item in ModelsConfig.presets {
            preset.addItem(withTitle: item.id == "custom" ? L("Custom", "自定义") : item.label)
            preset.lastItem?.representedObject = item.id
        }
        preset.target = self
        preset.action = #selector(applyPreset)
        kind.target = self
        kind.action = #selector(kindChanged)
        for field in [providerID, name, base, key] as [NSTextField] {
            field.delegate = self
        }
        for field in [base, key] as [NSTextField] {
            field.widthAnchor.constraint(equalToConstant: Self.fieldWidth).isActive = true
        }
        // ID and name share a row, laid out like the model rows below: ID on the left, name on the right.
        providerID.widthAnchor.constraint(equalToConstant: ModelRow.idWidth).isActive = true
        name.widthAnchor.constraint(equalToConstant: Self.fieldWidth - ModelRow.idWidth - ModelRow.spacing).isActive = true
        providerID.placeholderString = "openrouter"
        name.placeholderString = L("e.g. OpenRouter", "例如 OpenRouter")
        key.placeholderString = "sk-…"
        endpoint.font = .systemFont(ofSize: 11)
        endpoint.textColor = .secondaryLabelColor
        endpoint.lineBreakMode = .byTruncatingMiddle
        endpoint.isSelectable = true
        endpoint.widthAnchor.constraint(equalToConstant: Self.fieldWidth).isActive = true
        let idHint = Self.hint(L("Unique. Lowercase letters, digits, “.”, “_”, “-”. Models are referenced as provider ID/model ID.",
                                 "唯一，只能用小写字母、数字、“.”、“_”、“-”。模型以「服务商 ID/模型 ID」引用。"))
        let idHeader = Self.hint("ID")
        idHeader.widthAnchor.constraint(equalToConstant: ModelRow.idWidth).isActive = true
        let identityHeader = NSStackView(views: [idHeader, Self.hint(L("Name", "名称"))])
        identityHeader.spacing = ModelRow.spacing
        let identityFields = NSStackView(views: [providerID, name])
        identityFields.spacing = ModelRow.spacing
        let identityColumn = Self.column([identityHeader, identityFields, idHint])

        modelRows.orientation = .vertical
        modelRows.alignment = .leading
        modelRows.spacing = 6
        let modelIDHeader = Self.hint("ID")
        let titleHeader = Self.hint(L("Display Name (optional)", "显示名称（可选）"))
        modelIDHeader.widthAnchor.constraint(equalToConstant: ModelRow.idWidth).isActive = true
        let header = NSStackView(views: [modelIDHeader, titleHeader])
        header.spacing = ModelRow.spacing
        let addModel = NSButton(title: L("Add Model", "添加模型"), image: NSImage(systemSymbolName: "plus", accessibilityDescription: nil)!,
                                target: self, action: #selector(addModelRow))
        addModel.isBordered = false
        addModel.imagePosition = .imageLeading
        addModel.contentTintColor = Brand.accent
        addModel.attributedTitle = NSAttributedString(string: addModel.title, attributes: [.foregroundColor: Brand.accent, .font: NSFont.systemFont(ofSize: 12)])
        let modelColumn = Self.column([header, modelRows, addModel])

        let grid = PageView.form([
            [PageView.label(L("Preset", "预设")), preset],
            [PageView.label(L("API Format", "接口格式")), kind],
            [PageView.label(L("Provider", "服务商")), identityColumn],
            [PageView.label("Base URL"), Self.column([base, endpoint])],
            [PageView.label("API Key"), key],
            [PageView.label(L("Models", "模型")), modelColumn]
        ])
        grid.rowSpacing = 12

        status.font = .systemFont(ofSize: 12)
        status.preferredMaxLayoutWidth = 300
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        testButton.target = self
        testButton.action = #selector(test)
        testButton.bezelStyle = .rounded
        let cancel = NSButton(title: L("Cancel", "取消"), target: self, action: #selector(cancel))
        cancel.bezelStyle = .rounded
        cancel.keyEquivalent = "\u{1b}"
        let done = NSButton(title: isNew ? L("Add", "添加") : L("Done", "完成"), target: self, action: #selector(done))
        done.bezelStyle = .rounded
        done.keyEquivalent = "\r"
        let footer = NSStackView(views: [spinner, status, NSView(), testButton, cancel, done])
        footer.spacing = 8
        footer.alignment = .centerY

        let title = NSTextField(labelWithString: isNew ? L("Add Provider", "添加服务商") : L("Edit Provider", "编辑服务商"))
        title.font = .systemFont(ofSize: 15, weight: .semibold)
        let content = NSStackView(views: [title, grid, footer])
        content.orientation = .vertical
        content.alignment = .leading
        content.spacing = 18
        content.edgeInsets = NSEdgeInsets(top: 20, left: 24, bottom: 20, right: 24)
        content.translatesAutoresizingMaskIntoConstraints = false
        let root = NSView()
        root.addSubview(content)
        NSLayoutConstraint.activate([
            content.topAnchor.constraint(equalTo: root.topAnchor),
            content.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            content.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            footer.widthAnchor.constraint(equalTo: content.widthAnchor, constant: -48)
        ])
        sheet.contentView = root
    }

    private static func column(_ views: [NSView]) -> NSStackView {
        let stack = NSStackView(views: views)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 4
        return stack
    }

    private static func hint(_ text: String) -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: text)
        label.font = .systemFont(ofSize: 11)
        label.textColor = .secondaryLabelColor
        label.preferredMaxLayoutWidth = fieldWidth
        return label
    }

    private func fill() {
        let match = ModelsConfig.preset(matching: original)?.id ?? "custom"
        preset.selectItem(at: preset.indexOfItem(withRepresentedObject: match))
        kind.selectedSegment = ModelProvider.Kind.allCases.firstIndex(of: original.kind) ?? 0
        providerID.stringValue = original.id
        name.stringValue = original.name
        base.stringValue = original.apiBase
        key.stringValue = isNew ? "" : original.apiKey ?? ""
        setModels(original.models)
        updateEndpoint()
    }

    private func setModels(_ models: [ModelEntry]) {
        modelRows.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for model in models.isEmpty ? [ModelEntry(id: "")] : models { appendRow(model) }
    }

    private func appendRow(_ model: ModelEntry) {
        let row = ModelRow(model: model, placeholder: currentKind == .anthropic ? "claude-opus-5-5" : "deepseek-v4-flash")
        row.onRemove = { [weak self, weak row] in
            guard let self, let row else { return }
            row.removeFromSuperview()
            if self.modelRows.arrangedSubviews.isEmpty { self.appendRow(ModelEntry(id: "")) }
            self.clearStatus()
        }
        row.onChange = { [weak self] in self?.clearStatus() }
        modelRows.addArrangedSubview(row)
    }

    @objc private func addModelRow() {
        appendRow(ModelEntry(id: ""))
        (modelRows.arrangedSubviews.last as? ModelRow)?.focus(in: sheet)
    }

    private var currentKind: ModelProvider.Kind { ModelProvider.Kind.allCases[max(0, kind.selectedSegment)] }

    /// The provider as filled in; blank model rows are left out.
    private var draft: ModelProvider {
        let trimmedName = name.stringValue.trimmingCharacters(in: .whitespaces)
        let models = modelRows.arrangedSubviews.compactMap { ($0 as? ModelRow)?.entry }.filter { !($0.id.isEmpty && $0.title.isEmpty) }
        var value = ModelProvider(id: providerID.stringValue.trimmingCharacters(in: .whitespaces), name: trimmedName, kind: currentKind,
                                  apiBase: base.stringValue.trimmingCharacters(in: .whitespaces), models: models)
        if value.name.isEmpty { value.name = value.endpoint?.host ?? value.id }
        return value
    }

    private func updateEndpoint() {
        base.placeholderString = ModelProvider.defaultBase[currentKind]
        endpoint.stringValue = L("Requests go to ", "请求地址：") + (draft.endpoint?.absoluteString ?? "—")
    }

    private func showStatus(_ text: String, color: NSColor) {
        status.stringValue = text
        status.textColor = color
    }

    private func clearStatus() { showStatus("", color: .secondaryLabelColor) }

    func controlTextDidChange(_ obj: Notification) {
        let field = obj.object as? NSTextField
        if field === base { updateEndpoint() }
        if field === providerID { idEdited = true }
        clearStatus()
    }

    @objc private func applyPreset() {
        guard let id = preset.selectedItem?.representedObject as? String, id != "custom",
              let item = ModelsConfig.presets.first(where: { $0.id == id }) else { return }
        kind.selectedSegment = ModelProvider.Kind.allCases.firstIndex(of: item.kind) ?? 0
        if isNew && !idEdited { providerID.stringValue = ModelsStore.config.uniqueID(for: item.id) }
        name.stringValue = item.label
        base.stringValue = item.apiBase
        setModels([item.model])
        updateEndpoint()
        clearStatus()
    }

    @objc private func kindChanged() {
        preset.selectItem(at: preset.indexOfItem(withRepresentedObject: ModelsConfig.preset(matching: draft)?.id ?? "custom"))
        updateEndpoint()
    }

    /// The first problem that blocks a request: an invalid address or bad model IDs.
    private func requestProblem(in value: ModelProvider) -> String? {
        if value.endpoint == nil { return L("Enter a valid base URL, starting with https://.", "请填写有效的接口地址（以 https:// 开头）。") }
        return ModelsConfig.modelsProblem(value.models)
    }

    /// The first problem that blocks saving, if any.
    private func problem(in value: ModelProvider) -> String? {
        let others = ModelsStore.config.providers.filter { isNew || $0.id != original.id }
        return ModelsConfig.providerIDProblem(value.id, takenBy: others) ?? requestProblem(in: value)
    }

    @objc private func test() {
        let candidate = draft
        if let problem = requestProblem(in: candidate) {
            showStatus(problem, color: .systemRed)
            return
        }
        let typedKey = key.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        spinner.startAnimation(nil)
        testButton.isEnabled = false
        showStatus(L("Connecting…", "正在连接…"), color: .secondaryLabelColor)
        Task { @MainActor in
            do {
                let model = try await AIClient.test(candidate, apiKey: typedKey)
                showStatus(L("Connected. \(model) is available.", "连接成功，\(model) 可用。"), color: .systemGreen)
            } catch {
                showStatus(error.localizedDescription, color: .systemRed)
            }
            spinner.stopAnimation(nil)
            testButton.isEnabled = true
        }
    }

    @objc private func cancel() {
        close()
    }

    @objc private func done() {
        let value = draft
        if let problem = problem(in: value) {
            showStatus(problem, color: .systemRed)
            return
        }
        ModelsStore.save(value, replacing: isNew ? nil : original.id, apiKey: key.stringValue)
        close()
    }

    private func close() {
        sheet.sheetParent?.endSheet(sheet)
        onFinish?()
    }
}

/// One editable model: ID on the left, display name on the right, and a remove button.
@MainActor
private final class ModelRow: NSStackView {
    static let idWidth: CGFloat = 220
    static let spacing: CGFloat = 8

    var onRemove: (() -> Void)?
    var onChange: (() -> Void)?
    private let idField = NSTextField()
    private let titleField = NSTextField()

    init(model: ModelEntry, placeholder: String) {
        super.init(frame: .zero)
        spacing = Self.spacing
        alignment = .centerY
        idField.stringValue = model.id
        idField.placeholderString = placeholder
        titleField.stringValue = model.title
        titleField.placeholderString = L("Same as ID", "与 ID 相同")
        idField.widthAnchor.constraint(equalToConstant: Self.idWidth).isActive = true
        titleField.widthAnchor.constraint(equalToConstant: 160).isActive = true // with the remove button, ends where the name field does
        for field in [idField, titleField] {
            field.target = self
            field.action = #selector(changed)
            NotificationCenter.default.addObserver(self, selector: #selector(changed), name: NSControl.textDidChangeNotification, object: field)
        }
        let remove = NSButton(image: NSImage(systemSymbolName: "minus.circle.fill", accessibilityDescription: L("Remove model", "删除模型"))!,
                              target: self, action: #selector(removeTapped))
        remove.isBordered = false
        remove.contentTintColor = .secondaryLabelColor
        remove.toolTip = L("Remove model", "删除模型")
        [idField, titleField, remove].forEach(addArrangedSubview)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    var entry: ModelEntry {
        ModelEntry(id: idField.stringValue.trimmingCharacters(in: .whitespaces), title: titleField.stringValue.trimmingCharacters(in: .whitespaces))
    }

    func focus(in window: NSWindow) { window.makeFirstResponder(idField) }

    @objc private func changed() { onChange?() }
    @objc private func removeTapped() { onRemove?() }
}
