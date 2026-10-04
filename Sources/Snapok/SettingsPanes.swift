import AppKit
import Carbon
import ApplicationServices

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
    func addCard(_ content: NSView, scrollable: Bool = false) {
        let card = CardView()
        content.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(content)
        card.translatesAutoresizingMaskIntoConstraints = false
        let host: NSView
        if scrollable {
            let scroll = NSScrollView()
            scroll.drawsBackground = false
            scroll.hasVerticalScroller = true
            scroll.translatesAutoresizingMaskIntoConstraints = false
            let document = SettingsDocumentView()
            document.translatesAutoresizingMaskIntoConstraints = false
            scroll.documentView = document
            addSubview(scroll)
            NSLayoutConstraint.activate([
                scroll.topAnchor.constraint(equalTo: subtitleLabel.bottomAnchor, constant: 28),
                scroll.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 40),
                scroll.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -24),
                scroll.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -20),
                document.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor)
            ])
            host = document
        } else {
            host = self
        }
        host.addSubview(card)
        NSLayoutConstraint.activate([
            card.topAnchor.constraint(equalTo: scrollable ? host.topAnchor : subtitleLabel.bottomAnchor, constant: scrollable ? 0 : 28),
            card.leadingAnchor.constraint(equalTo: host.leadingAnchor, constant: scrollable ? 0 : 40),
            card.trailingAnchor.constraint(lessThanOrEqualTo: host.trailingAnchor, constant: scrollable ? -16 : -40),
            card.widthAnchor.constraint(greaterThanOrEqualToConstant: 480),
            content.topAnchor.constraint(equalTo: card.topAnchor, constant: 24),
            content.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 28),
            content.trailingAnchor.constraint(lessThanOrEqualTo: card.trailingAnchor, constant: -28),
            content.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -24)
        ])
        if scrollable { card.bottomAnchor.constraint(equalTo: host.bottomAnchor, constant: -12).isActive = true }
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

@MainActor
private final class SettingsDocumentView: NSView {
    override var isFlipped: Bool { true }
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
    private let reuseEditorStyle = NSButton(checkboxWithTitle: L("Use the last image editing style for new screenshots", "新截图沿用上次编辑图片的样式"), target: nil, action: nil)
    private let retention = NSPopUpButton()
    private let language = NSPopUpButton()
    private let theme = NSPopUpButton()
    private let captureColor = NSColorWell()
    private let captureBorder = NSPopUpButton()
    private let captureWidth = PixelNumberControl(value: 2, range: CaptureAppearance.borderWidthRange, label: L("Screenshot selection thickness", "截图选框粗细"))
    private let capturePreview = CaptureAppearancePreview()
    private let libraryLocation = NSTextField(labelWithString: "")
    private let restoreLibraryLocation = NSButton(title: L("Restore Default", "恢复默认"), target: nil, action: nil)
    private let operationFeedback = WindowFeedback()
    private let screenCaptureStatus = NSTextField(labelWithString: "")
    private let enableScreenCapture = NSButton(title: L("Authorize…", "授权…"), target: nil, action: nil)
    private let screenCaptureSettings = NSButton(title: L("System Settings…", "系统设置…"), target: nil, action: nil)
    private let snappingStatus = NSTextField(labelWithString: "")
    private let enableSnapping = NSButton(title: L("Enable…", "开启…"), target: nil, action: nil)
    private let retentionOptions: [(title: String, days: Int)] = [(L("7 days", "7 天"), 7), (L("30 days", "30 天"), 30), (L("90 days", "90 天"), 90), (L("Forever", "永久"), 0)]

    init() {
        super.init(title: L("General", "通用设置"), subtitle: L("Appearance, language, shortcuts, and screenshot storage preferences.", "外观、语言、快捷键与截图库保存方式。"))
        theme.addItems(withTitles: AppAppearance.allCases.map(\.title))
        theme.target = self
        theme.action = #selector(saveTheme)
        theme.setAccessibilityLabel(L("Theme", "主题"))
        captureColor.useCompactSwatch()
        captureColor.supportsAlpha = false
        captureColor.target = self
        captureColor.action = #selector(saveCaptureAppearance)
        captureColor.setAccessibilityLabel(L("Screenshot selection color", "截图选框颜色"))
        captureBorder.addItems(withTitles: CaptureBorderStyle.allCases.map(\.title))
        captureBorder.target = self
        captureBorder.action = #selector(saveCaptureAppearance)
        captureBorder.setAccessibilityLabel(L("Screenshot selection style", "截图选框线条样式"))
        captureWidth.onChange = { [weak self] _ in self?.saveCaptureAppearance() }
        captureWidth.setAccessibilityLabel(L("Screenshot selection thickness", "截图选框粗细"))
        captureWidth.toolTip = L("Border thickness", "边框粗细")
        capturePreview.setAccessibilityLabel(L("Screenshot selection preview", "截图选框预览"))
        let captureReset = NSButton(title: L("Restore Default", "恢复默认"), target: self, action: #selector(resetCaptureAppearance))
        captureReset.bezelStyle = .rounded
        let captureAppearanceRow = NSStackView(views: [captureColor, captureBorder, captureWidth, capturePreview, captureReset])
        captureAppearanceRow.spacing = 10
        language.addItems(withTitles: ["English", "简体中文"])
        language.selectItem(at: AppLanguage.allCases.firstIndex(of: AppLanguage.saved()) ?? 0)
        language.target = self
        language.action = #selector(saveLanguage)
        autoSave.target = self
        autoSave.action = #selector(save)
        reuseEditorStyle.target = self
        reuseEditorStyle.action = #selector(save)
        let reuseStyleHint = NSTextField(wrappingLabelWithString: L("Apply background, padding, border, corners, and shadow when copying, saving, or pinning. Annotations are not reused.", "复制、保存或钉图时自动应用背景、留白、描边、圆角和阴影，不沿用标注。"))
        reuseStyleHint.font = .systemFont(ofSize: 12)
        reuseStyleHint.textColor = .secondaryLabelColor
        reuseStyleHint.preferredMaxLayoutWidth = 500
        retention.addItems(withTitles: retentionOptions.map(\.title))
        retention.target = self
        retention.action = #selector(save)
        let openFolder = NSButton(title: L("Open in Finder", "在 Finder 中打开"), target: self, action: #selector(openHistoryFolder))
        openFolder.bezelStyle = .rounded
        let clear = NSButton(title: L("Clear Library…", "清空截图库…"), target: self, action: #selector(clearHistory))
        clear.bezelStyle = .rounded
        let changeFolder = NSButton(title: L("Change Folder…", "更改文件夹…"), target: self, action: #selector(changeHistoryFolder))
        changeFolder.bezelStyle = .rounded
        restoreLibraryLocation.bezelStyle = .rounded
        restoreLibraryLocation.target = self
        restoreLibraryLocation.action = #selector(resetHistoryFolder)
        restoreLibraryLocation.setAccessibilityLabel(L("Restore default library location", "恢复默认截图库位置"))
        restoreLibraryLocation.toolTip = L("Use the default folder for new screenshots. Current screenshots stay in their existing folder.", "新截图使用默认目录，当前截图仍保留在原目录。")
        libraryLocation.font = .systemFont(ofSize: 12)
        libraryLocation.textColor = .secondaryLabelColor
        libraryLocation.lineBreakMode = .byTruncatingMiddle
        libraryLocation.isSelectable = true
        libraryLocation.widthAnchor.constraint(equalToConstant: 360).isActive = true
        enableScreenCapture.bezelStyle = .rounded
        enableScreenCapture.target = self
        enableScreenCapture.action = #selector(requestScreenCapture)
        screenCaptureSettings.bezelStyle = .rounded
        screenCaptureSettings.target = self
        screenCaptureSettings.action = #selector(openScreenCaptureSettings)
        let screenCaptureRow = NSStackView(views: [screenCaptureStatus, enableScreenCapture, screenCaptureSettings])
        screenCaptureRow.spacing = 10
        let screenCaptureHint = NSTextField(wrappingLabelWithString: L(
            "Requires macOS Screen Recording access. If denied, enable this app in System Settings and restart it.",
            "需要 macOS 屏幕录制权限；已拒绝时请到系统设置开启当前应用，然后重启。"))
        screenCaptureHint.font = .systemFont(ofSize: 12)
        screenCaptureHint.textColor = .secondaryLabelColor
        screenCaptureHint.preferredMaxLayoutWidth = 360
        screenCaptureHint.widthAnchor.constraint(lessThanOrEqualToConstant: 360).isActive = true
        NotificationCenter.default.addObserver(self, selector: #selector(refreshScreenCaptureStatus),
                                               name: NSApplication.didBecomeActiveNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(refreshScreenCaptureStatus),
                                               name: ScreenRecordingPermission.didChange, object: nil)
        enableSnapping.bezelStyle = .rounded
        enableSnapping.target = self
        enableSnapping.action = #selector(requestComponentSnapping)
        let snappingRow = NSStackView(views: [snappingStatus, enableSnapping])
        snappingRow.spacing = 10
        NotificationCenter.default.addObserver(self, selector: #selector(refreshSnappingStatus),
                                               name: NSApplication.didBecomeActiveNotification, object: nil)
        addCard(Self.form([
            [Self.label(L("Language", "语言")), language],
            [Self.label(L("Theme", "主题")), theme],
            [Self.label(L("Screenshot selection", "截图选框")), captureAppearanceRow],
            [Self.label(L("Screenshot shortcut", "截图快捷键")), ShortcutRecorder()],
            [Self.label(L("Screenshot access", "截图权限")), screenCaptureRow],
            [NSGridCell.emptyContentView, screenCaptureHint],
            [Self.label(L("Component snapping", "组件自动吸附")), snappingRow],
            [NSGridCell.emptyContentView, Self.label(L("Accessibility access locates Dock icons and controls.", "需要辅助功能权限，用于定位 Dock 图标及控件。"), secondary: true)],
            [NSGridCell.emptyContentView, autoSave],
            [NSGridCell.emptyContentView, reuseEditorStyle],
            [NSGridCell.emptyContentView, reuseStyleHint],
            [Self.label(L("Keep screenshots", "保留时间")), retention],
            [NSGridCell.emptyContentView, Self.label(L("Screenshots older than this period are deleted automatically.", "超过保留时间的截图会自动删除。"), secondary: true)],
            [Self.label(L("Library", "截图库")), NSStackView(views: [openFolder, clear])],
            [Self.label(L("Storage location", "存储位置")), NSStackView(views: [changeFolder, restoreLibraryLocation])],
            [NSGridCell.emptyContentView, libraryLocation],
            [NSGridCell.emptyContentView, Self.label(L("New screenshots use this folder. Copying existing screenshots is optional.", "新截图保存到此文件夹，旧截图可选择是否复制。"), secondary: true)]
        ]), scrollable: true)
        load()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func load() {
        refreshScreenCaptureStatus()
        refreshSnappingStatus()
        theme.selectItem(at: AppAppearance.allCases.firstIndex(of: AppAppearance.saved()) ?? 0)
        loadCaptureAppearance()
        autoSave.state = AppSettings.autoSave ? .on : .off
        reuseEditorStyle.state = AppSettings.reuseEditorStyle ? .on : .off
        retention.selectItem(at: retentionOptions.firstIndex { $0.days == AppSettings.retentionDays } ?? 1)
        refreshLibraryLocation()
    }

    @objc private func refreshScreenCaptureStatus() {
        let enabled = CGPreflightScreenCaptureAccess()
        screenCaptureStatus.stringValue = enabled ? L("Allowed", "已允许") : L("Not allowed", "未允许")
        screenCaptureStatus.textColor = enabled ? .systemGreen : .secondaryLabelColor
        enableScreenCapture.isHidden = enabled
    }

    @objc private func requestScreenCapture() {
        enableScreenCapture.isEnabled = false
        Task { [weak self] in
            _ = await ScreenRecordingPermission.request()
            self?.enableScreenCapture.isEnabled = true
            self?.refreshScreenCaptureStatus()
        }
    }

    @objc private func openScreenCaptureSettings() {
        ScreenRecordingPermission.openSettings()
    }

    @objc private func refreshSnappingStatus() {
        let enabled = AXIsProcessTrusted()
        snappingStatus.stringValue = enabled
            ? L("Enabled", "已开启")
            : L("Accessibility permission needed", "未开启辅助功能权限")
        snappingStatus.textColor = enabled ? .systemGreen : .secondaryLabelColor
        enableSnapping.isHidden = enabled
    }

    @objc private func requestComponentSnapping() {
        ComponentSnappingPermission.request()
        refreshSnappingStatus()
    }

    @objc private func saveTheme() {
        guard AppAppearance.allCases.indices.contains(theme.indexOfSelectedItem) else { return }
        AppAppearance.allCases[theme.indexOfSelectedItem].select()
    }

    private func loadCaptureAppearance() {
        let appearance = CaptureAppearance.load()
        captureColor.color = appearance.nsColor
        captureBorder.selectItem(at: CaptureBorderStyle.allCases.firstIndex(of: appearance.borderStyle) ?? 0)
        captureWidth.setValue(appearance.borderWidth)
        capturePreview.appearanceSettings = appearance
    }

    @objc private func saveCaptureAppearance() {
        guard CaptureBorderStyle.allCases.indices.contains(captureBorder.indexOfSelectedItem) else { return }
        var appearance = CaptureAppearance.load()
        appearance.setColor(captureColor.color)
        appearance.borderStyle = CaptureBorderStyle.allCases[captureBorder.indexOfSelectedItem]
        appearance.borderWidth = captureWidth.value
        appearance.save()
        capturePreview.appearanceSettings = appearance
    }

    @objc private func resetCaptureAppearance() {
        CaptureAppearance().save()
        loadCaptureAppearance()
    }

    @objc private func saveLanguage() {
        guard AppLanguage.allCases.indices.contains(language.indexOfSelectedItem) else { return }
        AppLanguage.switchTo(AppLanguage.allCases[language.indexOfSelectedItem])
    }

    @objc private func save() {
        AppSettings.autoSave = autoSave.state == .on
        AppSettings.reuseEditorStyle = reuseEditorStyle.state == .on
        AppSettings.retentionDays = retentionOptions[retention.indexOfSelectedItem].days
        HistoryStore.shared.purgeExpired()
        NotificationCenter.default.post(name: HistoryStore.didChange, object: nil)
    }

    @objc private func openHistoryFolder() {
        NSWorkspace.shared.open(HistoryStore.shared.root)
    }

    private func refreshLibraryLocation() {
        libraryLocation.stringValue = HistoryStore.shared.root.path
        libraryLocation.toolTip = libraryLocation.stringValue
        restoreLibraryLocation.isEnabled = HistoryStore.shared.root.resolvingSymlinksInPath().standardizedFileURL != HistoryStore.defaultRoot.resolvingSymlinksInPath().standardizedFileURL
    }

    @objc private func resetHistoryFolder() {
        do {
            try HistoryStore.shared.restoreDefaultLocation()
            refreshLibraryLocation()
            operationFeedback.show(L("Default library location restored.", "已恢复默认截图库位置。"), in: window)
        } catch {
            operationFeedback.showError(L("Could not restore the library folder: ", "无法恢复截图库位置：") + error.localizedDescription, in: window)
        }
    }

    @objc private func changeHistoryFolder() {
        guard let window else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = FileManager.default.homeDirectoryForCurrentUser
        panel.prompt = L("Use This Folder", "使用此文件夹")
        panel.message = L("New screenshots will be saved here. The library displays the selected folder; previous screenshots remain in their original folder unless you copy them.", "新截图将保存到这里，截图库显示所选文件夹的内容。不复制时，旧截图仍保留在原目录。")
        let copyExisting = NSButton(checkboxWithTitle: L("Also copy existing screenshots", "同时复制现有截图"), target: nil, action: nil)
        copyExisting.state = .off
        copyExisting.sizeToFit()
        panel.accessoryView = copyExisting
        panel.isAccessoryViewDisclosed = true
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let destination = panel.url else { return }
            do {
                try HistoryStore.shared.changeLocation(to: destination, copyExisting: copyExisting.state == .on)
                self?.refreshLibraryLocation()
            } catch {
                let alert = NSAlert()
                alert.messageText = L("Could not change the library folder", "无法更改截图库位置")
                alert.informativeText = error.localizedDescription
                alert.beginSheetModal(for: window)
            }
        }
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
            // 560 pt of cards plus insets, narrower when the window is.
            stack.widthAnchor.constraint(lessThanOrEqualTo: document.widthAnchor)
        ])
        let preferred = stack.widthAnchor.constraint(equalToConstant: 640)
        preferred.priority = .defaultHigh
        preferred.isActive = true
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
