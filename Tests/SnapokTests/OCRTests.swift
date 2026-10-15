import AppKit
import Carbon

extension Bundle { static var module: Bundle { .main } }

@main @MainActor
struct OCRTests {
    static func main() async {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        if ProcessInfo.processInfo.environment["SNAPOK_TEST_LANGUAGE"] == "en" {
            let languageSuite = "Snapok.OCRTests.Language.\(UUID().uuidString)"
            let languageDefaults = UserDefaults(suiteName: languageSuite)!
            AppLanguage.switchTo(AppLanguage.english, in: languageDefaults)
            languageDefaults.removePersistentDomain(forName: languageSuite)
        }
        var checks = 0
        func check(_ condition: Bool, _ message: String) {
            precondition(condition, message)
            checks += 1
        }
        check(OCRFormat.lines.apply("  indented  \r\nsecond\t\r\n") == "  indented\nsecond", "Keep indentation and normalize line endings")
        check(OCRFormat.lines.apply("A\tB\n1\t2") == "A\tB\n1\t2", "Keep table tabs")
        check(OCRFormat.paragraphs.apply("这是第一\n行文字。") == "这是第一行文字。", "Join Chinese wrapped lines without spaces")
        check(OCRFormat.paragraphs.apply("Hello\nworld") == "Hello world", "Join English wrapped lines with spaces")
        check(OCRFormat.paragraphs.apply("First\nparagraph\n\nSecond\nparagraph") == "First paragraph\n\nSecond paragraph", "Preserve blank-line paragraph boundaries")
        check(OCRFormat.paragraphs.apply("Tasks:\n- One\n- Two") == "Tasks:\n- One\n- Two", "Preserve bullets")
        check(OCRFormat.paragraphs.apply("标题：\n1. 第一项\n2. 第二项") == "标题：\n1. 第一项\n2. 第二项", "Preserve numbered lists")
        check(OCRFormat.singleLine.apply("Hello\n\nworld") == "Hello world", "Single-line English")
        check(OCRFormat.singleLine.apply("你好\n\n世界") == "你好世界", "Single-line Chinese")
        check(OCRFormat.paragraphs.apply("\n\n") == "", "Empty recognition")
        check(OCRFormat.paragraphs.apply("A\u{00a0}B") == "A B", "Normalize nonbreaking spaces")

        let suite = "Snapok.OCRTests.\(UUID().uuidString)"
        let store = UserDefaults(suiteName: suite)!
        defer { store.removePersistentDomain(forName: suite) }
        for action in [HotKeyAction.ocrCapture, .ocrSelection] {
            let key = action.defaultHotKey
            check(key.isValidGlobalShortcut, "OCR shortcut must be valid")
            check(!action.isArmedOnly, "OCR shortcuts must work globally")
            key.save(in: store, key: action.preferenceKey)
            check(HotKey.saved(in: store, key: action.preferenceKey, default: .init(keyCode: 0, modifiers: 0, key: "")) == key, "Shortcut round trip")
            store.removeObject(forKey: action.preferenceKey)
        }
        let defaults = HotKeyAction.allCases.map(\.defaultHotKey)
        check(Set(defaults.map { "\($0.keyCode):\($0.modifiers)" }).count == defaults.count, "Default actions must not conflict")
        let oldFormat = UserDefaults.standard.object(forKey: "ocr.format")
        defer {
            if let oldFormat { UserDefaults.standard.set(oldFormat, forKey: "ocr.format") }
            else { UserDefaults.standard.removeObject(forKey: "ocr.format") }
        }
        UserDefaults.standard.set(0, forKey: "ocr.format")
        let controller = OCRResultWindowController()
        controller.setText("Hello\nworld", status: "Test")
        let root = controller.window!.contentView as! NSStackView
        root.layoutSubtreeIfNeeded()
        let toolbar = root.arrangedSubviews[0] as! NSStackView
        let popup = toolbar.arrangedSubviews[0] as! NSPopUpButton
        let restore = toolbar.arrangedSubviews[1] as! NSButton
        let scroll = root.arrangedSubviews[2] as! NSScrollView
        let text = scroll.documentView as! NSTextView
        check(scroll.frame.width > 400 && scroll.frame.height >= 200, "Result window layout")
        check(text.string == "Hello\nworld", "Initial text")
        popup.selectItem(at: OCRFormat.singleLine.rawValue)
        NSApp.sendAction(popup.action!, to: popup.target, from: popup)
        check(text.string == "Hello world", "Switch to single line")
        popup.selectItem(at: OCRFormat.lines.rawValue)
        NSApp.sendAction(popup.action!, to: popup.target, from: popup)
        check(text.string == "Hello\nworld", "Switching formats restores original breaks")
        text.string = "Manual\ncorrection"
        popup.selectItem(at: OCRFormat.singleLine.rawValue)
        NSApp.sendAction(popup.action!, to: popup.target, from: popup)
        check(text.string == "Manual correction", "Manual edits survive formatting")
        NSApp.sendAction(restore.action!, to: restore.target, from: restore)
        check(text.string == "Hello\nworld", "Restore original text")
        var closed = false
        controller.onClose = { closed = true }
        controller.windowWillClose(Notification(name: NSWindow.willCloseNotification))
        check(closed, "Closing cancels pending recognition")
        let preferences = TextActionPreferences(defaults: store)
        check(preferences.autoCopy, "Automatic copying defaults on")
        check(preferences.showSideNotice, "Side notification defaults on")
        check(preferences.playSound, "Sound defaults on")
        check(!preferences.showResultWindow, "Result window defaults off")
        check(preferences.format == .paragraphs, "New users default to smart paragraphs")
        preferences.format = .lines
        check(TextActionPreferences(defaults: store).format == .lines, "Existing format preserved")
        store.set(999, forKey: "ocr.format")
        check(preferences.format == .paragraphs, "Invalid formatting falls back safely")
        preferences.translationTarget = "invalid-language"
        check(preferences.translationTarget == "auto", "Invalid translation target falls back")
        preferences.translationTarget = "ja"
        check(SelectedTextTranslator.target(for: "Hello world", preference: preferences.translationTarget).languageCode?.identifier == "ja", "Explicit target respected")
        check(SelectedTextTranslator.target(for: "This sentence is written in English.", preference: "auto").languageCode?.identifier == "zh", "English automatically translates to Chinese")
        check(SelectedTextTranslator.target(for: "这是一段中文文字，用于测试自动选择翻译目标语言。", preference: "auto").languageCode?.identifier == "en", "Chinese automatically translates to English")

        check(preferences.translationProvider == .baidu, "Baidu is the default translation service")
        preferences.translationProvider = .system
        check(TextActionPreferences(defaults: store).translationProvider == .system, "Provider choice persists")
        preferences.translationProvider = .baidu
        let sampleCredentials = BaiduTranslationCredentials(appID: "2015063000000001", secret: "1234567890")
        check(BaiduTextTranslator.signature(appID: sampleCredentials.appID, text: "apple", salt: "65478", secret: sampleCredentials.secret) == "a1a7461d92e5194c5cae3182b5b24de1", "Baidu official signature example")
        let specialText = "你好 + & = ?\n100% apple"
        let request = try! BaiduTextTranslator.request(text: specialText, target: Locale.Language(identifier: "zh-Hant"), credentials: sampleCredentials, salt: "testSalt")
        check(request.url?.scheme == "https" && request.url?.host == "fanyi-api.baidu.com", "Baidu endpoint is official HTTPS")
        check(request.httpMethod == "POST" && request.url?.query == nil, "Text and signatures stay out of URL")
        check(request.timeoutInterval == 20, "Translation request has bounded timeout")
        let body = String(data: request.httpBody!, encoding: .utf8)!
        let fields = Dictionary(uniqueKeysWithValues: body.split(separator: "&").map { field -> (String, String) in
            let pair = field.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            return (String(pair[0]), String(pair[1]).removingPercentEncoding!)
        })
        check(fields["q"] == specialText, "UTF-8 and reserved characters round trip without corruption")
        check(fields["from"] == "auto" && fields["to"] == "cht", "Source autodetection and traditional Chinese target")
        check(!body.contains(sampleCredentials.secret), "Secret never included in request body")
        check(fields["sign"] == BaiduTextTranslator.signature(appID: sampleCredentials.appID, text: specialText, salt: "testSalt", secret: sampleCredentials.secret), "Sign raw text before form encoding")
        for (language, expected) in [("zh-Hans", "zh"), ("en", "en"), ("ja", "jp"), ("ko", "kor"), ("fr", "fra"), ("es", "spa"), ("ar", "ara")] {
            check((try? BaiduTextTranslator.languageCode(Locale.Language(identifier: language))) == expected, "Baidu language mapping: \(language)")
        }
        let successResponse = Data(#"{"from":"en","to":"zh","trans_result":[{"src":"one","dst":"第一段"},{"src":"two","dst":"第二段"}]}"#.utf8)
        check((try? BaiduTextTranslator.parse(successResponse, status: 200)) == "第一段\n第二段", "Baidu response preserves multiple paragraphs")
        check((try? BaiduTextTranslator.parse(successResponse, status: 503)) == nil, "Reject unsuccessful HTTP status")
        for invalid in [#"{}"#, #"{"trans_result":[]}"#, #"{"trans_result":[{"src":"x"}]}"#, #"{"trans_result":[{"dst":""}]}"#, "not JSON"] {
            check((try? BaiduTextTranslator.parse(Data(invalid.utf8), status: 200)) == nil, "Reject malformed or empty translation")
        }
        for errorJSON in [#"{"error_code":"54001","error_msg":"Invalid Sign"}"#, #"{"error_code":54004}"#] {
            do { _ = try BaiduTextTranslator.parse(Data(errorJSON.utf8), status: 200); preconditionFailure("Expected API failure") }
            catch BaiduTranslationError.api(let code) { check(["54001", "54004"].contains(code), "String and numeric Baidu error codes supported") }
            catch { preconditionFailure("Unexpected error: \(error)") }
        }
        check((try? BaiduTextTranslator.request(text: "hello", target: Locale.Language(identifier: "zh-Hans"), credentials: .init(appID: "", secret: ""))) == nil, "Missing credentials rejected before networking")
        check((try? BaiduTextTranslator.request(text: String(repeating: "中", count: 6001), target: Locale.Language(identifier: "en"), credentials: sampleCredentials)) == nil, "Oversized Baidu query rejected before networking")
        check((try? BaiduTextTranslator.request(text: String(repeating: "中", count: 6000), target: Locale.Language(identifier: "en"), credentials: sampleCredentials)) != nil, "6000-character boundary supported")
        check((try? BaiduTextTranslator.request(text: " \n", target: Locale.Language(identifier: "en"), credentials: sampleCredentials)) == nil, "Empty Baidu input rejected before networking")

        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        board.setString("sentinel", forType: .string)
        preferences.format = .paragraphs
        let recognized = TextActionDelivery.complete("Hello\nworld", kind: .recognition, preferences: preferences, pasteboard: board)
        check(recognized?.text == "Hello world" && recognized?.copied == true, "OCR formats before copying")
        check(board.string(forType: .string) == "Hello world", "Formatted OCR copied")
        let translated = TextActionDelivery.complete("第一段\n第二段", kind: .translation, preferences: preferences, pasteboard: board)
        check(translated?.text == "第一段\n第二段", "Translation retains its paragraphs")
        check(board.string(forType: .string) == "第一段\n第二段", "Translation output, not source, copied")
        let changeCount = board.changeCount
        check(TextActionDelivery.complete(" \n\t", kind: .recognition, preferences: preferences, pasteboard: board) == nil, "Empty recognition is not delivered")
        check(board.changeCount == changeCount, "Empty result leaves clipboard unchanged")
        preferences.autoCopy = false
        let noCopy = TextActionDelivery.complete("Do not copy", kind: .recognition, preferences: preferences, pasteboard: board)
        check(noCopy?.copied == false && noCopy?.copyFailed == false, "Disabled automatic copying is not a failure")
        check(board.changeCount == changeCount, "Copy switch protects clipboard")

        var openedOfficialURLs: [URL] = []
        let pane = TextActionsPane(preferences: preferences, openOfficialURL: {
            openedOfficialURLs.append($0)
            return true
        })
        let layoutWindow = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 700, height: 760), styleMask: [.titled], backing: .buffered, defer: false)
        let layoutHost = NSView(frame: CGRect(x: 0, y: 0, width: 700, height: 760))
        layoutWindow.contentView = layoutHost
        pane.translatesAutoresizingMaskIntoConstraints = false
        layoutHost.addSubview(pane)
        NSLayoutConstraint.activate([
            pane.leadingAnchor.constraint(equalTo: layoutHost.leadingAnchor),
            pane.trailingAnchor.constraint(equalTo: layoutHost.trailingAnchor),
            pane.topAnchor.constraint(equalTo: layoutHost.topAnchor),
            pane.bottomAnchor.constraint(equalTo: layoutHost.bottomAnchor)
        ])
        layoutHost.layoutSubtreeIfNeeded()
        func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
        let controls = descendants(pane)
        for (identifier, key) in [("textActions.autoCopy", "ocr.autoCopy"), ("textActions.sideNotice", "ocr.showSideNotice"),
                                   ("textActions.sound", "ocr.playSound"), ("textActions.resultWindow", "ocr.showResultWindow")] {
            let button = controls.first { $0.identifier?.rawValue == identifier } as! NSButton
            button.state = button.state == .on ? .off : .on
            NSApp.sendAction(button.action!, to: button.target, from: button)
            check(store.bool(forKey: key) == (button.state == .on), "Switch saves: \(key)")
            let refreshed = TextActionPreferences(defaults: UserDefaults(suiteName: suite)!)
            let effective = [refreshed.autoCopy, refreshed.showSideNotice, refreshed.playSound, refreshed.showResultWindow]
            let expected = ["textActions.autoCopy", "textActions.sideNotice", "textActions.sound", "textActions.resultWindow"].map { id in
                (controls.first { $0.identifier?.rawValue == id } as! NSButton).state == .on
            }
            check(effective == expected, "Switches persist independently: \(key)")
        }
        let providerControl = controls.first { $0.identifier?.rawValue == "textActions.provider" } as! NSPopUpButton
        let secretControl = controls.first { $0.identifier?.rawValue == "textActions.baiduSecret" }
        check(secretControl is NSSecureTextField, "Baidu secret uses secure field")
        check((secretControl as? NSSecureTextField)?.stringValue == "", "Saved secret is never filled into UI")
        providerControl.selectItem(at: 1)
        NSApp.sendAction(providerControl.action!, to: providerControl.target, from: providerControl)
        check(preferences.translationProvider == .system && (secretControl as? NSSecureTextField)?.isEnabled == false, "System provider saves and disables Baidu credentials")
        providerControl.selectItem(at: 0)
        NSApp.sendAction(providerControl.action!, to: providerControl.target, from: providerControl)
        check(preferences.translationProvider == .baidu && (secretControl as? NSSecureTextField)?.isEnabled == true, "Baidu provider saves and enables credentials")
        let targetControl = controls.first { $0.identifier?.rawValue == "textActions.targetLanguage" } as! NSPopUpButton
        targetControl.selectItem(at: 4)
        NSApp.sendAction(targetControl.action!, to: targetControl.target, from: targetControl)
        check(preferences.translationTarget == "ja", "Target-language menu saves")
        check(SettingsPage.allCases.contains(.textActions), "Settings navigation exposes text actions")
        check(controls.contains { $0.identifier?.rawValue == "textActions.downloadLanguages" }, "Settings provide explicit language-pack setup")
        check(controls.compactMap { ($0 as? NSTextField)?.stringValue }.contains { $0 == L("Text translation", "文字翻译") }, "Settings label is translation")

        let guideButton = controls.first { $0.identifier?.rawValue == "textActions.baiduGuideToggle" } as! NSButton
        let guide = controls.first { $0.identifier?.rawValue == "textActions.baiduGuide" } as! NSStackView
        check(guide.isHidden, "Registration guide starts compact")
        let platformButton = controls.first { $0.identifier?.rawValue == "textActions.baiduPlatform" } as! NSButton
        check(!platformButton.isHiddenOrHasHiddenAncestor && platformButton.isEnabled, "Platform shortcut is available before expanding the guide")
        check(platformButton.bezelStyle == .rounded && platformButton.frame.width > 150 && platformButton.frame.height > 15, "Platform shortcut is a visible prominent button")
        check(platformButton.toolTip == "https://fanyi-api.baidu.com/", "Platform shortcut shows the official destination")
        NSApp.sendAction(platformButton.action!, to: platformButton.target, from: platformButton)
        check(openedOfficialURLs.map(\.absoluteString) == ["https://fanyi-api.baidu.com/"], "Platform shortcut dispatches the official URL exactly once")
        NSApp.sendAction(guideButton.action!, to: guideButton.target, from: guideButton)
        check(!guide.isHidden, "Registration guide expands inside the app")
        pane.layoutSubtreeIfNeeded()
        check(descendants(guide).compactMap { ($0 as? NSTextField)?.stringValue }.contains { $0.contains("APP ID") }, "Guide explains where to get APP ID and secret")
        check(descendants(guide).compactMap { ($0 as? NSButton)?.title }.count == 3, "Guide includes three official links")
        let addressButton = controls.first { $0.identifier?.rawValue == "textActions.baiduPlatformAddress" } as! NSButton
        check(addressButton.title.contains("https://fanyi-api.baidu.com/") && !addressButton.isHiddenOrHasHiddenAncestor, "Expanded guide displays a clickable official website address")
        for (identifier, destination) in [
            ("textActions.baiduPlatformAddress", "https://fanyi-api.baidu.com/"),
            ("textActions.baiduAPIDocs", "https://fanyi-api.baidu.com/doc/23"),
            ("textActions.baiduPricing", "https://fanyi-api.baidu.com/product/112")
        ] {
            let link = controls.first { $0.identifier?.rawValue == identifier } as! NSButton
            let before = openedOfficialURLs.count
            NSApp.sendAction(link.action!, to: link.target, from: link)
            check(openedOfficialURLs.count == before + 1 && openedOfficialURLs.last?.absoluteString == destination, "Official link routes correctly: \(identifier)")
        }
        check(guide.frame.width > 250 && guide.frame.height > 200, "Expanded guide has real multiline layout in a window")
        let guideLabels = descendants(guide).compactMap { $0 as? NSTextField }
        check(guideLabels.allSatisfy {
            let contentBounds = $0.alignmentRect(forFrame: $0.frame)
            return contentBounds.height > 12 && contentBounds.minX >= -1 && contentBounds.maxX <= guide.frame.width + 1
        }, "All guide steps are laid out inside card content width")
        let narrowPane = TextActionsPane(preferences: preferences)
        let narrowWindow = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 540, height: 700), styleMask: [.titled], backing: .buffered, defer: false)
        narrowWindow.contentView = narrowPane
        narrowPane.layoutSubtreeIfNeeded()
        let narrowControls = descendants(narrowPane)
        let narrowToggle = narrowControls.first { $0.identifier?.rawValue == "textActions.baiduGuideToggle" } as! NSButton
        NSApp.sendAction(narrowToggle.action!, to: narrowToggle.target, from: narrowToggle)
        narrowPane.layoutSubtreeIfNeeded()
        let narrowGuide = narrowControls.first { $0.identifier?.rawValue == "textActions.baiduGuide" } as! NSStackView
        let narrowLabels = descendants(narrowGuide).compactMap { $0 as? NSTextField }
        print("Layout diagnostic (narrow resize not asserted): window=\(narrowWindow.contentLayoutRect.width), page=\(narrowPane.frame.width), guide=\(narrowGuide.frame.width), guide-line-heights=\(narrowLabels.map { $0.frame.height })")
        check(narrowGuide.frame.width > 200 && narrowLabels.allSatisfy { $0.frame.height > 12 }, "Guide text remains laid out in the secondary layout host")
        NSApp.sendAction(guideButton.action!, to: guideButton.target, from: guideButton)
        check(guide.isHidden, "Registration guide collapses")
        check(!platformButton.isHiddenOrHasHiddenAncestor, "Platform shortcut stays available after collapsing the guide")
        let testControl = controls.first { $0.identifier?.rawValue == "textActions.testBaidu" } as! NSButton
        check(testControl.isEnabled, "Independent test button exists")
        check(testControl.frame.width > 50 && testControl.frame.height > 15, "Test button has visible size in real settings layout")
        providerControl.selectItem(at: 1)
        NSApp.sendAction(providerControl.action!, to: providerControl.target, from: providerControl)
        check(!testControl.isEnabled, "Baidu test disabled for system provider")
        check(platformButton.isEnabled && !platformButton.isHiddenOrHasHiddenAncestor, "Platform help is available regardless of translation provider")
        providerControl.selectItem(at: 0)
        NSApp.sendAction(providerControl.action!, to: providerControl.target, from: providerControl)
        let appIDControl = controls.first { $0.identifier?.rawValue == "textActions.baiduAppID" } as! NSTextField
        let statusControl = controls.first { $0.identifier?.rawValue == "textActions.baiduStatus" } as! NSTextField
        appIDControl.stringValue = "not-an-app-id"
        NSApp.sendAction(testControl.action!, to: testControl.target, from: testControl)
        check(pane.baiduTestTask == nil && statusControl.stringValue.contains("APP ID"), "Missing or invalid APP ID rejected before networking or Keychain access")

        var requestCount = 0
        let testPreferences = TextActionPreferences(defaults: store)
        let savedIDBefore = testPreferences.baiduAppID
        let generalClipboardBefore = NSPasteboard.general.changeCount
        let testPane = TextActionsPane(preferences: testPreferences, testTranslation: { text, target, credentials in
            requestCount += 1
            precondition(text == "Hello" && target.languageCode?.identifier == "zh")
            precondition(credentials.appID == "123456789" && credentials.secret == "unit-test-placeholder")
            try await Task.sleep(for: .milliseconds(30))
            return "你好"
        })
        let testControls = descendants(testPane)
        let testID = testControls.first { $0.identifier?.rawValue == "textActions.baiduAppID" } as! NSTextField
        let testSecret = testControls.first { $0.identifier?.rawValue == "textActions.baiduSecret" } as! NSSecureTextField
        let testButton = testControls.first { $0.identifier?.rawValue == "textActions.testBaidu" } as! NSButton
        let testStatus = testControls.first { $0.identifier?.rawValue == "textActions.baiduStatus" } as! NSTextField
        testID.stringValue = "123456789"
        testSecret.stringValue = "unit-test-placeholder"
        NSApp.sendAction(testButton.action!, to: testButton.target, from: testButton)
        check(testPane.baiduTestTask != nil && !testButton.isEnabled && !testID.isEnabled, "Test shows busy state and freezes fields")
        NSApp.sendAction(testButton.action!, to: testButton.target, from: testButton)
        await testPane.baiduTestTask?.value
        check(requestCount == 1, "Double click cannot send duplicate tests")
        check(testStatus.stringValue.contains("Hello → 你好") && !testStatus.stringValue.contains(testSecret.stringValue), "Test shows translated response, never secret")
        check(testPane.baiduTestTask == nil && testButton.isEnabled && testID.isEnabled, "Test button recovers after success")
        check(testPreferences.baiduAppID == savedIDBefore, "Testing unsaved fields never saves configuration")
        check(NSPasteboard.general.changeCount == generalClipboardBefore, "Connection testing never changes clipboard")
        let failurePane = TextActionsPane(preferences: testPreferences, testTranslation: { _, _, _ in throw BaiduTranslationError.api("54001") })
        let failureControls = descendants(failurePane)
        (failureControls.first { $0.identifier?.rawValue == "textActions.baiduAppID" } as! NSTextField).stringValue = "123456789"
        (failureControls.first { $0.identifier?.rawValue == "textActions.baiduSecret" } as! NSSecureTextField).stringValue = "unit-test-placeholder"
        let failureButton = failureControls.first { $0.identifier?.rawValue == "textActions.testBaidu" } as! NSButton
        NSApp.sendAction(failureButton.action!, to: failureButton.target, from: failureButton)
        await failurePane.baiduTestTask?.value
        let failureStatus = failureControls.first { $0.identifier?.rawValue == "textActions.baiduStatus" } as! NSTextField
        check(failureStatus.stringValue.contains(L("authentication failed", "鉴权失败")), "Test reports specific authentication errors")
        check(failureButton.isEnabled && failurePane.baiduTestTask == nil, "Test button recovers after failure")
        check(!BaiduTranslationError.api("unit-test-placeholder").localizedDescription.contains("unit-test-placeholder"), "Unknown API error strings cannot disclose credentials")

        let shortPreview = TextActionNotice.preview("短结果", width: 328, maxHeight: 190)
        let multilinePreview = TextActionNotice.preview("第一行\n第二行\n第三行", width: 328, maxHeight: 190)
        check(!shortPreview.truncated && multilinePreview.height > shortPreview.height * 2, "Notice height grows for multiple lines")
        let longPreview = TextActionNotice.preview(String(repeating: "这是一段很长的翻译结果，用来验证自动换行。", count: 100), width: 328, maxHeight: 190)
        check(longPreview.truncated && longPreview.height <= 190 && longPreview.text.hasSuffix("…"), "Long preview is bounded with explicit ellipsis")
        let tinyFrame = TextActionNotice.frame(in: CGRect(x: 0, y: 0, width: 240, height: 140), size: CGSize(width: 360, height: 300))
        check(tinyFrame.minX >= 0 && tinyFrame.minY >= 0 && tinyFrame.maxY <= 140, "Notice remains inside small visible frames")

        let frame = TextActionNotice.frame(in: CGRect(x: -1920, y: 30, width: 1920, height: 1050), size: CGSize(width: 360, height: 150))
        check(frame.maxX == -16 && frame.maxY == 1056, "Notice anchors to right edge on secondary monitor")
        let notice = TextActionNotice()
        notice.show(title: "Test", detail: "Result", screen: NSScreen.main, duration: 0.05)
        if let panel = notice.panel {
            check(!panel.canBecomeKey && !panel.canBecomeMain, "Notice never steals focus")
            check(panel.ignoresMouseEvents, "Notice is click-through")
            check(panel.collectionBehavior.contains(.fullScreenAuxiliary), "Notice supports full-screen apps")
            let noticeViews = descendants(panel.contentView!)
            let noticeBody = noticeViews.first { $0.identifier?.rawValue == "textNotice.body" } as! NSTextField
            check(noticeBody.maximumNumberOfLines == 0 && noticeBody.cell?.usesSingleLineMode == false, "Notice body is truly multiline")
            check(!panel.isOpaque && panel.backgroundColor == .clear, "Notice has transparent backing")
            let glass = noticeViews.first { $0.identifier?.rawValue == "textNotice.glass" } as! NSVisualEffectView
            check(NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency || glass.alphaValue < 0.8, "Glass background is translucent while text stays opaque")
            let dismissalDeadline = ContinuousClock.now + .seconds(3)
            while notice.panel != nil && ContinuousClock.now < dismissalDeadline {
                try? await Task.sleep(for: .milliseconds(25))
            }
            check(notice.panel == nil, "Notice automatically disappears within bounded deadline")
        }
        notice.dismiss()

        preferences.autoCopy = true
        preferences.showSideNotice = false
        preferences.playSound = false
        preferences.showResultWindow = false
        preferences.translationTarget = "zh-Hans"
        let action = OCRController(preferences: preferences, pasteboard: board) { source, target in
            precondition(source == "Hello world" && target.languageCode?.identifier == "zh")
            return "你好世界"
        }
        let visibleBefore = NSApp.windows.filter(\.isVisible).map(ObjectIdentifier.init)
        action.translateSelection("Hello world")
        await action.task?.value
        check(action.lastOutcome?.kind == .translation && action.lastOutcome?.text == "你好世界", "Selected text uses translation pipeline")
        check(board.string(forType: .string) == "你好世界", "Translated result delivered automatically")
        check(action.lastError == nil, "Successful translation clears errors")
        check(NSApp.windows.filter(\.isVisible).map(ObjectIdentifier.init) == visibleBefore, "Silent mode opens no windows")
        let afterSuccess = board.changeCount
        action.translateSelection("  \n")
        check(action.lastError != nil && board.changeCount == afterSuccess, "Empty selection fails without modifying clipboard")
        action.translateSelection(String(repeating: "x", count: 20_001))
        check(action.lastError != nil && board.changeCount == afterSuccess, "Oversized selection fails safely")
        let failure = OCRController(preferences: preferences, pasteboard: board) { _, _ in throw SelectedTextTranslationError.invalidResponse }
        failure.translateSelection("Hello world")
        await failure.task?.value
        check(failure.lastError != nil && board.changeCount == afterSuccess, "Translation errors preserve clipboard")
        let delayed = OCRController(preferences: preferences, pasteboard: board) { source, _ in
            if source == "old" { try? await Task.sleep(for: .milliseconds(40)) }
            return source == "old" ? "旧结果" : "最新结果"
        }
        delayed.translateSelection("old")
        let staleTask = delayed.task
        delayed.translateSelection("new")
        await delayed.task?.value
        await staleTask?.value
        check(board.string(forType: .string) == "最新结果" && delayed.lastOutcome?.text == "最新结果", "Cancelled tasks cannot overwrite newer results")
        let beforeCancel = board.changeCount
        delayed.translateSelection("old")
        let cancelledTask = delayed.task
        delayed.cancelPending()
        await cancelledTask?.value
        check(board.changeCount == beforeCancel, "Cancellation prevents delivery")
        check(NSApp.windows.filter(\.isVisible).map(ObjectIdentifier.init) == visibleBefore, "Failures and cancellation remain silent")
        // Image workflows share one cancellable OCR -> translation task. The OCR output
        // must never reach the pasteboard before translation succeeds.
        let testImage = NSImage(size: NSSize(width: 20, height: 20), flipped: false) { rect in
            NSColor.white.setFill()
            rect.fill()
            return true
        }
        let imageAction = OCRController(preferences: preferences, pasteboard: board,
                                       recognizer: { _ in "Hello world" }) { source, target in
            precondition(source == "Hello world" && target.languageCode?.identifier == "zh")
            return "图片译文"
        }
        let beforeImage = board.changeCount
        imageAction.recognize(testImage, translate: true)
        await imageAction.task?.value
        check(imageAction.lastOutcome?.kind == .translation && imageAction.lastOutcome?.text == "图片译文", "Region OCR feeds translation")
        check(board.string(forType: .string) == "图片译文" && board.changeCount == beforeImage + 1, "Only translation is copied, never intermediate OCR")
        imageAction.translateImage(testImage)
        await imageAction.task?.value
        check(imageAction.lastOutcome?.text == "图片译文" && imageAction.lastError == nil, "Library screenshot uses OCR translation pipeline")
        let beforeMissing = board.changeCount
        imageAction.translateImage(nil)
        check(imageAction.lastError != nil && board.changeCount == beforeMissing, "Missing library screenshot preserves clipboard")
        imageAction.recognize(testImage)
        await imageAction.task?.value
        check(imageAction.lastOutcome?.kind == .recognition && imageAction.lastOutcome?.text == "Hello world", "OCR-only action stays recognition-only")
        let emptyImage = OCRController(preferences: preferences, pasteboard: board,
                                       recognizer: { _ in "  \n" }) { _, _ in
            preconditionFailure("Empty OCR must not call the translator")
        }
        let beforeEmpty = board.changeCount
        emptyImage.translateImage(testImage)
        await emptyImage.task?.value
        check(emptyImage.lastError != nil && board.changeCount == beforeEmpty, "Empty OCR preserves clipboard and skips provider")
        let brokenOCR = OCRController(preferences: preferences, pasteboard: board,
                                      recognizer: { _ in throw SelectedTextTranslationError.invalidResponse }) { _, _ in
            preconditionFailure("Failed OCR must not call the translator")
        }
        brokenOCR.translateImage(testImage)
        await brokenOCR.task?.value
        check(brokenOCR.lastError != nil && board.changeCount == beforeEmpty, "OCR errors preserve clipboard")
        let failedImage = OCRController(preferences: preferences, pasteboard: board,
                                       recognizer: { _ in "Hello world" }) { _, _ in throw SelectedTextTranslationError.invalidResponse }
        failedImage.translateImage(testImage)
        await failedImage.task?.value
        check(failedImage.lastError != nil && board.changeCount == beforeEmpty, "Image translation failure does not copy OCR text")
        let slowOCR = OCRController(preferences: preferences, pasteboard: board, recognizer: { _ in
            try? await Task.sleep(for: .milliseconds(40))
            return "old OCR"
        }) { source, _ in source }
        slowOCR.translateImage(testImage)
        let staleOCR = slowOCR.task
        slowOCR.translateSelection("new translation")
        await slowOCR.task?.value
        await staleOCR?.value
        check(board.string(forType: .string) == "new translation", "Cancelled OCR cannot overwrite a newer translation")
        let slowTranslation = OCRController(preferences: preferences, pasteboard: board,
                                            recognizer: { _ in "Hello world" }) { _, _ in
            try? await Task.sleep(for: .milliseconds(100))
            return "cancelled image translation"
        }
        let beforeImageCancel = board.changeCount
        slowTranslation.translateImage(testImage)
        let cancelledImageTask = slowTranslation.task
        try? await Task.sleep(for: .milliseconds(30))
        slowTranslation.cancelPending()
        await cancelledImageTask?.value
        check(board.changeCount == beforeImageCancel, "Cancellation during image translation prevents delivery")
        let oversizedOCR = OCRController(preferences: preferences, pasteboard: board,
                                          recognizer: { _ in String(repeating: "x", count: 20_001) }) { _, _ in
            preconditionFailure("Oversized OCR must not call the translator")
        }
        oversizedOCR.translateImage(testImage)
        await oversizedOCR.task?.value
        check(oversizedOCR.lastError != nil && board.changeCount == beforeImageCancel, "Oversized OCR is rejected before sending")
        preferences.autoCopy = false
        imageAction.translateImage(testImage)
        await imageAction.task?.value
        check(imageAction.lastOutcome?.text == "图片译文" && imageAction.lastOutcome?.copied == false && board.changeCount == beforeImageCancel, "Image translation honors disabled auto-copy")
        preferences.autoCopy = true
        check(HotKeyAction.translateCapture.defaultHotKey.symbol == "⌃⌥T", "Region translation has its own shortcut")
        check(Set(HotKeyAction.allCases.map(\.preferenceKey)).count == HotKeyAction.allCases.count, "Global shortcuts have independent preferences")
        check(NSApp.windows.filter(\.isVisible).map(ObjectIdentifier.init) == visibleBefore, "Image actions honor silent result preferences")
        print("Passed \(checks) OCR / translation checks: formatting, shortcuts, defaults, switches, clipboard, UI, translation delivery, errors and cancellation")
    }
}
