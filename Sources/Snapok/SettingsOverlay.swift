import AppKit
import UniformTypeIdentifiers

enum SettingsPage: CaseIterable {
    case profile
    case general
    case ai
    case models
    case about

    var title: String {
        switch self {
        case .profile: return L("Profile", "个人资料")
        case .general: return L("General", "通用")
        case .ai: return L("AI Features", "AI 功能")
        case .models: return L("Models", "模型")
        case .about: return L("About", "关于")
        }
    }

    var symbol: String {
        switch self {
        case .profile: return "person.crop.circle"
        case .general: return "gearshape"
        case .ai: return "sparkles"
        case .models: return "cpu"
        case .about: return "info.circle"
        }
    }
}

/// Settings shown as a panel over the main window: a dimmed backdrop, a sidebar of pages, and a close button.
/// Esc, the close button, or a click on the backdrop dismisses it.
@MainActor
final class SettingsOverlay: NSView {
    var onClose: (() -> Void)?
    private(set) var page: SettingsPage = .general
    private let panel = NSView()
    private let content = ContentBackground()
    private var navItems: [SettingsPage: SidebarItem] = [:]
    private var profileCard: ProfileCard!
    private var pages: [SettingsPage: NSView] = [:]
    private var keyMonitor: Any?

    init(page: SettingsPage) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.withAlphaComponent(0.28).cgColor
        build()
        show(page)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func build() {
        panel.wantsLayer = true
        panel.layer?.cornerRadius = 14
        panel.layer?.masksToBounds = true
        panel.layer?.borderWidth = 1
        panel.layer?.borderColor = NSColor.separatorColor.cgColor
        let shadowHost = NSView()
        shadowHost.wantsLayer = true
        shadowHost.layer?.shadowColor = NSColor.black.cgColor
        shadowHost.layer?.shadowOpacity = 0.25
        shadowHost.layer?.shadowRadius = 24
        shadowHost.layer?.shadowOffset = CGSize(width: 0, height: -6)

        let sidebar = SidebarBackground()

        profileCard = ProfileCard { [weak self] in self?.show(.profile) }
        let nav = NSStackView()
        nav.orientation = .vertical
        nav.alignment = .leading
        nav.spacing = 4
        for page in SettingsPage.allCases where page != .profile {
            let item = SidebarItem(title: page.title, symbol: page.symbol) { [weak self] in self?.show(page) }
            navItems[page] = item
            nav.addArrangedSubview(item)
            item.widthAnchor.constraint(equalTo: nav.widthAnchor).isActive = true
        }

        let close = NSButton(image: NSImage(systemSymbolName: "xmark", accessibilityDescription: L("Close", "关闭"))!,
                             target: self, action: #selector(closeTapped))
        close.isBordered = false
        close.symbolConfiguration = .init(pointSize: 15, weight: .medium)
        close.contentTintColor = .secondaryLabelColor
        close.toolTip = L("Close (Esc)", "关闭（Esc）")

        [shadowHost, panel].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            addSubview($0)
        }
        [sidebar, content, close].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            panel.addSubview($0)
        }
        [profileCard, nav].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            sidebar.addSubview($0)
        }
        NSLayoutConstraint.activate([
            // Leave the title bar and traffic lights visible above the panel.
            panel.topAnchor.constraint(equalTo: topAnchor, constant: 44),
            panel.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -28),
            panel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 36),
            panel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -36),
            shadowHost.topAnchor.constraint(equalTo: panel.topAnchor),
            shadowHost.bottomAnchor.constraint(equalTo: panel.bottomAnchor),
            shadowHost.leadingAnchor.constraint(equalTo: panel.leadingAnchor),
            shadowHost.trailingAnchor.constraint(equalTo: panel.trailingAnchor),

            sidebar.topAnchor.constraint(equalTo: panel.topAnchor),
            sidebar.bottomAnchor.constraint(equalTo: panel.bottomAnchor),
            sidebar.leadingAnchor.constraint(equalTo: panel.leadingAnchor),
            sidebar.widthAnchor.constraint(equalToConstant: 230),
            content.topAnchor.constraint(equalTo: panel.topAnchor),
            content.bottomAnchor.constraint(equalTo: panel.bottomAnchor),
            content.leadingAnchor.constraint(equalTo: sidebar.trailingAnchor),
            content.trailingAnchor.constraint(equalTo: panel.trailingAnchor),
            close.topAnchor.constraint(equalTo: panel.topAnchor, constant: 18),
            close.trailingAnchor.constraint(equalTo: panel.trailingAnchor, constant: -20),

            profileCard.topAnchor.constraint(equalTo: sidebar.topAnchor, constant: 22),
            profileCard.leadingAnchor.constraint(equalTo: sidebar.leadingAnchor, constant: 14),
            profileCard.trailingAnchor.constraint(equalTo: sidebar.trailingAnchor, constant: -14),
            nav.topAnchor.constraint(equalTo: profileCard.bottomAnchor, constant: 18),
            nav.leadingAnchor.constraint(equalTo: sidebar.leadingAnchor, constant: 14),
            nav.trailingAnchor.constraint(equalTo: sidebar.trailingAnchor, constant: -14)
        ])
        shadowHost.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        shadowHost.layer?.cornerRadius = 14
    }

    func show(_ page: SettingsPage) {
        self.page = page
        navItems.forEach { $0.value.isSelected = $0.key == page }
        profileCard.isSelected = page == .profile
        let view = pages[page] ?? makePage(page)
        pages[page] = view
        if let general = view as? GeneralSettingsPane { general.load() }
        if let models = view as? ModelsPane { models.load() }
        if let ai = view as? AIFeaturesPane { ai.load() }
        content.subviews.forEach { $0.removeFromSuperview() }
        view.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(view)
        NSLayoutConstraint.activate([
            view.topAnchor.constraint(equalTo: content.topAnchor),
            view.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            view.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            view.bottomAnchor.constraint(equalTo: content.bottomAnchor)
        ])
        window?.makeFirstResponder(self)
    }

    private func makePage(_ page: SettingsPage) -> NSView {
        switch page {
        case .profile: return ProfilePane()
        case .general: return GeneralSettingsPane()
        case .ai: return AIFeaturesPane()
        case .models: return ModelsPane()
        case .about: return AboutPane()
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
        guard window != nil else { return }
        window?.makeFirstResponder(self)
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, event.window === self.window, self.window?.attachedSheet == nil,
                  event.keyCode == 53, event.modifierFlags.intersection(.deviceIndependentFlagsMask).isEmpty else { return event }
            // Let a field editor or shortcut recorder use Esc first.
            if let editor = self.window?.firstResponder as? NSTextView, editor.isFieldEditor { return event }
            self.onClose?()
            return nil
        }
    }

    override var acceptsFirstResponder: Bool { true }

    @objc private func closeTapped() { onClose?() }

    // The backdrop swallows clicks and scrolling so the library underneath stays put; a click outside the panel closes.
    override func mouseDown(with event: NSEvent) {
        if !panel.frame.contains(convert(event.locationInWindow, from: nil)) { onClose?() }
    }

    override func scrollWheel(with event: NSEvent) {}
}

// MARK: - Profile

/// A local nickname and avatar, shown at the top of Settings. Nothing leaves this Mac.
@MainActor
enum Profile {
    static let didChange = Notification.Name("Profile.didChange")
    private static let nicknameKey = "profile.nickname"
    private static var avatarURL: URL { AppChannel.supportDirectory.appendingPathComponent("avatar.png") }

    static var nickname: String {
        get { UserDefaults.standard.string(forKey: nicknameKey) ?? "" }
        set {
            UserDefaults.standard.set(newValue.trimmingCharacters(in: .whitespacesAndNewlines), forKey: nicknameKey)
            NotificationCenter.default.post(name: didChange, object: nil)
        }
    }

    static var avatar: NSImage? { NSImage(contentsOf: avatarURL) }

    /// Center-crops the image to a square and stores it at 256 × 256.
    static func setAvatar(from url: URL) throws {
        guard let source = NSImage(contentsOf: url), let cg = source.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        let side = min(cg.width, cg.height)
        let crop = CGRect(x: (cg.width - side) / 2, y: (cg.height - side) / 2, width: side, height: side)
        let size = 256
        guard let square = cg.cropping(to: crop),
              let context = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        context.interpolationQuality = .high
        context.draw(square, in: CGRect(x: 0, y: 0, width: size, height: size))
        guard let scaled = context.makeImage(),
              let png = NSBitmapImageRep(cgImage: scaled).representation(using: .png, properties: [:]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        try FileManager.default.createDirectory(at: avatarURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try png.write(to: avatarURL, options: .atomic)
        NotificationCenter.default.post(name: didChange, object: nil)
    }

    static func removeAvatar() {
        try? FileManager.default.removeItem(at: avatarURL)
        NotificationCenter.default.post(name: didChange, object: nil)
    }
}

/// A round avatar: the chosen image, else the nickname's first letter, else a person symbol.
@MainActor
final class AvatarView: NSView {
    private let size: CGFloat
    private let imageView = NSImageView()
    private let initial = NSTextField(labelWithString: "")

    init(size: CGFloat) {
        self.size = size
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = size / 2
        layer?.masksToBounds = true
        layer?.borderWidth = 1
        layer?.borderColor = NSColor.labelColor.withAlphaComponent(0.08).cgColor
        imageView.imageScaling = .scaleProportionallyUpOrDown
        initial.font = .systemFont(ofSize: size * 0.42, weight: .semibold)
        initial.textColor = .white
        initial.alignment = .center
        [imageView, initial].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            addSubview($0)
        }
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: size),
            heightAnchor.constraint(equalToConstant: size),
            imageView.topAnchor.constraint(equalTo: topAnchor),
            imageView.bottomAnchor.constraint(equalTo: bottomAnchor),
            imageView.leadingAnchor.constraint(equalTo: leadingAnchor),
            imageView.trailingAnchor.constraint(equalTo: trailingAnchor),
            initial.centerXAnchor.constraint(equalTo: centerXAnchor),
            initial.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
        reload()
        NotificationCenter.default.addObserver(forName: Profile.didChange, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.reload() }
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func reload() {
        if let image = Profile.avatar {
            imageView.image = image
            imageView.contentTintColor = nil
            initial.isHidden = true
            layer?.backgroundColor = nil
        } else if let first = Profile.nickname.first {
            imageView.image = nil
            initial.stringValue = String(first).uppercased()
            initial.isHidden = false
            layer?.backgroundColor = Brand.accent.cgColor
        } else {
            imageView.image = NSImage(systemSymbolName: "person.crop.circle.fill", accessibilityDescription: nil)
            imageView.symbolConfiguration = .init(pointSize: size, weight: .regular)
            imageView.contentTintColor = .tertiaryLabelColor
            initial.isHidden = true
            layer?.backgroundColor = nil
        }
    }
}

/// The Settings sidebar's top card: avatar, nickname, and a hint; opens the Profile page.
@MainActor
final class ProfileCard: NSView {
    var isSelected = false { didSet { needsDisplay = true } }
    private let action: () -> Void
    private let name = NSTextField(labelWithString: "")
    private var hovering = false

    init(action: @escaping () -> Void) {
        self.action = action
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 10
        name.font = .systemFont(ofSize: 14, weight: .semibold)
        name.lineBreakMode = .byTruncatingTail
        let hint = NSTextField(labelWithString: L("Avatar and nickname", "头像与昵称"))
        hint.font = .systemFont(ofSize: 11)
        hint.textColor = .secondaryLabelColor
        let text = NSStackView(views: [name, hint])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 1
        let row = NSStackView(views: [AvatarView(size: 38), text])
        row.spacing = 10
        row.alignment = .centerY
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        NSLayoutConstraint.activate([
            row.topAnchor.constraint(equalTo: topAnchor, constant: 9),
            row.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -9),
            row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 9),
            row.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -9)
        ])
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        reload()
        NotificationCenter.default.addObserver(forName: Profile.didChange, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.reload() }
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func reload() {
        name.stringValue = Profile.nickname.isEmpty ? L("Your Profile", "个人资料") : Profile.nickname
        setAccessibilityLabel(name.stringValue)
    }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(isSelected ? 0.1 : hovering ? 0.07 : 0.05).cgColor
    }

    override func mouseEntered(with event: NSEvent) { hovering = true; needsDisplay = true }
    override func mouseExited(with event: NSEvent) { hovering = false; needsDisplay = true }
    override func mouseDown(with event: NSEvent) { action() }
    override func accessibilityPerformPress() -> Bool { action(); return true }
}

/// Settings → Profile: choose or remove the avatar and set a nickname.
@MainActor
final class ProfilePane: SectionedPageView, NSTextFieldDelegate {
    private let nickname = NSTextField()
    private let remove = NSButton(title: L("Remove", "移除"), target: nil, action: nil)

    init() {
        super.init(title: L("Profile", "个人资料"))
        let choose = NSButton(title: L("Choose Image…", "选择图片…"), target: self, action: #selector(chooseAvatar))
        choose.bezelStyle = .rounded
        remove.target = self
        remove.action = #selector(removeAvatar)
        remove.bezelStyle = .rounded
        let buttons = NSStackView(views: [choose, remove])
        buttons.spacing = 8
        let avatarRow = NSStackView(views: [AvatarView(size: 56), buttons])
        avatarRow.spacing = 16
        avatarRow.alignment = .centerY

        nickname.placeholderString = L("What should Snapok call you?", "希望 Snapok 怎么称呼你？")
        nickname.stringValue = Profile.nickname
        nickname.delegate = self
        nickname.widthAnchor.constraint(equalToConstant: 300).isActive = true

        let form = PageView.form([
            [PageView.label(L("Avatar", "头像")), avatarRow],
            [PageView.label(L("Nickname", "昵称")), nickname]
        ])
        form.rowAlignment = .none
        form.row(at: 0).yPlacement = .center
        form.row(at: 1).yPlacement = .center
        add(Self.card(form, inset: NSEdgeInsets(top: 20, left: 24, bottom: 20, right: 24)))
        add(Self.footnote(L("Shown in Settings. Stored only on this Mac.", "显示在设置里，只保存在这台 Mac 上。")), spacingBefore: 8)
        updateRemove()
        NotificationCenter.default.addObserver(forName: Profile.didChange, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateRemove() }
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func updateRemove() { remove.isHidden = Profile.avatar == nil }

    func controlTextDidChange(_ obj: Notification) {
        Profile.nickname = nickname.stringValue
    }

    @objc private func chooseAvatar() {
        guard let window else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        panel.beginSheetModal(for: window) { response in
            guard response == .OK, let url = panel.url else { return }
            MainActor.assumeIsolated {
                do {
                    try Profile.setAvatar(from: url)
                } catch {
                    NSAlert(error: error).beginSheetModal(for: window)
                }
            }
        }
    }

    @objc private func removeAvatar() { Profile.removeAvatar() }
}
