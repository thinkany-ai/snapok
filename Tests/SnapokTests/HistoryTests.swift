import AppKit
extension Bundle { static var module: Bundle { .main } }

@main @MainActor
struct HistoryTests {
    static func main() async throws {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)

        // Annotations survive a JSON round trip, including color and kind.
        let annotations = [
            Annotation(kind: .arrow, rect: CGRect(x: 10, y: 20, width: 30, height: 40), points: [CGPoint(x: 10, y: 20), CGPoint(x: 40, y: 60)],
                       color: NSColor(srgbRed: 0.2, green: 0.4, blue: 0.6, alpha: 1), sizeLevel: 2),
            Annotation(kind: .text, rect: CGRect(x: 5, y: 5, width: 50, height: 20), points: [], text: "你好", color: .white, sizeLevel: 0)
        ]
        let decoded = try JSONDecoder().decode([Annotation].self, from: JSONEncoder().encode(annotations))
        precondition(decoded.count == 2 && decoded[0].kind == .arrow && decoded[1].text == "你好", "annotations must round-trip")
        precondition(decoded[0].color.matches(annotations[0].color) && decoded[0].points == annotations[0].points, "color and points must round-trip")

        // Sensitive values are found; ordinary words are not.
        let sample = "联系 13812345678 或 dev@example.com，密码: hunter2-secret，key sk-ant-abcdefghijklmnopqrstuv"
        let found = SensitiveDetector.ranges(in: sample).map { String(sample[$0]) }
        for expected in ["13812345678", "dev@example.com", "hunter2-secret，key", "sk-ant-abcdefghijklmnopqrstuv"] where !found.contains(where: { $0.hasPrefix(expected.prefix(8)) }) {
            preconditionFailure("missed sensitive value \(expected); found \(found)")
        }
        precondition(SensitiveDetector.ranges(in: "截图工具 Snapok version 2").isEmpty, "plain text must not be flagged")

        // A mosaic mask covers its box, with a zigzag when the box is taller than the widest brush.
        let tall = SensitiveDetector.mosaic(covering: CGRect(x: 0, y: 0, width: 200, height: 90))
        precondition(tall.kind == .mosaic && tall.points.count >= 4, "tall boxes need several mosaic rows")
        let short = SensitiveDetector.mosaic(covering: CGRect(x: 0, y: 0, width: 120, height: 10))
        precondition(short.points.count == 2 && short.lineWidth >= 16, "short boxes take one stroke wide enough to cover them")

        // The store writes, updates, reloads and deletes in a scratch folder.
        let image = render("Email: dev@example.com  Phone: 13812345678", size: CGSize(width: 900, height: 120))
        let store = HistoryStore.shared
        precondition(store.root.path.hasPrefix(NSTemporaryDirectory()) || store.root.path.hasPrefix("/private/var") || store.root.path.hasPrefix("/var"),
                     "tests must use a scratch history folder")
        guard let item = store.add(original: image, annotations: annotations) else { preconditionFailure("add failed") }
        precondition(store.items.first?.id == item.id && item.pixelSize == CGSize(width: 1800, height: 240), "item keeps pixel size")
        precondition(store.thumbnail(for: item) != nil && store.original(for: item)?.size == image.size, "original and thumbnail stored")
        store.update(item.id, regenerateThumbnail: true) { $0.title = "测试"; $0.annotations = [] }
        precondition(store.item(item.id)?.title == "测试" && store.item(item.id)?.annotations.isEmpty == true, "update persists")
        precondition(store.items.first?.matches("测试") == true && store.items.first?.matches("不存在") == false, "search matches titles")
        let rendered = store.rendered(for: store.item(item.id)!)
        precondition(rendered?.size == image.size, "rendered copy keeps point size")

        // Reuse is opt-in; framing uses image pixels, preserving editable Retina originals.
        let previousReuse = AppSettings.reuseEditorStyle
        let previousPreferences = UserDefaults.standard.data(forKey: BackgroundPreferences.key)
        defer {
            AppSettings.reuseEditorStyle = previousReuse
            if let previousPreferences { UserDefaults.standard.set(previousPreferences, forKey: BackgroundPreferences.key) }
            else { UserDefaults.standard.removeObject(forKey: BackgroundPreferences.key) }
        }
        var frame = BackgroundPreferences()
        frame.horizontalPadding = 24
        frame.verticalPadding = 12
        frame.cornerRadius = 0
        frame.shadow = false
        frame.backgroundType = 2
        frame.backgroundColor = [0, 0, 1, 1]
        frame.save()
        AppSettings.reuseEditorStyle = false
        precondition(CaptureStyle.forNewCapture(screen: nil) == nil, "Disabled reuse must leave new screenshots unframed")
        AppSettings.reuseEditorStyle = true
        let reuse = CaptureStyle.forNewCapture(screen: nil)!
        let framedSize = CGSize(width: 1848, height: 264)
        let annotated = HistoryRenderer.render(original: image, annotations: annotations)!
        precondition(reuse.render(annotated)?.size == framedSize, "Direct exports must add pixel padding exactly once")
        let styledItem = store.add(original: image, annotations: annotations, style: reuse)!
        let styledOriginalBytes = try Data(contentsOf: store.fileURL(for: styledItem))
        precondition(styledOriginalBytes == image.pngData!, "Framing must never flatten or replace the editable original")
        precondition(styledItem.pixelSize == framedSize && styledItem.pointSize == image.size)
        precondition(store.rendered(for: styledItem)?.size == framedSize && store.thumbnail(for: styledItem) != nil)
        let directPixels = NSBitmapImageRep(cgImage: reuse.render(annotated)!.cgImage(forProposedRect: nil, context: nil, hints: nil)!)
        let libraryPixels = NSBitmapImageRep(cgImage: store.rendered(for: styledItem)!.cgImage(forProposedRect: nil, context: nil, hints: nil)!)
        let paddingColor = directPixels.colorAt(x: 0, y: 0)!
        precondition(paddingColor.redComponent < 0.01 && paddingColor.greenComponent < 0.01 && paddingColor.blueComponent > 0.99,
                     "The saved solid background must fill the padding")
        for y in stride(from: 0, to: Int(framedSize.height), by: 7) {
            for x in stride(from: 0, to: Int(framedSize.width), by: 13) {
                precondition(directPixels.colorAt(x: x, y: y)!.matches(libraryPixels.colorAt(x: x, y: y)!),
                             "Direct and library rendering must agree on Retina annotation positions")
            }
        }
        frame.horizontalPadding = 100
        frame.save()
        precondition(store.rendered(for: styledItem)?.size == framedSize, "Later style choices must not change old screenshots")
        store.updateEditor(styledItem.id, annotations: [], style: reuse)
        precondition(store.rendered(for: store.item(styledItem.id)!)?.size == framedSize, "Re-editing must not double padding")

        // Image backgrounds are snapshotted and continue to work after library relocation.
        let styleRoot = store.root.deletingLastPathComponent().appendingPathComponent("style-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: styleRoot) }
        let styledStore = HistoryStore(root: styleRoot.appendingPathComponent("old"))
        let background = render("Background", size: CGSize(width: 80, height: 80))
        let imageStyle = CaptureStyle(preferences: reuse.preferences, background: .image(background))
        let imageItem = styledStore.add(original: image, annotations: [], style: imageStyle)!
        precondition(imageItem.backgroundStyle?.customImagePath == "background.png")
        let snapshotPath = styledStore.backgroundPreferences(for: imageItem)!.customImagePath!
        let snapshotBytes = try Data(contentsOf: URL(fileURLWithPath: snapshotPath))
        try styledStore.changeLocation(to: styleRoot.appendingPathComponent("new"), copyExisting: true)
        let movedStyle = styledStore.item(imageItem.id)!
        let movedPath = styledStore.backgroundPreferences(for: movedStyle)!.customImagePath!
        precondition(movedPath != snapshotPath && FileManager.default.fileExists(atPath: movedPath))
        let movedBytes = try Data(contentsOf: URL(fileURLWithPath: movedPath))
        precondition(movedBytes == snapshotBytes && styledStore.rendered(for: movedStyle)?.size == framedSize)
        var missing = reuse.preferences
        missing.backgroundType = 3
        missing.customImagePath = styleRoot.appendingPathComponent("missing.png").path
        precondition(CaptureStyle(preferences: missing).render(image)?.size == framedSize,
                     "Unavailable backgrounds must fall back to a gradient like the editor")
        store.delete([styledItem.id])
        var customPreferences = reuse.preferences
        customPreferences.backgroundType = 4
        customPreferences.customGradient = .init(start: [1, 0, 0, 1], end: [0, 0, 1, 1], angle: 90)
        let customStyle = CaptureStyle(preferences: customPreferences)
        let gradientItem = store.add(original: image, annotations: [], style: customStyle)!
        precondition(gradientItem.backgroundStyle?.customGradient == customPreferences.customGradient)
        precondition(store.rendered(for: gradientItem)?.pngData == customStyle.render(image)?.pngData,
                     "Custom gradients must render identically for direct captures and reopened library items")
        store.delete([gradientItem.id])

        // Changing folders preserves editable captures and only commits the preference on success.
        let migrationRoot = store.root.deletingLastPathComponent().appendingPathComponent("migration-" + UUID().uuidString)
        let locationSuite = "SnapokLibraryLocation-" + UUID().uuidString
        let locationDefaults = UserDefaults(suiteName: locationSuite)!
        defer {
            try? FileManager.default.removeItem(at: migrationRoot)
            locationDefaults.removePersistentDomain(forName: locationSuite)
        }
        let oldRoot = migrationRoot.appendingPathComponent("old")
        let newRoot = migrationRoot.appendingPathComponent("new")
        let moving = HistoryStore(root: oldRoot, defaults: locationDefaults)
        let movingItem = moving.add(original: image, annotations: annotations)!
        let originalBytes = try Data(contentsOf: moving.fileURL(for: movingItem))
        try moving.changeLocation(to: newRoot, copyExisting: true)
        precondition(moving.root == newRoot.resolvingSymlinksInPath().standardizedFileURL)
        precondition(locationDefaults.string(forKey: HistoryStore.locationKey) == moving.root.path)
        let copiedBytes = try Data(contentsOf: moving.fileURL(for: movingItem))
        precondition(copiedBytes == originalBytes)
        precondition(FileManager.default.fileExists(atPath: oldRoot.appendingPathComponent(movingItem.id.uuidString).appendingPathComponent("original.png").path), "Keep the source library as a backup")
        let reopened = HistoryStore(root: moving.root, defaults: locationDefaults)
        precondition(reopened.item(movingItem.id)?.annotations.count == annotations.count)
        precondition(reopened.original(for: movingItem)?.size == image.size && reopened.thumbnail(for: movingItem) != nil)
        let later = moving.add(original: image, annotations: [])!
        precondition(moving.fileURL(for: later).path.hasPrefix(moving.root.path + "/"))
        precondition(!FileManager.default.fileExists(atPath: oldRoot.appendingPathComponent(later.id.uuidString).path))
        do {
            try moving.changeLocation(to: moving.root.appendingPathComponent(movingItem.id.uuidString).appendingPathComponent("nested"))
            preconditionFailure("A destination inside screenshot data must be rejected")
        } catch LibraryLocationError.nestedFolder {}
        let ordinaryChild = moving.root.appendingPathComponent("Screenshots")
        try moving.changeLocation(to: ordinaryChild, copyExisting: true)
        precondition(moving.root == ordinaryChild.resolvingSymlinksInPath().standardizedFileURL && moving.item(later.id) != nil,
                     "An ordinary child folder is a valid library location")
        try moving.changeLocation(to: migrationRoot, copyExisting: true)
        precondition(moving.root == migrationRoot.resolvingSymlinksInPath().standardizedFileURL && moving.item(later.id) != nil,
                     "A parent folder such as the user's home must be a valid library location")
        let beforeFailure = moving.root
        let conflictRoot = migrationRoot.appendingPathComponent("conflict")
        let conflictingFolder = conflictRoot.appendingPathComponent(movingItem.id.uuidString)
        try FileManager.default.createDirectory(at: conflictingFolder, withIntermediateDirectories: true)
        try Data("existing data".utf8).write(to: conflictingFolder.appendingPathComponent("original.png"))
        do {
            try moving.changeLocation(to: conflictRoot, copyExisting: true)
            preconditionFailure("Different existing captures must never be overwritten")
        } catch LibraryLocationError.conflictingScreenshot {}
        precondition(moving.root == beforeFailure && locationDefaults.string(forKey: HistoryStore.locationKey) == beforeFailure.path)
        let preservedConflict = try Data(contentsOf: conflictingFolder.appendingPathComponent("original.png"))
        precondition(preservedConflict == Data("existing data".utf8))
        let remainingFiles = try FileManager.default.contentsOfDirectory(atPath: conflictRoot.path)
        precondition(remainingFiles == [movingItem.id.uuidString], "Failed copies must remove migration staging files")
        let freshRoot = migrationRoot.appendingPathComponent("fresh")
        let previousRoot = moving.root
        try moving.changeLocation(to: freshRoot)
        precondition(moving.items.isEmpty, "By default changing folders must not copy previous screenshots")
        precondition(!FileManager.default.fileExists(atPath: freshRoot.appendingPathComponent(movingItem.id.uuidString).path))
        precondition(FileManager.default.fileExists(atPath: previousRoot.appendingPathComponent(movingItem.id.uuidString).path))
        let freshItem = moving.add(original: image, annotations: [])!
        precondition(moving.fileURL(for: freshItem).path.hasPrefix(moving.root.path + "/"))
        precondition(!FileManager.default.fileExists(atPath: previousRoot.appendingPathComponent(freshItem.id.uuidString).path))
        try moving.changeLocation(to: previousRoot)
        precondition(moving.item(movingItem.id) != nil && moving.item(freshItem.id) == nil,
                     "Switching back without copying must reopen the old library without merging captures")
        moving.delete([movingItem.id, later.id])
        precondition(FileManager.default.fileExists(atPath: oldRoot.appendingPathComponent(movingItem.id.uuidString).path), "Deleting from the active library must leave its backup intact")


        // On-device text recognition reads the text and boxes the sensitive values.
        let scan = await TextScanner.scan(image.cgImage(forProposedRect: nil, context: nil, hints: nil)!)
        precondition(scan.text.contains("example.com"), "OCR must read the rendered text, got: \(scan.text)")
        precondition(scan.sensitiveBoxes.count >= 2, "email and phone must be boxed, got \(scan.sensitiveBoxes.count)")

        // A translated derivative gets its own item and updates in place while preserving the source.
        let autoSave = AppSettings.autoSave
        AppSettings.autoSave = false
        defer { AppSettings.autoSave = autoSave }
        let sourcePNG = image.pngData!
        let sourceBefore = try Data(contentsOf: store.fileURL(for: item))
        let translatedID = try store.saveTranslation(png: sourcePNG, target: "日本語", text: "設定 保存")
        let count = store.items.count
        guard let translated = store.item(translatedID) else { preconditionFailure("translation not saved") }
        precondition(translated.tags.contains("日本語") && translated.matches("設定"), "translation must be searchable")
        precondition(store.original(for: translated) != nil && store.thumbnail(for: translated) != nil)
        let revisedPNG = render("Updated translation", size: image.size).pngData!
        let revisedID = try store.saveTranslation(png: revisedPNG, target: "日本語", text: "修正した翻訳", replacing: translatedID)
        precondition(revisedID == translatedID && store.items.count == count, "Edits must update the same library item")
        precondition(store.item(translatedID)!.matches("修正した翻訳"))
        let savedPNG = try Data(contentsOf: store.fileURL(for: store.item(translatedID)!))
        precondition(savedPNG == revisedPNG, "Latest translated pixels must be persisted")
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decodedTranslation = try decoder.decode(HistoryItem.self, from: Data(contentsOf: store.root.appendingPathComponent(translatedID.uuidString).appendingPathComponent("meta.json")))
        precondition(decodedTranslation.id == translatedID && decodedTranslation.ocrText == "修正した翻訳")
        let sourceAfter = try Data(contentsOf: store.fileURL(for: item))
        precondition(sourceAfter == sourceBefore && translatedID != item.id, "Translated edits must leave the source capture intact")
        store.delete([translatedID])
        store.delete([item.id])
        precondition(store.item(item.id) == nil && !FileManager.default.fileExists(atPath: store.root.appendingPathComponent(item.id.uuidString).path),
                     "delete removes the folder")

        print("Passed history checks: annotation coding, sensitive detection, mosaic coverage, store lifecycle, on-device OCR, translated-image persistence")
    }

    static func render(_ text: String, size: CGSize) -> NSImage {
        let context = CGContext(data: nil, width: Int(size.width * 2), height: Int(size.height * 2), bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(red: 1, green: 1, blue: 1, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: size.width * 2, height: size.height * 2))
        context.scaleBy(x: 2, y: 2)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        text.draw(at: CGPoint(x: 20, y: 40), withAttributes: [.font: NSFont.systemFont(ofSize: 32), .foregroundColor: NSColor.black])
        NSGraphicsContext.restoreGraphicsState()
        return NSImage(cgImage: context.makeImage()!, size: size)
    }
}
