import AppKit
@preconcurrency import Translation

@MainActor
final class TextActionsPane: SectionedPageView {
    private let preferences: TextActionPreferences
    private let autoCopy = NSButton(checkboxWithTitle: L("Automatically copy results", "完成后自动复制到剪贴板"), target: nil, action: nil)
    private let sideNotice = NSButton(checkboxWithTitle: L("Show a right-side text notification", "在屏幕右侧显示文字提示"), target: nil, action: nil)
    private let sound = NSButton(checkboxWithTitle: L("Play a feedback sound", "播放完成 / 失败提示音"), target: nil, action: nil)
    private let resultWindow = NSButton(checkboxWithTitle: L("Open the editable result window", "自动打开可编辑的结果窗口"), target: nil, action: nil)
    private let format = NSPopUpButton()
    private let provider = NSPopUpButton()
    private let baiduID = NSTextField()
    private let baiduSecret = NSSecureTextField()
    private let saveBaidu = NSButton(title: L("Save Baidu Configuration", "保存百度配置"), target: nil, action: nil)
    private let testBaidu = NSButton(title: L("Test Connection", "测试连接"), target: nil, action: nil)
    private let showBaiduGuide = NSButton(title: L("Registration & Setup Guide ▸", "注册与申请指引 ▸"), target: nil, action: nil)
    private let baiduGuide = NSStackView()
    private let testTranslation: (String, Locale.Language, BaiduTranslationCredentials) async throws -> String
    private(set) var baiduTestTask: Task<Void, Never>?
    private let baiduStatus = NSTextField(wrappingLabelWithString: L("Your secret is stored only in this Mac's Keychain, never in plain-text settings.", "密钥仅保存在本机钥匙串，不写入明文设置。"))
    private let targetLanguage = NSPopUpButton()
    private let sourceLanguage = NSPopUpButton()
    private let downloadLanguages = NSButton(title: L("Check / Download Language Packs", "检查 / 下载翻译语言包"), target: nil, action: nil)
    private let languageStatus = NSTextField(wrappingLabelWithString: L("Only needed for system translation, not Baidu.", "仅系统翻译需要语言包，使用百度翻译无需下载。"))
    private var targetIDs: [String] { ["auto"] + TranslationTargets.all.map(\.identifier) }

    init(preferences: TextActionPreferences = TextActionPreferences(),
         openOfficialURL: @escaping (URL) -> Bool = { NSWorkspace.shared.open($0) },
         testTranslation: @escaping (String, Locale.Language, BaiduTranslationCredentials) async throws -> String = {
             try await BaiduTextTranslator.translate($0, target: $1, credentials: $2)
         }) {
        self.preferences = preferences
        self.testTranslation = testTranslation
        super.init(title: L("OCR & Translation", "文字识别与翻译"))
        for (button, identifier) in [(autoCopy, "textActions.autoCopy"), (sideNotice, "textActions.sideNotice"),
                                      (sound, "textActions.sound"), (resultWindow, "textActions.resultWindow")] {
            button.target = self
            button.action = #selector(saveSwitches)
            button.identifier = NSUserInterfaceItemIdentifier(identifier)
            button.setAccessibilityIdentifier(identifier)
        }
        addSection(L("After recognition or translation", "识别 / 翻译完成后"), rows: [
            Self.row(autoCopy, hint: L("Area OCR copies the formatted text; selected-text translation copies the translation.", "框选识别复制整理后的文字；选中文字翻译复制译文。默认开启。")),
            Self.row(sideNotice, hint: L("A translucent, multiline preview appears at the top right for 5–12 seconds without taking focus or blocking clicks.", "右上角显示半透明多行预览，按内容停留 5–12 秒；不抢焦点、不挡鼠标。")),
            Self.row(sound, hint: L("Uses system sounds and follows the system volume. Can be disabled independently.", "使用系统音效并遵循系统音量，可单独关闭。")),
            Self.row(resultWindow, hint: L("Off by default. You can always open the last result from the Snapok menu.", "默认关闭，不再自动弹出编辑框；仍可从 Snapok 菜单手动查看上次结果。"))
        ])
        add(Self.footnote(L("Turn off both the notification and sound for silent operation. If it fails, the clipboard stays unchanged; use Show Last OCR / Translation Result in the menu to view the reason.", "同时关闭右侧提示和音效即可静默处理。失败不会覆盖剪贴板；可从菜单「查看上次识别 / 翻译结果」查看原因。")), spacingBefore: 8)
        format.addItems(withTitles: OCRFormat.allCases.map(\.title))
        format.target = self
        format.action = #selector(saveFormat)
        format.identifier = NSUserInterfaceItemIdentifier("textActions.format")
        format.setAccessibilityLabel(L("OCR text formatting", "识别文字格式"))
        addSection(L("Area OCR", "框选文字识别"), rows: [Self.row(format, title: L("Text formatting", "文字格式"), hint: L("Smart paragraphs join wrapped text while keeping blank lines and lists. Existing format choices are preserved.", "智能段落合并断行并保留空行和列表；保留你之前选择的格式。"))])
        provider.addItems(withTitles: TextTranslationProvider.allCases.map(\.title))
        provider.target = self
        provider.action = #selector(saveProvider)
        provider.identifier = NSUserInterfaceItemIdentifier("textActions.provider")
        provider.setAccessibilityLabel(L("Translation service", "翻译服务"))
        addSection(L("Translation service", "翻译服务"), rows: [Self.row(provider, hint: L("Baidu sends the selected text to Baidu via HTTPS. Area OCR stays on-device. No automatic provider switching.", "百度翻译会通过 HTTPS 将选中文字发送至百度；框选 OCR 仍在本机处理。不会自动切换服务。"))])
        baiduID.placeholderString = "APP ID"
        baiduID.identifier = NSUserInterfaceItemIdentifier("textActions.baiduAppID")
        baiduID.setAccessibilityLabel("Baidu APP ID")
        baiduSecret.placeholderString = L("Secret (leave blank to keep saved secret)", "密钥（已保存时留空不更改）")
        baiduSecret.identifier = NSUserInterfaceItemIdentifier("textActions.baiduSecret")
        baiduSecret.setAccessibilityLabel(L("Baidu secret", "百度密钥"))
        saveBaidu.target = self
        saveBaidu.action = #selector(saveBaiduConfiguration)
        saveBaidu.bezelStyle = .rounded
        saveBaidu.identifier = NSUserInterfaceItemIdentifier("textActions.saveBaidu")
        testBaidu.target = self
        testBaidu.action = #selector(testBaiduConfiguration)
        testBaidu.bezelStyle = .rounded
        testBaidu.identifier = NSUserInterfaceItemIdentifier("textActions.testBaidu")
        testBaidu.setAccessibilityIdentifier("textActions.testBaidu")
        let baiduButtons = NSStackView(views: [saveBaidu, testBaidu])
        baiduButtons.orientation = .horizontal
        baiduButtons.spacing = 10
        baiduStatus.identifier = NSUserInterfaceItemIdentifier("textActions.baiduStatus")
        baiduStatus.font = .systemFont(ofSize: 12)
        baiduStatus.textColor = .secondaryLabelColor
        baiduStatus.maximumNumberOfLines = 0
        baiduStatus.setAccessibilityElement(true)
        showBaiduGuide.target = self
        showBaiduGuide.action = #selector(toggleBaiduGuide)
        showBaiduGuide.bezelStyle = .rounded
        showBaiduGuide.identifier = NSUserInterfaceItemIdentifier("textActions.baiduGuideToggle")
        baiduGuide.orientation = .vertical
        baiduGuide.alignment = .leading
        baiduGuide.spacing = 10
        baiduGuide.identifier = NSUserInterfaceItemIdentifier("textActions.baiduGuide")
        let platformButton = Self.officialLink(
            L("Go to Baidu Translate Open Platform ↗", "前往百度翻译开放平台 ↗"),
            url: "https://fanyi-api.baidu.com/", identifier: "textActions.baiduPlatform",
            prominent: true, openURL: openOfficialURL)
        let platformAddress = Self.officialLink(
            "https://fanyi-api.baidu.com/ ↗", url: "https://fanyi-api.baidu.com/",
            identifier: "textActions.baiduPlatformAddress", openURL: openOfficialURL)
        baiduGuide.addArrangedSubview(platformAddress)
        let guideSteps = [
            L("1. Click the platform button or the website address above to open the official site in your browser. Sign in with your own Baidu account, and register as a developer if prompted.", "1. 点击上方「前往百度翻译开放平台」或网址，即可在浏览器打开官方平台。用自己的百度账号登录，按页面提示注册开发者。"),
            L("2. In the console, enable General Text Translation. Complete personal / business verification if required for your chosen plan. Menu names may change.", "2. 在管理控制台申请开通「通用文本翻译」；若选择的版本要求认证，按官方页面完成个人 / 企业认证。菜单名称可能随平台更新。"),
            L("3. In application / developer information, find the matching APP ID and secret. This adapter uses General Text Translation signing, not an AI Cloud API Key or token.", "3. 在应用 / 开发者信息中找到同一应用配套的 APP ID 和密钥。本软件这里接入的是「通用文本翻译」签名接口，不是其他产品的 API Key / Token。"),
            L("4. Paste the APP ID and secret above. Click Test Connection to translate only ‘Hello’, then save when successful. An empty secret field reuses the saved secret for the same APP ID.", "4. 将 APP ID 和密钥填到上方，点击「测试连接」，成功后再保存。测试仅翻译 Hello；密钥留空时仅可复用同一 APP ID 已保存的密钥。"),
            L("5. Confirm service activation, current free character allowance, rate limits and overage charges in Baidu's console. Credentials alone do not grant a particular free plan. Test requests also count toward usage; this app cannot read your remaining quota.", "5. 在百度控制台确认已开通服务、当前免费字符额度、频率和超额计费。获得密钥不等于获得特定免费版本；测试也计入用量，本软件无法查询剩余额度。"),
            L("Keep passwords, verification codes and secrets private. The guide works offline; official links need a network connection. Never send credentials in chat.", "密码、验证码和密钥仅在官方页面或本机填写。此指引可离线查看，官方链接需联网；不要把密钥发到聊天里。")
        ]
        for step in guideSteps {
            let label = NSTextField(wrappingLabelWithString: step)
            label.font = .systemFont(ofSize: 12)
            label.textColor = .secondaryLabelColor
            baiduGuide.addArrangedSubview(label)
            label.widthAnchor.constraint(equalTo: baiduGuide.widthAnchor).isActive = true
        }
        let links = NSStackView(views: [
            Self.officialLink(L("Official API Documentation ↗", "官方接口文档 ↗"), url: "https://fanyi-api.baidu.com/doc/23", identifier: "textActions.baiduAPIDocs", openURL: openOfficialURL),
            Self.officialLink(L("Official Pricing & Allowances ↗", "官方价格与额度 ↗"), url: "https://fanyi-api.baidu.com/product/112", identifier: "textActions.baiduPricing", openURL: openOfficialURL)
        ])
        links.orientation = .vertical
        links.alignment = .leading
        links.spacing = 8
        baiduGuide.addArrangedSubview(links)
        baiduGuide.isHidden = true
        let guideContainer = NSStackView(views: [platformButton, showBaiduGuide, baiduGuide])
        guideContainer.orientation = .vertical
        guideContainer.alignment = .leading
        guideContainer.spacing = 12
        baiduGuide.widthAnchor.constraint(equalTo: guideContainer.widthAnchor).isActive = true
        addSection(L("Baidu General Text Translation", "百度通用文本翻译"), rows: [
            Self.row(baiduID, title: "APP ID", hint: L("Use your own Baidu Translate Open Platform APP ID with General Text Translation enabled.", "填写你在百度翻译开放平台开通「通用文本翻译」服务的 APP ID。")),
            Self.row(baiduSecret, title: L("Secret", "密钥"), hint: L("Enter the matching secret here, not in chat. Saving does not send a translation request.", "在这里填写配套密钥，不要发送到聊天中；保存不会发起翻译请求。")),
            Self.row(baiduButtons, hint: L("Test uses the current fields without saving: sends only Hello to Baidu, counts toward usage and leaves your clipboard unchanged.", "测试直接使用当前填写内容，无需先保存；仅发送 Hello 到百度，计入用量，不改剪贴板或已有配置。")),
            Self.row(baiduStatus, hint: L("Your own account's quota and pricing apply. Test success confirms this request only, not your remaining free allowance.", "调用使用你自己的百度账户额度；测试成功只说明本次请求可用，不代表还有免费额度。")),
            Self.row(guideContainer, hint: L("The platform button opens the official website in your default browser, even with this guide collapsed. Expand the guide for setup steps; never share credentials in chat.", "平台按钮可直接在默认浏览器打开官方网站，无需先展开指引。展开可查看申请步骤；无需在聊天里提供任何密钥。"))
        ])
        targetLanguage.addItem(withTitle: L("Auto: Chinese → English; others → Chinese", "自动：中文译英文，其他语言译中文"))
        targetLanguage.addItems(withTitles: TranslationTargets.all.map(\.name))
        targetLanguage.target = self
        targetLanguage.action = #selector(saveLanguage)
        targetLanguage.identifier = NSUserInterfaceItemIdentifier("textActions.targetLanguage")
        targetLanguage.setAccessibilityLabel(L("Translation target language", "翻译目标语言"))
        targetLanguage.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        addSection(L("Selected-text translation", "选中文字翻译"), rows: [Self.row(targetLanguage, title: L("Target language", "目标语言"), hint: L("Select actual text in another app, then press your shortcut. Baidu needs network access, not system language packs.", "在其他应用中选中实际文本后按快捷键；百度翻译需要联网，不需要下载系统语言包。"))])
        sourceLanguage.addItems(withTitles: TranslationTargets.all.map(\.name))
        sourceLanguage.selectItem(at: 2)
        sourceLanguage.setAccessibilityLabel(L("Language pack source language", "语言包原文语言"))
        sourceLanguage.identifier = NSUserInterfaceItemIdentifier("textActions.packSource")
        downloadLanguages.target = self
        downloadLanguages.action = #selector(prepareLanguages)
        downloadLanguages.bezelStyle = .rounded
        downloadLanguages.identifier = NSUserInterfaceItemIdentifier("textActions.downloadLanguages")
        languageStatus.font = .systemFont(ofSize: 12)
        languageStatus.textColor = .secondaryLabelColor
        addSection(L("System translation language packs (optional)", "系统翻译语言包（可选）"), rows: [
            Self.row(sourceLanguage, title: L("Source language to prepare", "需要准备的原文语言"), hint: L("Choose the source language here; the target follows the setting above. This does not change automatic source detection.", "这里选择原文语言，目标语言沿用上方设置；不会影响划词时的自动语言识别。")),
            Self.row(downloadLanguages, hint: L("Only clicking this button opens the system download prompt. A missing pack never opens a result window or replaces the clipboard.", "仅点击此按钮时请求系统下载。日常划词缺少语言包时不会弹出结果框，也不会覆盖剪贴板。")),
            Self.row(languageStatus, hint: L("Language downloads require a network connection and your confirmation in the system prompt.", "下载语言包需要联网，并由你在系统提示中确认。"))
        ])
        add(Self.footnote(L("Shortcuts remain customizable under Shortcuts → Global.", "快捷键仍在「快捷键 → 全局快捷键」中自定义。")), spacingBefore: 8)
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "development"
        add(Self.footnote(L("Multiline glass notice · Connection test · Platform shortcut · Build \(build)", "多行透明浮窗 · 连接测试 · 平台直达入口 · 构建 \(build)")), spacingBefore: 6)
        load()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func load() {
        provider.selectItem(at: TextTranslationProvider.allCases.firstIndex(of: preferences.translationProvider) ?? 0)
        baiduID.stringValue = preferences.baiduAppID
        baiduSecret.stringValue = ""
        refreshProviderControls()
        autoCopy.state = preferences.autoCopy ? .on : .off
        sideNotice.state = preferences.showSideNotice ? .on : .off
        sound.state = preferences.playSound ? .on : .off
        resultWindow.state = preferences.showResultWindow ? .on : .off
        format.selectItem(at: preferences.format.rawValue)
        targetLanguage.selectItem(at: targetIDs.firstIndex(of: preferences.translationTarget) ?? 0)
    }

    private func refreshProviderControls() {
        let usesBaidu = preferences.translationProvider == .baidu
        let testing = baiduTestTask != nil
        provider.isEnabled = !testing
        baiduID.isEnabled = usesBaidu && !testing
        baiduSecret.isEnabled = usesBaidu && !testing
        saveBaidu.isEnabled = usesBaidu && !testing
        testBaidu.isEnabled = usesBaidu && !testing
        sourceLanguage.isEnabled = !usesBaidu
        downloadLanguages.isEnabled = !usesBaidu
    }
    @objc private func saveProvider() {
        let index = provider.indexOfSelectedItem
        guard TextTranslationProvider.allCases.indices.contains(index) else { return }
        preferences.translationProvider = TextTranslationProvider.allCases[index]
        refreshProviderControls()
    }
    private func credentialsFromFields() throws -> BaiduTranslationCredentials {
        let id = baiduID.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        var secret = baiduSecret.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty, id.allSatisfy({ $0.isASCII && $0.isNumber }) else {
            throw BaiduTranslationError.missingAppID
        }
        if secret.isEmpty {
            guard let existing = try? BaiduTranslationCredentialStore.load(), existing.appID == id else {
                throw BaiduTranslationError.missingSecret
            }
            secret = existing.secret
        }
        return BaiduTranslationCredentials(appID: id, secret: secret)
    }

    private func setBaiduStatus(_ text: String, failed: Bool = false) {
        baiduStatus.textColor = failed ? .systemOrange : .secondaryLabelColor
        baiduStatus.stringValue = text
        baiduStatus.setAccessibilityLabel(text)
        NSAccessibility.post(element: baiduStatus, notification: .valueChanged)
    }

    @objc private func saveBaiduConfiguration() {
        do {
            let credentials = try credentialsFromFields()
            try BaiduTranslationCredentialStore.save(credentials)
            preferences.baiduAppID = credentials.appID
            baiduSecret.stringValue = ""
            setBaiduStatus(L("Saved securely. Click Test Connection to verify the saved configuration.", "配置已安全保存，可点击「测试连接」验证。"))
        } catch { setBaiduStatus(error.localizedDescription, failed: true) }
    }

    @objc private func testBaiduConfiguration() {
        guard baiduTestTask == nil else { return }
        let credentials: BaiduTranslationCredentials
        do { credentials = try credentialsFromFields() }
        catch { setBaiduStatus(error.localizedDescription, failed: true); return }
        setBaiduStatus(L("Testing Baidu with Hello → Chinese… (up to 25 seconds)", "正在测试百度：Hello → 中文…（最长约 25 秒）"))
        testBaidu.title = L("Testing…", "测试中…")
        baiduTestTask = Task { [weak self] in
            guard let self else { return }
            defer {
                self.baiduTestTask = nil
                self.testBaidu.title = L("Test Connection", "测试连接")
                self.refreshProviderControls()
            }
            do {
                let translated = try await self.testTranslation("Hello", Locale.Language(identifier: "zh-Hans"), credentials)
                guard !translated.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    throw BaiduTranslationError.invalidResponse
                }
                self.setBaiduStatus(L("Connection successful: Hello → \(String(translated.prefix(120)))\nCurrent fields were tested; no settings or clipboard changed. Save if you edited the credentials.", "连接成功：Hello → \(String(translated.prefix(120)))\n已验证当前填写内容，未改设置或剪贴板；若修改过配置，请再点击保存。"))
            } catch {
                // Only show known service codes or safe URL errors, never arbitrary response text.
                let reason: String
                if error is BaiduTranslationError { reason = error.localizedDescription }
                else if let network = error as? URLError { reason = L("Network error (\(network.code.rawValue)). Check your connection or try again later.", "网络请求失败（\(network.code.rawValue)），请检查网络或稍后重试。") }
                else { reason = L("Could not complete the request. Try again later.", "请求未能完成，请稍后重试。") }
                self.setBaiduStatus(L("Test failed: \(reason)", "测试失败：\(reason)"), failed: true)
            }
        }
        refreshProviderControls()
    }

    @objc private func toggleBaiduGuide() {
        baiduGuide.isHidden.toggle()
        showBaiduGuide.title = baiduGuide.isHidden
            ? L("Registration & Setup Guide ▸", "注册与申请指引 ▸")
            : L("Hide Registration & Setup Guide ▾", "收起注册与申请指引 ▾")
        needsLayout = true
    }

    private static func officialLink(_ title: String, url: String, identifier: String,
                                     prominent: Bool = false, openURL: @escaping (URL) -> Bool) -> NSButton {
        let button = BaiduOfficialLinkButton(title: title, url: url, openURL: openURL)
        button.identifier = NSUserInterfaceItemIdentifier(identifier)
        button.setAccessibilityIdentifier(identifier)
        if prominent { button.bezelStyle = .rounded }
        return button
    }

    @objc private func saveSwitches() {
        preferences.autoCopy = autoCopy.state == .on
        preferences.showSideNotice = sideNotice.state == .on
        preferences.playSound = sound.state == .on
        preferences.showResultWindow = resultWindow.state == .on
    }
    @objc private func saveFormat() { preferences.format = OCRFormat(rawValue: format.indexOfSelectedItem) ?? .paragraphs }
    @objc private func saveLanguage() {
        guard targetIDs.indices.contains(targetLanguage.indexOfSelectedItem) else { return }
        preferences.translationTarget = targetIDs[targetLanguage.indexOfSelectedItem]
    }

    @objc private func prepareLanguages() {
        guard #available(macOS 26.0, *) else {
            languageStatus.stringValue = SystemTranslationError.unavailable.localizedDescription
            return
        }
        let index = sourceLanguage.indexOfSelectedItem
        guard TranslationTargets.all.indices.contains(index), window != nil else { return }
        let sourceID = TranslationTargets.all[index].identifier
        let targetID = preferences.translationTarget == "auto" ? (sourceID.hasPrefix("zh") ? "en" : "zh-Hans") : preferences.translationTarget
        guard sourceID != targetID else {
            languageStatus.stringValue = L("Source and target are the same. Select a different source language.", "原文和目标语言相同，请选择需要翻译的另一种原文语言。")
            return
        }
        let source = Locale.Language(identifier: sourceID)
        let target = Locale.Language(identifier: targetID)
        downloadLanguages.isEnabled = false
        languageStatus.stringValue = L("Checking translation language packs…", "正在检查翻译语言包…")
        Task { [weak self] in
            guard let self else { return }
            defer { self.downloadLanguages.isEnabled = true }
            switch await LanguageAvailability().status(from: source, to: target) {
            case .installed:
                self.languageStatus.stringValue = L("Language packs ready. You can translate selected text now.", "语言包已就绪，可以使用选中文字翻译。")
            case .supported:
                self.languageStatus.stringValue = L("Confirm the system download prompt, then wait for it to finish.", "请在系统提示中确认下载，并等待完成。")
                let downloaded = await SystemTranslationDownload.request(from: source, to: target)
                let status = await LanguageAvailability().status(from: source, to: target)
                self.languageStatus.stringValue = downloaded && status == .installed
                    ? L("Language packs ready. You can translate selected text now.", "语言包已就绪，可以使用选中文字翻译。")
                    : L("Download not completed. You can retry when ready.", "语言包尚未下载完成，可稍后重试。")
            default:
                self.languageStatus.stringValue = L("System translation does not support this language pair.", "系统翻译暂不支持这组语言。")
            }
        }
    }

    private static func row(_ control: NSView, title: String? = nil, hint: String) -> NSView {
        var views: [NSView] = []
        if let title {
            let label = NSTextField(labelWithString: title)
            label.font = .systemFont(ofSize: 13, weight: .medium)
            views.append(label)
        }
        views.append(control)
        let note = NSTextField(wrappingLabelWithString: hint)
        note.font = .systemFont(ofSize: 12)
        note.textColor = .secondaryLabelColor
        views.append(note)
        let stack = NSStackView(views: views)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        stack.edgeInsets = NSEdgeInsets(top: 12, left: 18, bottom: 12, right: 18)
        note.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -36).isActive = true
        control.widthAnchor.constraint(lessThanOrEqualTo: stack.widthAnchor, constant: -36).isActive = true
        if control is NSStackView {
            control.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -36).isActive = true
        }
        if let field = control as? NSTextField, field.isEditable || field.maximumNumberOfLines == 0 {
            field.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -36).isActive = true
        }
        return stack
    }
}

@MainActor
private final class BaiduOfficialLinkButton: NSButton {
    private let officialURL: URL
    private let openURL: (URL) -> Bool
    init(title: String, url: String, openURL: @escaping (URL) -> Bool) {
        officialURL = URL(string: url)!
        self.openURL = openURL
        super.init(frame: .zero)
        self.title = title
        bezelStyle = .inline
        contentTintColor = .linkColor
        toolTip = officialURL.absoluteString
        setAccessibilityLabel(title)
        setAccessibilityHelp(L("Open the official website in your default browser.", "在默认浏览器打开官方网站。") + "\n" + officialURL.absoluteString)
        target = self
        action = #selector(openOfficialLink)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    @objc private func openOfficialLink() {
        if !openURL(officialURL) { NSSound.beep() }
    }
}
