import AppKit
import Quartz

/// What a new Snapok Agent chat starts with when opened from elsewhere (the image editor).
enum AgentRequest {
    /// Ask about the attached image or describe how to change it.
    case edit
    /// Continue from the translation panel: the attached image is the translation, `original` goes along for context.
    case continueTranslation(original: NSImage)
}

/// Routes requests from anywhere (the image editor) to the Snapok Agent page.
@MainActor
enum ImageAgentEntry {
    static var open: ((NSImage?, AgentRequest) -> Void)?
    /// Shows a saved chat, e.g. from a "task finished" notification.
    static var openChat: ((String) -> Void)?
}

/// The Snapok Agent page: past chats, the conversation with the cloud image agent, and a preview of every image in it.
@MainActor
final class ImageAgentPane: NSView, NSSplitViewDelegate {
    var onEditImage: ((NSImage) -> Void)?
    var onOpenSettings: ((SettingsPage) -> Void)?

    private let store = ImageAgentStore.shared
    /// nil while composing a new chat.
    private var chatID: String?
    private var previewName: String?
    private var previewOpen = false
    /// The chat's images while Quick Look shows them; the pane is their data source.
    private var quickLookURLs: [URL] = []
    private var quickLookIndex = 0
    private var imageCounts: [String: Int] = [:]

    private let history = AgentHistoryController()
    private let historyPopover = NSPopover()
    private let chatCard = CardView()
    private let previewCard = CardView()
    private let split = AgentSplitView()
    private var previewLimits: [NSLayoutConstraint] = []
    private let titleLabel = NSTextField(labelWithString: "")
    private let galleryButton = NSButton()
    private let newChatButton = NSButton()
    private let transcript = AgentTranscriptView()
    private let composer = AgentComposer()
    /// What stands between the user and the next step, and the one thing that fixes it.
    private enum Gate {
        /// No model of their own and not signed in: nothing can plan a turn.
        case signIn
        /// Planning with Snapok Cloud, without the credits for it.
        case planCredits(SnapokCloud.Account)
        /// The last reply has a cloud generation waiting on signing in.
        case signInToGenerate
        /// The last reply has a cloud generation waiting on credits.
        case generateCredits(SnapokCloud.Account)
    }
    private var gate: Gate?

    /// Above the composer: why sending is unavailable (signed out, out of credits) and how to fix it.
    private let noticeBar = NSView()
    /// The label stops before the model button when it shows, otherwise before the main button.
    private var noticeLabelBeforeModel: NSLayoutConstraint!
    private var noticeLabelBeforeButton: NSLayoutConstraint!
    private let noticeLabel = WrappingLabel(wrappingLabelWithString: "")
    private let noticeButton = NSButton(title: "", target: nil, action: nil)
    private let ownModelButton = NSButton(title: L("Add My Model", "配置自己的模型"), target: nil, action: nil)
    private let creditsButton = NSButton(title: "", target: nil, action: nil)
    private let preview = AgentPreviewPane()
    private let feedback = WindowFeedback()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        build()
        NotificationCenter.default.addObserver(forName: ImageAgentStore.didChange, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.reload() }
        }
        // Coming back from the browser (signing in, buying credits) refreshes the balance.
        NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { _ in
            Task { await SnapokCloud.refreshAccount() }
        }
        Task { await SnapokCloud.refreshAccount() }
        NotificationCenter.default.addObserver(forName: SnapokCloud.didChangeAccount, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.reload() }
        }
        // A model added in Settings → Models can plan turns without signing in.
        NotificationCenter.default.addObserver(forName: ModelsStore.didChange, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.reload() }
        }
        imageCounts = Dictionary(uniqueKeysWithValues: store.chats.map { ($0.id, store.allImages(in: $0).count) })
        reload()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// Starts a new chat, optionally with an image already attached, and focuses the message box.
    func startNewChat(attaching image: NSImage? = nil, request: AgentRequest = .edit) {
        chatID = nil
        previewOpen = false
        composer.clear()
        if let image { composer.attach([image]) }
        // Arriving from elsewhere fills in the likeliest request, selected: Return sends it, typing replaces it.
        switch request {
        case .edit:
            if image != nil {
                composer.text = L("What's in this screenshot? Summarize the key points.", "这张截图里是什么？帮我总结一下要点。")
            }
        case .continueTranslation(let original):
            // The translation goes first: it is the image the next edits apply to.
            composer.attach([original])
            composer.text = L("The first image is the translation and the second is the original. Redraw the translation in the original's fonts, sizes, and colors, keeping the layout.",
                              "第一张是译文图，第二张是原图。请参照原图的字体、字号和颜色重新绘制译文，保持排版不变。")
        }
        reload()
        composer.focus(selectingAll: true)
    }

    func focusComposer() { composer.focus() }

    /// Opens a saved chat, optionally with one of its images in the preview.
    func open(chat id: String, previewing image: String? = nil) {
        select(id)
        if let image { openPreview(image) }
    }

    private func build() {
        history.onSelect = { [weak self] id in
            self?.historyPopover.performClose(nil)
            self?.select(id)
        }
        history.onRename = { [weak self] id in
            self?.historyPopover.performClose(nil)
            self?.rename(id)
        }
        history.onDelete = { [weak self] id in
            self?.historyPopover.performClose(nil)
            self?.delete(id)
        }
        historyPopover.contentViewController = history
        historyPopover.behavior = .transient
        historyPopover.contentSize = CGSize(width: 320, height: 440)

        let historyButton = NSButton(image: NSImage(systemSymbolName: "clock.arrow.circlepath", accessibilityDescription: L("Chat history", "历史对话"))!,
                                     target: self, action: #selector(showHistory(_:)))
        historyButton.isBordered = false
        historyButton.contentTintColor = .secondaryLabelColor
        historyButton.toolTip = L("Chat history", "历史对话")
        newChatButton.image = NSImage(systemSymbolName: "square.and.pencil", accessibilityDescription: L("New chat", "新对话"))
        newChatButton.target = self
        newChatButton.action = #selector(newChatClicked)
        newChatButton.isBordered = false
        newChatButton.contentTintColor = .secondaryLabelColor
        newChatButton.toolTip = L("New chat", "新对话")
        galleryButton.image = NSImage(systemSymbolName: "photo.stack", accessibilityDescription: L("Images in this chat", "本对话的图片"))
        galleryButton.target = self
        galleryButton.action = #selector(openGallery)
        galleryButton.isBordered = false
        galleryButton.contentTintColor = .secondaryLabelColor
        galleryButton.toolTip = L("Images in this chat", "本对话的图片")
        titleLabel.font = .systemFont(ofSize: 15, weight: .semibold)
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        creditsButton.image = NSImage(systemSymbolName: "sparkles", accessibilityDescription: nil)
        creditsButton.imagePosition = .imageLeading
        creditsButton.bezelStyle = .inline
        creditsButton.font = .systemFont(ofSize: 12, weight: .medium)
        creditsButton.target = self
        creditsButton.action = #selector(showAccountMenu(_:))
        creditsButton.toolTip = L("Credits", "积分")
        let header = NSStackView(views: [titleLabel, NSView(), creditsButton, galleryButton, historyButton, newChatButton])
        header.spacing = 10
        header.heightAnchor.constraint(equalToConstant: 32).isActive = true

        noticeLabel.font = .systemFont(ofSize: 13)
        noticeLabel.textColor = .secondaryLabelColor
        noticeLabel.maximumNumberOfLines = 2
        noticeLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        // The buttons keep their own width; any spare width goes to the label (it re-wraps), never to a stretched button.
        noticeLabel.setContentHuggingPriority(.init(1), for: .horizontal)
        for button in [noticeButton, ownModelButton] {
            button.setContentHuggingPriority(.required, for: .horizontal)
            button.setContentCompressionResistancePriority(.required, for: .horizontal)
        }
        noticeButton.bezelStyle = .rounded
        noticeButton.target = self
        noticeButton.action = #selector(noticeAction)
        ownModelButton.bezelStyle = .rounded
        ownModelButton.target = self
        ownModelButton.action = #selector(openModels)
        // Buttons keep their width at the trailing edge; the label takes the rest and wraps.
        for view in [noticeLabel, ownModelButton, noticeButton] {
            view.translatesAutoresizingMaskIntoConstraints = false
            noticeBar.addSubview(view)
        }
        noticeLabelBeforeModel = noticeLabel.trailingAnchor.constraint(equalTo: ownModelButton.leadingAnchor, constant: -12)
        noticeLabelBeforeButton = noticeLabel.trailingAnchor.constraint(equalTo: noticeButton.leadingAnchor, constant: -12)
        NSLayoutConstraint.activate([
            noticeLabel.leadingAnchor.constraint(equalTo: noticeBar.leadingAnchor),
            noticeLabel.centerYAnchor.constraint(equalTo: noticeBar.centerYAnchor),
            noticeLabel.topAnchor.constraint(greaterThanOrEqualTo: noticeBar.topAnchor),
            noticeLabel.bottomAnchor.constraint(lessThanOrEqualTo: noticeBar.bottomAnchor),
            noticeButton.trailingAnchor.constraint(equalTo: noticeBar.trailingAnchor),
            noticeButton.centerYAnchor.constraint(equalTo: noticeBar.centerYAnchor),
            noticeButton.topAnchor.constraint(greaterThanOrEqualTo: noticeBar.topAnchor),
            noticeButton.bottomAnchor.constraint(lessThanOrEqualTo: noticeBar.bottomAnchor),
            ownModelButton.trailingAnchor.constraint(equalTo: noticeButton.leadingAnchor, constant: -8),
            ownModelButton.centerYAnchor.constraint(equalTo: noticeBar.centerYAnchor),
            noticeLabelBeforeModel
        ])
        // A plain view has no height of its own: hug the content so the transcript gets the spare room.
        let hug = noticeBar.heightAnchor.constraint(equalToConstant: 0)
        hug.priority = .defaultHigh
        hug.isActive = true

        transcript.onOpenImage = { [weak self] name in self?.openPreview(name) }
        transcript.onQuickLook = { [weak self] name in self?.quickLook(name) }
        transcript.imageMenu = { [weak self] name in self?.imageMenu(for: name) }
        transcript.onRetry = { [weak self] in
            guard let self, let chatID else { return }
            store.retry(chatID)
        }
        transcript.onResume = { [weak self] in self?.resumeGeneration() }
        composer.onSend = { [weak self] text, images in self?.send(text, images) }
        composer.onStop = { [weak self] in
            guard let self, let chatID else { return }
            store.stop(chatID)
        }

        let chatColumn = NSStackView(views: [header, transcript, noticeBar, composer])
        chatColumn.orientation = .vertical
        // Fill, not the default gravity areas, so the transcript takes the spare height.
        chatColumn.distribution = .fill
        chatColumn.spacing = 10
        // No side insets: the transcript spans the card so its scroller sits on the edge.
        chatColumn.edgeInsets = NSEdgeInsets(top: 14, left: 0, bottom: 16, right: 0)
        chatColumn.translatesAutoresizingMaskIntoConstraints = false
        chatCard.addSubview(chatColumn)
        for view in [header, noticeBar, composer] {
            view.widthAnchor.constraint(equalTo: chatColumn.widthAnchor, constant: -32).isActive = true
        }
        transcript.widthAnchor.constraint(equalTo: chatColumn.widthAnchor).isActive = true
        transcript.setContentHuggingPriority(.defaultLow, for: .vertical)

        preview.onSelect = { [weak self] name in self?.openPreview(name) }
        preview.onClose = { [weak self] in
            self?.previewOpen = false
            self?.reload()
        }
        preview.onAction = { [weak self] action in self?.perform(action) }
        preview.onQuickLook = { [weak self] name in self?.quickLook(name) }
        preview.imageMenu = { [weak self] name in self?.imageMenu(for: name) }
        preview.translatesAutoresizingMaskIntoConstraints = false
        previewCard.addSubview(preview)

        // The split view only ever divides its own width, so neither pane can push past the window.
        split.delegate = self
        split.isVertical = true
        split.addArrangedSubview(chatCard)
        split.addArrangedSubview(previewCard)
        // Window resizes go to the chat; the preview keeps the width it was dragged to.
        split.setHoldingPriority(.init(250), forSubviewAt: 0)
        split.setHoldingPriority(.init(260), forSubviewAt: 1)
        split.translatesAutoresizingMaskIntoConstraints = false
        addSubview(split)
        // Below required, so an impossibly narrow window squeezes the panes instead of overflowing.
        let limit = NSLayoutConstraint.Priority(999)
        let chatMin = chatCard.widthAnchor.constraint(greaterThanOrEqualToConstant: Self.minChatWidth)
        chatMin.priority = limit
        previewLimits = [
            previewCard.widthAnchor.constraint(greaterThanOrEqualToConstant: Self.minPreviewWidth),
            previewCard.widthAnchor.constraint(lessThanOrEqualTo: split.widthAnchor, multiplier: Self.maxPreviewFraction)
        ]
        previewLimits.forEach { $0.priority = limit }
        NSLayoutConstraint.activate([
            split.topAnchor.constraint(equalTo: topAnchor, constant: 40),
            split.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -16),
            split.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            split.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            chatMin,
            chatColumn.topAnchor.constraint(equalTo: chatCard.topAnchor),
            chatColumn.bottomAnchor.constraint(equalTo: chatCard.bottomAnchor),
            chatColumn.leadingAnchor.constraint(equalTo: chatCard.leadingAnchor),
            chatColumn.trailingAnchor.constraint(equalTo: chatCard.trailingAnchor),
            preview.topAnchor.constraint(equalTo: previewCard.topAnchor),
            preview.bottomAnchor.constraint(equalTo: previewCard.bottomAnchor),
            preview.leadingAnchor.constraint(equalTo: previewCard.leadingAnchor),
            preview.trailingAnchor.constraint(equalTo: previewCard.trailingAnchor)
        ])
        setPreviewVisible(false)
    }

    // MARK: Split between chat and preview

    private static let minChatWidth: CGFloat = 320
    private static let minPreviewWidth: CGFloat = 260
    private static let maxPreviewFraction: CGFloat = 0.65
    private static let previewWidthKey = "imageAgent.previewWidth"

    private func setPreviewVisible(_ visible: Bool) {
        guard previewCard.isHidden == visible || previewLimits.first?.isActive != visible else { return }
        previewCard.isHidden = !visible
        // A collapsed pane can't meet a minimum width.
        visible ? NSLayoutConstraint.activate(previewLimits) : NSLayoutConstraint.deactivate(previewLimits)
        split.adjustSubviews()
        guard visible else { return }
        layoutSubtreeIfNeeded()
        let total = split.bounds.width - split.dividerThickness
        let saved = UserDefaults.standard.double(forKey: Self.previewWidthKey)
        let preferred = saved > 0 ? CGFloat(saved) : total * 0.45
        let width = min(max(preferred, Self.minPreviewWidth), total * Self.maxPreviewFraction, total - Self.minChatWidth)
        split.setPosition(total - width, ofDividerAt: 0)
    }

    private func reload() {
        let chat = chatID.flatMap(store.chat)
        if chatID != nil && chat == nil { chatID = nil }
        let running = chatID.map(store.running.contains) ?? false
        history.show(store.chats, selected: chatID, running: store.running)
        titleLabel.stringValue = chat?.title ?? L("New Chat", "新对话")

        // A new result opens the preview on it.
        let names = chat.map(store.allImages) ?? []
        if let chat {
            let previous = imageCounts[chat.id] ?? names.count
            if names.count > previous, chat.messages.last?.role == .assistant, let latest = names.last {
                previewName = latest
                previewOpen = true
            }
            imageCounts[chat.id] = names.count
        }
        if previewName.map({ !names.contains($0) }) ?? true { previewName = names.last }

        transcript.show(chat, running: running, generating: chatID.map(store.generating.contains) ?? false,
                        liveText: chatID.flatMap { store.liveText[$0] }, steps: chatID.flatMap { store.liveSteps[$0] } ?? [],
                        started: chatID.flatMap { store.startedAt[$0] })
        let account = SnapokCloud.account
        gate = currentGate(chat)
        let cloud = SnapokCloud.isAvailable
        switch gate {
        case .signIn where !cloud:
            noticeLabel.stringValue = L("Add your own model to use Snapok Agent.", "配置自己的模型即可使用 Snapok Agent。")
            noticeButton.title = L("Add My Model", "配置自己的模型")
        case .signIn:
            noticeLabel.stringValue = L("Sign in to use Snapok Agent (new accounts get free credits), or add your own model to use it free.",
                                        "登录即可使用 Snapok Agent（新用户赠送积分），也可以配置自己的模型免费使用。")
            noticeButton.title = L("Sign In", "登录")
        case .planCredits(let account):
            noticeLabel.stringValue = L("Each message needs \(account.textCost) credits; you have \(account.balance). Or add your own model to use it free.",
                                        "每条消息需要 \(account.textCost) 积分，当前剩余 \(account.balance)。也可以配置自己的模型免费使用。")
            noticeButton.title = account.isPro ? L("Buy Credits", "购买积分") : L("Get Pro", "订阅 Pro")
        case .signInToGenerate where !cloud:
            noticeLabel.stringValue = L("Generating images runs on Snapok Cloud, which builds from source don't include. Download Snapok to use it.",
                                        "生成图片需要 Snapok 云端，源码构建的版本不包含云端功能。下载官方版本即可使用。")
            noticeButton.title = L("Download Snapok", "下载官方版本")
        case .signInToGenerate:
            noticeLabel.stringValue = L("Sign in to Snapok to finish this with cloud generation; new accounts get free credits.",
                                        "登录 Snapok 账号即可继续云端生成，新用户赠送积分。")
            noticeButton.title = L("Sign In", "登录")
        case .generateCredits(let account):
            noticeLabel.stringValue = L("Cloud generation needs \(account.cost) credits; you have \(account.balance).",
                                        "云端生成需要 \(account.cost) 积分，当前剩余 \(account.balance)。")
            noticeButton.title = account.isPro ? L("Buy Credits", "购买积分") : L("Get Pro", "订阅 Pro")
        case nil:
            break
        }
        noticeBar.isHidden = gate == nil
        // Planning can use the user's own model instead of signing in or buying credits; generation always runs on Snapok Cloud.
        switch gate {
        case .signIn, .planCredits: ownModelButton.isHidden = !cloud
        default: ownModelButton.isHidden = true
        }
        noticeLabelBeforeModel.isActive = !ownModelButton.isHidden
        noticeLabelBeforeButton.isActive = ownModelButton.isHidden
        // Always an account entry: sign in when signed out (a user with their own model is never asked otherwise),
        // the balance once the account has loaded. Builds without Snapok Cloud have no account at all.
        creditsButton.isHidden = !cloud
        if !SnapokCloud.isSignedIn {
            creditsButton.title = L("Sign In", "登录")
            creditsButton.image = NSImage(systemSymbolName: "person.crop.circle", accessibilityDescription: nil)
            creditsButton.toolTip = L("Sign in to Snapok for cloud planning and image generation", "登录 Snapok，使用云端规划和图片生成")
            creditsButton.contentTintColor = .secondaryLabelColor
        } else {
            creditsButton.title = account.map { L("\($0.balance) credits", "\($0.balance) 积分") } ?? L("Account", "账户")
            creditsButton.image = NSImage(systemSymbolName: "sparkles", accessibilityDescription: nil)
            creditsButton.toolTip = L("Credits", "积分")
            creditsButton.contentTintColor = account.map { !$0.canAffordTurn } ?? false ? .systemOrange : .secondaryLabelColor
        }
        composer.isAvailable = canSend
        composer.isBusy = running
        composer.placeholder = chat == nil
            ? L("Ask about the image, or describe a change…", "问点什么，或者描述怎么改图…")
            : L("Follow up…", "接着问，或者继续修改…")

        let showPreview = previewOpen && previewName != nil
        setPreviewVisible(showPreview)
        // Only a chat with images has a gallery, and the open preview has its own close button.
        galleryButton.isHidden = names.isEmpty || showPreview
        newChatButton.isHidden = chat == nil
        if showPreview, let chat, let previewName {
            preview.show(chatID: chat.id, names: names, selected: previewName)
        }
    }

    /// The model plans turns; credits are checked only for what Snapok Cloud would run.
    private var canSend: Bool {
        guard let source = AgentPlanner.source else { return false }
        if case .cloud = source { return SnapokCloud.account?.canAffordPlan ?? true }
        return true
    }

    private func currentGate(_ chat: AgentChat?) -> Gate? {
        guard let source = AgentPlanner.source else { return .signIn }
        let account = SnapokCloud.account
        if case .cloud = source, let account, !account.canAffordPlan { return .planCredits(account) }
        guard let last = chat?.messages.last, last.pendingGeneration != nil else { return nil }
        if !SnapokCloud.isSignedIn { return .signInToGenerate }
        if let account, !account.canAffordTurn { return .generateCredits(account) }
        return nil
    }

    /// The reply's "Continue" button: fixes what blocks the generation first, otherwise runs it.
    private func resumeGeneration() {
        guard let chatID else { return }
        guard let gate = currentGate(store.chat(chatID)) else {
            Telemetry.capture("ai_used", ["feature": "image_agent"])
            store.resumeGeneration(chatID)
            return
        }
        resolve(gate)
    }

    /// What the notice button (and the reply's "Continue") does about a gate.
    private func resolve(_ gate: Gate) {
        switch gate {
        case .signIn where !SnapokCloud.isAvailable: openModels()
        case .signInToGenerate where !SnapokCloud.isAvailable: NSWorkspace.shared.open(URL(string: "https://snapok.app")!)
        case .signIn, .signInToGenerate: SnapokCloud.signIn()
        case .planCredits, .generateCredits: SnapokCloud.openPricing()
        }
    }

    private func select(_ id: String) {
        guard id != chatID else { return }
        chatID = id
        previewOpen = false
        composer.clear()
        reload()
        composer.focus()
    }

    private func send(_ text: String, _ images: [NSImage]) {
        Telemetry.capture("ai_used", ["feature": "image_agent"])
        guard let id = store.send(text, attachments: images, to: chatID) else { return }
        chatID = id
        composer.clear()
        reload()
    }

    private func openPreview(_ name: String) {
        previewName = name
        previewOpen = true
        reload()
    }

    private func rename(_ id: String) {
        guard let chat = store.chat(id), let window else { return }
        let alert = NSAlert()
        alert.messageText = L("Rename Chat", "重命名对话")
        let field = NSTextField(string: chat.title)
        field.frame = CGRect(x: 0, y: 0, width: 300, height: 24)
        alert.accessoryView = field
        alert.addButton(withTitle: L("Save", "保存"))
        alert.addButton(withTitle: L("Cancel", "取消"))
        alert.window.initialFirstResponder = field
        alert.beginSheetModal(for: window) { [weak self] response in
            let title = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard response == .alertFirstButtonReturn, !title.isEmpty else { return }
            self?.store.rename(id, to: title)
        }
    }

    private func delete(_ id: String) {
        guard let chat = store.chat(id), let window else { return }
        let alert = NSAlert()
        alert.messageText = L("Delete “\(chat.title)”?", "删除“\(chat.title)”？")
        alert.informativeText = L("Its messages and images are removed from this Mac. This can't be undone.", "对话里的消息和图片会从这台 Mac 上删除，无法恢复。")
        alert.addButton(withTitle: L("Delete", "删除")).hasDestructiveAction = true
        alert.addButton(withTitle: L("Cancel", "取消"))
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn else { return }
            if self?.chatID == id { self?.chatID = nil }
            self?.store.delete(id)
        }
    }

    /// Runs `action` on the previewed image, or on `name` when it comes from an image's context menu.
    private func perform(_ action: AgentPreviewPane.Action, name: String? = nil) {
        guard let chatID, let name = name ?? previewName, let image = store.image(name, in: chatID) else { return }
        switch action {
        case .edit:
            onEditImage?(image)
        case .library:
            guard let png = image.pngData else { return }
            do {
                let title = store.chat(chatID)?.title ?? ""
                try HistoryStore.shared.saveDerivative(png: png, title: "Snapok Agent · \(title)", tags: ["ai-edit"], text: "")
                feedback.show(L("Saved to the library.", "已保存到截图库。"), in: window)
            } catch {
                log("saving agent image to the library failed", error: error)
                feedback.showError(L("Could not save to the library.", "保存到截图库失败。"), in: window)
            }
        case .copy:
            ImageExport.copy(image)
            feedback.show(L("Copied to clipboard.", "已复制到剪贴板。"), in: window)
        case .save:
            switch ImageExport.save(image) {
            case .saved: feedback.show(L("Image saved.", "图片已保存。"), in: window)
            case .cancelled: break
            case .failed: feedback.showError(L("Could not save. Choose another location and try again.", "保存失败，请选择其他位置后重试。"), in: window)
            }
        }
    }

    /// The right-click menu of a chat image.
    private func imageMenu(for name: String) -> NSMenu {
        let menu = NSMenu()
        let items: [(String, Selector)?] = [
            (L("Quick Look", "快速查看"), #selector(quickLookItem(_:))),
            nil,
            (L("Copy Image", "复制图片"), #selector(copyItem(_:))),
            (L("Save PNG…", "保存 PNG…"), #selector(saveItem(_:))),
            nil,
            (L("Open in Editor", "在编辑器中打开"), #selector(editItem(_:))),
            (L("Save to Library", "保存到截图库"), #selector(libraryItem(_:)))
        ]
        for entry in items {
            guard let (title, action) = entry else { menu.addItem(.separator()); continue }
            let item = menu.addItem(withTitle: title, action: action, keyEquivalent: "")
            item.target = self
            item.representedObject = name
        }
        return menu
    }

    @objc private func quickLookItem(_ sender: NSMenuItem) { (sender.representedObject as? String).map(quickLook) }
    @objc private func copyItem(_ sender: NSMenuItem) { perform(.copy, name: sender.representedObject as? String) }
    @objc private func saveItem(_ sender: NSMenuItem) { perform(.save, name: sender.representedObject as? String) }
    @objc private func editItem(_ sender: NSMenuItem) { perform(.edit, name: sender.representedObject as? String) }
    @objc private func libraryItem(_ sender: NSMenuItem) { perform(.library, name: sender.representedObject as? String) }

    /// Opens `name` in Quick Look, with the chat's other images a swipe or arrow key away.
    private func quickLook(_ name: String) {
        guard let chatID, let chat = store.chat(chatID) else { return }
        let names = store.allImages(in: chat)
        quickLookURLs = names.map { store.imageURL($0, in: chatID) }
        quickLookIndex = names.firstIndex(of: name) ?? 0
        guard !quickLookURLs.isEmpty, let panel = QLPreviewPanel.shared() else { return }
        // Quick Look asks the responder chain for a controller, so take focus for as long as it is open.
        acceptsQuickLookFocus = true
        window?.makeFirstResponder(self)
        if panel.isVisible {
            panel.reloadData()
            panel.currentPreviewItemIndex = quickLookIndex
        } else {
            panel.makeKeyAndOrderFront(nil)
        }
    }

    private var acceptsQuickLookFocus = false
    override var acceptsFirstResponder: Bool { acceptsQuickLookFocus }

    // Quick Look calls these on the main thread, though they aren't annotated that way.
    nonisolated override func acceptsPreviewPanelControl(_ panel: QLPreviewPanel!) -> Bool {
        MainActor.assumeIsolated { !quickLookURLs.isEmpty }
    }

    nonisolated override func beginPreviewPanelControl(_ panel: QLPreviewPanel!) {
        MainActor.assumeIsolated {
            panel.dataSource = self
            panel.currentPreviewItemIndex = quickLookIndex
        }
    }

    nonisolated override func endPreviewPanelControl(_ panel: QLPreviewPanel!) {
        MainActor.assumeIsolated {
            panel.dataSource = nil
            acceptsQuickLookFocus = false
        }
    }

    @objc private func showHistory(_ sender: NSButton) {
        if historyPopover.isShown {
            historyPopover.performClose(nil)
        } else {
            historyPopover.show(relativeTo: sender.bounds, of: sender, preferredEdge: .minY)
        }
    }
    @objc private func newChatClicked() { startNewChat() }
    @objc private func noticeAction() { gate.map(resolve) }
    @objc private func openModels() { onOpenSettings?(.models) }

    @objc private func showAccountMenu(_ sender: NSButton) {
        guard SnapokCloud.isAvailable else { return }
        guard SnapokCloud.isSignedIn else { SnapokCloud.signIn(); return }
        guard let account = SnapokCloud.account else {
            // Still loading, or the server was unreachable: try again.
            Task { await SnapokCloud.refreshAccount() }
            return
        }
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.addItem(withTitle: account.email, action: nil, keyEquivalent: "").isEnabled = false
        menu.addItem(withTitle: account.isPro ? L("Snapok Pro", "Snapok Pro 会员") : L("Free plan", "免费版"),
                     action: nil, keyEquivalent: "").isEnabled = false
        menu.addItem(withTitle: L("\(account.balance) credits left", "剩余 \(account.balance) 积分"), action: nil, keyEquivalent: "").isEnabled = false
        menu.addItem(withTitle: L("Image result \(account.cost) · text answer \(account.textCost) credits", "出图 \(account.cost) 积分 · 文字回答 \(account.textCost) 积分"),
                     action: nil, keyEquivalent: "").isEnabled = false
        menu.addItem(.separator())
        menu.addItem(withTitle: account.isPro ? L("Buy Credits…", "购买积分…") : L("Get Snapok Pro…", "订阅 Snapok Pro…"),
                     action: #selector(buyCredits), keyEquivalent: "").target = self
        menu.addItem(withTitle: L("Refresh Balance", "刷新余额"), action: #selector(refreshCredits), keyEquivalent: "").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: L("Sign Out", "退出登录"), action: #selector(signOut), keyEquivalent: "").target = self
        menu.popUp(positioning: nil, at: CGPoint(x: 0, y: sender.bounds.height + 4), in: sender)
    }

    @objc private func buyCredits() { SnapokCloud.openPricing() }
    @objc private func refreshCredits() { Task { await SnapokCloud.refreshAccount() } }
    @objc private func signOut() { SnapokCloud.signOut() }

    @objc private func openGallery() {
        guard let previewName = previewName ?? chatID.flatMap(store.chat).flatMap({ store.allImages(in: $0).last }) else {
            NSSound.beep()
            return
        }
        openPreview(previewName)
    }
}

extension ImageAgentPane {
    func splitView(_ splitView: NSSplitView, constrainMinCoordinate proposedMinimumPosition: CGFloat, ofSubviewAt dividerIndex: Int) -> CGFloat {
        let total = splitView.bounds.width - splitView.dividerThickness
        return max(proposedMinimumPosition, Self.minChatWidth, total * (1 - Self.maxPreviewFraction))
    }

    func splitView(_ splitView: NSSplitView, constrainMaxCoordinate proposedMaximumPosition: CGFloat, ofSubviewAt dividerIndex: Int) -> CGFloat {
        min(proposedMaximumPosition, splitView.bounds.width - splitView.dividerThickness - Self.minPreviewWidth)
    }

    func splitView(_ splitView: NSSplitView, canCollapseSubview subview: NSView) -> Bool { false }

    func splitViewDidResizeSubviews(_ notification: Notification) {
        // Remember the dragged width for the next time the preview opens.
        guard NSEvent.pressedMouseButtons & 1 != 0, !previewCard.isHidden, previewCard.frame.width > 0 else { return }
        UserDefaults.standard.set(Double(previewCard.frame.width), forKey: Self.previewWidthKey)
    }
}

/// Chat and preview side by side, with a gap that doubles as the drag handle.
extension ImageAgentPane: @preconcurrency QLPreviewPanelDataSource {
    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int { quickLookURLs.count }

    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> (any QLPreviewItem)! {
        quickLookURLs[index] as NSURL
    }
}

final class AgentSplitView: NSSplitView {
    override var dividerThickness: CGFloat {
        arrangedSubviews.contains(where: \.isHidden) ? 0 : 14
    }

    override func drawDivider(in rect: NSRect) {
        guard dividerThickness > 0 else { return }
        let grip = NSRect(x: rect.midX - 2, y: rect.midY - 18, width: 4, height: 36)
        NSColor.tertiaryLabelColor.withAlphaComponent(0.6).setFill()
        NSBezierPath(roundedRect: grip, xRadius: 2, yRadius: 2).fill()
    }
}

/// Past chats in a popover, grouped by date with a search field. Click to open; right-click to rename or delete.
@MainActor
final class AgentHistoryController: NSViewController, NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate {
    var onSelect: ((String) -> Void)?
    var onRename: ((String) -> Void)?
    var onDelete: ((String) -> Void)?

    private enum Row {
        case section(String)
        case chat(AgentChat)
    }

    private var chats: [AgentChat] = []
    private var running: Set<String> = []
    private var selected: String?
    private var rows: [Row] = []
    private let search = NSSearchField()
    private let table = NSTableView()
    private let empty = NSTextField(labelWithString: "")
    private let times: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return formatter
    }()
    private let days: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "M/d"
        return formatter
    }()

    override func loadView() {
        let root = NSView(frame: CGRect(x: 0, y: 0, width: 320, height: 440))
        search.placeholderString = L("Search chats", "搜索对话")
        search.delegate = self
        search.controlSize = .large
        let column = NSTableColumn(identifier: .init("chat"))
        table.addTableColumn(column)
        table.headerView = nil
        table.style = .plain
        table.backgroundColor = .clear
        table.intercellSpacing = CGSize(width: 0, height: 2)
        table.selectionHighlightStyle = .regular
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.action = #selector(openClicked)
        table.menu = NSMenu()
        table.menu?.addItem(withTitle: L("Rename…", "重命名…"), action: #selector(renameClicked), keyEquivalent: "").target = self
        table.menu?.addItem(withTitle: L("Delete…", "删除…"), action: #selector(deleteClicked), keyEquivalent: "").target = self
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.scrollerStyle = .overlay
        scroll.verticalScroller = ThinScroller()
        scroll.autohidesScrollers = true
        empty.font = .systemFont(ofSize: 13)
        empty.textColor = .secondaryLabelColor
        empty.alignment = .center
        for view in [search, scroll, empty] {
            view.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(view)
        }
        NSLayoutConstraint.activate([
            search.topAnchor.constraint(equalTo: root.topAnchor, constant: 12),
            search.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 12),
            search.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -12),
            scroll.topAnchor.constraint(equalTo: search.bottomAnchor, constant: 8),
            // Edge to edge, so the scroller sits at the popover's right edge; rows inset themselves.
            scroll.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -8),
            empty.centerXAnchor.constraint(equalTo: root.centerXAnchor),
            empty.centerYAnchor.constraint(equalTo: scroll.centerYAnchor)
        ])
        view = root
    }

    func show(_ chats: [AgentChat], selected: String?, running: Set<String>) {
        self.chats = chats
        self.selected = selected
        self.running = running
        guard isViewLoaded else { return }
        rebuild()
    }

    override func viewWillAppear() {
        super.viewWillAppear()
        search.stringValue = ""
        rebuild()
        view.window?.makeFirstResponder(search)
    }

    func controlTextDidChange(_ obj: Notification) { rebuild() }

    private func rebuild() {
        let query = search.stringValue.trimmingCharacters(in: .whitespaces)
        let matches = query.isEmpty ? chats : chats.filter { $0.title.localizedCaseInsensitiveContains(query) }
        let calendar = Calendar.current
        let weekAgo = calendar.date(byAdding: .day, value: -7, to: calendar.startOfDay(for: Date())) ?? .distantPast
        let groups: [(String, [AgentChat])] = [
            (L("Today", "今天"), matches.filter { calendar.isDateInToday($0.updatedAt) }),
            (L("Previous 7 Days", "过去 7 天"), matches.filter { !calendar.isDateInToday($0.updatedAt) && $0.updatedAt >= weekAgo }),
            (L("Earlier", "更早"), matches.filter { $0.updatedAt < weekAgo })
        ]
        rows = groups.filter { !$0.1.isEmpty }.flatMap { title, chats in [Row.section(title)] + chats.map(Row.chat) }
        table.reloadData()
        if let index = rows.firstIndex(where: { if case .chat(let chat) = $0 { return chat.id == selected }; return false }) {
            table.selectRowIndexes([index], byExtendingSelection: false)
        }
        empty.stringValue = chats.isEmpty ? L("No chats yet", "还没有对话") : L("No matching chats", "没有匹配的对话")
        empty.isHidden = !rows.isEmpty
    }

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        if case .section = rows[row] { return 30 }
        return 40
    }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
        if case .chat = rows[row] { return true }
        return false
    }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        let view = HistoryRowView()
        if case .chat = rows[row] { view.isHoverable = true }
        return view
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let cell = NSTableCellView()
        switch rows[row] {
        case .section(let title):
            let label = NSTextField(labelWithString: title)
            label.font = .systemFont(ofSize: 12, weight: .semibold)
            label.textColor = .tertiaryLabelColor
            label.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(label)
            NSLayoutConstraint.activate([
                label.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 16),
                label.bottomAnchor.constraint(equalTo: cell.bottomAnchor, constant: -4)
            ])
        case .chat(let chat):
            let title = NSTextField(labelWithString: chat.title)
            title.font = .systemFont(ofSize: 13)
            title.lineBreakMode = .byTruncatingTail
            title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            let isRunning = running.contains(chat.id)
            let date = NSTextField(labelWithString: isRunning
                ? L("Working…", "处理中…")
                : (Calendar.current.isDateInToday(chat.updatedAt) ? times : days).string(from: chat.updatedAt))
            date.font = .systemFont(ofSize: 12)
            date.textColor = isRunning ? Brand.accent : .tertiaryLabelColor
            date.setContentCompressionResistancePriority(.required, for: .horizontal)
            let thumbnail = thumbnailView(for: chat)
            for view in [thumbnail, title, date] {
                view.translatesAutoresizingMaskIntoConstraints = false
                cell.addSubview(view)
            }
            NSLayoutConstraint.activate([
                thumbnail.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 14),
                thumbnail.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                thumbnail.widthAnchor.constraint(equalToConstant: Self.thumbnailSize),
                thumbnail.heightAnchor.constraint(equalToConstant: Self.thumbnailSize),
                title.leadingAnchor.constraint(equalTo: thumbnail.trailingAnchor, constant: 10),
                title.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                title.trailingAnchor.constraint(lessThanOrEqualTo: date.leadingAnchor, constant: -10),
                date.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -16),
                date.centerYAnchor.constraint(equalTo: cell.centerYAnchor)
            ])
        }
        return cell
    }

    private static let thumbnailSize: CGFloat = 26
    /// Square crops of each chat's first image, keyed by "chat/image", so scrolling never rescales full images.
    private var thumbnails: [String: NSImage] = [:]

    /// The chat's first image, cropped square; a plain chat bubble icon when it has none.
    private func thumbnailView(for chat: AgentChat) -> NSView {
        let view = NSImageView()
        view.wantsLayer = true
        view.layer?.cornerRadius = 6
        view.layer?.masksToBounds = true
        if let name = ImageAgentStore.shared.allImages(in: chat).first, let image = thumbnail(name, in: chat.id) {
            view.image = image
            view.imageScaling = .scaleAxesIndependently
            view.layer?.borderWidth = 0.5
            view.layer?.borderColor = NSColor.separatorColor.cgColor
        } else {
            view.image = NSImage(systemSymbolName: "bubble.left", accessibilityDescription: nil)
            view.symbolConfiguration = .init(pointSize: 14, weight: .regular)
            view.contentTintColor = .tertiaryLabelColor
        }
        return view
    }

    private func thumbnail(_ name: String, in chatID: String) -> NSImage? {
        let key = "\(chatID)/\(name)"
        if let cached = thumbnails[key] { return cached }
        guard let source = ImageAgentStore.shared.image(name, in: chatID), source.size.width > 0, source.size.height > 0 else { return nil }
        let pixels = Self.thumbnailSize * 2
        let side = min(source.size.width, source.size.height)
        let crop = CGRect(x: (source.size.width - side) / 2, y: (source.size.height - side) / 2, width: side, height: side)
        let image = NSImage(size: CGSize(width: pixels, height: pixels), flipped: false) { rect in
            source.draw(in: rect, from: crop, operation: .copy, fraction: 1)
            return true
        }
        // Render once so the full image isn't drawn again on every redraw.
        guard let rendered = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        let result = NSImage(cgImage: rendered, size: CGSize(width: Self.thumbnailSize, height: Self.thumbnailSize))
        thumbnails[key] = result
        return result
    }

    private func chat(at row: Int) -> String? {
        guard rows.indices.contains(row), case .chat(let chat) = rows[row] else { return nil }
        return chat.id
    }

    @objc private func openClicked() { chat(at: table.clickedRow).map { onSelect?($0) } }
    @objc private func renameClicked() { chat(at: table.clickedRow).map { onRename?($0) } }
    @objc private func deleteClicked() { chat(at: table.clickedRow).map { onDelete?($0) } }
}

/// A history row: a rounded fill inset from the popover's edges when hovered or selected.
@MainActor
private final class HistoryRowView: NSTableRowView {
    var isHoverable = false
    private var hovering = false { didSet { if hovering != oldValue { needsDisplay = true } } }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        guard isHoverable else { return }
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }

    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false }

    private var fillRect: NSRect { bounds.insetBy(dx: 6, dy: 1) }

    override func drawBackground(in dirtyRect: NSRect) {
        guard hovering, !isSelected else { return }
        NSColor.labelColor.withAlphaComponent(0.06).setFill()
        NSBezierPath(roundedRect: fillRect, xRadius: 7, yRadius: 7).fill()
    }

    override func drawSelection(in dirtyRect: NSRect) {
        NSColor.labelColor.withAlphaComponent(0.11).setFill()
        NSBezierPath(roundedRect: fillRect, xRadius: 7, yRadius: 7).fill()
    }
}

/// The large view of one image in the chat, its actions, and a filmstrip of all the chat's images.
@MainActor
final class AgentPreviewPane: NSView {
    enum Action { case edit, library, copy, save }
    var onSelect: ((String) -> Void)?
    var onClose: (() -> Void)?
    var onAction: ((Action) -> Void)?
    var onQuickLook: ((String) -> Void)?
    var imageMenu: ((String) -> NSMenu?)?

    private var selected: String?
    private let counter = NSTextField(labelWithString: "")
    private let imageView = AgentImageView()
    private let filmstrip = NSStackView()
    private let filmstripScroll = NSScrollView()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        counter.font = .systemFont(ofSize: 15, weight: .semibold)
        counter.lineBreakMode = .byTruncatingTail
        counter.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let buttons: [(String, String, Selector)] = [
            ("pencil", L("Open in Editor", "在编辑器中打开"), #selector(editImage)),
            ("photo.badge.plus", L("Save to Library", "保存到截图库"), #selector(saveToLibrary)),
            ("doc.on.doc", L("Copy Image", "复制图片"), #selector(copyImage)),
            ("square.and.arrow.down", L("Save PNG…", "保存 PNG…"), #selector(saveImage)),
            ("xmark", L("Close", "关闭"), #selector(closePreview))
        ]
        let actions = buttons.map { symbol, title, action -> NSButton in
            let button = NSButton(image: NSImage(systemSymbolName: symbol, accessibilityDescription: title)!, target: self, action: action)
            button.isBordered = false
            button.contentTintColor = .secondaryLabelColor
            button.toolTip = title
            button.symbolConfiguration = .init(pointSize: 14, weight: .regular)
            return button
        }
        let header = NSStackView(views: [counter, NSView()] + actions)
        header.spacing = 14
        header.heightAnchor.constraint(equalToConstant: 32).isActive = true

        imageView.imageScaling = .scaleProportionallyDown
        imageView.onDoubleClick = { [weak self] in
            guard let self, let selected else { return }
            onQuickLook?(selected)
        }
        imageView.contextMenu = { [weak self] in self?.selected.flatMap { self?.imageMenu?($0) } }
        // Lowest of all, so a large image never widens the pane.
        imageView.setContentCompressionResistancePriority(.init(100), for: .vertical)
        imageView.setContentCompressionResistancePriority(.init(100), for: .horizontal)
        imageView.setContentHuggingPriority(.defaultLow, for: .vertical)

        filmstrip.spacing = 8
        filmstrip.translatesAutoresizingMaskIntoConstraints = false
        let document = FlippedView()
        document.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(filmstrip)
        filmstripScroll.documentView = document
        filmstripScroll.drawsBackground = false
        filmstripScroll.hasHorizontalScroller = true
        filmstripScroll.scrollerStyle = .overlay
        filmstripScroll.horizontalScroller = ThinScroller()
        filmstripScroll.autohidesScrollers = true

        for view in [header, imageView, filmstripScroll] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: topAnchor, constant: 14),
            header.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 18),
            header.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            imageView.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 16),
            imageView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 18),
            imageView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -18),
            filmstripScroll.topAnchor.constraint(equalTo: imageView.bottomAnchor, constant: 14),
            filmstripScroll.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            filmstripScroll.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            filmstripScroll.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -12),
            filmstripScroll.heightAnchor.constraint(equalToConstant: 76),
            document.topAnchor.constraint(equalTo: filmstripScroll.contentView.topAnchor),
            document.heightAnchor.constraint(equalTo: filmstripScroll.contentView.heightAnchor),
            filmstrip.topAnchor.constraint(equalTo: document.topAnchor, constant: 4),
            filmstrip.leadingAnchor.constraint(equalTo: document.leadingAnchor),
            filmstrip.trailingAnchor.constraint(equalTo: document.trailingAnchor)
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func show(chatID: String, names: [String], selected: String) {
        self.selected = selected
        let index = names.firstIndex(of: selected) ?? 0
        counter.stringValue = L("Image \(index + 1) of \(names.count)", "第 \(index + 1) 张，共 \(names.count) 张")
        imageView.image = ImageAgentStore.shared.image(selected, in: chatID)
        filmstrip.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for name in names {
            guard let image = ImageAgentStore.shared.image(name, in: chatID) else { continue }
            let thumb = AgentThumbnail(image: image, maxSize: CGSize(width: 64, height: 64), cornerRadius: 8) { [weak self] in
                self?.onSelect?(name)
            }
            thumb.onDoubleClick = { [weak self] in self?.onQuickLook?(name) }
            thumb.contextMenu = { [weak self] in self?.imageMenu?(name) }
            if name == selected {
                thumb.layer?.borderWidth = 2
                thumb.layer?.borderColor = Brand.accent.cgColor
            }
            filmstrip.addArrangedSubview(thumb)
        }
        filmstripScroll.isHidden = names.count < 2
    }

    @objc private func editImage() { onAction?(.edit) }
    @objc private func saveToLibrary() { onAction?(.library) }
    @objc private func copyImage() { onAction?(.copy) }
    @objc private func saveImage() { onAction?(.save) }
    @objc private func closePreview() { onClose?() }
}
