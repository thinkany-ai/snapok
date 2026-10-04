import AppKit

/// A resolved frame, shared by direct capture exports and editable library entries.
@MainActor
struct CaptureStyle {
    var preferences: BackgroundPreferences
    var background: EditorBackground

    init(preferences: BackgroundPreferences, screen: NSScreen? = nil) {
        self.preferences = preferences
        switch preferences.backgroundType {
        case 1:
            if let screen = screen ?? NSScreen.main,
               let url = NSWorkspace.shared.desktopImageURL(for: screen),
               let image = NSImage(contentsOf: url) {
                background = .image(image)
            } else { background = .gradient(preferences.gradient) }
        case 2: background = .color(Self.color(preferences.backgroundColor))
        case 3:
            if let path = preferences.customImagePath, let image = NSImage(contentsOfFile: path) {
                background = .image(image)
            } else { background = .gradient(preferences.gradient) }
        default: background = .gradient(preferences.gradient)
        }
    }

    init(preferences: BackgroundPreferences, background: EditorBackground) {
        self.preferences = preferences
        self.background = background
    }

    static func forNewCapture(screen: NSScreen?) -> Self? {
        AppSettings.reuseEditorStyle ? Self(preferences: .load(), screen: screen) : nil
    }

    var layout: BackgroundLayout {
        BackgroundLayout(horizontalPadding: CGFloat(preferences.horizontalPadding),
                         verticalPadding: CGFloat(preferences.verticalPadding),
                         cornerRadius: CGFloat(preferences.cornerRadius), shadow: preferences.shadow,
                         borderWidth: CGFloat(preferences.borderWidth), borderColor: Self.color(preferences.borderColor))
    }

    func render(_ image: NSImage) -> NSImage? {
        guard let source = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        return BackgroundRenderer.render(source: source, background: background, layout: layout)
    }

    /// Image backgrounds belong to the item, so later edits and folder moves cannot change them.
    func snapshot(in folder: URL) throws -> BackgroundPreferences {
        var saved = preferences
        switch background {
        case .image(let image):
            guard let png = image.pngData else { throw CocoaError(.fileWriteUnknown) }
            try png.write(to: folder.appendingPathComponent("background.png"), options: .atomic)
            saved.backgroundType = 3
            saved.customImagePath = "background.png"
        case .gradient(let index): saved.backgroundType = 0; saved.gradient = index
        case .color: saved.backgroundType = 2
        }
        return saved
    }

    private static func color(_ values: [Double]) -> NSColor {
        NSColor(srgbRed: values[0], green: values[1], blue: values[2], alpha: values[3])
    }
}
