import AppKit
import Security

/// User-facing settings backed by UserDefaults. The API key lives in the Keychain, not here.
enum AppSettings {
    static var reuseEditorStyle: Bool {
        get { defaults.bool(forKey: "capture.reuseEditorStyle") }
        set { defaults.set(newValue, forKey: "capture.reuseEditorStyle") }
    }
    private static var defaults: UserDefaults { .standard }

    static var autoSave: Bool {
        get { defaults.object(forKey: "history.autoSave") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "history.autoSave") }
    }

    /// Days to keep screenshots; 0 keeps them forever.
    static var retentionDays: Int {
        get { defaults.object(forKey: "history.retentionDays") as? Int ?? 30 }
        set { defaults.set(newValue, forKey: "history.retentionDays") }
    }

    /// Preselect the last language in the per-translation chooser; every request still asks.
    static var lastTranslationTarget: String {
        get { defaults.string(forKey: "ai.translateTarget") ?? "简体中文" }
        set { defaults.set(newValue, forKey: "ai.translateTarget") }
    }

    /// Sends each new screenshot to the AI service for a title and tags; off until the user opts in.
    static var autoName: Bool {
        get { defaults.bool(forKey: "ai.autoName") }
        set { defaults.set(newValue, forKey: "ai.autoName") }
    }

    /// The single Anthropic key of earlier builds; `ModelsStore` moves it into a provider on first use.
    static var apiKey: String? {
        get { Keychain.read(account: "anthropic-api-key") }
        set { Keychain.write(newValue, account: "anthropic-api-key") }
    }
}

enum Keychain {
    static func read(account: String, service: String = AppChannel.keychainService) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data,
              let value = String(data: data, encoding: .utf8), !value.isEmpty else {
            return nil
        }
        return value
    }

    static func write(_ value: String?, account: String, service: String = AppChannel.keychainService) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(query as CFDictionary)
        guard let value, !value.isEmpty else { return }
        var item = query
        item[kSecValueData as String] = Data(value.utf8)
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        let status = SecItemAdd(item as CFDictionary, nil)
        if status != errSecSuccess {
            log("keychain write failed, status=\(status)")
        }
    }
}

extension Annotation: Codable {
    private enum CodingKeys: String, CodingKey {
        case kind, rect, points, text, color, sizeLevel, textStyle, stepStyle, stepNumber
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let rgba = try container.decode([CGFloat].self, forKey: .color)
        self.init(
            kind: try container.decode(ToolKind.self, forKey: .kind),
            rect: try container.decode(CGRect.self, forKey: .rect),
            points: try container.decode([CGPoint].self, forKey: .points),
            text: try container.decodeIfPresent(String.self, forKey: .text) ?? "",
            color: NSColor(srgbRed: rgba[0], green: rgba[1], blue: rgba[2], alpha: rgba.count > 3 ? rgba[3] : 1),
            sizeLevel: try container.decode(Int.self, forKey: .sizeLevel),
            textStyle: try container.decodeIfPresent(AnnotationTextStyle.self, forKey: .textStyle),
            stepStyle: try container.decodeIfPresent(StepMarkerStyle.self, forKey: .stepStyle),
            stepNumber: try container.decodeIfPresent(String.self, forKey: .stepNumber)
        )
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(kind, forKey: .kind)
        try container.encode(rect, forKey: .rect)
        try container.encode(points, forKey: .points)
        try container.encode(text, forKey: .text)
        let srgb = color.usingColorSpace(.sRGB) ?? .systemRed
        try container.encode([srgb.redComponent, srgb.greenComponent, srgb.blueComponent, srgb.alphaComponent], forKey: .color)
        try container.encode(sizeLevel, forKey: .sizeLevel)
        try container.encodeIfPresent(textStyle, forKey: .textStyle)
        try container.encodeIfPresent(stepStyle, forKey: .stepStyle)
        try container.encodeIfPresent(stepNumber, forKey: .stepNumber)
    }
}

struct HistoryItem: Codable {
    let id: UUID
    let createdAt: Date
    /// Point size of the original capture; the PNG on disk is at full pixel resolution.
    let pointSize: CGSize
    var pixelSize: CGSize
    var title: String
    var tags: [String]
    var ocrText: String
    var annotations: [Annotation]
    var backgroundStyle: BackgroundPreferences? = nil

    var displayTitle: String {
        if !title.isEmpty { return title }
        let formatter = DateFormatter()
        formatter.locale = AppLanguage.current.locale
        formatter.dateFormat = L("MMM d, HH:mm:ss", "M月d日 HH:mm:ss")
        return L("Screenshot ", "截图 ") + formatter.string(from: createdAt)
    }

    func matches(_ query: String) -> Bool {
        let query = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !query.isEmpty else { return true }
        return ([displayTitle, ocrText] + tags).contains { $0.lowercased().contains(query) }
    }
}

/// Screenshot history: one folder per capture holding the original PNG, a thumbnail and `meta.json`,
/// so annotations stay editable after the capture closes.
@MainActor
final class HistoryStore {
    static let shared = HistoryStore()
    static let didChange = Notification.Name("SnapokHistoryDidChange")

    static let locationKey = "history.location"
    static var defaultRoot: URL { AppChannel.supportDirectory.appendingPathComponent("History", isDirectory: true) }
    private(set) var root: URL
    private let defaults: UserDefaults
    private(set) var items: [HistoryItem] = []
    private var thumbnails: [UUID: NSImage] = [:]

    private convenience init() {
        let root: URL
        if let override = ProcessInfo.processInfo.environment["SNAPOK_HISTORY_DIR"]
            ?? ProcessInfo.processInfo.environment["SNAPANY_HISTORY_DIR"] {
            // Tests point the store at a scratch folder so they never touch the real library.
            root = URL(fileURLWithPath: override, isDirectory: true)
        } else {
            // Development and release builds keep separate libraries.
            if let path = UserDefaults.standard.string(forKey: Self.locationKey), !path.isEmpty {
                root = URL(fileURLWithPath: path, isDirectory: true)
            } else {
                root = Self.defaultRoot
                LegacyMigration.run(historyRoot: root)
            }
        }
        self.init(root: root)
    }

    init(root: URL, defaults: UserDefaults = .standard) {
        self.root = root
        self.defaults = defaults
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        load()
        purgeExpired()
    }

    /// Switch the active library; optionally copy existing captures before committing the location.
    func changeLocation(to destination: URL, copyExisting: Bool = false) throws {
        let fm = FileManager.default
        let source = root.resolvingSymlinksInPath().standardizedFileURL
        let target = destination.resolvingSymlinksInPath().standardizedFileURL
        guard target != source else { return }
        let entries = copyExisting
            ? try fm.contentsOfDirectory(at: source, includingPropertiesForKeys: nil).filter { UUID(uuidString: $0.lastPathComponent) != nil }
            : []
        if target.path.hasPrefix(source.path + "/") {
            let relative = String(target.path.dropFirst(source.path.count + 1))
            if let first = relative.split(separator: "/").first, UUID(uuidString: String(first)) != nil {
                throw LibraryLocationError.nestedFolder
            }
        }
        for entry in entries {
            let capture = entry.resolvingSymlinksInPath().standardizedFileURL
            if target == capture || target.path.hasPrefix(capture.path + "/") {
                throw LibraryLocationError.nestedFolder
            }
        }
        try fm.createDirectory(at: target, withIntermediateDirectories: true)
        let staging = target.appendingPathComponent(".snapok-migration-" + UUID().uuidString, isDirectory: true)
        try fm.createDirectory(at: staging, withIntermediateDirectories: false)
        defer { try? fm.removeItem(at: staging) }
        var pending: [String] = []
        for entry in entries {
            let existing = target.appendingPathComponent(entry.lastPathComponent)
            if fm.fileExists(atPath: existing.path) {
                guard fm.contentsEqual(atPath: entry.path, andPath: existing.path) else {
                    throw LibraryLocationError.conflictingScreenshot
                }
            } else {
                try fm.copyItem(at: entry, to: staging.appendingPathComponent(entry.lastPathComponent))
                pending.append(entry.lastPathComponent)
            }
        }
        var installed: [URL] = []
        do {
            for name in pending {
                let url = target.appendingPathComponent(name)
                try fm.moveItem(at: staging.appendingPathComponent(name), to: url)
                installed.append(url)
            }
        } catch {
            installed.forEach { try? fm.removeItem(at: $0) }
            throw error
        }
        root = target
        defaults.set(target.path, forKey: Self.locationKey)
        thumbnails.removeAll()
        load()
        notify()
    }

    func restoreDefaultLocation() throws {
        try changeLocation(to: Self.defaultRoot)
        defaults.removeObject(forKey: Self.locationKey)
    }

    private func folder(_ id: UUID) -> URL { root.appendingPathComponent(id.uuidString, isDirectory: true) }
    private func originalURL(_ id: UUID) -> URL { folder(id).appendingPathComponent("original.png") }
    private func thumbnailURL(_ id: UUID) -> URL { folder(id).appendingPathComponent("thumbnail.png") }
    private func metaURL(_ id: UUID) -> URL { folder(id).appendingPathComponent("meta.json") }

    private func load() {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let folders = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        items = folders.compactMap { folder in
            guard let data = try? Data(contentsOf: folder.appendingPathComponent("meta.json")) else { return nil }
            return try? decoder.decode(HistoryItem.self, from: data)
        }.sorted { $0.createdAt > $1.createdAt }
    }

    private func notify() {
        NotificationCenter.default.post(name: Self.didChange, object: self)
    }

    private func writeMeta(_ item: HistoryItem) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        do {
            try encoder.encode(item).write(to: metaURL(item.id), options: .atomic)
        } catch {
            log("history meta write failed", error: error)
        }
    }

    private func writeThumbnail(for item: HistoryItem, original: NSImage) {
        guard let rendered = render(original: original, item: item),
              let thumbnail = rendered.scaled(maxPixel: 640) else { return }
        try? thumbnail.pngData?.write(to: thumbnailURL(item.id), options: .atomic)
        thumbnails[item.id] = thumbnail
    }

    /// Records a finished capture. Returns nil when auto-save is off or the write fails.
    @discardableResult
    func add(original: NSImage, annotations: [Annotation], style: CaptureStyle? = nil) -> HistoryItem? {
        guard AppSettings.autoSave,
              let cgImage = original.cgImage(forProposedRect: nil, context: nil, hints: nil),
              let png = original.pngData else { return nil }

        var item = HistoryItem(
            id: UUID(),
            createdAt: Date(),
            pointSize: original.size,
            pixelSize: CGSize(width: cgImage.width, height: cgImage.height),
            title: "",
            tags: [],
            ocrText: "",
            annotations: annotations
        )
        do {
            try FileManager.default.createDirectory(at: folder(item.id), withIntermediateDirectories: true)
            try png.write(to: originalURL(item.id), options: .atomic)
            if let style {
                item.backgroundStyle = try style.snapshot(in: folder(item.id))
                item.pixelSize = style.layout.canvasSize(for: item.pixelSize)
            }
        } catch {
            log("history write failed", error: error)
            return nil
        }
        writeMeta(item)
        writeThumbnail(for: item, original: original)
        items.insert(item, at: 0)
        notify()
        AIAssistant.enrich(item)
        return item
    }

    /// Saves a translated derivative without overwriting its source or running AI naming again.
    /// Explicit saves work even when automatic screenshot saving is disabled.
    @discardableResult
    func saveTranslation(png: Data, target: String, text: String, replacing id: UUID? = nil) throws -> UUID {
        guard let bitmap = NSBitmapImageRep(data: png), let cgImage = bitmap.cgImage else {
            throw CocoaError(.fileReadCorruptFile)
        }
        let size = CGSize(width: cgImage.width, height: cgImage.height)
        let image = NSImage(cgImage: cgImage, size: size)
        let index = id.flatMap { savedID in items.firstIndex { $0.id == savedID } }
        var item = index.map { items[$0] } ?? HistoryItem(
            id: UUID(), createdAt: Date(), pointSize: size, pixelSize: size,
            title: L("Translated Image · \(target)", "翻译图片 · \(target)"),
            tags: ["translation", target], ocrText: text, annotations: [])
        item.ocrText = text
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let metadata = try encoder.encode(item)
        try FileManager.default.createDirectory(at: folder(item.id), withIntermediateDirectories: true)
        try png.write(to: originalURL(item.id), options: .atomic)
        try metadata.write(to: metaURL(item.id), options: .atomic)
        writeThumbnail(for: item, original: image)
        if let index { items[index] = item } else { items.insert(item, at: 0) }
        notify()
        return item.id
    }

    func item(_ id: UUID) -> HistoryItem? {
        items.first { $0.id == id }
    }

    func update(_ id: UUID, regenerateThumbnail: Bool = false, change: (inout HistoryItem) -> Void) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        change(&items[index])
        writeMeta(items[index])
        if regenerateThumbnail, let original = original(for: items[index]) {
            writeThumbnail(for: items[index], original: original)
        }
        notify()
    }

    func original(for item: HistoryItem) -> NSImage? {
        guard let image = NSImage(contentsOf: originalURL(item.id)),
              let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        return NSImage(cgImage: cgImage, size: item.pointSize)
    }

    func thumbnail(for item: HistoryItem) -> NSImage? {
        if let cached = thumbnails[item.id] { return cached }
        let image = NSImage(contentsOf: thumbnailURL(item.id))
        thumbnails[item.id] = image
        return image
    }

    func rendered(for item: HistoryItem) -> NSImage? {
        original(for: item).flatMap { render(original: $0, item: item) }
    }

    func backgroundPreferences(for item: HistoryItem) -> BackgroundPreferences? {
        guard var preferences = item.backgroundStyle else { return nil }
        if let path = preferences.customImagePath, !path.hasPrefix("/") {
            preferences.customImagePath = folder(item.id).appendingPathComponent(path).path
        }
        return preferences
    }

    private func render(original: NSImage, item: HistoryItem) -> NSImage? {
        guard let annotated = HistoryRenderer.render(original: original, annotations: item.annotations) else { return nil }
        guard let preferences = backgroundPreferences(for: item) else { return annotated }
        return CaptureStyle(preferences: preferences).render(annotated)
    }

    func updateEditor(_ id: UUID, annotations: [Annotation], style: CaptureStyle) {
        guard let item = item(id), let original = original(for: item),
              let source = original.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return }
        do {
            let preferences = try style.snapshot(in: folder(id))
            update(id, regenerateThumbnail: true) {
                $0.annotations = annotations
                $0.backgroundStyle = preferences
                $0.pixelSize = style.layout.canvasSize(for: CGSize(width: source.width, height: source.height))
            }
        } catch { log("history editor style write failed", error: error) }
    }

    func fileURL(for item: HistoryItem) -> URL { originalURL(item.id) }

    func delete(_ ids: [UUID]) {
        for id in ids {
            try? FileManager.default.removeItem(at: folder(id))
            thumbnails[id] = nil
        }
        items.removeAll { ids.contains($0.id) }
        notify()
    }

    func clearAll() {
        delete(items.map(\.id))
    }

    func purgeExpired() {
        let days = AppSettings.retentionDays
        guard days > 0 else { return }
        let cutoff = Date().addingTimeInterval(-Double(days) * 24 * 60 * 60)
        let expired = items.filter { $0.createdAt < cutoff }.map(\.id)
        if !expired.isEmpty {
            delete(expired)
        }
    }
}

enum LibraryLocationError: LocalizedError {
    case nestedFolder, conflictingScreenshot

    var errorDescription: String? {
        switch self {
        case .nestedFolder: return L("Choose a library folder rather than a folder inside an individual screenshot's data.", "请选择普通文件夹作为截图库，不能存放到某张截图的数据文件夹里。")
        case .conflictingScreenshot: return L("The destination contains a different version of an existing screenshot. Choose an empty folder to keep both libraries intact.", "目标文件夹包含同一截图的不同版本，请选择空文件夹，避免覆盖现有数据。")
        }
    }
}

/// Flattens an original capture and its annotations at full pixel resolution.
@MainActor
enum HistoryRenderer {
    static func render(original: NSImage, annotations: [Annotation]) -> NSImage? {
        guard let source = original.cgImage(forProposedRect: nil, context: nil, hints: nil),
              let colorSpace = source.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                data: nil, width: source.width, height: source.height, bitsPerComponent: 8, bytesPerRow: 0,
                space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              ) else {
            return nil
        }
        context.draw(source, in: CGRect(x: 0, y: 0, width: source.width, height: source.height))
        if !annotations.isEmpty {
            let scale = CGFloat(source.width) / original.size.width
            context.scaleBy(x: scale, y: scale)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
            for annotation in annotations {
                AnnotationRenderer.draw(annotation, in: context, sourceImage: original, origin: .zero, localImage: true)
            }
            NSGraphicsContext.restoreGraphicsState()
        }
        guard let output = context.makeImage() else { return nil }
        return NSImage(cgImage: output, size: original.size)
    }
}

extension NSImage {
    /// Downscales so the longest side is at most `maxPixel` pixels; returns self-sized copies unchanged.
    func scaled(maxPixel: CGFloat) -> NSImage? {
        guard let source = cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        let longest = CGFloat(max(source.width, source.height))
        let factor = min(1, maxPixel / longest)
        let width = max(1, Int(CGFloat(source.width) * factor))
        let height = max(1, Int(CGFloat(source.height) * factor))
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              ) else {
            return nil
        }
        context.interpolationQuality = .high
        context.draw(source, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage().map { NSImage(cgImage: $0, size: CGSize(width: width, height: height)) }
    }
}
