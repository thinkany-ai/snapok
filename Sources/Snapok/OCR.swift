import AppKit
@preconcurrency import ApplicationServices
@preconcurrency import Vision

/// Deterministic local formatting; never rewrites the meaning of recognized text.
enum OCRFormat: Int, CaseIterable {
    case lines, paragraphs, singleLine
    var title: String {
        switch self {
        case .lines: return L("Keep line breaks", "保留换行")
        case .paragraphs: return L("Smart paragraphs", "智能段落")
        case .singleLine: return L("Single line", "整理成单行")
        }
    }
    func apply(_ text: String) -> String {
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .replacingOccurrences(of: "\u{00a0}", with: " ")
        if self == .lines {
            return normalized.components(separatedBy: "\n").map {
                $0.replacingOccurrences(of: #"[ \t]+$"#, with: "", options: .regularExpression)
            }.joined(separator: "\n").trimmingCharacters(in: .newlines)
        }
        let lines = normalized.components(separatedBy: "\n").map {
            $0.trimmingCharacters(in: .whitespaces)
        }
        var output = ""
        var paragraphBreak = false
        for line in lines {
            if line.isEmpty { paragraphBreak = !output.isEmpty; continue }
            if output.isEmpty { output = line; continue }
            let isList = line.range(of: #"^([-*•●]|\d+[.)、])\s*"#, options: .regularExpression) != nil
            if self == .paragraphs && (paragraphBreak || isList || output.hasSuffix(":") || output.hasSuffix("：")) {
                output += paragraphBreak ? "\n\n" : "\n"
            } else if let last = output.unicodeScalars.last, let first = line.unicodeScalars.first {
                if !Self.isCJK(last) && !Self.isCJK(first) { output += " " }
            }
            output += line
            paragraphBreak = false
        }
        return output
    }
    private static func isCJK(_ scalar: Unicode.Scalar) -> Bool {
        (0x3400...0x9FFF).contains(scalar.value) || (0x3000...0x303F).contains(scalar.value)
        || (0xF900...0xFAFF).contains(scalar.value) || (0x20000...0x2FA1F).contains(scalar.value)
    }
}

private struct OCRLine: Sendable {
    let text: String
    let rect: CGRect
}

@MainActor
final class OCRController {
    static let shared = OCRController()
    private var result: OCRResultWindowController?
    private(set) var task: Task<Void, Never>?
    private(set) var lastOutcome: TextActionOutcome?
    private(set) var lastError: String?
    private var lastSource = ""
    private let notice = TextActionNotice()
    private let preferences: TextActionPreferences
    private let pasteboard: NSPasteboard
    private let translator: @Sendable (String, Locale.Language) async throws -> String

    init(preferences: TextActionPreferences = TextActionPreferences(), pasteboard: NSPasteboard = .general,
         translator: @escaping @Sendable (String, Locale.Language) async throws -> String = { text, target in
             try await SelectedTextTranslationService.translate(text, target: target)
         }) {
        self.preferences = preferences
        self.pasteboard = pasteboard
        self.translator = translator
    }

    func cancelPending() {
        task?.cancel()
        task = nil
        notice.dismiss()
    }

    private func begin(_ title: String, screen: NSScreen?, detail: String? = nil) {
        cancelPending()
        lastError = nil
        // An earlier manually opened result must not keep popping up over other apps.
        result?.window?.orderOut(nil)
        if preferences.showSideNotice {
            notice.show(title: title, detail: detail ?? L("Processing locally…", "正在本机处理…"), success: false, screen: screen, duration: 30)
        }
    }

    func recognize(_ image: NSImage, screen: NSScreen? = nil) {
        let screen = screen ?? actionScreen()
        begin(L("Recognizing text…", "正在识别文字…"), screen: screen)
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            fail(L("Unable to read this image.", "无法读取这张图片。"), screen: screen); return
        }
        let worker = Task.detached(priority: .userInitiated) { () throws -> String in
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = true
            request.automaticallyDetectsLanguage = true
            let supported = try request.supportedRecognitionLanguages()
            request.recognitionLanguages = ["zh-Hans", "zh-Hant", "en-US"].filter { supported.contains($0) }
            try VNImageRequestHandler(cgImage: cgImage).perform([request])
            let lines = (request.results ?? []).compactMap { observation -> OCRLine? in
                guard let candidate = observation.topCandidates(1).first else { return nil }
                return OCRLine(text: candidate.string, rect: observation.boundingBox)
            }.sorted { $0.rect.midY > $1.rect.midY }
            // Group boxes on the same baseline, then read each row left to right.
            var rows: [[OCRLine]] = []
            for line in lines {
                if let last = rows.last, let anchor = last.first,
                   abs(anchor.rect.midY - line.rect.midY) < min(anchor.rect.height, line.rect.height) * 0.45 {
                    rows[rows.count - 1].append(line)
                } else { rows.append([line]) }
            }
            var text = ""
            var previous: CGRect?
            for row in rows {
                let sorted = row.sorted { $0.rect.minX < $1.rect.minX }
                guard let first = sorted.first else { continue }
                if let previous {
                    text += previous.minY - first.rect.maxY > max(previous.height, first.rect.height) * 0.9 ? "\n\n" : "\n"
                }
                text += sorted.map(\.text).joined(separator: "\t")
                previous = first.rect
            }
            return text
        }
        task = Task { [weak self] in
            do {
                let text = try await withTaskCancellationHandler(operation: { try await worker.value }, onCancel: { worker.cancel() })
                guard !Task.isCancelled else { return }
                self?.complete(text, kind: .recognition, screen: screen)
            } catch {
                guard !Task.isCancelled else { return }
                self?.fail(L("Recognition failed: ", "识别失败：") + error.localizedDescription, screen: screen)
            }
        }
    }

    func readSelection() {
        let screen = actionScreen()
        begin(L("Reading selected text…", "正在读取选中文字…"), screen: screen)
        guard AXIsProcessTrusted() else {
            let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
            _ = AXIsProcessTrustedWithOptions(options)
            fail(L("Allow Accessibility access for Snapok, then select text and try again.", "请为 Snapok 授予辅助功能权限，再选中文字并重试。"), screen: screen)
            return
        }
        guard let app = NSWorkspace.shared.frontmostApplication,
              app.processIdentifier != ProcessInfo.processInfo.processIdentifier else {
            fail(L("Select text in another app first, then press the translation shortcut.", "请先在其他应用中选中文字，再按选中文字翻译快捷键。"), screen: screen); return
        }
        let application = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(application, 1)
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(application, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
              let focused, CFGetTypeID(focused) == AXUIElementGetTypeID() else {
            fail(L("This app does not expose selected text. Try an app that supports text selection.", "当前应用不支持读取选中文字，请在支持取词的应用中选中实际文本后重试。"), screen: screen); return
        }
        let element = unsafeDowncast(focused, to: AXUIElement.self)
        AXUIElementSetMessagingTimeout(element, 1)
        var value: CFTypeRef?
        let status = AXUIElementCopyAttributeValue(element, kAXSelectedTextAttribute as CFString, &value)
        let text = (value as? String) ?? (value as? NSAttributedString)?.string ?? ""
        guard status == .success, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            fail(L("No selected text is available. Select actual text in a supported app, then retry.", "未读取到选中文字。请在支持取词的应用中选中实际文本后重试。"), screen: screen); return
        }
        translateSelection(text, screen: screen)
    }

    func translateSelection(_ text: String, screen: NSScreen? = nil) {
        let screen = screen ?? actionScreen()
        begin(L("Translating selected text…", "正在翻译选中文字…"), screen: screen,
              detail: preferences.translationProvider == .baidu ? L("Translating with Baidu…", "正在使用百度翻译…") : nil)
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            fail(SelectedTextTranslationError.empty.localizedDescription, screen: screen); return
        }
        guard text.count <= 20_000 else {
            fail(SelectedTextTranslationError.tooLong.localizedDescription, screen: screen); return
        }
        let target = SelectedTextTranslator.target(for: text, preference: preferences.translationTarget)
        let translate = translator
        task = Task { [weak self] in
            do {
                let translated = try await translate(text, target)
                guard !Task.isCancelled else { return }
                self?.complete(translated, kind: .translation, screen: screen)
            } catch {
                guard !Task.isCancelled else { return }
                self?.fail(L("Translation failed: ", "翻译失败：") + error.localizedDescription, screen: screen)
            }
        }
    }

    private func complete(_ text: String, kind: TextActionKind, screen: NSScreen?) {
        guard let outcome = TextActionDelivery.complete(text, kind: kind, preferences: preferences, pasteboard: pasteboard) else {
            fail(kind == .recognition
                 ? L("No text found. Try a larger or sharper area.", "未识别到文字，请尝试更清晰或更大的选区。")
                 : SelectedTextTranslationError.invalidResponse.localizedDescription, screen: screen)
            return
        }
        lastSource = text
        lastOutcome = outcome
        lastError = nil
        notice.dismiss()
        if preferences.showSideNotice {
            notice.show(title: kind.title, detail: outcome.text, success: !outcome.copyFailed, screen: screen, status: outcome.status)
        }
        if preferences.playSound { NSSound(named: outcome.copyFailed ? "Basso" : "Glass")?.play() }
        if preferences.showResultWindow { presentLastResult() }
    }

    private func fail(_ message: String, screen: NSScreen?) {
        lastError = message
        notice.dismiss()
        if preferences.showSideNotice {
            notice.show(title: L("Action not completed", "操作未完成"), detail: message, success: false, screen: screen, duration: 8)
        }
        if preferences.playSound { NSSound(named: "Basso")?.play() }
    }

    func captureFailed(screen: NSScreen?) {
        fail(L("Could not capture the selected area. Clipboard unchanged.", "无法获取框选区域，剪贴板未改动。"), screen: screen)
    }

    func showLastResult() {
        if let lastError {
            notice.show(title: L("Last action failed", "上次操作未完成"), detail: lastError, success: false, screen: actionScreen(), duration: 10)
        } else if lastOutcome != nil {
            presentLastResult()
        } else {
            notice.show(title: L("No result yet", "暂无识别或翻译结果"), detail: L("Use an OCR or translation shortcut first.", "请先使用框选识别或选中文字翻译快捷键。"), success: false, screen: actionScreen())
        }
    }

    private func presentLastResult() {
        guard let outcome = lastOutcome else { return }
        if result == nil {
            result = OCRResultWindowController()
            result?.onClose = { [weak self] in self?.cancelPending() }
        }
        result?.setText(lastSource, status: outcome.status, kind: outcome.kind, renderedText: outcome.text)
        result?.showWindow(nil)
        result?.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func actionScreen() -> NSScreen? {
        NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main
    }
}

@MainActor
final class OCRResultWindowController: NSWindowController, NSWindowDelegate {
    var onClose: (() -> Void)?
    private var formatSource = ""
    private var lastRendered = ""
    private let textView = NSTextView()
    private let statusLabel = NSTextField(wrappingLabelWithString: "")
    private let format = NSPopUpButton()
    private let copyButton = NSButton(title: L("Copy Text", "复制文字"), target: nil, action: nil)
    private var original = ""
    private var resultKind: TextActionKind = .recognition

    init() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 740, height: 530),
                              styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
        window.title = L("Text Recognition", "文字识别")
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 520, height: 360)
        window.level = .floating
        window.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        super.init(window: window)
        window.delegate = self
        let root = NSStackView()
        root.orientation = .vertical
        root.alignment = .leading
        root.spacing = 12
        root.edgeInsets = NSEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)
        window.contentView = root
        format.addItems(withTitles: OCRFormat.allCases.map(\.title))
        format.selectItem(at: TextActionPreferences().format.rawValue)
        format.target = self
        format.action = #selector(changeFormat)
        copyButton.target = self
        copyButton.action = #selector(copyText)
        copyButton.bezelStyle = .rounded
        let restore = NSButton(title: L("Restore Original", "恢复原文"), target: self, action: #selector(restoreOriginal))
        restore.bezelStyle = .rounded
        let toolbar = NSStackView(views: [format, restore, copyButton])
        toolbar.spacing = 10
        root.addArrangedSubview(toolbar)
        root.addArrangedSubview(statusLabel)
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        textView.isRichText = false
        textView.isEditable = true
        textView.allowsUndo = true
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.textContainerInset = NSSize(width: 12, height: 12)
        textView.font = .systemFont(ofSize: 15)
        scroll.documentView = textView
        root.addArrangedSubview(scroll)
        NSLayoutConstraint.activate([
            scroll.widthAnchor.constraint(equalTo: root.widthAnchor, constant: -32),
            statusLabel.widthAnchor.constraint(equalTo: scroll.widthAnchor),
            scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 200)
        ])
        window.center()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    func setText(_ text: String, status: String, kind: TextActionKind = .recognition, renderedText: String? = nil) {
        resultKind = kind
        window?.title = kind == .recognition ? L("Text Recognition", "文字识别") : L("Text Translation", "文字翻译")
        format.selectItem(at: (kind == .recognition ? TextActionPreferences().format : .lines).rawValue)
        original = text
        formatSource = text
        textView.undoManager?.removeAllActions()
        textView.string = renderedText ?? (OCRFormat(rawValue: format.indexOfSelectedItem) ?? .lines).apply(text)
        lastRendered = textView.string
        statusLabel.stringValue = status
    }
    @objc private func changeFormat() {
        if resultKind == .recognition { UserDefaults.standard.set(format.indexOfSelectedItem, forKey: "ocr.format") }
        // Use the source while switching modes; preserve any intervening manual corrections.
        if textView.string != lastRendered { formatSource = textView.string }
        textView.string = (OCRFormat(rawValue: format.indexOfSelectedItem) ?? .lines).apply(formatSource)
        lastRendered = textView.string
    }
    @objc private func restoreOriginal() {
        textView.string = original
        formatSource = original
        lastRendered = original
        format.selectItem(at: OCRFormat.lines.rawValue)
        if resultKind == .recognition { UserDefaults.standard.set(OCRFormat.lines.rawValue, forKey: "ocr.format") }
    }
    func windowWillClose(_ notification: Notification) { onClose?() }

    @objc private func copyText() {
        guard !textView.string.isEmpty else { NSSound.beep(); return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(textView.string, forType: .string)
        statusLabel.stringValue = L("Copied to clipboard.", "已复制到剪贴板。")
    }
}
