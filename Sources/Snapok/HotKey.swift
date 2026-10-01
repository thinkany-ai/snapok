import AppKit
import Carbon

/// A global shortcut: a virtual key code plus Carbon modifier flags, with the key's display name.
struct HotKey: Equatable, Sendable {
    var keyCode: UInt32
    var modifiers: UInt32
    var key: String

    static let preferenceKey = "app.hotKey"

    /// Apple's menu order: ⌃ ⌥ ⇧ ⌘.
    private static let modifierOrder: [(flag: Int, symbol: String, name: String, menu: NSEvent.ModifierFlags)] = [
        (controlKey, "⌃", "Control", .control),
        (optionKey, "⌥", "Option", .option),
        (shiftKey, "⇧", "Shift", .shift),
        (cmdKey, "⌘", "Command", .command)
    ]

    private static let namedKeys: [Int: String] = [
        kVK_Space: "Space", kVK_Return: "↩", kVK_Tab: "⇥", kVK_Delete: "⌫", kVK_ForwardDelete: "⌦", kVK_Escape: "⎋",
        kVK_LeftArrow: "←", kVK_RightArrow: "→", kVK_UpArrow: "↑", kVK_DownArrow: "↓",
        kVK_Home: "↖", kVK_End: "↘", kVK_PageUp: "⇞", kVK_PageDown: "⇟", kVK_ANSI_KeypadEnter: "⌤",
        kVK_F1: "F1", kVK_F2: "F2", kVK_F3: "F3", kVK_F4: "F4", kVK_F5: "F5", kVK_F6: "F6", kVK_F7: "F7", kVK_F8: "F8",
        kVK_F9: "F9", kVK_F10: "F10", kVK_F11: "F11", kVK_F12: "F12", kVK_F13: "F13", kVK_F14: "F14", kVK_F15: "F15",
        kVK_F16: "F16", kVK_F17: "F17", kVK_F18: "F18", kVK_F19: "F19", kVK_F20: "F20"
    ]

    /// Reads a shortcut from a key press. Returns nil for modifier-only presses.
    init?(event: NSEvent) {
        guard event.type == .keyDown else { return nil }
        let code = Int(event.keyCode)
        guard let name = Self.namedKeys[code] ?? event.characters(byApplyingModifiers: [])?.uppercased(),
              !name.isEmpty, !name.contains(where: \.isNewline) else { return nil }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        keyCode = UInt32(code)
        modifiers = Self.modifierOrder.reduce(0) { flags.contains($1.menu) ? $0 | UInt32($1.flag) : $0 }
        key = name
    }

    init(keyCode: UInt32, modifiers: UInt32, key: String) {
        self.keyCode = keyCode
        self.modifiers = modifiers
        self.key = key
    }

    private var activeModifiers: [(flag: Int, symbol: String, name: String, menu: NSEvent.ModifierFlags)] {
        Self.modifierOrder.filter { modifiers & UInt32($0.flag) != 0 }
    }

    var isFunctionKey: Bool { key.count > 1 && key.hasPrefix("F") && Int(key.dropFirst()) != nil }

    /// A global shortcut needs ⌃, ⌥, or ⌘ (Shift alone would swallow typing); function keys may stand alone.
    var isValidGlobalShortcut: Bool {
        isFunctionKey || modifiers & UInt32(controlKey | optionKey | cmdKey) != 0
    }

    var keys: [String] { activeModifiers.map(\.symbol) + [key] }

    var symbol: String { keys.joined() }

    var description: String { (activeModifiers.map(\.name) + [key]).joined(separator: " + ") }

    var menuModifiers: NSEvent.ModifierFlags { NSEvent.ModifierFlags(activeModifiers.map(\.menu)) }

    /// Menus can show single printable keys only; others go without a key equivalent.
    var menuKeyEquivalent: String { key.count == 1 && Self.namedKeys[Int(keyCode)] == nil ? key.lowercased() : "" }

    static func saved(in defaults: UserDefaults = .standard, default fallback: HotKey) -> HotKey {
        guard let stored = defaults.dictionary(forKey: preferenceKey),
              let code = stored["keyCode"] as? Int, let flags = stored["modifiers"] as? Int, let key = stored["key"] as? String,
              case let hotKey = HotKey(keyCode: UInt32(code), modifiers: UInt32(flags), key: key), hotKey.isValidGlobalShortcut
        else { return fallback }
        return hotKey
    }

    func save(in defaults: UserDefaults = .standard) {
        defaults.set(["keyCode": Int(keyCode), "modifiers": Int(modifiers), "key": key], forKey: Self.preferenceKey)
    }
}

/// Owns the Carbon registration of the capture shortcut so it can be changed while the app runs.
@MainActor
final class HotKeyCenter {
    static let shared = HotKeyCenter()
    static let didChange = Notification.Name("HotKeyCenter.didChange")
    private static let signature = OSType(0x534E4150)

    private(set) var current = HotKey.saved(default: AppChannel.defaultHotKey)
    var onPress: (() -> Void)?
    private var ref: EventHotKeyRef?

    func start() {
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            var hotKeyID = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                              nil, MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID)
            guard hotKeyID.signature == HotKeyCenter.signature, hotKeyID.id == 1 else { return noErr }
            log("hotkey pressed")
            Task { @MainActor in HotKeyCenter.shared.onPress?() }
            return noErr
        }, 1, &eventType, nil, nil)
        register(current)
    }

    /// Switches to a new shortcut; keeps the old one and returns false when macOS refuses it.
    func change(to hotKey: HotKey) -> Bool {
        guard register(hotKey) else {
            register(current)
            return false
        }
        current = hotKey
        hotKey.save()
        NotificationCenter.default.post(name: Self.didChange, object: nil)
        return true
    }

    /// Releases the shortcut while the user records a new one, so pressing it does not start a capture.
    func suspend() { unregister() }

    func resume() {
        if ref == nil { register(current) }
    }

    func stop() { unregister() }

    @discardableResult
    private func register(_ hotKey: HotKey) -> Bool {
        unregister()
        let status = RegisterEventHotKey(hotKey.keyCode, hotKey.modifiers, EventHotKeyID(signature: Self.signature, id: 1),
                                         GetApplicationEventTarget(), 0, &ref)
        log(status == noErr ? "hotkey registered: \(hotKey.description)" : "failed to register hotkey \(hotKey.description), status=\(status)")
        if status != noErr { ref = nil }
        return status == noErr
    }

    private func unregister() {
        if let ref { UnregisterEventHotKey(ref) }
        ref = nil
    }
}
