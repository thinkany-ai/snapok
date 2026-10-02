import AppKit
import Carbon

/// The main window: a sidebar with the library and a Settings entry, the library itself, and Settings as a panel on top.
@MainActor
final class MainWindowController: NSWindowController, NSWindowDelegate {
    var onCapture: (() -> Void)? {
        didSet { library.onCapture = onCapture }
    }
    var onOpen: ((HistoryItem) -> Void)? {
        didSet { library.onOpen = onOpen }
    }
    var onPin: ((NSImage) -> Void)? {
        didSet { library.onPin = onPin }
    }

    private var library = LibraryPane()
    private let content = ContentBackground()
    private var settings: SettingsOverlay?

    init() {
        let window = NSWindow(
            contentRect: CGRect(x: 0, y: 0, width: 1120, height: 740),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = AppChannel.displayName
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.minSize = CGSize(width: 820, height: 520)
        window.isReleasedWhenClosed = false
        // Preserve the saved window position from earlier versions.
        window.setFrameAutosaveName("SnapokMain")
        super.init(window: window)
        window.delegate = self
        build()
        if !window.setFrameUsingName("SnapokMain") { window.center() }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// Rebuilds every view in the current language, keeping the window frame and any open Settings page.
    func relocalize() {
        let openPage = settings?.page
        settings = nil
        // Swap old and new views in one frame, so the window never shows a half-built state.
        window?.disableScreenUpdatesUntilFlush()
        window?.contentView?.subviews.forEach { $0.removeFromSuperview() }
        library = LibraryPane()
        library.onCapture = onCapture
        library.onOpen = onOpen
        library.onPin = onPin
        build()
        if let openPage { showSettings(openPage, animated: false) }
    }

    /// Shows the library, closing Settings if it is open.
    func present() {
        closeSettings()
        bringToFront()
    }

    func presentSettings(_ page: SettingsPage) {
        bringToFront()
        showSettings(page)
    }

    private func bringToFront() {
        HistoryStore.shared.purgeExpired()
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func showSettings(_ page: SettingsPage, animated: Bool = true) {
        if let settings {
            settings.show(page)
            return
        }
        guard let root = window?.contentView else { return }
        let overlay = SettingsOverlay(page: page)
        overlay.onClose = { [weak self] in self?.closeSettings() }
        overlay.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(overlay)
        NSLayoutConstraint.activate([
            overlay.topAnchor.constraint(equalTo: root.topAnchor),
            overlay.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            overlay.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            overlay.trailingAnchor.constraint(equalTo: root.trailingAnchor)
        ])
        settings = overlay
        guard animated else { return }
        overlay.alphaValue = 0
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.15
            overlay.animator().alphaValue = 1
        }
    }

    private func closeSettings() {
        guard let overlay = settings else { return }
        settings = nil
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.12
            overlay.animator().alphaValue = 0
        }, completionHandler: {
            MainActor.assumeIsolated { overlay.removeFromSuperview() }
        })
        window?.makeFirstResponder(library.collection)
    }

    private func build() {
        guard let root = window?.contentView else { return }

        let sidebar = SidebarBackground()

        let icon = NSImageView(image: Brand.appIcon ?? NSImage())
        icon.imageScaling = .scaleProportionallyUpOrDown
        icon.widthAnchor.constraint(equalToConstant: 30).isActive = true
        icon.heightAnchor.constraint(equalToConstant: 30).isActive = true
        let name = NSTextField(labelWithString: "Snapok")
        name.font = .systemFont(ofSize: 20, weight: .bold)
        let brand = NSStackView(views: [icon, name])
        brand.spacing = 8
        if !AppChannel.isRelease {
            brand.addArrangedSubview(ChannelBadge(text: "Dev"))
        }

        let libraryItem = SidebarItem(title: L("Library", "截图库"), symbol: "photo.on.rectangle") { [weak self] in self?.present() }
        libraryItem.isSelected = true
        let nav = NSStackView(views: [libraryItem])
        nav.orientation = .vertical
        nav.alignment = .leading
        nav.spacing = 4
        libraryItem.widthAnchor.constraint(equalTo: nav.widthAnchor).isActive = true

        let shortcut = makeShortcutCard()
        let version = NSTextField(labelWithString: L("Version ", "版本 ") + ((Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "dev"))
        version.font = .systemFont(ofSize: 11)
        version.textColor = .tertiaryLabelColor
        let settingsButton = NSButton(title: L("Settings", "设置"), image: NSImage(systemSymbolName: "gearshape", accessibilityDescription: nil)!, target: self, action: #selector(openSettings))
        settingsButton.isBordered = false
        settingsButton.imagePosition = .imageLeading
        settingsButton.font = .systemFont(ofSize: 11)
        settingsButton.imageScaling = .scaleNone
        settingsButton.symbolConfiguration = .init(pointSize: 12, weight: .regular)
        settingsButton.setContentCompressionResistancePriority(.required, for: .horizontal)
        settingsButton.contentTintColor = .secondaryLabelColor
        settingsButton.toolTip = L("Settings", "设置")
        settingsButton.setAccessibilityLabel(L("Settings", "设置"))

        [sidebar, content].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview($0)
        }
        library.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(library)
        [brand, nav, shortcut, version, settingsButton].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            sidebar.addSubview($0)
        }
        NSLayoutConstraint.activate([
            sidebar.topAnchor.constraint(equalTo: root.topAnchor),
            sidebar.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            sidebar.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            sidebar.widthAnchor.constraint(equalToConstant: 236),
            content.topAnchor.constraint(equalTo: root.topAnchor),
            content.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            content.leadingAnchor.constraint(equalTo: sidebar.trailingAnchor),
            content.trailingAnchor.constraint(equalTo: root.trailingAnchor),

            brand.topAnchor.constraint(equalTo: sidebar.topAnchor, constant: 58),
            brand.leadingAnchor.constraint(equalTo: sidebar.leadingAnchor, constant: 22),
            nav.topAnchor.constraint(equalTo: brand.bottomAnchor, constant: 28),
            nav.leadingAnchor.constraint(equalTo: sidebar.leadingAnchor, constant: 14),
            nav.trailingAnchor.constraint(equalTo: sidebar.trailingAnchor, constant: -14),
            shortcut.leadingAnchor.constraint(equalTo: sidebar.leadingAnchor, constant: 14),
            shortcut.trailingAnchor.constraint(equalTo: sidebar.trailingAnchor, constant: -14),
            shortcut.bottomAnchor.constraint(equalTo: version.topAnchor, constant: -14),
            version.leadingAnchor.constraint(equalTo: sidebar.leadingAnchor, constant: 22),
            version.bottomAnchor.constraint(equalTo: sidebar.bottomAnchor, constant: -16),
            version.trailingAnchor.constraint(lessThanOrEqualTo: settingsButton.leadingAnchor, constant: -8),
            settingsButton.trailingAnchor.constraint(equalTo: sidebar.trailingAnchor, constant: -18),
            settingsButton.centerYAnchor.constraint(equalTo: version.centerYAnchor),
            settingsButton.heightAnchor.constraint(equalToConstant: 24),
            library.topAnchor.constraint(equalTo: content.topAnchor),
            library.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            library.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            library.bottomAnchor.constraint(equalTo: content.bottomAnchor)
        ])
        window?.makeFirstResponder(library.collection)
    }

    @objc private func openSettings() {
        presentSettings(.general)
    }

    private func makeShortcutCard() -> NSView {
        let card = CardView()
        let title = NSTextField(labelWithString: L("Capture anytime", "随时截图"))
        title.font = .systemFont(ofSize: 14, weight: .semibold)
        let hint = NSTextField(wrappingLabelWithString: L("Use the shortcut in any app. Finished screenshots are saved here automatically.", "在任何应用里按快捷键，截图完成后会自动保存到这里。"))
        hint.font = .systemFont(ofSize: 12)
        hint.textColor = .secondaryLabelColor
        let keys = KeycapRow.captureShortcut(size: 12)
        let button = PillButton(title: L("Take Screenshot", "开始截图")) { [weak self] in self?.onCapture?() }
        let stack = NSStackView(views: [title, hint, keys, button])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.setCustomSpacing(14, after: keys)
        stack.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: card.topAnchor, constant: 16),
            stack.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -16),
            stack.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -16),
            hint.widthAnchor.constraint(equalTo: stack.widthAnchor),
            button.widthAnchor.constraint(equalTo: stack.widthAnchor)
        ])
        return card
    }
}

/// Opaque, theme-aware navigation surface, unaffected by the desktop wallpaper.
@MainActor
final class SidebarBackground: NSView {
    private let divider = CALayer()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.addSublayer(divider)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        let dark = effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        layer?.backgroundColor = (dark
            ? NSColor(srgbRed: 0.095, green: 0.095, blue: 0.105, alpha: 1)
            : NSColor(srgbRed: 0.94, green: 0.94, blue: 0.952, alpha: 1)).cgColor
        divider.backgroundColor = NSColor(white: dark ? 1 : 0, alpha: dark ? 0.07 : 0.06).cgColor
    }

    override func layout() {
        super.layout()
        let scale = window?.backingScaleFactor ?? 2
        let width = 1 / scale
        divider.frame = CGRect(x: bounds.maxX - width, y: bounds.minY, width: width, height: bounds.height)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
}

/// The content area's soft gray background, so white cards stand out.
@MainActor
final class ContentBackground: NSView {
    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        let dark = effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        layer?.backgroundColor = (dark ? NSColor(white: 0.12, alpha: 1) : NSColor(srgbRed: 0.965, green: 0.965, blue: 0.972, alpha: 1)).cgColor
    }
}

@MainActor
final class SidebarItem: NSView {
    private let onSelect: () -> Void
    var isSelected = false {
        didSet { needsDisplay = true; updateColors() }
    }
    private let icon = NSImageView()
    private let label = NSTextField(labelWithString: "")
    private var hovering = false

    init(title: String, symbol: String, onSelect: @escaping () -> Void) {
        self.onSelect = onSelect
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 9
        icon.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        icon.symbolConfiguration = .init(pointSize: 15, weight: .regular)
        label.stringValue = title
        label.font = .systemFont(ofSize: 14, weight: .medium)
        let row = NSStackView(views: [icon, label])
        row.spacing = 10
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 38),
            row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            row.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 20)
        ])
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
        setAccessibilityRole(.button)
        setAccessibilityLabel(title)
        updateColors()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        let dark = effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        effectiveAppearance.performAsCurrentDrawingAppearance {
            let color = isSelected
                ? Brand.accent.withAlphaComponent(dark ? 0.16 : 0.10)
                : NSColor.labelColor.withAlphaComponent(hovering ? 0.05 : 0)
            layer?.backgroundColor = color.cgColor
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
        updateColors()
    }

    private func updateColors() {
        icon.contentTintColor = isSelected ? Brand.accent : .secondaryLabelColor
        label.textColor = isSelected ? .labelColor : .secondaryLabelColor
    }

    override func mouseEntered(with event: NSEvent) { hovering = true; needsDisplay = true }
    override func mouseExited(with event: NSEvent) { hovering = false; needsDisplay = true }
    override func mouseDown(with event: NSEvent) { onSelect() }
    override func accessibilityPerformPress() -> Bool { onSelect(); return true }
}

/// A filled brand-color button; system bezels ignore custom colors on non-default buttons.
@MainActor
final class PillButton: NSView {
    private let action: () -> Void
    private let label = NSTextField(labelWithString: "")
    private var pressed = false

    init(title: String, action: @escaping () -> Void) {
        self.action = action
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 10
        label.stringValue = title
        label.font = .systemFont(ofSize: 14, weight: .semibold)
        label.textColor = .white
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 38),
            label.centerXAnchor.constraint(equalTo: centerXAnchor),
            label.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
        setAccessibilityRole(.button)
        setAccessibilityLabel(title)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        layer?.backgroundColor = (pressed ? Brand.accent.blended(withFraction: 0.15, of: .black) ?? Brand.accent : Brand.accent).cgColor
    }

    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }

    override func mouseDown(with event: NSEvent) { pressed = true; needsDisplay = true }

    override func mouseUp(with event: NSEvent) {
        pressed = false
        needsDisplay = true
        if bounds.contains(convert(event.locationInWindow, from: nil)) { action() }
    }

    override func accessibilityPerformPress() -> Bool { action(); return true }
}

/// The library page: screenshots grouped by day as cards, with search.
@MainActor
final class LibraryPane: PageView, NSCollectionViewDataSource, NSCollectionViewDelegate {
    var onCapture: (() -> Void)?
    var onOpen: ((HistoryItem) -> Void)?
    var onPin: ((NSImage) -> Void)?

    let collection = LibraryCollectionView()
    private let search = NSSearchField()
    private let empty = NSTextField(wrappingLabelWithString: "")
    private var sections: [(title: String, items: [HistoryItem])] = []

    init() {
        super.init(title: L("Library", "截图库"), subtitle: "")
        build()
        reload()
        for name in [HistoryStore.didChange, HotKeyCenter.didChange] {
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.reload() }
            }
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func build() {
        search.placeholderString = L("Search titles, tags, or text in screenshots", "搜索标题、标签或截图里的文字")
        search.target = self
        search.action = #selector(searchChanged)
        search.sendsSearchStringImmediately = true
        search.controlSize = .large

        let layout = NSCollectionViewFlowLayout()
        layout.itemSize = CGSize(width: 248, height: 214)
        layout.minimumInteritemSpacing = 20
        layout.minimumLineSpacing = 20
        layout.sectionInset = NSEdgeInsets(top: 6, left: 40, bottom: 24, right: 40)
        layout.headerReferenceSize = CGSize(width: 0, height: 36)
        collection.collectionViewLayout = layout
        collection.isSelectable = true
        collection.allowsMultipleSelection = true
        collection.backgroundColors = [.clear]
        collection.dataSource = self
        collection.delegate = self
        collection.register(HistoryCell.self, forItemWithIdentifier: HistoryCell.identifier)
        collection.register(SectionHeader.self, forSupplementaryViewOfKind: NSCollectionView.elementKindSectionHeader, withIdentifier: SectionHeader.identifier)
        collection.onOpen = { [weak self] indexPath in self?.open(at: indexPath) }
        collection.onDelete = { [weak self] in self?.deleteSelection() }
        collection.menuProvider = { [weak self] in self?.contextMenu() }

        let scroll = NSScrollView()
        scroll.documentView = collection
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.automaticallyAdjustsContentInsets = false

        empty.alignment = .center
        empty.font = .systemFont(ofSize: 14)
        empty.textColor = .secondaryLabelColor

        [search, scroll, empty].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            addSubview($0)
        }
        NSLayoutConstraint.activate([
            search.centerYAnchor.constraint(equalTo: titleLabel.centerYAnchor),
            search.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -40),
            search.widthAnchor.constraint(equalToConstant: 280),
            scroll.topAnchor.constraint(equalTo: subtitleLabel.bottomAnchor, constant: 18),
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor),
            empty.centerXAnchor.constraint(equalTo: scroll.centerXAnchor),
            empty.centerYAnchor.constraint(equalTo: scroll.centerYAnchor, constant: -30),
            empty.widthAnchor.constraint(lessThanOrEqualToConstant: 420)
        ])
    }

    // MARK: Data

    private func reload() {
        let store = HistoryStore.shared
        let query = search.stringValue
        let visible = store.items.filter { $0.matches(query) }

        let calendar = Calendar.current
        let sameYear = DateFormatter()
        sameYear.locale = Locale(identifier: "zh_CN")
        sameYear.locale = AppLanguage.current.locale
        sameYear.dateFormat = L("EEEE, MMM d", "M月d日 EEEE")
        let otherYear = DateFormatter()
        otherYear.locale = AppLanguage.current.locale
        otherYear.dateFormat = L("MMM d, yyyy", "yyyy年M月d日")
        var grouped: [(title: String, items: [HistoryItem])] = []
        for item in visible {
            let title: String
            if calendar.isDateInToday(item.createdAt) {
                title = L("Today", "今天")
            } else if calendar.isDateInYesterday(item.createdAt) {
                title = L("Yesterday", "昨天")
            } else if calendar.isDate(item.createdAt, equalTo: Date(), toGranularity: .year) {
                title = sameYear.string(from: item.createdAt)
            } else {
                title = otherYear.string(from: item.createdAt)
            }
            if grouped.last?.title == title {
                grouped[grouped.count - 1].items.append(item)
            } else {
                grouped.append((title, [item]))
            }
        }
        sections = grouped
        collection.reloadData()

        let retention = AppSettings.retentionDays > 0 ? L("Kept for \(AppSettings.retentionDays) days", "保留 \(AppSettings.retentionDays) 天") : L("Kept forever", "永久保留")
        subtitleLabel.stringValue = AppSettings.autoSave
            ? L("\(store.items.count) screenshots · \(retention) · Double-click to edit", "共 \(store.items.count) 张截图 · \(retention) · 双击打开编辑")
            : L("\(store.items.count) screenshots · Auto-save is off", "共 \(store.items.count) 张截图 · 自动保存已关闭")
        if store.items.isEmpty {
            empty.stringValue = AppSettings.autoSave
                ? L("No screenshots yet.\nPress \(HotKeyCenter.shared.current.symbol) to capture your first screenshot.", "还没有截图。\n按 \(HotKeyCenter.shared.current.symbol) 截一张，完成后会自动出现在这里。")
                : L("Auto-save is off. New screenshots will not appear here.\nYou can enable it in General settings.", "自动保存已关闭，新截图不会进入截图库。\n可以在通用设置里重新打开。")
        } else {
            empty.stringValue = visible.isEmpty ? L("No screenshots found for “\(query)”.", "没有找到「\(query)」相关的截图。") : ""
        }
        empty.isHidden = empty.stringValue.isEmpty
    }

    private func item(at indexPath: IndexPath) -> HistoryItem? {
        guard sections.indices.contains(indexPath.section),
              sections[indexPath.section].items.indices.contains(indexPath.item) else { return nil }
        return sections[indexPath.section].items[indexPath.item]
    }

    private var selectedItems: [HistoryItem] {
        collection.selectionIndexPaths.sorted().compactMap(item(at:))
    }

    func numberOfSections(in collectionView: NSCollectionView) -> Int { sections.count }

    func collectionView(_ collectionView: NSCollectionView, numberOfItemsInSection section: Int) -> Int {
        sections[section].items.count
    }

    func collectionView(_ collectionView: NSCollectionView, itemForRepresentedObjectAt indexPath: IndexPath) -> NSCollectionViewItem {
        let cell = collectionView.makeItem(withIdentifier: HistoryCell.identifier, for: indexPath)
        if let cell = cell as? HistoryCell, let item = item(at: indexPath) {
            cell.configure(with: item, thumbnail: HistoryStore.shared.thumbnail(for: item))
        }
        return cell
    }

    func collectionView(_ collectionView: NSCollectionView, viewForSupplementaryElementOfKind kind: NSCollectionView.SupplementaryElementKind, at indexPath: IndexPath) -> NSView {
        let header = collectionView.makeSupplementaryView(ofKind: kind, withIdentifier: SectionHeader.identifier, for: indexPath)
        (header as? SectionHeader)?.label.stringValue = L("\(sections[indexPath.section].title) · \(sections[indexPath.section].items.count)", "\(sections[indexPath.section].title) · \(sections[indexPath.section].items.count) 张")
        return header
    }

    // MARK: Actions

    @objc private func searchChanged() { reload() }

    private func open(at indexPath: IndexPath) {
        if let item = item(at: indexPath) { onOpen?(item) }
    }

    private func contextMenu() -> NSMenu? {
        let items = selectedItems
        guard !items.isEmpty else { return nil }
        let menu = NSMenu()
        if items.count == 1 {
            menu.addItem(withTitle: L("Edit", "编辑"), action: #selector(editSelected), keyEquivalent: "")
            menu.addItem(withTitle: L("Copy Image", "复制图片"), action: #selector(copySelected), keyEquivalent: "")
            menu.addItem(withTitle: L("Pin to Screen", "钉在屏幕上"), action: #selector(pinSelected), keyEquivalent: "")
            menu.addItem(withTitle: L("Copy Recognized Text", "复制识别出的文字"), action: #selector(copyText), keyEquivalent: "")
            menu.addItem(withTitle: L("Rename…", "重命名…"), action: #selector(renameSelected), keyEquivalent: "")
            menu.addItem(withTitle: L("Show in Finder", "在 Finder 中显示"), action: #selector(revealSelected), keyEquivalent: "")
            menu.addItem(.separator())
        }
        menu.addItem(withTitle: items.count == 1 ? L("Delete", "删除") : L("Delete \(items.count) Screenshots", "删除 \(items.count) 张截图"), action: #selector(deleteSelectedFromMenu), keyEquivalent: "")
        menu.items.forEach { $0.target = self }
        return menu
    }

    @objc private func editSelected() {
        if let item = selectedItems.first { onOpen?(item) }
    }

    @objc private func copySelected() {
        guard let item = selectedItems.first, let image = HistoryStore.shared.rendered(for: item) else { return }
        ImageExport.copy(image)
    }

    @objc private func pinSelected() {
        guard let item = selectedItems.first, let image = HistoryStore.shared.rendered(for: item) else { return }
        onPin?(image)
    }

    @objc private func copyText() {
        guard let item = selectedItems.first else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(item.ocrText, forType: .string)
    }

    @objc private func renameSelected() {
        guard let item = selectedItems.first, let window else { return }
        let alert = NSAlert()
        alert.messageText = L("Rename Screenshot", "重命名截图")
        let field = NSTextField(frame: CGRect(x: 0, y: 0, width: 300, height: 24))
        field.stringValue = item.title
        field.placeholderString = item.displayTitle
        alert.accessoryView = field
        alert.addButton(withTitle: L("OK", "确定"))
        alert.addButton(withTitle: L("Cancel", "取消"))
        alert.window.initialFirstResponder = field
        alert.beginSheetModal(for: window) { response in
            guard response == .alertFirstButtonReturn else { return }
            HistoryStore.shared.update(item.id) { $0.title = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines) }
        }
    }

    @objc private func revealSelected() {
        guard let item = selectedItems.first else { return }
        NSWorkspace.shared.activateFileViewerSelecting([HistoryStore.shared.fileURL(for: item)])
    }

    @objc private func deleteSelectedFromMenu() { deleteSelection() }

    private func deleteSelection() {
        let items = selectedItems
        guard !items.isEmpty, let window else { return }
        let alert = NSAlert()
        alert.messageText = items.count == 1 ? L("Delete this screenshot?", "删除这张截图？") : L("Delete \(items.count) screenshots?", "删除 \(items.count) 张截图？")
        alert.informativeText = L("This cannot be undone.", "删除后无法恢复。")
        alert.addButton(withTitle: L("Delete", "删除"))
        alert.addButton(withTitle: L("Cancel", "取消"))
        alert.buttons.first?.hasDestructiveAction = true
        alert.beginSheetModal(for: window) { response in
            guard response == .alertFirstButtonReturn else { return }
            HistoryStore.shared.delete(items.map(\.id))
        }
    }
}

/// Collection view that reports double-clicks, Delete, and context-menu requests to its owner.
@MainActor
final class LibraryCollectionView: NSCollectionView {
    var onOpen: ((IndexPath) -> Void)?
    var onDelete: (() -> Void)?
    var menuProvider: (() -> NSMenu?)?

    override func mouseDown(with event: NSEvent) {
        super.mouseDown(with: event)
        if event.clickCount == 2, let indexPath = indexPathForItem(at: convert(event.locationInWindow, from: nil)) {
            onOpen?(indexPath)
        }
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        if let indexPath = indexPathForItem(at: convert(event.locationInWindow, from: nil)), !selectionIndexPaths.contains(indexPath) {
            selectionIndexPaths = [indexPath]
        }
        return menuProvider?()
    }

    override func keyDown(with event: NSEvent) {
        switch Int(event.keyCode) {
        case kVK_Delete, kVK_ForwardDelete:
            onDelete?()
        case kVK_Return, kVK_ANSI_KeypadEnter:
            if let indexPath = selectionIndexPaths.sorted().first { onOpen?(indexPath) }
        default:
            super.keyDown(with: event)
        }
    }
}

@MainActor
final class HistoryCell: NSCollectionViewItem {
    static let identifier = NSUserInterfaceItemIdentifier("HistoryCell")

    private let card = CardView()
    private let preview = ThumbnailWell()
    private let titleLabel = NSTextField(labelWithString: "")
    private let detailLabel = NSTextField(labelWithString: "")

    override func loadView() {
        view = NSView()
        titleLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        titleLabel.lineBreakMode = .byTruncatingTail
        detailLabel.font = .systemFont(ofSize: 11)
        detailLabel.textColor = .secondaryLabelColor
        detailLabel.lineBreakMode = .byTruncatingTail

        card.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(card)
        [preview, titleLabel, detailLabel].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            card.addSubview($0)
        }
        NSLayoutConstraint.activate([
            card.topAnchor.constraint(equalTo: view.topAnchor),
            card.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            card.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            card.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            preview.topAnchor.constraint(equalTo: card.topAnchor, constant: 10),
            preview.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 10),
            preview.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -10),
            preview.heightAnchor.constraint(equalToConstant: 138),
            titleLabel.topAnchor.constraint(equalTo: preview.bottomAnchor, constant: 12),
            titleLabel.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 14),
            titleLabel.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -14),
            detailLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 4),
            detailLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            detailLabel.trailingAnchor.constraint(equalTo: titleLabel.trailingAnchor)
        ])
    }

    override var isSelected: Bool {
        didSet { card.isHighlighted = isSelected }
    }

    func configure(with item: HistoryItem, thumbnail: NSImage?) {
        preview.image = thumbnail
        titleLabel.stringValue = item.displayTitle
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        var detail = "\(formatter.string(from: item.createdAt)) · \(Int(item.pixelSize.width))×\(Int(item.pixelSize.height))"
        if !item.tags.isEmpty {
            detail += " · " + item.tags.map { "#" + $0 }.joined(separator: " ")
        }
        detailLabel.stringValue = detail
        detailLabel.toolTip = detail
        titleLabel.toolTip = item.displayTitle
    }
}

/// Light backdrop that letterboxes a screenshot thumbnail.
@MainActor
final class ThumbnailWell: NSView {
    var image: NSImage? {
        didSet { imageView.image = image }
    }
    private let imageView = NSImageView()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 9
        layer?.masksToBounds = true
        imageView.imageScaling = .scaleProportionallyDown
        imageView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(imageView)
        NSLayoutConstraint.activate([
            imageView.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            imageView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            imageView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            imageView.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8)
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        let dark = effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        layer?.backgroundColor = (dark ? NSColor(white: 0.22, alpha: 1) : NSColor(srgbRed: 0.95, green: 0.95, blue: 0.96, alpha: 1)).cgColor
    }
}

@MainActor
final class SectionHeader: NSView, NSCollectionViewElement {
    static let identifier = NSUserInterfaceItemIdentifier("SectionHeader")
    let label = NSTextField(labelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        label.font = .systemFont(ofSize: 15, weight: .bold)
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 42),
            label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8)
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}

/// Small pill next to the app name marking a development build.
@MainActor
final class ChannelBadge: NSView {
    init(text: String) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 6
        layer?.backgroundColor = Brand.accent.withAlphaComponent(0.14).cgColor
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 12, weight: .semibold)
        label.textColor = Brand.accent
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.topAnchor.constraint(equalTo: topAnchor, constant: 3),
            label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -3),
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8)
        ])
        setAccessibilityLabel(text)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}
