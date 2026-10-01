import AppKit

/// Shared look for the right-hand pages of the main window: a large title, a subtitle, then content.
@MainActor
class PageView: NSView {
    let titleLabel = NSTextField(labelWithString: "")
    let subtitleLabel = NSTextField(labelWithString: "")

    init(title: String, subtitle: String) {
        super.init(frame: .zero)
        titleLabel.stringValue = title
        titleLabel.font = .systemFont(ofSize: 30, weight: .bold)
        subtitleLabel.stringValue = subtitle
        subtitleLabel.font = .systemFont(ofSize: 13)
        subtitleLabel.textColor = .secondaryLabelColor
        subtitleLabel.maximumNumberOfLines = 0
        subtitleLabel.lineBreakMode = .byWordWrapping
        [titleLabel, subtitleLabel].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            addSubview($0)
        }
        NSLayoutConstraint.activate([
            titleLabel.topAnchor.constraint(equalTo: topAnchor, constant: 44),
            titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 40),
            subtitleLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 6),
            subtitleLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            subtitleLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -40)
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// A white rounded card holding a settings form, placed under the page title.
    func addCard(_ content: NSView) {
        let card = CardView()
        content.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(content)
        card.translatesAutoresizingMaskIntoConstraints = false
        addSubview(card)
        NSLayoutConstraint.activate([
            card.topAnchor.constraint(equalTo: subtitleLabel.bottomAnchor, constant: 28),
            card.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 40),
            card.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -40),
            card.widthAnchor.constraint(greaterThanOrEqualToConstant: 480),
            content.topAnchor.constraint(equalTo: card.topAnchor, constant: 24),
            content.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 28),
            content.trailingAnchor.constraint(lessThanOrEqualTo: card.trailingAnchor, constant: -28),
            content.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -24)
        ])
    }

    static func label(_ text: String, secondary: Bool = false) -> NSTextField {
        let field = NSTextField(labelWithString: text)
        field.font = .systemFont(ofSize: secondary ? 12 : 13)
        if secondary { field.textColor = .secondaryLabelColor }
        return field
    }

    static func form(_ rows: [[NSView]]) -> NSGridView {
        let grid = NSGridView(views: rows)
        grid.rowSpacing = 14
        grid.columnSpacing = 14
        grid.column(at: 0).xPlacement = .trailing
        grid.rowAlignment = .firstBaseline
        return grid
    }
}

/// Rounded card that follows light/dark appearance.
@MainActor
final class CardView: NSView {
    var isHighlighted = false {
        didSet { needsDisplay = true }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 14
        layer?.borderWidth = 1
        layer?.shadowOpacity = 1
        layer?.shadowRadius = 10
        layer?.shadowOffset = CGSize(width: 0, height: -2)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        let dark = effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        layer?.backgroundColor = (dark ? NSColor(white: 0.17, alpha: 1) : .white).cgColor
        layer?.borderColor = isHighlighted ? Brand.accent.cgColor : NSColor(white: dark ? 1 : 0, alpha: 0.06).cgColor
        layer?.borderWidth = isHighlighted ? 2 : 1
        layer?.shadowColor = NSColor(white: 0, alpha: dark ? 0.3 : 0.06).cgColor
    }
}

@MainActor
final class GeneralSettingsPane: PageView {
    private let autoSave = NSButton(checkboxWithTitle: L("Automatically save screenshots to the library", "截图后自动保存到截图库"), target: nil, action: nil)
    private let retention = NSPopUpButton()
    private let language = NSPopUpButton()
    private let retentionOptions: [(title: String, days: Int)] = [(L("7 days", "7 天"), 7), (L("30 days", "30 天"), 30), (L("90 days", "90 天"), 90), (L("Forever", "永久"), 0)]

    init() {
        super.init(title: L("General", "通用设置"), subtitle: L("Shortcuts and screenshot storage preferences.", "快捷键、截图库保存方式。"))
        language.addItems(withTitles: ["English", "简体中文"])
        language.selectItem(at: AppLanguage.allCases.firstIndex(of: AppLanguage.saved()) ?? 0)
        language.target = self
        language.action = #selector(saveLanguage)
        autoSave.target = self
        autoSave.action = #selector(save)
        retention.addItems(withTitles: retentionOptions.map(\.title))
        retention.target = self
        retention.action = #selector(save)
        let openFolder = NSButton(title: L("Open in Finder", "在 Finder 中打开"), target: self, action: #selector(openHistoryFolder))
        openFolder.bezelStyle = .rounded
        let clear = NSButton(title: L("Clear Library…", "清空截图库…"), target: self, action: #selector(clearHistory))
        clear.bezelStyle = .rounded
        addCard(Self.form([
            [Self.label(L("Language", "语言")), language],
            [NSGridCell.emptyContentView, Self.label(L("Applies after restarting Snapok.", "重启 Snapok 后生效。"), secondary: true)],
            [Self.label(L("Screenshot shortcut", "截图快捷键")), KeycapRow(keys: AppChannel.hotKeyKeys)],
            [NSGridCell.emptyContentView, autoSave],
            [Self.label(L("Keep screenshots", "保留时间")), retention],
            [NSGridCell.emptyContentView, Self.label(L("Screenshots older than this period are deleted automatically.", "超过保留时间的截图会自动删除。"), secondary: true)],
            [Self.label(L("Library", "截图库")), NSStackView(views: [openFolder, clear])],
            [NSGridCell.emptyContentView, Self.label(L("Screenshots are stored only on this Mac.", "截图只保存在这台 Mac 上。"), secondary: true)]
        ]))
        load()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func load() {
        autoSave.state = AppSettings.autoSave ? .on : .off
        retention.selectItem(at: retentionOptions.firstIndex { $0.days == AppSettings.retentionDays } ?? 1)
    }

    @objc private func saveLanguage() {
        guard AppLanguage.allCases.indices.contains(language.indexOfSelectedItem) else { return }
        AppLanguage.allCases[language.indexOfSelectedItem].save()
    }

    @objc private func save() {
        AppSettings.autoSave = autoSave.state == .on
        AppSettings.retentionDays = retentionOptions[retention.indexOfSelectedItem].days
        HistoryStore.shared.purgeExpired()
        NotificationCenter.default.post(name: HistoryStore.didChange, object: nil)
    }

    @objc private func openHistoryFolder() {
        NSWorkspace.shared.open(HistoryStore.shared.root)
    }

    @objc private func clearHistory() {
        guard let window else { return }
        let alert = NSAlert()
        alert.messageText = L("Clear the screenshot library?", "清空截图库？")
        alert.informativeText = L("All \(HistoryStore.shared.items.count) screenshots will be permanently deleted.", "会删除截图库里全部 \(HistoryStore.shared.items.count) 张截图，无法恢复。")
        alert.addButton(withTitle: L("Clear", "清空"))
        alert.addButton(withTitle: L("Cancel", "取消"))
        alert.buttons.first?.hasDestructiveAction = true
        alert.beginSheetModal(for: window) { response in
            if response == .alertFirstButtonReturn { HistoryStore.shared.clearAll() }
        }
    }
}

@MainActor
final class AISettingsPane: PageView, NSTextFieldDelegate {
    private let apiKey = NSSecureTextField()
    private let model = NSComboBox()
    private let baseURL = NSTextField()
    private let translateTarget = NSPopUpButton()
    private let targets = ["简体中文", "繁體中文", "English", "日本語", "한국어"]
    private let autoName = NSButton(checkboxWithTitle: L("Automatically title and tag screenshots (sends images to the AI service)", "截图后自动起标题、打标签（会把截图发送给 AI 服务）"), target: nil, action: nil)
    private let status = NSTextField(wrappingLabelWithString: "")

    init() {
        super.init(title: L("AI Settings", "AI 设置"), subtitle: L("Text recognition and redaction run locally. Translation, questions, and naming use Claude.", "文字识别和敏感信息打码在本机完成；翻译、提问和自动命名使用 Claude。"))
        apiKey.placeholderString = "sk-ant-…"
        model.addItems(withObjectValues: ["claude-opus-5-5", "claude-sonnet-5-5", "claude-haiku-4-5"])
        model.completes = true
        baseURL.placeholderString = "https://api.anthropic.com"
        for field in [apiKey, model, baseURL] as [NSTextField] {
            field.widthAnchor.constraint(equalToConstant: 340).isActive = true
            field.delegate = self
        }
        translateTarget.addItems(withTitles: targets)
        translateTarget.target = self
        translateTarget.action = #selector(save)
        autoName.cell?.wraps = true
        autoName.widthAnchor.constraint(lessThanOrEqualToConstant: 340).isActive = true
        autoName.target = self
        autoName.action = #selector(save)
        status.font = .systemFont(ofSize: 12)
        status.textColor = .secondaryLabelColor
        status.preferredMaxLayoutWidth = 340
        let test = NSButton(title: L("Test Connection", "测试连接"), target: self, action: #selector(testConnection))
        test.bezelStyle = .rounded
        addCard(Self.form([
            [Self.label(L("Service", "服务")), Self.label("Anthropic Claude")],
            [Self.label("API Key"), apiKey],
            [NSGridCell.emptyContentView, Self.label(L("Your API key is stored in macOS Keychain.", "API Key 保存在系统钥匙串里。"), secondary: true)],
            [Self.label(L("Model", "模型")), model],
            [Self.label(L("Base URL", "接口地址")), baseURL],
            [Self.label(L("Translate to", "翻译成")), translateTarget],
            [NSGridCell.emptyContentView, autoName],
            [NSGridCell.emptyContentView, test],
            [NSGridCell.emptyContentView, status]
        ]))
        load()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func load() {
        apiKey.stringValue = AppSettings.apiKey ?? ""
        model.stringValue = AppSettings.aiModel
        baseURL.stringValue = AppSettings.aiBaseURL
        translateTarget.selectItem(withTitle: AppSettings.translateTarget)
        autoName.state = AppSettings.autoName ? .on : .off
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        save()
    }

    @objc func save() {
        let key = apiKey.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if key != (AppSettings.apiKey ?? "") {
            AppSettings.apiKey = key.isEmpty ? nil : key
        }
        let modelName = model.stringValue.trimmingCharacters(in: .whitespaces)
        AppSettings.aiModel = modelName.isEmpty ? "claude-opus-5-5" : modelName
        let url = baseURL.stringValue.trimmingCharacters(in: .whitespaces)
        AppSettings.aiBaseURL = url.isEmpty ? "https://api.anthropic.com" : url
        AppSettings.translateTarget = translateTarget.titleOfSelectedItem ?? "简体中文"
        AppSettings.autoName = autoName.state == .on
    }

    @objc private func testConnection() {
        save()
        status.textColor = .secondaryLabelColor
        status.stringValue = L("Connecting…", "正在连接…")
        Task { @MainActor in
            do {
                let client = try ClaudeClient.configured()
                _ = try await client.send(system: "只回复 OK。", text: "连接测试", effort: "low")
                status.textColor = .systemGreen
                status.stringValue = L("Connected. Model \(client.model) is available.", "连接成功，模型 \(client.model) 可用。")
            } catch {
                status.textColor = .systemRed
                status.stringValue = error.localizedDescription
            }
        }
    }
}

/// Keyboard keys drawn as small outlined caps, as in "⌃ ⌘ A".
@MainActor
final class KeycapRow: NSStackView {
    init(keys: [String], size: CGFloat = 13) {
        super.init(frame: .zero)
        spacing = 6
        for key in keys {
            let label = NSTextField(labelWithString: key)
            label.font = .systemFont(ofSize: size, weight: .semibold)
            label.alignment = .center
            let cap = NSView()
            cap.wantsLayer = true
            cap.layer?.cornerRadius = 6
            cap.layer?.borderWidth = 1.2
            cap.layer?.borderColor = NSColor.tertiaryLabelColor.cgColor
            label.translatesAutoresizingMaskIntoConstraints = false
            cap.addSubview(label)
            NSLayoutConstraint.activate([
                cap.heightAnchor.constraint(equalToConstant: size + 14),
                cap.widthAnchor.constraint(greaterThanOrEqualToConstant: size + 14),
                label.centerYAnchor.constraint(equalTo: cap.centerYAnchor),
                label.leadingAnchor.constraint(equalTo: cap.leadingAnchor, constant: 7),
                label.trailingAnchor.constraint(equalTo: cap.trailingAnchor, constant: -7)
            ])
            addArrangedSubview(cap)
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}
