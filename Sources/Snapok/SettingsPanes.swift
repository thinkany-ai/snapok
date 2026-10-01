import AppKit
import Carbon

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
            [Self.label(L("Screenshot shortcut", "截图快捷键")), ShortcutRecorder()],
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
        AppLanguage.switchTo(AppLanguage.allCases[language.indexOfSelectedItem])
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

/// Keyboard keys drawn as small outlined caps, as in "⌃ ⌘ A".
@MainActor
final class KeycapRow: NSStackView {
    private let size: CGFloat

    /// Shows the capture shortcut and follows changes made in settings.
    static func captureShortcut(size: CGFloat = 13) -> KeycapRow {
        let row = KeycapRow(keys: HotKeyCenter.shared.current.keys, size: size)
        NotificationCenter.default.addObserver(forName: HotKeyCenter.didChange, object: nil, queue: .main) { [weak row] _ in
            MainActor.assumeIsolated { row?.setKeys(HotKeyCenter.shared.current.keys) }
        }
        return row
    }

    init(keys: [String], size: CGFloat = 13) {
        self.size = size
        super.init(frame: .zero)
        spacing = 6
        setKeys(keys)
    }

    func setKeys(_ keys: [String]) {
        arrangedSubviews.forEach { $0.removeFromSuperview() }
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

/// Click "Change…", then press a new shortcut; Esc cancels. The current shortcut is paused while recording.
@MainActor
final class ShortcutRecorder: NSStackView {
    private let keys = KeycapRow.captureShortcut()
    private let prompt = NSTextField(labelWithString: L("Press a new shortcut…", "请按下新的快捷键…"))
    private let change = NSButton(title: L("Change…", "修改…"), target: nil, action: nil)
    private let reset = NSButton(title: L("Restore Default", "恢复默认"), target: nil, action: nil)
    private let status = NSTextField(wrappingLabelWithString: "")
    private var monitor: Any?
    private var resignObserver: NSObjectProtocol?

    init() {
        super.init(frame: .zero)
        orientation = .vertical
        alignment = .leading
        spacing = 6
        prompt.font = .systemFont(ofSize: 13)
        prompt.textColor = .controlAccentColor
        prompt.isHidden = true
        for button in [change, reset] {
            button.bezelStyle = .rounded
            button.target = self
        }
        change.action = #selector(toggleRecording)
        reset.action = #selector(restoreDefault)
        status.font = .systemFont(ofSize: 12)
        status.preferredMaxLayoutWidth = 340
        status.isHidden = true
        let row = NSStackView(views: [keys, prompt, change, reset])
        row.spacing = 10
        addArrangedSubview(row)
        addArrangedSubview(status)
        updateReset()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow == nil { stopRecording() }
        super.viewWillMove(toWindow: newWindow)
    }

    @objc private func toggleRecording() {
        monitor == nil ? startRecording() : stopRecording()
    }

    private func startRecording() {
        HotKeyCenter.shared.suspend()
        keys.isHidden = true
        prompt.isHidden = false
        change.title = L("Cancel", "取消")
        showStatus(L("Include ⌃, ⌥, or ⌘ (function keys work alone). Press Esc to cancel.", "需包含 ⌃、⌥ 或 ⌘（F 功能键可单独使用），按 Esc 取消。"), error: false)
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            self?.record(event)
            return nil
        }
        resignObserver = NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification, object: window, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.stopRecording() }
        }
    }

    private func stopRecording() {
        guard let monitor else { return }
        NSEvent.removeMonitor(monitor)
        self.monitor = nil
        if let resignObserver { NotificationCenter.default.removeObserver(resignObserver) }
        resignObserver = nil
        HotKeyCenter.shared.resume()
        keys.isHidden = false
        prompt.isHidden = true
        change.title = L("Change…", "修改…")
        if status.textColor != .systemRed { status.isHidden = true }
        updateReset()
    }

    private func record(_ event: NSEvent) {
        let plain = event.modifierFlags.intersection([.control, .option, .shift, .command]).isEmpty
        if plain, event.keyCode == UInt16(kVK_Escape) {
            status.isHidden = true
            stopRecording()
            return
        }
        guard let hotKey = HotKey(event: event) else { return }
        guard hotKey.isValidGlobalShortcut else {
            showStatus(L("\(hotKey.symbol) needs ⌃, ⌥, or ⌘.", "\(hotKey.symbol) 需要包含 ⌃、⌥ 或 ⌘。"), error: true)
            return
        }
        apply(hotKey)
    }

    @objc private func restoreDefault() {
        stopRecording()
        apply(AppChannel.defaultHotKey)
    }

    private func apply(_ hotKey: HotKey) {
        if HotKeyCenter.shared.change(to: hotKey) {
            status.isHidden = true
            status.textColor = .secondaryLabelColor
        } else {
            showStatus(L("\(hotKey.symbol) is used by macOS or another app. Try a different shortcut.", "\(hotKey.symbol) 已被系统或其他应用占用，请换一个。"), error: true)
        }
        stopRecording()
    }

    private func showStatus(_ text: String, error: Bool) {
        status.stringValue = text
        status.textColor = error ? .systemRed : .secondaryLabelColor
        status.isHidden = false
    }

    private func updateReset() {
        reset.isHidden = HotKeyCenter.shared.current == AppChannel.defaultHotKey
    }
}

/// A page of titled sections, each a card, that scrolls when the window is shorter than the content.
@MainActor
class SectionedPageView: PageView {
    private let stack = NSStackView()

    init(title: String) {
        super.init(title: title, subtitle: "")
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.edgeInsets = NSEdgeInsets(top: 0, left: 40, bottom: 40, right: 40)

        let document = FlippedView()
        stack.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(stack)
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.documentView = document
        scroll.translatesAutoresizingMaskIntoConstraints = false
        document.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scroll)
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 20),
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor),
            document.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
            stack.topAnchor.constraint(equalTo: document.topAnchor),
            stack.leadingAnchor.constraint(equalTo: document.leadingAnchor),
            stack.bottomAnchor.constraint(equalTo: document.bottomAnchor),
            stack.widthAnchor.constraint(equalToConstant: 640)
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// Adds a full-width view, such as a card or a footnote.
    func add(_ view: NSView, spacingBefore: CGFloat? = nil) {
        if let spacingBefore, let previous = stack.arrangedSubviews.last { stack.setCustomSpacing(spacingBefore, after: previous) }
        stack.addArrangedSubview(view)
        view.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -80).isActive = true
    }

    /// A bold heading, with an optional control on the right, followed by a card of rows split by separators.
    @discardableResult
    func addSection(_ title: String, accessory: NSView? = nil, rows: [NSView]) -> NSStackView {
        let heading = NSTextField(labelWithString: title)
        heading.font = .systemFont(ofSize: 14, weight: .semibold)
        let headingRow = NSStackView(views: [heading, NSView()] + (accessory.map { [$0] } ?? []))
        headingRow.alignment = .centerY
        add(headingRow, spacingBefore: stack.arrangedSubviews.isEmpty ? nil : 28)
        stack.setCustomSpacing(10, after: headingRow)
        let list = NSStackView()
        list.orientation = .vertical
        list.spacing = 0
        Self.fill(list, with: rows)
        add(Self.card(list, inset: NSEdgeInsets(top: 4, left: 0, bottom: 4, right: 0)))
        return list
    }

    /// Replaces the rows of a section list.
    static func fill(_ list: NSStackView, with rows: [NSView]) {
        list.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for (index, row) in rows.enumerated() {
            if index > 0 {
                let separator = NSBox()
                separator.boxType = .separator
                list.addArrangedSubview(separator)
                separator.widthAnchor.constraint(equalTo: list.widthAnchor, constant: -36).isActive = true
            }
            list.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: list.widthAnchor).isActive = true
        }
    }

    static func card(_ content: NSView, inset: NSEdgeInsets) -> CardView {
        let card = CardView()
        content.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(content)
        NSLayoutConstraint.activate([
            content.topAnchor.constraint(equalTo: card.topAnchor, constant: inset.top),
            content.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: inset.left),
            content.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -inset.right),
            content.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -inset.bottom)
        ])
        return card
    }

    static func footnote(_ text: String) -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: text)
        label.font = .systemFont(ofSize: 12)
        label.textColor = .secondaryLabelColor
        return label
    }
}

/// A rounded, colored square with a white SF Symbol, as in System Settings.
@MainActor
final class IconTile: NSView {
    init(symbol: String, tint: NSColor, size: CGFloat = 30) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = size * 0.27
        layer?.backgroundColor = tint.cgColor
        let glyph = NSImageView(image: NSImage(systemSymbolName: symbol, accessibilityDescription: nil) ?? NSImage())
        glyph.symbolConfiguration = .init(pointSize: size / 2, weight: .semibold)
        glyph.contentTintColor = .white
        glyph.translatesAutoresizingMaskIntoConstraints = false
        addSubview(glyph)
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: size),
            heightAnchor.constraint(equalToConstant: size),
            glyph.centerXAnchor.constraint(equalTo: centerXAnchor),
            glyph.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}

final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}
