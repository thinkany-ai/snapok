import AppKit
import NaturalLanguage
@preconcurrency import Translation

/// Keep the existing OCR format and shortcut keys so upgrades preserve user choices.
@MainActor
struct TextActionPreferences {
    let defaults: UserDefaults
    init(defaults: UserDefaults = .standard) { self.defaults = defaults }
    private func enabled(_ key: String, fallback: Bool) -> Bool {
        (defaults.object(forKey: key) as? Bool) ?? fallback
    }
    var autoCopy: Bool {
        get { enabled("ocr.autoCopy", fallback: true) }
        nonmutating set { defaults.set(newValue, forKey: "ocr.autoCopy") }
    }
    var showSideNotice: Bool {
        get { enabled("ocr.showSideNotice", fallback: true) }
        nonmutating set { defaults.set(newValue, forKey: "ocr.showSideNotice") }
    }
    var playSound: Bool {
        get { enabled("ocr.playSound", fallback: true) }
        nonmutating set { defaults.set(newValue, forKey: "ocr.playSound") }
    }
    var showResultWindow: Bool {
        get { enabled("ocr.showResultWindow", fallback: false) }
        nonmutating set { defaults.set(newValue, forKey: "ocr.showResultWindow") }
    }
    var format: OCRFormat {
        get {
            guard let value = defaults.object(forKey: "ocr.format") as? Int else { return .paragraphs }
            return OCRFormat(rawValue: value) ?? .paragraphs
        }
        nonmutating set { defaults.set(newValue.rawValue, forKey: "ocr.format") }
    }
    var translationProvider: TextTranslationProvider {
        get { TextTranslationProvider(rawValue: defaults.string(forKey: "ocr.translationProvider") ?? "") ?? .baidu }
        nonmutating set { defaults.set(newValue.rawValue, forKey: "ocr.translationProvider") }
    }
    var baiduAppID: String {
        get { defaults.string(forKey: "ocr.baiduAppID") ?? "" }
        nonmutating set { defaults.set(newValue, forKey: "ocr.baiduAppID") }
    }
    var translationTarget: String {
        get {
            let saved = defaults.string(forKey: "ocr.translationTarget") ?? "auto"
            return saved == "auto" || TranslationTargets.all.contains(where: { $0.identifier == saved }) ? saved : "auto"
        }
        nonmutating set { defaults.set(newValue, forKey: "ocr.translationTarget") }
    }
}

enum SelectedTextTranslationError: LocalizedError {
    case empty, tooLong, invalidResponse
    case missingPacks(source: String, target: String)
    var errorDescription: String? {
        switch self {
        case .empty: return L("No text selected.", "没有选中文字。")
        case .missingPacks(let source, let target):
            return L("Download \(source) / \(target) in Snapok Settings → OCR & Translation → Check / Download Language Packs. Clipboard unchanged.", "请在 Snapok 设置 → 文字识别与翻译 → 检查 / 下载翻译语言包中准备「\(source)」和「\(target)」。剪贴板未改动。")
        case .tooLong: return L("Select up to 20,000 characters at a time.", "每次最多翻译 20,000 字，请分段选择。")
        case .invalidResponse: return L("Translation returned no text. Clipboard unchanged.", "翻译未返回文字，剪贴板未改动。")
        }
    }
}

/// The selected-text action is translation, not OCR. No network or model account is required.
enum SelectedTextTranslator {
    static func target(for text: String, preference: String) -> Locale.Language {
        if preference != "auto", TranslationTargets.all.contains(where: { $0.identifier == preference }) {
            return Locale.Language(identifier: preference)
        }
        let source = NLLanguageRecognizer.dominantLanguage(for: text)
        let isChinese = source == .simplifiedChinese || source == .traditionalChinese
        return Locale.Language(identifier: isChinese ? "en" : "zh-Hans")
    }

    static func translate(_ text: String, target: Locale.Language) async throws -> String {
        let sourceText = OCRFormat.lines.apply(text).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !sourceText.isEmpty else { throw SelectedTextTranslationError.empty }
        guard sourceText.count <= 20_000 else { throw SelectedTextTranslationError.tooLong }
        guard #available(macOS 26.0, *) else { throw SystemTranslationError.unavailable }
        guard let detected = NLLanguageRecognizer.dominantLanguage(for: sourceText), detected != .undetermined else {
            throw SystemTranslationError.unknownSourceLanguage
        }
        let source = Locale.Language(identifier: detected.rawValue)
        let same = source.languageCode == target.languageCode && (source.languageCode?.identifier != "zh" || source.maximalIdentifier == target.maximalIdentifier)
        // Already in an explicitly chosen target language: the unchanged text is the correct result.
        if same { return sourceText }
        let locale = Locale(identifier: L("en", "zh-Hans"))
        let sourceName = locale.localizedString(forIdentifier: source.minimalIdentifier) ?? source.minimalIdentifier
        let targetName = locale.localizedString(forIdentifier: target.minimalIdentifier) ?? target.minimalIdentifier
        switch await LanguageAvailability().status(from: source, to: target) {
        case .installed: break
        case .supported: throw SelectedTextTranslationError.missingPacks(source: sourceName, target: targetName)
        default: throw SystemTranslationError.unsupported(source: sourceName, target: targetName)
        }
        try Task.checkCancellation()
        let session = TranslationSession(installedSource: source, target: target)
        let response = try await session.translate(sourceText)
        try Task.checkCancellation()
        let translated = OCRFormat.lines.apply(response.targetText)
        guard !translated.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw SelectedTextTranslationError.invalidResponse
        }
        return translated
    }
}

enum TextActionKind { case recognition, translation
    var title: String {
        switch self {
        case .recognition: return L("Text recognized", "文字识别成功")
        case .translation: return L("Translation complete", "翻译完成")
        }
    }
}

@MainActor
struct TextActionOutcome {
    let text: String
    let kind: TextActionKind
    let copied: Bool
    let copyFailed: Bool
    var status: String {
        if copyFailed { return L("Couldn't copy. Open the last result from the menu to retry.", "复制失败，可从菜单查看上次结果并重试。") }
        return copied ? L("Copied to clipboard", "已自动复制到剪贴板") : L("Automatic copying is off", "自动复制已关闭")
    }
}

/// Isolated clipboard dependency makes silent delivery testable without touching the user's clipboard.
@MainActor
enum TextActionDelivery {
    static func complete(_ text: String, kind: TextActionKind, preferences: TextActionPreferences,
                         pasteboard: NSPasteboard = .general) -> TextActionOutcome? {
        let prepared = kind == .recognition ? preferences.format.apply(text) : OCRFormat.lines.apply(text)
        guard !prepared.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        var copied = false
        if preferences.autoCopy {
            pasteboard.clearContents()
            copied = pasteboard.setString(prepared, forType: .string)
        }
        return TextActionOutcome(text: prepared, kind: kind, copied: copied, copyFailed: preferences.autoCopy && !copied)
    }
}
