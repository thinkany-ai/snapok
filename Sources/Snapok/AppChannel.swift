import AppKit
import Carbon

/// Development and release builds run side by side with separate names, data, settings, and hotkeys.
/// The channel comes from `SnapokChannel` in Info.plist, which `scripts/build-app.sh` sets;
/// anything other than "release" (including `swift run`, which has no Info.plist) is a development build.
enum AppChannel {
    static let isRelease = (Bundle.main.object(forInfoDictionaryKey: "SnapokChannel") as? String) == "release"

    static var displayName: String { isRelease ? "Snapok" : "Snapok Dev" }

    /// Application Support and log folder names; UserDefaults are already split by bundle identifier.
    static var dataFolderName: String { displayName }

    static var keychainService: String { isRelease ? "ai.snapok.mac" : "ai.snapok.mac.dev" }

    /// ⌃⌘A for release, ⇧⌥A for development so both can be open at once. Users can change it in General settings.
    static var defaultHotKey: HotKey {
        isRelease
            ? HotKey(keyCode: UInt32(kVK_ANSI_A), modifiers: UInt32(controlKey | cmdKey), key: "A")
            : HotKey(keyCode: UInt32(kVK_ANSI_A), modifiers: UInt32(shiftKey | optionKey), key: "A")
    }

    static var supportDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(dataFolderName, isDirectory: true)
    }

    static var logURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/\(dataFolderName).log")
    }
}

/// One-time move of data written before the rename (SnapAny, bundle `ai.snapany.mac.test`).
/// Those builds were all development previews, so their data moves to the development channel only.
@MainActor
enum LegacyMigration {
    private static let legacyDefaultsDomain = "ai.snapany.mac.test"
    private static let legacyKeychainService = "ai.snapany.mac"
    private static let doneKey = "migration.snapany.done"

    static func run(historyRoot: URL) {
        let defaults = UserDefaults.standard
        guard !AppChannel.isRelease, !defaults.bool(forKey: doneKey) else { return }
        defer { defaults.set(true, forKey: doneKey) }

        let fileManager = FileManager.default
        let legacyHistory = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("SnapAny/History", isDirectory: true)
        if fileManager.fileExists(atPath: legacyHistory.path) {
            let existing = (try? fileManager.contentsOfDirectory(atPath: historyRoot.path)) ?? []
            do {
                if existing.isEmpty {
                    try? fileManager.removeItem(at: historyRoot)
                    try fileManager.createDirectory(at: historyRoot.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try fileManager.moveItem(at: legacyHistory, to: historyRoot)
                } else {
                    for name in try fileManager.contentsOfDirectory(atPath: legacyHistory.path) where !existing.contains(name) {
                        try fileManager.moveItem(at: legacyHistory.appendingPathComponent(name), to: historyRoot.appendingPathComponent(name))
                    }
                }
                // Remove the emptied legacy folders, never anything still holding files.
                for folder in [legacyHistory, legacyHistory.deletingLastPathComponent()]
                where ((try? fileManager.contentsOfDirectory(atPath: folder.path)) ?? ["?"]).filter({ $0 != ".DS_Store" }).isEmpty {
                    try? fileManager.removeItem(at: folder)
                }
                log("moved legacy SnapAny history into \(historyRoot.path)")
            } catch {
                log("legacy history migration failed: \(error)")
            }
        }

        if let legacy = UserDefaults(suiteName: legacyDefaultsDomain) {
            for (key, value) in legacy.dictionaryRepresentation()
            where (key.hasPrefix("history.") || key.hasPrefix("ai.") || key.hasPrefix("app.")) && defaults.object(forKey: key) == nil {
                defaults.set(value, forKey: key)
            }
        }

        if AppSettings.apiKey == nil, let key = Keychain.read(account: "anthropic-api-key", service: legacyKeychainService) {
            AppSettings.apiKey = key
        }
    }
}
