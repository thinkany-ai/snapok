import AppKit

/// First-run guide: permissions, the screenshot shortcut, a first capture, then the toolbar and Snapok Agent.
/// Shown once to new users; the progress survives the relaunch that screen recording access needs.
@MainActor
final class OnboardingWindowController: NSWindowController, NSWindowDelegate {
    static let shared = OnboardingWindowController()

    /// Starts a screenshot (the app's own capture flow).
    var onCapture: (() -> Void)?
    /// Opens Snapok Agent with an image attached.
    var onAskAgent: ((NSImage) -> Void)?

    private enum Step: Int, CaseIterable { case permissions, shortcut, capture, explore }
    private static let completedKey = "onboarding.completed"
    private static let stepKey = "onboarding.step"

    private var step: Step {
        get { Step(rawValue: UserDefaults.standard.integer(forKey: Self.stepKey)) ?? .permissions }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: Self.stepKey) }
    }
    private var lastCapture: NSImage?
    private var statusTimer: Timer?
    private let content = NSStackView()
    private let dots = NSStackView()

    static var isCompleted: Bool { UserDefaults.standard.bool(forKey: completedKey) }

    /// Shows the guide on first launch. People who already used Snapok (`isNewUser` false) never see it unasked.
    static func showIfNeeded(isNewUser: Bool) {
        guard !isCompleted else { return }
        guard isNewUser || UserDefaults.standard.object(forKey: stepKey) != nil else {
            UserDefaults.standard.set(true, forKey: completedKey)
            return
        }
        shared.present()
    }

    /// From the app menu: always available, starting over.
    func presentFromStart() {
        step = .permissions
        present()
    }

    private init() {
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 560, height: 520),
                              styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self

        let root = NSView()
        content.orientation = .vertical
        content.alignment = .leading
        content.spacing = 14
        dots.spacing = 8
        for view in [content, dots] {
            view.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(view)
        }
        NSLayoutConstraint.activate([
            content.topAnchor.constraint(equalTo: root.topAnchor, constant: 52),
            content.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 40),
            content.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -40),
            content.bottomAnchor.constraint(lessThanOrEqualTo: dots.topAnchor, constant: -16),
            dots.centerXAnchor.constraint(equalTo: root.centerXAnchor),
            dots.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -20)
        ])
        window.contentView = root

        NotificationCenter.default.addObserver(forName: ScreenshotController.didFinishCapture, object: nil, queue: .main) { [weak self] note in
            // Delivered on the main queue, where the image was posted.
            nonisolated(unsafe) let image = note.object as? NSImage
            MainActor.assumeIsolated { self?.captureFinished(image) }
        }
        NotificationCenter.default.addObserver(forName: HotKeyCenter.didChange, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { if self?.step == .capture { self?.render() } }
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func present() {
        render()
        window?.center()
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        // Permission changes happen in System Settings; check while the guide is open.
        statusTimer?.invalidate()
        statusTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { if self?.step == .permissions { self?.render() } }
        }
    }

    func windowWillClose(_ notification: Notification) {
        statusTimer?.invalidate()
        statusTimer = nil
    }

    // MARK: Steps

    private func render() {
        content.arrangedSubviews.forEach { $0.removeFromSuperview() }
        switch step {
        case .permissions: permissions()
        case .shortcut: shortcut()
        case .capture: capture()
        case .explore: explore()
        }
        dots.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for item in Step.allCases {
            let dot = NSView()
            dot.wantsLayer = true
            dot.layer?.cornerRadius = 3
            dot.layer?.backgroundColor = (item == step ? Brand.accent : NSColor.tertiaryLabelColor).cgColor
            dot.widthAnchor.constraint(equalToConstant: item == step ? 18 : 6).isActive = true
            dot.heightAnchor.constraint(equalToConstant: 6).isActive = true
            dots.addArrangedSubview(dot)
        }
        // Fit the window to the step, keeping its top edge where it was.
        guard let window else { return }
        content.layoutSubtreeIfNeeded()
        let height = 52 + content.fittingSize.height + 64
        var frame = window.frame
        let newHeight = window.frameRect(forContentRect: CGRect(x: 0, y: 0, width: 560, height: height)).height
        frame.origin.y += frame.height - newHeight
        frame.size.height = newHeight
        window.setFrame(frame, display: true, animate: window.isVisible)
    }

    private func permissions() {
        header(L("Welcome to \(AppChannel.displayName)", "欢迎使用 \(AppChannel.displayName)"),
               L("Two permissions first: one so Snapok can take screenshots, one so it can snap to buttons and icons.",
                 "先开启两个权限：一个用来截图，一个用来自动吸附按钮和图标。"))
        let screen = CGPreflightScreenCaptureAccess()
        let accessibility = AXIsProcessTrusted()
        let requested = ScreenRecordingPermission.wasRequested
        let screenRow = permissionRow(
            title: L("Screen Recording (required)", "屏幕录制（必需）"),
            detail: screen ? L("Enabled.", "已开启。")
                : requested ? L("Turned it on in System Settings? Reopen Snapok for it to take effect.", "已经在系统设置里打开了？需要重新打开 Snapok 才会生效。")
                            : L("Needed to capture the screen. Nothing leaves your Mac.", "截图必须的权限，截图只保存在本机。"),
            granted: screen,
            actions: screen ? [] : (requested
                ? [button(L("Reopen Snapok", "重新打开 Snapok"), #selector(relaunch), primary: true),
                   button(L("Open Settings", "打开设置"), #selector(openScreenSettings))]
                : [button(L("Enable", "开启"), #selector(requestScreen), primary: true)]))
        let accessibilityRow = permissionRow(
            title: L("Accessibility (recommended)", "辅助功能（推荐）"),
            detail: accessibility ? L("Enabled.", "已开启。")
                : L("Snaps the selection to Dock icons, buttons, and controls, and pastes styled screenshots for you.",
                    "截图时自动吸附 Dock 图标、按钮等控件；粘贴带样式截图时自动粘贴。"),
            granted: accessibility,
            actions: accessibility ? [] : [button(L("Enable", "开启"), #selector(requestAccessibility), primary: false)])
        content.addArrangedSubview(screenRow)
        content.addArrangedSubview(accessibilityRow)
        footer(next: screen ? L("Continue", "继续") : L("Skip for Now", "稍后再说"), primary: screen)
    }

    private func shortcut() {
        let skipped = HotKeyCenter.shared.skippedCaptureHotKeys
        let note = skipped.isEmpty ? ""
            : L(" \(skipped.map(\.symbol).joined(separator: ", ")) is taken by another app or macOS, so Snapok picked this one.",
                "\(skipped.map(\.symbol).joined(separator: "、")) 已被其他应用或系统占用，已自动换成这个。")
        header(L("Your screenshot shortcut", "设置截图快捷键"),
               L("Press it in any app to start a screenshot. Change it to whatever your fingers already know.",
                 "在任何应用里按下它就能截图。可以换成你习惯的组合。") + note)
        let recorder = ShortcutRecorder(action: .capture)
        content.addArrangedSubview(recorder)
        let more = secondary(L("Pin, paste with style, and the editing tools have shortcuts too, in Settings → Shortcuts.",
                               "钉图、粘贴带样式截图和编辑工具的快捷键，可以在「设置 → 快捷键」里修改。"))
        content.addArrangedSubview(more)
        // The shortcut only works while Snapok runs, so it starts at login unless turned off here or in Settings.
        let login = NSButton(checkboxWithTitle: L("Open Snapok at login, so the shortcut always works", "开机自动启动，让快捷键随时可用"),
                             target: self, action: #selector(toggleLaunchAtLogin(_:)))
        login.state = LaunchAtLogin.isEnabled || LaunchAtLogin.needsApproval ? .on : .off
        content.setCustomSpacing(18, after: more)
        content.addArrangedSubview(login)
        footer(next: L("Continue", "继续"), primary: true)
    }

    @objc private func toggleLaunchAtLogin(_ sender: NSButton) {
        _ = LaunchAtLogin.set(sender.state == .on)
        sender.state = LaunchAtLogin.isEnabled || LaunchAtLogin.needsApproval ? .on : .off
    }

    private func capture() {
        let keys = HotKeyCenter.shared.current.symbol
        header(L("Take your first screenshot", "截一张图试试"),
               L("Press \(keys) (or the button below), drag over anything, then press ✓ or Enter to copy it.",
                 "按 \(keys)（或点下面的按钮），框选任意区域，再按 ✓ 或回车复制。"))
        let tips = list([
            L("Move the pointer over a window or button to snap to it; click to select it.", "鼠标移到窗口或按钮上会自动吸附，点一下就选中。"),
            L("Before copying, try the toolbar: boxes, arrows, mosaic, erase, text, and step numbers.", "复制前可以试试工具栏：画框、箭头、马赛克、擦除、文字、步骤编号。"),
            L("Esc cancels at any time.", "随时按 Esc 取消。")
        ])
        content.addArrangedSubview(tips)
        let start = button(L("Start Screenshot", "开始截图"), #selector(startCapture), primary: true)
        content.addArrangedSubview(start)
        footer(next: L("Skip", "跳过"), primary: false)
    }

    private func explore() {
        header(lastCapture == nil ? L("More to try", "还可以试试这些") : L("Nice shot!", "截得不错！"),
               lastCapture == nil ? L("After a screenshot, Snapok can also:", "截完图之后，还可以：")
                   : L("It's copied and saved to the library. Snapok can do more with it:", "截图已复制，并保存到截图库。接下来还可以："))
        if let lastCapture {
            let preview = NSImageView(image: lastCapture)
            preview.imageScaling = .scaleProportionallyDown
            preview.wantsLayer = true
            preview.layer?.cornerRadius = 8
            preview.layer?.borderWidth = 1
            preview.layer?.borderColor = NSColor.separatorColor.cgColor
            preview.heightAnchor.constraint(lessThanOrEqualToConstant: 120).isActive = true
            preview.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
            content.addArrangedSubview(preview)
        }
        content.addArrangedSubview(list([
            L("Pin it on screen with \(HotKeyCenter.shared.pinHotKey.symbol), or ⌘T while selecting.", "按 \(HotKeyCenter.shared.pinHotKey.symbol) 把它钉在屏幕上，框选时也可以按 ⌘T。"),
            L("Paste it framed in a background with \(HotKeyCenter.shared.hotKey(for: .pasteStyled).symbol) (within 5 minutes of copying).",
              "复制后 5 分钟内按 \(HotKeyCenter.shared.hotKey(for: .pasteStyled).symbol)，粘贴套好背景样式的版本。"),
            L("Ask Snapok Agent about it, redact it, annotate it, or translate it.", "让 Snapok Agent 解读截图、打码、标注或翻译。")
        ]))
        let row = NSStackView(views: [button(L("Ask Snapok Agent", "问问 Snapok Agent"), #selector(askAgent), primary: true)])
        content.addArrangedSubview(row)
        footer(next: L("Done", "完成"), primary: false)
    }

    // MARK: Actions

    @objc private func requestScreen() {
        Task {
            _ = await ScreenRecordingPermission.request()
            render()
        }
    }

    @objc private func openScreenSettings() { ScreenRecordingPermission.openSettings() }

    @objc private func relaunch() { AppRelauncher.relaunch() }

    @objc private func requestAccessibility() {
        // The capture flow won't explain it again later.
        UserDefaults.standard.set(true, forKey: "permissions.componentSnapping.explained")
        ComponentSnappingPermission.request()
    }

    @objc private func startCapture() { onCapture?() }

    private func captureFinished(_ image: NSImage?) {
        guard step == .capture, window?.isVisible == true else { return }
        lastCapture = image
        step = .explore
        render()
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func askAgent() {
        let image = lastCapture ?? (NSImage(pasteboard: .general).flatMap { $0.isValid ? $0 : nil })
        finish()
        if let image { onAskAgent?(image) }
    }

    @objc private func next() {
        guard let following = Step(rawValue: step.rawValue + 1) else { finish(); return }
        if step == .permissions { UserDefaults.standard.set(true, forKey: "permissions.componentSnapping.explained") }
        step = following
        render()
    }

    @objc private func back() {
        guard let previous = Step(rawValue: step.rawValue - 1) else { return }
        step = previous
        render()
    }

    private func finish() {
        UserDefaults.standard.set(true, forKey: Self.completedKey)
        UserDefaults.standard.removeObject(forKey: Self.stepKey)
        close()
    }

    // MARK: Building blocks

    private func header(_ title: String, _ subtitle: String) {
        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = .systemFont(ofSize: 24, weight: .bold)
        content.addArrangedSubview(titleLabel)
        let subtitleLabel = secondary(subtitle, size: 14)
        content.addArrangedSubview(subtitleLabel)
        content.setCustomSpacing(22, after: subtitleLabel)
    }

    private func secondary(_ text: String, size: CGFloat = 12) -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: text)
        label.font = .systemFont(ofSize: size)
        label.textColor = .secondaryLabelColor
        label.preferredMaxLayoutWidth = 480
        return label
    }

    private func list(_ items: [String]) -> NSView {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        // Wrapped lines line up under the text, not the bullet.
        let paragraph = NSMutableParagraphStyle()
        paragraph.headIndent = 16
        paragraph.tabStops = [NSTextTab(textAlignment: .left, location: 16)]
        for item in items {
            let label = NSTextField(wrappingLabelWithString: "")
            label.attributedStringValue = NSAttributedString(string: "•\t" + item, attributes: [
                .font: NSFont.systemFont(ofSize: 13), .foregroundColor: NSColor.labelColor, .paragraphStyle: paragraph
            ])
            label.preferredMaxLayoutWidth = 470
            stack.addArrangedSubview(label)
        }
        return stack
    }

    private func button(_ title: String, _ action: Selector, primary: Bool) -> NSButton {
        let button = NSButton(title: title, target: self, action: action)
        button.bezelStyle = .rounded
        button.controlSize = .large
        if primary { button.keyEquivalent = "\r"; button.bezelColor = Brand.accent }
        return button
    }

    private func button(_ title: String, _ action: Selector) -> NSButton { button(title, action, primary: false) }

    private func permissionRow(title: String, detail: String, granted: Bool, actions: [NSButton]) -> NSView {
        let icon = NSImageView(image: NSImage(systemSymbolName: granted ? "checkmark.circle.fill" : "circle.dashed", accessibilityDescription: nil)!)
        icon.symbolConfiguration = .init(pointSize: 18, weight: .regular)
        icon.contentTintColor = granted ? .systemGreen : .tertiaryLabelColor
        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = .systemFont(ofSize: 14, weight: .semibold)
        let detailLabel = secondary(detail)
        // Wrap before the buttons, which sit at the trailing edge of every row.
        detailLabel.preferredMaxLayoutWidth = actions.isEmpty ? 400 : 300
        let text = NSStackView(views: [titleLabel, detailLabel])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 3
        text.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let buttons = NSStackView(views: actions)
        buttons.spacing = 8
        buttons.setContentCompressionResistancePriority(.required, for: .horizontal)
        buttons.setContentHuggingPriority(.required, for: .horizontal)
        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        let row = NSStackView(views: [icon, text, spacer, buttons])
        row.alignment = .centerY
        row.spacing = 12
        row.edgeInsets = NSEdgeInsets(top: 14, left: 14, bottom: 14, right: 14)
        row.wantsLayer = true
        row.layer?.cornerRadius = 10
        row.layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(0.04).cgColor
        row.widthAnchor.constraint(equalToConstant: 480).isActive = true
        return row
    }

    private func footer(next title: String, primary: Bool) {
        let spacer = NSView()
        spacer.heightAnchor.constraint(equalToConstant: 8).isActive = true
        content.addArrangedSubview(spacer)
        var views: [NSView] = []
        if step != .permissions { views.append(button(L("Back", "上一步"), #selector(back))) }
        views.append(NSView())
        let nextButton = NSButton(title: title, target: self, action: #selector(next))
        nextButton.bezelStyle = .rounded
        nextButton.controlSize = .large
        // Only one default button per step: the step's own main action keeps Return when it has one.
        if primary && !content.arrangedSubviews.contains(where: { ($0 as? NSButton)?.keyEquivalent == "\r" }) {
            nextButton.keyEquivalent = "\r"
        }
        views.append(nextButton)
        let row = NSStackView(views: views)
        row.widthAnchor.constraint(equalToConstant: 480).isActive = true
        content.addArrangedSubview(row)
    }
}
