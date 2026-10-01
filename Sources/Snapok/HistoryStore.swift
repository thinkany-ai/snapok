import AppKit
import Security

/// User-facing settings backed by UserDefaults. The API key lives in the Keychain, not here.
enum AppSettings {
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

    static var aiBaseURL: String {
        get { defaults.string(forKey: "ai.baseURL") ?? "https://api.anthropic.com" }
        set { defaults.set(newValue, forKey: "ai.baseURL") }
    }

    static var aiModel: String {
        get { defaults.string(forKey: "ai.model") ?? "claude-opus-5-5" }
        set { defaults.set(newValue, forKey: "ai.model") }
    }

    static var translateTarget: String {
        get { defaults.string(forKey: "ai.translateTarget") ?? "简体中文" }
        set { defaults.set(newValue, forKey: "ai.translateTarget") }
    }

    /// Sends each new screenshot to the AI service for a title and tags; off until the user opts in.
    static var autoName: Bool {
        get { defaults.bool(forKey: "ai.autoName") }
        set { defaults.set(newValue, forKey: "ai.autoName") }
    }

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
        case kind, rect, points, text, color, sizeLevel
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
            sizeLevel: try container.decode(Int.self, forKey: .sizeLevel)
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

    let root: URL
    private(set) var items: [HistoryItem] = []
    private var thumbnails: [UUID: NSImage] = [:]

    private init() {
        if let override = ProcessInfo.processInfo.environment["SNAPOK_HISTORY_DIR"]
            ?? ProcessInfo.processInfo.environment["SNAPANY_HISTORY_DIR"] {
            // Tests point the store at a scratch folder so they never touch the real library.
            root = URL(fileURLWithPath: override, isDirectory: true)
        } else {
            // Development and release builds keep separate libraries.
            root = AppChannel.supportDirectory.appendingPathComponent("History", isDirectory: true)
            LegacyMigration.run(historyRoot: root)
        }
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        load()
        purgeExpired()
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
            log("history meta write failed: \(error)")
        }
    }

    private func writeThumbnail(for item: HistoryItem, original: NSImage) {
        guard let rendered = HistoryRenderer.render(original: original, annotations: item.annotations),
              let thumbnail = rendered.scaled(maxPixel: 640) else { return }
        try? thumbnail.pngData?.write(to: thumbnailURL(item.id), options: .atomic)
        thumbnails[item.id] = thumbnail
    }

    /// Records a finished capture. Returns nil when auto-save is off or the write fails.
    @discardableResult
    func add(original: NSImage, annotations: [Annotation]) -> HistoryItem? {
        guard AppSettings.autoSave,
              let cgImage = original.cgImage(forProposedRect: nil, context: nil, hints: nil),
              let png = original.pngData else { return nil }

        let item = HistoryItem(
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
        } catch {
            log("history write failed: \(error)")
            return nil
        }
        writeMeta(item)
        writeThumbnail(for: item, original: original)
        items.insert(item, at: 0)
        notify()
        AIAssistant.enrich(item)
        return item
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
        original(for: item).flatMap { HistoryRenderer.render(original: $0, annotations: item.annotations) }
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
