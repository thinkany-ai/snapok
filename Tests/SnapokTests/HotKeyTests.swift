import AppKit
import Carbon
extension Bundle { static var module: Bundle { .main } }

@main @MainActor
struct HotKeyTests {
    static func main() {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)

        func press(_ characters: String, _ code: Int, _ flags: NSEvent.ModifierFlags) -> HotKey? {
            NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: 0, context: nil,
                             characters: characters, charactersIgnoringModifiers: characters, isARepeat: false, keyCode: UInt16(code))
                .flatMap(HotKey.init(event:))
        }

        // Key presses become shortcuts with modifiers in Apple's ⌃⌥⇧⌘ order.
        let captured = press("s", kVK_ANSI_S, [.command, .shift])!
        precondition(captured.keyCode == UInt32(kVK_ANSI_S) && captured.modifiers == UInt32(cmdKey | shiftKey))
        precondition(captured.symbol == "⇧⌘S" && captured.description == "Shift + Command + S", "got \(captured.symbol)")
        precondition(captured.menuKeyEquivalent == "s" && captured.menuModifiers == [.shift, .command])
        precondition(captured.isValidGlobalShortcut)

        // Shift alone would swallow typing; function keys may stand alone.
        precondition(!press("a", kVK_ANSI_A, [.shift])!.isValidGlobalShortcut)
        precondition(!press("a", kVK_ANSI_A, [])!.isValidGlobalShortcut)
        let f5 = press("\u{F708}", kVK_F5, [])!
        precondition(f5.key == "F5" && f5.isValidGlobalShortcut && f5.menuKeyEquivalent.isEmpty)
        precondition(press(" ", kVK_Space, [.control])!.symbol == "⌃Space")

        // Shortcuts persist; missing or invalid stored values fall back to the default.
        let suite = "Snapok.HotKeyTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let fallback = AppChannel.defaultHotKey
        precondition(HotKey.saved(in: defaults, default: fallback) == fallback)
        captured.save(in: defaults)
        precondition(HotKey.saved(in: UserDefaults(suiteName: suite)!, default: fallback) == captured)
        defaults.set(["keyCode": kVK_ANSI_A, "modifiers": shiftKey, "key": "A"], forKey: HotKey.preferenceKey)
        precondition(HotKey.saved(in: defaults, default: fallback) == fallback)
        precondition(fallback.symbol == "⌥⇧A", "development builds default to Shift + Option + A")

        print("Passed hotkey checks: capture, ordering, validation, menu equivalents, persistence")
    }
}
