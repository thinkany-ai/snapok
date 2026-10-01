import AppKit
import Carbon
@preconcurrency import ApplicationServices

@MainActor
enum Brand {
    static var appIcon: NSImage? {
        (Bundle.main.url(forResource: "AppIcon", withExtension: "png") ?? Bundle.module.url(forResource: "AppIcon", withExtension: "png")).flatMap { NSImage(contentsOf: $0) } ?? logo
    }
    static let accent = NSColor(srgbRed: 236 / 255, green: 72 / 255, blue: 153 / 255, alpha: 1)
    static var logo: NSImage? {
        (Bundle.main.url(forResource: "Logo", withExtension: "png") ?? Bundle.module.url(forResource: "Logo", withExtension: "png")).flatMap { NSImage(contentsOf: $0) }
    }
}

private let logURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/SnapAny.log")

func log(_ message: String) {
    NSLog("SnapAny: %@", message)
    let line = "\(ISO8601DateFormatter().string(from: Date())) \(message)\n"
    if let handle = try? FileHandle(forWritingTo: logURL) {
        handle.seekToEndOfFile()
        handle.write(Data(line.utf8))
        try? handle.close()
    } else {
        try? Data(line.utf8).write(to: logURL)
    }
}

@main
@MainActor
final class SnapAnyApp: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var hotKey: EventHotKeyRef?
    private var screenshotController: ScreenshotController!
    private var preferencesWindow: NSWindow?

    static func main() {
        let app = NSApplication.shared
        let delegate = SnapAnyApp()
        app.delegate = delegate
        app.run()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        NSApp.applicationIconImage = Brand.appIcon
        screenshotController = ScreenshotController()
        configureMenuBar()
        registerHotKey()
        let hasScreenAccess = CGPreflightScreenCaptureAccess()
        log("screen capture access=\(hasScreenAccess)")
        if !hasScreenAccess {
            CGRequestScreenCaptureAccess()
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        screenshotController?.reopenEditor()
        return true
    }

    func applicationWillTerminate(_ notification: Notification) {
        if let hotKey {
            UnregisterEventHotKey(hotKey)
        }
    }

    private func configureMenuBar() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.title = "SnapAny"
        if let logo = Brand.logo {
            logo.size = NSSize(width: 22, height: 22)
            statusItem.button?.image = logo
            statusItem.button?.title = ""
        }
        statusItem.button?.toolTip = "SnapAny"

        let menu = NSMenu()
        let screenshotItem = NSMenuItem(title: "Take Screenshot", action: #selector(startScreenshot), keyEquivalent: "a")
        screenshotItem.keyEquivalentModifierMask = [.control, .command]
        menu.addItem(screenshotItem)
        menu.addItem(NSMenuItem(title: "启用组件自动吸附…", action: #selector(enableComponentFocus), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Preferences", action: #selector(showPreferences), keyEquivalent: ","))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Quit SnapAny", action: #selector(quit), keyEquivalent: "q"))
        statusItem.menu = menu
    }

    @objc private func enableComponentFocus() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        if !AXIsProcessTrustedWithOptions(options),
           let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    private func registerHotKey() {
        let hotKeyID = EventHotKeyID(signature: OSType(0x534E4150), id: 1)
        let modifiers = UInt32(controlKey | cmdKey)
        let keyCode = UInt32(kVK_ANSI_A)

        let status = RegisterEventHotKey(keyCode, modifiers, hotKeyID, GetApplicationEventTarget(), 0, &hotKey)
        if status != noErr {
            log("failed to register hotkey, status=\(status)")
        } else {
            log("hotkey registered")
        }

        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, userData in
            var hotKeyID = EventHotKeyID()
            GetEventParameter(
                event,
                EventParamName(kEventParamDirectObject),
                EventParamType(typeEventHotKeyID),
                nil,
                MemoryLayout<EventHotKeyID>.size,
                nil,
                &hotKeyID
            )

            guard hotKeyID.signature == OSType(0x534E4150), hotKeyID.id == 1 else {
                return noErr
            }

            log("hotkey pressed")
            let app = Unmanaged<SnapAnyApp>.fromOpaque(userData!).takeUnretainedValue()
            Task { @MainActor in
                app.startScreenshot()
            }
            return noErr
        }, 1, &eventType, Unmanaged.passUnretained(self).toOpaque(), nil)
    }

    @objc private func startScreenshot() {
        screenshotController.start()
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    @objc private func showPreferences() {
        if let preferencesWindow {
            preferencesWindow.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let content = PreferencesView(frame: CGRect(x: 0, y: 0, width: 420, height: 360))
        let window = NSWindow(
            contentRect: content.frame,
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "SnapAny Preferences"
        window.contentView = content
        window.center()
        window.isReleasedWhenClosed = false
        preferencesWindow = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

@MainActor
final class ScreenshotController {
    private var windows: [CaptureWindow] = []
    private var pinnedWindows: [PinnedImageWindow] = []
    private var editors: [BackgroundEditorController] = []
    private var screenImage: NSImage?

    func start() {
        guard windows.isEmpty else { return }

        let windowFrames = WindowDetector.visibleWindowFrames()
        guard let image = ScreenCapture.captureAllScreens() else {
            log("screen capture failed, access=\(CGPreflightScreenCaptureAccess())")
            NSSound.beep()
            return
        }
        screenImage = image

        NSApp.activate(ignoringOtherApps: true)
        windows = NSScreen.screens.map { screen in
            let window = CaptureWindow(screen: screen, desktopImage: image, windowFrames: windowFrames)
            window.captureDelegate = self
            return window
        }

        windows.forEach { $0.orderFrontRegardless() }
        let mouse = NSEvent.mouseLocation
        (windows.first { $0.frame.contains(mouse) } ?? windows.first)?.makeKey()
    }

    private func finish(_ result: CaptureResult, mode: CaptureFinishMode, from window: CaptureWindow) {
        guard let image = screenImage,
              let rendered = ScreenCapture.render(image: image, result: result) else {
            closeWindows()
            return
        }

        switch mode {
        case .editImage:
            let screen = NSScreen.screens.first { $0.frame.intersects(result.globalRect) }
            closeWindows()
            guard let original = ScreenCapture.crop(image: image, to: result.globalRect) else { return }
            let editor = BackgroundEditorController(image: original, screen: screen, annotations: result.annotations)
            editors.append(editor)
            editor.onClose = { [weak self, weak editor] in
                guard let self else { return }
                self.editors.removeAll { $0 === editor }
                if self.editors.isEmpty { NSApp.setActivationPolicy(.accessory) }
            }
            editor.onPin = { [weak self] image in
                let visible = (screen ?? NSScreen.main)?.visibleFrame ?? result.globalRect
                let scale = min(1, min(visible.width * 0.8 / image.size.width, visible.height * 0.8 / image.size.height))
                let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
                self?.pin(image, at: CGRect(x: visible.midX - size.width / 2, y: visible.midY - size.height / 2, width: size.width, height: size.height))
            }
            NSApp.setActivationPolicy(.regular)
            editor.showWindow(nil)
            NSApp.activate(ignoringOtherApps: true)
        case .copy:
            ImageExport.copy(rendered)
            closeWindows()
        case .pin:
            pin(rendered, at: result.globalRect)
            closeWindows()
        case .save:
            windows.forEach { $0.orderOut(nil) }
            if ImageExport.save(rendered) == .cancelled {
                windows.forEach { $0.orderFrontRegardless() }
                window.makeKey()
            } else {
                closeWindows()
            }
        }
    }

    func reopenEditor() {
        guard let editor = editors.last else { return }
        editor.window?.deminiaturize(nil)
        editor.showWindow(nil)
    }

    private func pin(_ image: NSImage, at rect: CGRect) {
        let panel = PinnedImageWindow(image: image, frame: rect)
        pinnedWindows.append(panel)
        panel.onClose = { [weak self, weak panel] in
            guard let self, let panel else { return }
            self.pinnedWindows.removeAll { $0 === panel }
        }
        panel.makeKeyAndOrderFront(nil)
    }

    private func closeWindows() {
        windows.forEach { $0.orderOut(nil) }
        windows.removeAll()
        screenImage = nil
        MosaicCache.clear()
        NSCursor.arrow.set()
    }
}

extension ScreenshotController: CaptureWindowDelegate {
    func captureWindowDidCancel(_ window: CaptureWindow) {
        closeWindows()
    }

    func captureWindow(_ window: CaptureWindow, didFinish result: CaptureResult, mode: CaptureFinishMode) {
        finish(result, mode: mode, from: window)
    }
}

enum CaptureFinishMode {
    case editImage
    case copy
    case save
    case pin
}

enum SaveResult {
    case saved
    case cancelled
    case failed
}

struct CaptureResult {
    let globalRect: CGRect
    let annotations: [Annotation]
}

enum ToolKind: CaseIterable {
    case rect
    case oval
    case arrow
    case pen
    case mosaic
    case text

    var symbol: String {
        switch self {
        case .rect: return "square"
        case .oval: return "circle"
        case .arrow: return "arrow.up.right"
        case .pen: return "scribble"
        case .mosaic: return "checkerboard.rectangle"
        case .text: return "textformat"
        }
    }

    var title: String {
        switch self {
        case .rect: return "矩形"
        case .oval: return "椭圆"
        case .arrow: return "箭头"
        case .pen: return "画笔"
        case .mosaic: return "马赛克"
        case .text: return "文字"
        }
    }
}

@MainActor
enum Style {
    static var accent: NSColor { Brand.accent }
    static let danger = NSColor(srgbRed: 0.95, green: 0.32, blue: 0.32, alpha: 1)
    static let colors: [NSColor] = [
        NSColor(srgbRed: 0.98, green: 0.32, blue: 0.32, alpha: 1),
        NSColor(srgbRed: 1.0, green: 0.76, blue: 0.0, alpha: 1),
        NSColor(srgbRed: 0.027, green: 0.757, blue: 0.376, alpha: 1),
        NSColor(srgbRed: 0.06, green: 0.68, blue: 1.0, alpha: 1),
        NSColor(srgbRed: 0.1, green: 0.1, blue: 0.1, alpha: 1),
        NSColor(srgbRed: 1.0, green: 1.0, blue: 1.0, alpha: 1)
    ]
    nonisolated static let sizeLevels = 3

    nonisolated static func lineWidth(for kind: ToolKind, level: Int) -> CGFloat {
        let level = min(max(level, 0), sizeLevels - 1)
        switch kind {
        case .text: return [14, 20, 28][level]
        case .mosaic: return [14, 24, 40][level]
        default: return [2, 4, 6][level]
        }
    }
}

struct Annotation {
    var kind: ToolKind
    var rect: CGRect
    var points: [CGPoint]
    var text: String = ""
    var color: NSColor
    var sizeLevel: Int

    var lineWidth: CGFloat {
        Style.lineWidth(for: kind, level: sizeLevel)
    }
}

@MainActor
protocol CaptureWindowDelegate: AnyObject {
    func captureWindowDidCancel(_ window: CaptureWindow)
    func captureWindow(_ window: CaptureWindow, didFinish result: CaptureResult, mode: CaptureFinishMode)
}

@MainActor
final class CaptureWindow: NSWindow {
    weak var captureDelegate: CaptureWindowDelegate?

    init(screen: NSScreen, desktopImage: NSImage, windowFrames: [WindowTarget]) {
        let view = CaptureView(screen: screen, desktopImage: desktopImage, windowFrames: windowFrames)
        super.init(contentRect: screen.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        contentView = view
        view.windowRef = self

        level = .screenSaver
        backgroundColor = .black
        isOpaque = true
        ignoresMouseEvents = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        hasShadow = false
        acceptsMouseMovedEvents = true
        isReleasedWhenClosed = false
    }

    override var canBecomeKey: Bool { true }
}

@MainActor
final class PinnedImageWindow: NSPanel {
    var onClose: (() -> Void)?

    init(image: NSImage, frame: CGRect) {
        super.init(
            contentRect: frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        level = .floating
        hasShadow = true
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        isReleasedWhenClosed = false
        contentView = PinnedImageView(image: image)
    }

    override var canBecomeKey: Bool { true }

    override func close() {
        super.close()
        onClose?()
    }
}

@MainActor
final class PinnedImageView: NSView {
    private let image: NSImage

    init(image: NSImage) {
        self.image = image
        super.init(frame: CGRect(origin: .zero, size: image.size))
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var acceptsFirstResponder: Bool { true }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        image.draw(in: bounds)
        Style.accent.withAlphaComponent(0.8).setStroke()
        let border = NSBezierPath(rect: bounds.insetBy(dx: 0.5, dy: 0.5))
        border.lineWidth = 1
        border.stroke()
    }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount >= 2 {
            window?.close()
        } else {
            window?.performDrag(with: event)
        }
    }

    override func rightMouseDown(with event: NSEvent) {
        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "复制", action: #selector(copyImage), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "保存…", action: #selector(saveImage), keyEquivalent: ""))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "关闭", action: #selector(closeWindow), keyEquivalent: ""))
        menu.items.forEach { $0.target = self }
        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == UInt16(kVK_Escape) {
            window?.close()
        } else if event.keyCode == UInt16(kVK_ANSI_C), event.modifierFlags.contains(.command) {
            copyImage()
        } else {
            super.keyDown(with: event)
        }
    }

    @objc private func copyImage() {
        ImageExport.copy(image)
    }

    @objc private func saveImage() {
        _ = ImageExport.save(image)
    }

    @objc private func closeWindow() {
        window?.close()
    }
}

@MainActor
final class PreferencesView: NSView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        build()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func build() {
        let logo = NSImageView(frame: CGRect(x: 20, y: 299, width: 38, height: 38))
        logo.image = Brand.logo
        logo.imageScaling = .scaleProportionallyUpOrDown
        addSubview(logo)
        let title = NSTextField(labelWithString: "SnapAny")
        title.font = .systemFont(ofSize: 22, weight: .semibold)
        title.frame = CGRect(x: 66, y: 304, width: 330, height: 28)
        addSubview(title)

        let lines = [
            "截图快捷键：Control + Command + A",
            "悬停吸附组件；单击确认；拖动框选",
            "滚轮切换父级区域；按住 Option 选择整窗",
            "拖动选区内部移动，拖动边框或控制点调整大小",
            "双击选区或按 Enter：完成并复制到剪贴板",
            "Esc：退出截图；右键：重新选择区域",
            "⌘Z 撤销，⌘S 保存，Delete 删除选中的标注",
            "方向键微调选区（按住 Shift 每次 10 点）",
            "钉图：双击或 Esc 关闭，右键可复制/保存"
        ]

        var y: CGFloat = 264
        for line in lines {
            let label = NSTextField(labelWithString: line)
            label.font = .systemFont(ofSize: 13)
            label.textColor = .secondaryLabelColor
            label.frame = CGRect(x: 24, y: y, width: 380, height: 20)
            addSubview(label)
            y -= 27
        }
    }
}

@MainActor
final class CaptureView: NSView, NSTextFieldDelegate {
    weak var windowRef: CaptureWindow?

    private let screenFrame: CGRect
    private let desktopImage: NSImage
    private let desktopCGImage: CGImage?
    private let screenPreview: NSImage?
    private let windowRects: [CGRect]
    private let windowTargets: [WindowTarget]
    private let primaryHeight: CGFloat
    private var focusTask: Task<Void, Never>?
    private var focusGeneration = 0
    private var focusCandidates: [CGRect] = []
    private var focusIndex = 0
    private var wholeWindow = false
    private var focusScroll: CGFloat = 0
    private let pixelScale: CGFloat

    private var selection: CGRect?
    private var hoverRect: CGRect?
    private var mouseLocation: CGPoint = .zero
    private var mouseInside = false

    private var selectedTool: ToolKind?
    private var selectedColor: NSColor = Style.colors[0]
    private var sizeLevel = 1
    private var annotations: [Annotation] = []
    private var draftAnnotation: Annotation?
    private var dragState: DragState = .idle
    private var selectedAnnotationIndex: Int?
    private var activeTextField: NSTextField?
    private var editingTextIndex: Int?

    private var toolbarButtons: [(action: ToolbarAction, rect: CGRect)] = []
    private var toolbarPanels: [CGRect] = []
    private var hoveredAction: ToolbarAction?

    init(screen: NSScreen, desktopImage: NSImage, windowFrames: [WindowTarget]) {
        screenFrame = screen.frame
        self.desktopImage = desktopImage
        desktopCGImage = desktopImage.cgImage(forProposedRect: nil, context: nil, hints: nil)
        screenPreview = ScreenCapture.crop(image: desktopImage, to: screen.frame)
        pixelScale = screen.backingScaleFactor

        windowTargets = windowFrames
        primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        let localBounds = CGRect(origin: .zero, size: screen.frame.size)
        windowRects = windowFrames.compactMap { target in
            let local = target.frame.offsetBy(dx: -screen.frame.minX, dy: -screen.frame.minY).intersection(localBounds)
            return local.isNull || local.width < 20 || local.height < 20 ? nil : local
        }
        super.init(frame: localBounds)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var acceptsFirstResponder: Bool { true }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func viewDidMoveToWindow() {
        window?.makeFirstResponder(self)
        let mouse = NSEvent.mouseLocation
        mouseInside = screenFrame.contains(mouse)
        wholeWindow = NSEvent.modifierFlags.contains(.option)
        mouseLocation = CGPoint(x: mouse.x - screenFrame.minX, y: mouse.y - screenFrame.minY)
        if mouseInside { updateFocus() }
        if mouseInside {
            NSCursor.crosshair.set()
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(
            rect: .zero,
            options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self
        ))
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        NSGraphicsContext.current?.imageInterpolation = .high
        screenPreview?.draw(in: bounds)

        let showsHover = selection == nil && mouseInside && isPicking
        let hole = selection ?? (showsHover ? hoverRect : nil)
        drawDim(except: hole)

        if let selection {
            drawAnnotations(in: selection)
            drawSelectionFrame(selection)
            drawSizeLabel(for: selection)
            if isAdjustingSelection {
                toolbarButtons = []
                toolbarPanels = []
            } else {
                drawToolbar(for: selection)
            }
        } else {
            toolbarButtons = []
            toolbarPanels = []
            if let hole {
                drawHoverFrame(hole)
                drawSizeLabel(for: hole)
            }
        }

        if showsMagnifier {
            drawMagnifier()
        }
    }

    private var isPicking: Bool {
        switch dragState {
        case .idle, .pressing: return true
        default: return false
        }
    }

    private var isAdjustingSelection: Bool {
        switch dragState {
        case .selecting, .resizingSelection, .movingSelection: return true
        default: return false
        }
    }

    private var showsMagnifier: Bool {
        guard mouseInside else { return false }
        switch dragState {
        case .selecting, .resizingSelection: return true
        case .idle, .pressing: return selection == nil
        default: return false
        }
    }

    private func drawDim(except hole: CGRect?) {
        let path = NSBezierPath(rect: bounds)
        if let hole {
            path.append(NSBezierPath(rect: hole))
            path.windingRule = .evenOdd
        }
        NSColor.black.withAlphaComponent(0.45).setFill()
        path.fill()
    }

    private func drawHoverFrame(_ rect: CGRect) {
        Style.accent.setStroke()
        let path = NSBezierPath(rect: rect.insetBy(dx: 1.5, dy: 1.5))
        path.lineWidth = 3
        path.stroke()
    }

    private func drawSelectionFrame(_ rect: CGRect) {
        Style.accent.setStroke()
        let path = NSBezierPath(rect: rect.insetBy(dx: -0.5, dy: -0.5))
        path.lineWidth = 1
        path.stroke()

        Style.accent.setFill()
        for handle in SelectionHandle.allCases {
            NSBezierPath(rect: handleRect(for: handle, in: rect)).fill()
        }
    }

    private func drawSizeLabel(for rect: CGRect) {
        var text = "\(Int((rect.width * pixelScale).rounded())) × \(Int((rect.height * pixelScale).rounded()))"
        if selection == nil {
            text += AXIsProcessTrusted()
                ? "  · 滚轮切换区域 · ⌥ 整窗"
                : "  · 整窗吸附 · 菜单中启用组件吸附"
        }
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular),
            .foregroundColor: NSColor.white
        ]
        let size = text.size(withAttributes: attrs)
        let labelSize = CGSize(width: size.width + 12, height: 22)
        var origin = CGPoint(x: rect.minX, y: rect.maxY + 4)
        if origin.y + labelSize.height > bounds.maxY {
            origin = CGPoint(x: rect.minX + 4, y: rect.maxY - labelSize.height - 4)
        }
        origin.x = min(max(origin.x, bounds.minX), bounds.maxX - labelSize.width)
        let labelRect = CGRect(origin: origin, size: labelSize)
        NSColor.black.withAlphaComponent(0.75).setFill()
        NSBezierPath(roundedRect: labelRect, xRadius: 3, yRadius: 3).fill()
        text.draw(at: CGPoint(x: labelRect.minX + 6, y: labelRect.midY - size.height / 2), withAttributes: attrs)
    }

    private func drawAnnotations(in selection: CGRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        context.saveGState()
        context.clip(to: selection)
        for (index, annotation) in annotations.enumerated() where index != editingTextIndex {
            AnnotationRenderer.draw(annotation, in: context, sourceImage: desktopImage, origin: screenFrame.origin)
        }
        if let draftAnnotation {
            AnnotationRenderer.draw(draftAnnotation, in: context, sourceImage: desktopImage, origin: screenFrame.origin)
        }
        context.restoreGState()

        if let index = selectedAnnotationIndex, index != editingTextIndex, annotations.indices.contains(index) {
            drawDashedBox(annotations[index].rect.insetBy(dx: -4, dy: -4))
        }
        if let field = activeTextField {
            drawDashedBox(field.frame.insetBy(dx: -2, dy: -2))
        }
    }

    private func drawDashedBox(_ rect: CGRect) {
        NSColor.white.withAlphaComponent(0.9).setStroke()
        let path = NSBezierPath(rect: rect)
        path.lineWidth = 1
        path.setLineDash([4, 3], count: 2, phase: 0)
        path.stroke()
    }

    private func drawMagnifier() {
        let boxSize: CGFloat = 112
        let sourceSize: CGFloat = 14
        let infoHeight: CGFloat = 40
        let offset: CGFloat = 20

        var origin = CGPoint(x: mouseLocation.x + offset, y: mouseLocation.y - offset - boxSize - infoHeight)
        if origin.x + boxSize > bounds.maxX {
            origin.x = mouseLocation.x - offset - boxSize
        }
        if origin.y < bounds.minY {
            origin.y = mouseLocation.y + offset
        }
        let box = CGRect(x: origin.x, y: origin.y + infoHeight, width: boxSize, height: boxSize)
        let info = CGRect(x: origin.x, y: origin.y, width: boxSize, height: infoHeight)

        NSColor.black.setFill()
        box.fill()
        let source = CGRect(
            x: mouseLocation.x - sourceSize / 2,
            y: mouseLocation.y - sourceSize / 2,
            width: sourceSize,
            height: sourceSize
        )
        drawScreenRegion(source, into: box)

        let pixel = max(1, boxSize / (sourceSize * pixelScale))
        Style.accent.withAlphaComponent(0.45).setFill()
        CGRect(x: box.minX, y: box.midY - pixel / 2, width: box.width, height: pixel).fill()
        CGRect(x: box.midX - pixel / 2, y: box.minY, width: pixel, height: box.height).fill()

        NSColor.white.setStroke()
        let border = NSBezierPath(rect: box.insetBy(dx: 0.5, dy: 0.5))
        border.lineWidth = 1
        border.stroke()

        NSColor.black.withAlphaComponent(0.8).setFill()
        info.fill()
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular),
            .foregroundColor: NSColor.white
        ]
        let x = Int((mouseLocation.x * pixelScale).rounded(.down))
        let y = Int(((bounds.height - mouseLocation.y) * pixelScale).rounded(.down))
        "(\(x), \(y))".draw(at: CGPoint(x: info.minX + 8, y: info.minY + 22), withAttributes: attrs)
        if let rgb = pixelColor(at: mouseLocation) {
            "RGB(\(rgb.0), \(rgb.1), \(rgb.2))".draw(at: CGPoint(x: info.minX + 8, y: info.minY + 6), withAttributes: attrs)
        }
    }

    private func drawScreenRegion(_ source: CGRect, into destination: CGRect) {
        let clipped = source.intersection(bounds)
        guard !clipped.isNull, clipped.width > 0, clipped.height > 0 else { return }
        let scaleX = destination.width / source.width
        let scaleY = destination.height / source.height
        let target = CGRect(
            x: destination.minX + (clipped.minX - source.minX) * scaleX,
            y: destination.minY + (clipped.minY - source.minY) * scaleY,
            width: clipped.width * scaleX,
            height: clipped.height * scaleY
        )
        let globalRect = clipped.offsetBy(dx: screenFrame.minX, dy: screenFrame.minY)
        guard let image = ScreenCapture.crop(image: desktopImage, to: globalRect) else { return }
        NSGraphicsContext.current?.imageInterpolation = .none
        image.draw(in: target)
        NSGraphicsContext.current?.imageInterpolation = .high
    }

    private func pixelColor(at point: CGPoint) -> (Int, Int, Int)? {
        guard let cgImage = desktopCGImage else { return nil }
        let global = CGRect(x: point.x + screenFrame.minX, y: point.y + screenFrame.minY, width: 1, height: 1)
        let rect = ScreenCapture.imageRect(for: global, image: desktopImage)
        let x = Int(rect.minX)
        let y = Int(rect.minY)
        guard x >= 0, y >= 0, x < cgImage.width, y < cgImage.height,
              let pixel = cgImage.cropping(to: CGRect(x: x, y: y, width: 1, height: 1)),
              let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) else {
            return nil
        }

        var data = [UInt8](repeating: 0, count: 4)
        data.withUnsafeMutableBytes { buffer in
            let context = CGContext(
                data: buffer.baseAddress,
                width: 1,
                height: 1,
                bitsPerComponent: 8,
                bytesPerRow: 4,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )
            context?.draw(pixel, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        }
        return (Int(data[0]), Int(data[1]), Int(data[2]))
    }

    // MARK: Toolbar

    private var toolbarItems: [ToolbarItem] {
        ToolKind.allCases.map { ToolbarItem.button(.tool($0)) }
            + [.separator, .button(.undo), .button(.editImage), .button(.pin), .button(.save), .separator, .button(.cancel), .button(.done)]
    }

    private func drawToolbar(for selection: CGRect) {
        toolbarButtons = []
        toolbarPanels = []

        let buttonSize: CGFloat = 30
        let padding: CGFloat = 5
        let separatorWidth: CGFloat = 13
        let gap: CGFloat = 8
        let optionsGap: CGFloat = 6
        let optionsHeight: CGFloat = 32

        let barWidth = padding * 2 + toolbarItems.reduce(0) { width, item in
            if case .separator = item { return width + separatorWidth }
            return width + buttonSize
        }
        let barHeight = buttonSize + padding * 2
        let showsOptions = selectedTool != nil || selectedAnnotationIndex != nil
        let needed = gap + barHeight + (showsOptions ? optionsGap + optionsHeight : 0)

        let x = min(max(selection.maxX - barWidth, bounds.minX + 4), bounds.maxX - barWidth - 4)
        let barY: CGFloat
        let optionsBelowBar: Bool
        if selection.minY - needed >= bounds.minY + 4 {
            barY = selection.minY - gap - barHeight
            optionsBelowBar = true
        } else if selection.maxY + needed <= bounds.maxY - 4 {
            barY = selection.maxY + gap
            optionsBelowBar = false
        } else {
            barY = selection.minY + gap
            optionsBelowBar = false
        }

        let bar = CGRect(x: x, y: barY, width: barWidth, height: barHeight)
        drawPanel(bar)

        var cursorX = bar.minX + padding
        for item in toolbarItems {
            switch item {
            case .separator:
                NSColor(white: 0, alpha: 0.12).setFill()
                CGRect(x: cursorX + separatorWidth / 2, y: bar.minY + 11, width: 1, height: bar.height - 22).fill()
                cursorX += separatorWidth
            case .button(let action):
                let rect = CGRect(x: cursorX, y: bar.minY + padding, width: buttonSize, height: buttonSize)
                drawToolbarButton(action, in: rect)
                toolbarButtons.append((action, rect))
                cursorX += buttonSize
            }
        }

        if showsOptions {
            let width = optionsWidth
            let optionsX = min(max(bar.minX, bounds.minX + 4), bounds.maxX - width - 4)
            let optionsY = optionsBelowBar ? bar.minY - optionsGap - optionsHeight : bar.maxY + optionsGap
            drawOptions(in: CGRect(x: optionsX, y: optionsY, width: width, height: optionsHeight))
        }

        drawTooltip(near: bar, below: !(optionsBelowBar && showsOptions))
    }

    private var optionsWidth: CGFloat {
        12 + CGFloat(Style.sizeLevels) * 28 + 13 + CGFloat(Style.colors.count) * 26
    }

    private func drawOptions(in panel: CGRect) {
        drawPanel(panel)

        var cursorX = panel.minX + 6
        for level in 0..<Style.sizeLevels {
            let rect = CGRect(x: cursorX, y: panel.minY + 2, width: 28, height: 28)
            let diameter: CGFloat = [6, 10, 14][level]
            (level == sizeLevel ? Style.accent : NSColor(white: 0.55, alpha: 1)).setFill()
            NSBezierPath(ovalIn: CGRect(x: rect.midX - diameter / 2, y: rect.midY - diameter / 2, width: diameter, height: diameter)).fill()
            toolbarButtons.append((.size(level), rect))
            cursorX += 28
        }

        NSColor(white: 0, alpha: 0.12).setFill()
        CGRect(x: cursorX + 6, y: panel.minY + 8, width: 1, height: panel.height - 16).fill()
        cursorX += 13

        for (index, color) in Style.colors.enumerated() {
            let rect = CGRect(x: cursorX, y: panel.minY + 2, width: 26, height: 28)
            let swatch = CGRect(x: rect.midX - 8, y: rect.midY - 8, width: 16, height: 16)
            if selectedColor.matches(color) {
                Style.accent.setStroke()
                let ring = NSBezierPath(roundedRect: swatch.insetBy(dx: -3, dy: -3), xRadius: 4, yRadius: 4)
                ring.lineWidth = 2
                ring.stroke()
            }
            color.setFill()
            NSBezierPath(roundedRect: swatch, xRadius: 2, yRadius: 2).fill()
            NSColor(white: 0, alpha: 0.2).setStroke()
            let edge = NSBezierPath(roundedRect: swatch.insetBy(dx: 0.5, dy: 0.5), xRadius: 2, yRadius: 2)
            edge.lineWidth = 1
            edge.stroke()
            toolbarButtons.append((.color(index), rect))
            cursorX += 26
        }
    }

    private func drawPanel(_ rect: CGRect) {
        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.35)
        shadow.shadowBlurRadius = 8
        shadow.shadowOffset = NSSize(width: 0, height: -2)
        shadow.set()
        NSColor(white: 0.98, alpha: 1).setFill()
        NSBezierPath(roundedRect: rect, xRadius: 6, yRadius: 6).fill()
        NSGraphicsContext.restoreGraphicsState()
        toolbarPanels.append(rect)
    }

    private func drawToolbarButton(_ action: ToolbarAction, in rect: CGRect) {
        var isActive = false
        if case .tool(let tool) = action {
            isActive = selectedTool == tool
        }
        let isEnabled = action != .undo || !annotations.isEmpty

        if isEnabled, isActive || hoveredAction == action {
            NSColor(white: 0, alpha: 0.07).setFill()
            NSBezierPath(roundedRect: rect.insetBy(dx: 1, dy: 1), xRadius: 5, yRadius: 5).fill()
        }

        let color: NSColor
        switch action {
        case _ where !isEnabled:
            color = NSColor(white: 0.75, alpha: 1)
        case .done:
            color = Style.accent
        case .cancel:
            color = Style.danger
        default:
            color = isActive ? Style.accent : NSColor(white: 0.25, alpha: 1)
        }

        guard let symbol = action.symbol else { return }
        let weight: NSFont.Weight = action == .done ? .bold : .regular
        drawSymbol(symbol, in: rect, color: color, weight: weight)
    }

    private func drawSymbol(_ name: String, in rect: CGRect, color: NSColor, weight: NSFont.Weight) {
        let config = NSImage.SymbolConfiguration(pointSize: 15, weight: weight)
            .applying(NSImage.SymbolConfiguration(paletteColors: [color]))
        guard let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(config) else {
            return
        }
        let size = image.size
        image.draw(in: CGRect(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2, width: size.width, height: size.height))
    }

    private func drawTooltip(near bar: CGRect, below: Bool) {
        guard let hoveredAction,
              let title = hoveredAction.title,
              let button = toolbarButtons.first(where: { $0.action == hoveredAction }) else {
            return
        }
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11),
            .foregroundColor: NSColor.white
        ]
        let size = title.size(withAttributes: attrs)
        let tipSize = CGSize(width: size.width + 12, height: size.height + 6)
        let y = below ? bar.minY - tipSize.height - 4 : bar.maxY + 4
        let x = min(max(button.rect.midX - tipSize.width / 2, bounds.minX + 2), bounds.maxX - tipSize.width - 2)
        let tip = CGRect(origin: CGPoint(x: x, y: y), size: tipSize)
        NSColor.black.withAlphaComponent(0.8).setFill()
        NSBezierPath(roundedRect: tip, xRadius: 4, yRadius: 4).fill()
        title.draw(at: CGPoint(x: tip.minX + 6, y: tip.minY + 3), withAttributes: attrs)
    }

    private func toolbarAction(at point: CGPoint) -> ToolbarAction? {
        toolbarButtons.first { $0.rect.contains(point) }?.action
    }

    private func perform(_ action: ToolbarAction) {
        switch action {
        case .tool(let tool):
            selectedTool = selectedTool == tool ? nil : tool
            selectedAnnotationIndex = nil
        case .undo:
            undo()
        case .editImage:
            finish(.editImage)
        case .pin:
            finish(.pin)
        case .save:
            finish(.save)
        case .cancel:
            cancel()
        case .done:
            finish(.copy)
        case .size(let level):
            sizeLevel = level
            applyStyleToSelection()
        case .color(let index):
            selectedColor = Style.colors[index]
            applyStyleToSelection()
        }
        needsDisplay = true
    }

    // MARK: Mouse

    override func mouseEntered(with event: NSEvent) {
        mouseInside = true
        mouseMoved(with: event)
    }

    override func mouseExited(with event: NSEvent) {
        mouseInside = false
        cancelFocusQuery()
        focusCandidates = []
        hoverRect = nil
        hoveredAction = nil
        needsDisplay = true
    }

    override func mouseMoved(with event: NSEvent) {
        wholeWindow = event.modifierFlags.contains(.option)
        mouseLocation = convert(event.locationInWindow, from: nil)
        mouseInside = bounds.contains(mouseLocation)
        if selection == nil {
            updateFocus()
        }
        hoveredAction = toolbarAction(at: mouseLocation)
        updateCursor()
        needsDisplay = true
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        mouseLocation = point

        if activeTextField != nil {
            commitActiveTextField()
            if selectedTool == .text, toolbarAction(at: point) == nil {
                needsDisplay = true
                return
            }
        }

        if let action = toolbarAction(at: point) {
            perform(action)
            return
        }
        if toolbarPanels.contains(where: { $0.contains(point) }) {
            return
        }

        guard let selection else {
            cancelFocusQuery()
            dragState = .pressing(start: point)
            return
        }

        if event.clickCount == 2, selection.contains(point), selectedTool == nil {
            if let index = hitAnnotation(at: point), annotations[index].kind == .text {
                beginTextEdit(index: index)
            } else {
                finish(.copy)
            }
            return
        }

        if let handle = hitSelectionHandle(at: point, in: selection) {
            dragState = .resizingSelection(handle: handle, original: selection)
            selectedAnnotationIndex = nil
            needsDisplay = true
            return
        }

        if let index = hitAnnotation(at: point) {
            if selectedTool == .text, annotations[index].kind == .text {
                beginTextEdit(index: index)
                return
            }
            selectedAnnotationIndex = index
            selectedColor = annotations[index].color
            sizeLevel = annotations[index].sizeLevel
            dragState = .movingAnnotation(index: index, lastPoint: point)
            needsDisplay = true
            return
        }

        selectedAnnotationIndex = nil
        guard selection.contains(point) else {
            needsDisplay = true
            return
        }

        if let tool = selectedTool {
            beginAnnotation(tool, at: point)
        } else {
            dragState = .movingSelection(lastPoint: point)
            NSCursor.closedHand.set()
        }
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        mouseLocation = point
        let clamped = CGPoint(
            x: min(max(point.x, bounds.minX), bounds.maxX),
            y: min(max(point.y, bounds.minY), bounds.maxY)
        )

        switch dragState {
        case .pressing(let start):
            if hypot(point.x - start.x, point.y - start.y) > 3 {
                dragState = .selecting(start: start)
                selection = normalizedRect(from: start, to: clamped)
                hoverRect = nil
            }
        case .selecting(let start):
            selection = normalizedRect(from: start, to: clamped)
        case .drawingAnnotation:
            updateDraft(to: point)
        case .movingSelection(let lastPoint):
            moveSelection(by: CGPoint(x: point.x - lastPoint.x, y: point.y - lastPoint.y))
            dragState = .movingSelection(lastPoint: point)
        case .resizingSelection(let handle, let original):
            selection = resized(original, handle: handle, to: clamped)
        case .movingAnnotation(let index, let lastPoint):
            if annotations.indices.contains(index) {
                annotations[index] = annotations[index].offsetBy(dx: point.x - lastPoint.x, dy: point.y - lastPoint.y)
                dragState = .movingAnnotation(index: index, lastPoint: point)
            }
        case .idle:
            break
        }
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        mouseLocation = point

        switch dragState {
        case .pressing:
            selection = hoverRect ?? windowRect(at: point)
            hoverRect = nil
        case .selecting:
            if let selection, selection.width < 4 || selection.height < 4 {
                self.selection = nil
                updateFocus()
            }
        case .drawingAnnotation:
            finishDraft()
        case .movingSelection, .resizingSelection, .movingAnnotation, .idle:
            break
        }
        dragState = .idle
        if selection == nil { updateFocus() }
        updateCursor()
        needsDisplay = true
    }

    override func rightMouseDown(with event: NSEvent) {
        commitActiveTextField()
        guard selection != nil else {
            cancel()
            return
        }
        selection = nil
        annotations.removeAll()
        draftAnnotation = nil
        selectedAnnotationIndex = nil
        selectedTool = nil
        dragState = .idle
        mouseLocation = convert(event.locationInWindow, from: nil)
        updateFocus()
        updateCursor()
        needsDisplay = true
    }

    private func updateCursor() {
        let point = mouseLocation
        if toolbarPanels.contains(where: { $0.contains(point) }) {
            NSCursor.arrow.set()
            return
        }
        guard let selection else {
            NSCursor.crosshair.set()
            return
        }
        if let handle = hitSelectionHandle(at: point, in: selection) {
            handle.cursor.set()
        } else if selection.contains(point) {
            if let tool = selectedTool {
                (tool == .text ? NSCursor.iBeam : NSCursor.crosshair).set()
            } else if hitAnnotation(at: point) != nil {
                NSCursor.pointingHand.set()
            } else {
                NSCursor.openHand.set()
            }
        } else {
            NSCursor.arrow.set()
        }
    }

    // MARK: Automatic region focus

    private func cancelFocusQuery() {
        focusTask?.cancel()
        focusTask = nil
        focusGeneration += 1
    }

    private func updateFocus() {
        cancelFocusQuery()
        guard selection == nil, mouseInside, isPicking else { return }
        let fallback = windowRect(at: mouseLocation)
        let global = CGPoint(x: mouseLocation.x + screenFrame.minX, y: mouseLocation.y + screenFrame.minY)
        let previous = hoverRect
        focusCandidates = [fallback]
        focusIndex = 0
        focusScroll = 0
        hoverRect = fallback
        guard !wholeWindow, AXIsProcessTrusted(),
              let target = windowTargets.first(where: { $0.frame.contains(global) }) else { return }
        // Keep the previous component while a new hit test is pending, only within the same window.
        if let previous, previous.contains(mouseLocation), fallback.contains(previous) {
            hoverRect = previous
        }
        let generation = focusGeneration
        let height = primaryHeight
        focusTask = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(45)) } catch { return }
            let frames = await FocusDetector.shared.regions(in: target, at: global, primaryHeight: height)
            guard !Task.isCancelled, let self, self.focusGeneration == generation,
                  self.selection == nil, self.mouseInside, self.isPicking,
                  self.window?.isVisible == true else { return }
            var regions: [CGRect] = []
            for frame in frames {
                let local = frame.offsetBy(dx: -self.screenFrame.minX, dy: -self.screenFrame.minY)
                    .intersection(self.bounds)
                if !local.isNull, local.contains(self.mouseLocation), local != fallback, !regions.contains(local) {
                    regions.append(local)
                }
            }
            regions.append(fallback)
            self.focusCandidates = regions
            self.focusIndex = 0
            self.hoverRect = regions.first
            self.needsDisplay = true
        }
    }

    override func flagsChanged(with event: NSEvent) {
        wholeWindow = event.modifierFlags.contains(.option)
        if selection == nil {
            updateFocus()
            needsDisplay = true
        }
    }

    override func scrollWheel(with event: NSEvent) {
        guard selection == nil, mouseInside, !wholeWindow, isPicking,
              focusCandidates.count > 1, abs(event.scrollingDeltaY) > 0.1,
              event.momentumPhase.isEmpty else { return }
        cancelFocusQuery()
        focusScroll += event.scrollingDeltaY
        let threshold: CGFloat = event.hasPreciseScrollingDeltas ? 12 : 1
        guard abs(focusScroll) >= threshold else { return }
        focusIndex = min(max(focusIndex + (focusScroll > 0 ? 1 : -1), 0), focusCandidates.count - 1)
        focusScroll = 0
        hoverRect = focusCandidates[focusIndex]
        needsDisplay = true
    }

    // MARK: Keyboard

    override func keyDown(with event: NSEvent) {
        let command = event.modifierFlags.contains(.command)
        let step: CGFloat = event.modifierFlags.contains(.shift) ? 10 : 1

        switch Int(event.keyCode) {
        case kVK_Escape:
            cancel()
        case kVK_Return, kVK_ANSI_KeypadEnter:
            finish(.copy)
        case kVK_ANSI_C where command:
            finish(.copy)
        case kVK_ANSI_B where command:
            finish(.editImage)
        case kVK_ANSI_S where command:
            finish(.save)
        case kVK_ANSI_Z where command:
            undo()
        case kVK_Delete, kVK_ForwardDelete:
            deleteSelectedAnnotation()
        case kVK_LeftArrow:
            moveSelection(by: CGPoint(x: -step, y: 0))
        case kVK_RightArrow:
            moveSelection(by: CGPoint(x: step, y: 0))
        case kVK_UpArrow:
            moveSelection(by: CGPoint(x: 0, y: step))
        case kVK_DownArrow:
            moveSelection(by: CGPoint(x: 0, y: -step))
        default:
            super.keyDown(with: event)
        }
        needsDisplay = true
    }

    // MARK: Annotations

    private func beginAnnotation(_ tool: ToolKind, at point: CGPoint) {
        if tool == .text {
            beginText(at: point)
            return
        }
        dragState = .drawingAnnotation
        draftAnnotation = makeAnnotation(tool, from: point, to: point)
    }

    private func makeAnnotation(_ tool: ToolKind, from start: CGPoint, to end: CGPoint) -> Annotation {
        var annotation = Annotation(kind: tool, rect: .zero, points: [start, end], color: selectedColor, sizeLevel: sizeLevel)
        switch tool {
        case .pen, .mosaic:
            annotation.points = start == end ? [start] : [start, end]
            annotation.rect = boundingRect(for: annotation.points).insetBy(dx: -annotation.lineWidth / 2, dy: -annotation.lineWidth / 2)
        default:
            annotation.rect = normalizedRect(from: start, to: end)
        }
        return annotation
    }

    private func updateDraft(to point: CGPoint) {
        guard var draft = draftAnnotation else { return }
        switch draft.kind {
        case .pen, .mosaic:
            draft.points.append(point)
            draft.rect = boundingRect(for: draft.points).insetBy(dx: -draft.lineWidth / 2, dy: -draft.lineWidth / 2)
        default:
            draft = makeAnnotation(draft.kind, from: draft.points.first ?? point, to: point)
        }
        draftAnnotation = draft
    }

    private func finishDraft() {
        defer { draftAnnotation = nil }
        guard let draft = draftAnnotation else { return }
        let isUsable: Bool
        switch draft.kind {
        case .pen, .mosaic:
            isUsable = draft.points.count >= 2
        case .arrow:
            isUsable = draft.rect.width + draft.rect.height >= 6
        default:
            isUsable = draft.rect.width >= 3 && draft.rect.height >= 3
        }
        if isUsable {
            annotations.append(draft)
        }
    }

    private func textFont(level: Int) -> NSFont {
        .systemFont(ofSize: Style.lineWidth(for: .text, level: level), weight: .medium)
    }

    private func textFieldHeight(for font: NSFont) -> CGFloat {
        ceil(("Ag" as NSString).size(withAttributes: [.font: font]).height) + 2
    }

    private func makeTextField(frame: CGRect, text: String) {
        let field = NSTextField(frame: frame)
        field.stringValue = text
        field.font = textFont(level: sizeLevel)
        field.textColor = selectedColor
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.cell?.wraps = false
        field.cell?.isScrollable = true
        field.delegate = self
        addSubview(field)
        activeTextField = field
        window?.makeFirstResponder(field)
        resizeActiveTextField()
    }

    private func beginText(at point: CGPoint) {
        let height = textFieldHeight(for: textFont(level: sizeLevel))
        editingTextIndex = nil
        makeTextField(frame: CGRect(x: point.x - 2, y: point.y - height / 2, width: 40, height: height), text: "")
    }

    private func beginTextEdit(index: Int) {
        guard annotations.indices.contains(index), annotations[index].kind == .text else { return }
        let annotation = annotations[index]
        selectedColor = annotation.color
        sizeLevel = annotation.sizeLevel
        selectedAnnotationIndex = nil
        editingTextIndex = index
        let height = textFieldHeight(for: textFont(level: sizeLevel))
        makeTextField(
            frame: CGRect(x: annotation.rect.minX - 2, y: annotation.rect.minY - 1, width: annotation.rect.width + 12, height: height),
            text: annotation.text
        )
        needsDisplay = true
    }

    private func resizeActiveTextField() {
        guard let field = activeTextField, let font = field.font else { return }
        let width = (field.stringValue as NSString).size(withAttributes: [.font: font]).width
        var frame = field.frame
        frame.size.width = max(40, ceil(width) + 16)
        frame.size.height = textFieldHeight(for: font)
        field.frame = frame
        needsDisplay = true
    }

    func controlTextDidChange(_ obj: Notification) {
        resizeActiveTextField()
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        commitActiveTextField()
    }

    private func commitActiveTextField() {
        guard let field = activeTextField else { return }
        activeTextField = nil
        let text = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let font = field.font ?? textFont(level: sizeLevel)
        field.removeFromSuperview()

        if text.isEmpty {
            if let index = editingTextIndex, annotations.indices.contains(index) {
                annotations.remove(at: index)
            }
        } else {
            let size = (text as NSString).size(withAttributes: [.font: font])
            let rect = CGRect(x: field.frame.minX + 2, y: field.frame.minY + 1, width: ceil(size.width), height: ceil(size.height))
            let annotation = Annotation(kind: .text, rect: rect, points: [rect.origin], text: text, color: selectedColor, sizeLevel: sizeLevel)
            if let index = editingTextIndex, annotations.indices.contains(index) {
                annotations[index] = annotation
            } else {
                annotations.append(annotation)
            }
        }
        editingTextIndex = nil
        window?.makeFirstResponder(self)
        needsDisplay = true
    }

    private func applyStyleToSelection() {
        if let field = activeTextField {
            field.font = textFont(level: sizeLevel)
            field.textColor = selectedColor
            resizeActiveTextField()
        }
        guard let index = selectedAnnotationIndex, annotations.indices.contains(index) else { return }
        annotations[index].color = selectedColor
        annotations[index].sizeLevel = sizeLevel
        if annotations[index].kind == .text {
            let size = (annotations[index].text as NSString).size(withAttributes: [.font: textFont(level: sizeLevel)])
            annotations[index].rect.size = CGSize(width: ceil(size.width), height: ceil(size.height))
        }
    }

    private func undo() {
        commitActiveTextField()
        guard !annotations.isEmpty else { return }
        annotations.removeLast()
        selectedAnnotationIndex = nil
        needsDisplay = true
    }

    private func deleteSelectedAnnotation() {
        guard let index = selectedAnnotationIndex, annotations.indices.contains(index) else { return }
        annotations.remove(at: index)
        selectedAnnotationIndex = nil
        needsDisplay = true
    }

    private func hitAnnotation(at point: CGPoint) -> Int? {
        annotations.indices.reversed().first { index in
            let annotation = annotations[index]
            if let tool = selectedTool, tool != annotation.kind || tool == .pen || tool == .mosaic {
                return false
            }
            return annotation.hitTest(point)
        }
    }

    // MARK: Finish

    private func finish(_ mode: CaptureFinishMode) {
        commitActiveTextField()
        guard let selection, selection.width >= 2, selection.height >= 2, let windowRef else { return }
        let globalRect = selection.offsetBy(dx: screenFrame.minX, dy: screenFrame.minY)
        let localAnnotations = annotations.map { $0.offsetBy(dx: -selection.minX, dy: -selection.minY) }
        windowRef.captureDelegate?.captureWindow(windowRef, didFinish: CaptureResult(globalRect: globalRect, annotations: localAnnotations), mode: mode)
    }

    private func cancel() {
        guard let windowRef else { return }
        windowRef.captureDelegate?.captureWindowDidCancel(windowRef)
    }

    // MARK: Geometry

    private func windowRect(at point: CGPoint) -> CGRect {
        windowRects.first { $0.contains(point) } ?? bounds
    }

    private func moveSelection(by delta: CGPoint) {
        guard let selection else { return }
        var dx = delta.x
        var dy = delta.y
        if selection.minX + dx < bounds.minX { dx = bounds.minX - selection.minX }
        if selection.maxX + dx > bounds.maxX { dx = bounds.maxX - selection.maxX }
        if selection.minY + dy < bounds.minY { dy = bounds.minY - selection.minY }
        if selection.maxY + dy > bounds.maxY { dy = bounds.maxY - selection.maxY }

        self.selection = selection.offsetBy(dx: dx, dy: dy)
        annotations = annotations.map { $0.offsetBy(dx: dx, dy: dy) }
        if let field = activeTextField {
            field.frame = field.frame.offsetBy(dx: dx, dy: dy)
        }
    }

    private func resized(_ original: CGRect, handle: SelectionHandle, to point: CGPoint) -> CGRect {
        var minX = original.minX
        var maxX = original.maxX
        var minY = original.minY
        var maxY = original.maxY

        if handle.affectsLeft { minX = min(point.x, maxX - 4) }
        if handle.affectsRight { maxX = max(point.x, minX + 4) }
        if handle.affectsBottom { minY = min(point.y, maxY - 4) }
        if handle.affectsTop { maxY = max(point.y, minY + 4) }

        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    private func hitSelectionHandle(at point: CGPoint, in selection: CGRect) -> SelectionHandle? {
        if let handle = SelectionHandle.allCases.first(where: { handleRect(for: $0, in: selection).insetBy(dx: -4, dy: -4).contains(point) }) {
            return handle
        }

        let tolerance: CGFloat = 4
        let withinX = point.x >= selection.minX && point.x <= selection.maxX
        let withinY = point.y >= selection.minY && point.y <= selection.maxY
        if withinY, abs(point.x - selection.minX) <= tolerance { return .left }
        if withinY, abs(point.x - selection.maxX) <= tolerance { return .right }
        if withinX, abs(point.y - selection.maxY) <= tolerance { return .top }
        if withinX, abs(point.y - selection.minY) <= tolerance { return .bottom }
        return nil
    }

    private func handleRect(for handle: SelectionHandle, in rect: CGRect) -> CGRect {
        let size: CGFloat = 6
        let point = handle.point(in: rect)
        return CGRect(x: point.x - size / 2, y: point.y - size / 2, width: size, height: size)
    }

    private func normalizedRect(from start: CGPoint, to end: CGPoint) -> CGRect {
        CGRect(
            x: min(start.x, end.x),
            y: min(start.y, end.y),
            width: abs(start.x - end.x),
            height: abs(start.y - end.y)
        )
    }

    private func boundingRect(for points: [CGPoint]) -> CGRect {
        guard let first = points.first else { return .zero }
        return points.dropFirst().reduce(CGRect(origin: first, size: .zero)) { rect, point in
            rect.union(CGRect(origin: point, size: .zero))
        }
    }
}

enum ToolbarItem {
    case button(ToolbarAction)
    case separator
}

enum ToolbarAction: Equatable {
    case editImage
    case tool(ToolKind)
    case undo
    case pin
    case save
    case cancel
    case done
    case size(Int)
    case color(Int)

    var symbol: String? {
        switch self {
        case .tool(let tool): return tool.symbol
        case .editImage: return "photo.on.rectangle.angled"
        case .undo: return "arrow.uturn.backward"
        case .pin: return "pin"
        case .save: return "square.and.arrow.down"
        case .cancel: return "xmark"
        case .done: return "checkmark"
        case .size, .color: return nil
        }
    }

    var title: String? {
        switch self {
        case .tool(let tool): return tool.title
        case .editImage: return "编辑图片（⌘B）"
        case .undo: return "撤销"
        case .pin: return "钉在屏幕上"
        case .save: return "保存"
        case .cancel: return "退出截图"
        case .done: return "完成"
        case .size, .color: return nil
        }
    }
}

enum DragState {
    case idle
    case pressing(start: CGPoint)
    case selecting(start: CGPoint)
    case drawingAnnotation
    case movingSelection(lastPoint: CGPoint)
    case resizingSelection(handle: SelectionHandle, original: CGRect)
    case movingAnnotation(index: Int, lastPoint: CGPoint)
}

enum SelectionHandle: CaseIterable {
    case topLeft
    case top
    case topRight
    case right
    case bottomRight
    case bottom
    case bottomLeft
    case left

    var affectsLeft: Bool {
        self == .topLeft || self == .bottomLeft || self == .left
    }

    var affectsRight: Bool {
        self == .topRight || self == .bottomRight || self == .right
    }

    var affectsTop: Bool {
        self == .topLeft || self == .top || self == .topRight
    }

    var affectsBottom: Bool {
        self == .bottomLeft || self == .bottom || self == .bottomRight
    }

    @MainActor
    var cursor: NSCursor {
        if #available(macOS 15.0, *) {
            let position: NSCursor.FrameResizePosition
            switch self {
            case .topLeft: position = .topLeft
            case .top: position = .top
            case .topRight: position = .topRight
            case .right: position = .right
            case .bottomRight: position = .bottomRight
            case .bottom: position = .bottom
            case .bottomLeft: position = .bottomLeft
            case .left: position = .left
            }
            return NSCursor.frameResize(position: position, directions: .all)
        }
        switch self {
        case .left, .right: return .resizeLeftRight
        case .top, .bottom: return .resizeUpDown
        default: return .crosshair
        }
    }

    func point(in rect: CGRect) -> CGPoint {
        switch self {
        case .topLeft:
            return CGPoint(x: rect.minX, y: rect.maxY)
        case .top:
            return CGPoint(x: rect.midX, y: rect.maxY)
        case .topRight:
            return CGPoint(x: rect.maxX, y: rect.maxY)
        case .right:
            return CGPoint(x: rect.maxX, y: rect.midY)
        case .bottomRight:
            return CGPoint(x: rect.maxX, y: rect.minY)
        case .bottom:
            return CGPoint(x: rect.midX, y: rect.minY)
        case .bottomLeft:
            return CGPoint(x: rect.minX, y: rect.minY)
        case .left:
            return CGPoint(x: rect.minX, y: rect.midY)
        }
    }
}

@MainActor
enum AnnotationRenderer {
    /// `origin` is the global position of the annotations' coordinate space, used to sample the screenshot for mosaic.
    static func draw(_ annotation: Annotation, in context: CGContext, sourceImage: NSImage, origin: CGPoint, localImage: Bool = false) {
        context.saveGState()
        context.setLineCap(.round)
        context.setLineJoin(.round)
        context.setLineWidth(annotation.lineWidth)
        context.setStrokeColor(annotation.color.cgColor)
        context.setFillColor(annotation.color.cgColor)

        switch annotation.kind {
        case .rect:
            context.stroke(annotation.rect)
        case .oval:
            context.strokeEllipse(in: annotation.rect)
        case .arrow:
            drawArrow(annotation, in: context)
        case .pen:
            context.addPath(smoothPath(annotation.points))
            context.strokePath()
        case .text:
            drawText(annotation)
        case .mosaic:
            drawMosaic(annotation, in: context, sourceImage: sourceImage, origin: origin, localImage: localImage)
        }

        context.restoreGState()
    }

    private static func drawArrow(_ annotation: Annotation, in context: CGContext) {
        guard let start = annotation.points.first, let end = annotation.points.last else { return }
        let length = hypot(end.x - start.x, end.y - start.y)
        guard length > 0 else { return }

        let width = annotation.lineWidth
        let headLength = min(max(14, width * 4.5), length)
        let headWidth = headLength * 0.8
        let direction = CGPoint(x: (end.x - start.x) / length, y: (end.y - start.y) / length)
        let normal = CGPoint(x: -direction.y, y: direction.x)
        let base = CGPoint(x: end.x - direction.x * headLength, y: end.y - direction.y * headLength)

        context.move(to: start)
        context.addLine(to: CGPoint(x: base.x + direction.x * 2, y: base.y + direction.y * 2))
        context.strokePath()

        context.move(to: end)
        context.addLine(to: CGPoint(x: base.x + normal.x * headWidth / 2, y: base.y + normal.y * headWidth / 2))
        context.addLine(to: CGPoint(x: base.x - normal.x * headWidth / 2, y: base.y - normal.y * headWidth / 2))
        context.closePath()
        context.fillPath()
    }

    private static func smoothPath(_ points: [CGPoint]) -> CGPath {
        let path = CGMutablePath()
        guard let first = points.first else { return path }
        path.move(to: first)
        if points.count == 1 {
            path.addLine(to: first)
            return path
        }
        for index in 1..<points.count {
            let previous = points[index - 1]
            let current = points[index]
            path.addQuadCurve(to: CGPoint(x: (previous.x + current.x) / 2, y: (previous.y + current.y) / 2), control: previous)
        }
        path.addLine(to: points[points.count - 1])
        return path
    }

    private static func drawText(_ annotation: Annotation) {
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: annotation.lineWidth, weight: .medium),
            .foregroundColor: annotation.color
        ]
        annotation.text.draw(at: annotation.rect.origin, withAttributes: attrs)
    }

    private static func drawMosaic(_ annotation: Annotation, in context: CGContext, sourceImage: NSImage, origin: CGPoint, localImage: Bool = false) {
        if localImage {
            guard let pixelated = MosaicCache.pixelated(for: sourceImage) else { return }
            context.addPath(smoothPath(annotation.points))
            context.replacePathWithStrokedPath()
            context.clip()
            NSGraphicsContext.current?.imageInterpolation = .none
            pixelated.draw(in: CGRect(origin: .zero, size: sourceImage.size))
            return
        }
        guard let pixelated = MosaicCache.pixelated(for: sourceImage),
              let source = ScreenCapture.crop(image: pixelated, to: annotation.rect.offsetBy(dx: origin.x, dy: origin.y)) else {
            return
        }
        context.addPath(smoothPath(annotation.points))
        context.replacePathWithStrokedPath()
        context.clip()
        NSGraphicsContext.current?.imageInterpolation = .none
        source.draw(in: annotation.rect)
    }
}

@MainActor
enum MosaicCache {
    private static var sourceID: ObjectIdentifier?
    private static var image: NSImage?

    static func pixelated(for source: NSImage) -> NSImage? {
        if sourceID == ObjectIdentifier(source), let image {
            return image
        }
        sourceID = ObjectIdentifier(source)
        image = source.pixelated(blockSize: 10)
        return image
    }

    static func clear() {
        sourceID = nil
        image = nil
    }
}

@MainActor
enum WindowDetector {
    /// On-screen app windows, front to back, in Cocoa global coordinates.
    static func visibleWindowFrames() -> [WindowTarget] {
        guard let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else {
            return []
        }
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        let ownPID = ProcessInfo.processInfo.processIdentifier

        return info.compactMap { entry in
            guard (entry[kCGWindowLayer as String] as? NSNumber)?.intValue == 0,
                  let pid = (entry[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value,
                  pid != ownPID,
                  ((entry[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 1) > 0,
                  let boundsDictionary = entry[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: boundsDictionary as CFDictionary),
                  bounds.width >= 40, bounds.height >= 40 else {
                return nil
            }
            return WindowTarget(frame: FocusGeometry.cocoaRect(bounds, primaryHeight: primaryHeight), pid: pid)
        }
    }
}

@MainActor
enum ImageExport {
    static func copy(_ image: NSImage) {
        let item = NSPasteboardItem()
        if let png = image.pngData {
            item.setData(png, forType: .png)
        }
        if let tiff = image.tiffRepresentation {
            item.setData(tiff, forType: .tiff)
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects([item])
    }

    static func save(_ image: NSImage) -> SaveResult {
        guard let data = image.pngData else {
            NSSound.beep()
            return .failed
        }

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "SnapAny-\(formatter.string(from: Date())).png"
        panel.allowedContentTypes = [.png]
        panel.directoryURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Desktop")

        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else {
            return .cancelled
        }

        do {
            try data.write(to: url)
            return .saved
        } catch {
            log("save failed: \(error)")
            NSSound.beep()
            return .failed
        }
    }
}

@MainActor
enum ScreenCapture {
    static func captureAllScreens() -> NSImage? {
        let union = screenUnion()
        guard !union.isNull else { return nil }

        guard let cgImage = CGWindowListCreateImage(union, .optionOnScreenOnly, kCGNullWindowID, [.bestResolution]) else {
            return nil
        }

        return NSImage(cgImage: cgImage, size: union.size)
    }

    static func render(image: NSImage, result: CaptureResult) -> NSImage? {
        guard let full = image.cgImage(forProposedRect: nil, context: nil, hints: nil),
              let cropped = full.cropping(to: imageRect(for: result.globalRect, image: image)) else {
            return nil
        }

        let colorSpace = cropped.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!
        guard let context = CGContext(
            data: nil,
            width: cropped.width,
            height: cropped.height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return nil
        }

        context.draw(cropped, in: CGRect(x: 0, y: 0, width: cropped.width, height: cropped.height))
        let scale = CGFloat(cropped.width) / result.globalRect.width
        context.scaleBy(x: scale, y: scale)

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        for annotation in result.annotations {
            AnnotationRenderer.draw(annotation, in: context, sourceImage: image, origin: result.globalRect.origin)
        }
        NSGraphicsContext.restoreGraphicsState()

        guard let output = context.makeImage() else { return nil }
        return NSImage(cgImage: output, size: result.globalRect.size)
    }

    static func crop(image: NSImage, to globalRect: CGRect) -> NSImage? {
        let imageRect = imageRect(for: globalRect, image: image)
        guard imageRect.width > 0,
              imageRect.height > 0,
              let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil)?.cropping(to: imageRect) else {
            return nil
        }
        return NSImage(cgImage: cgImage, size: globalRect.size)
    }

    static func imageRect(for globalRect: CGRect, image: NSImage) -> CGRect {
        let union = screenUnion()
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            return .zero
        }

        let scaleX = CGFloat(cgImage.width) / union.width
        let scaleY = CGFloat(cgImage.height) / union.height
        let x = (globalRect.minX - union.minX) * scaleX
        let y = (union.maxY - globalRect.maxY) * scaleY
        return CGRect(x: x, y: y, width: globalRect.width * scaleX, height: globalRect.height * scaleY).integral
    }

    private static func screenUnion() -> CGRect {
        NSScreen.screens.reduce(CGRect.null) { $0.union($1.frame) }
    }
}

extension Annotation {
    func offsetBy(dx: CGFloat, dy: CGFloat) -> Annotation {
        var copy = self
        copy.rect = rect.offsetBy(dx: dx, dy: dy)
        copy.points = points.map { CGPoint(x: $0.x + dx, y: $0.y + dy) }
        return copy
    }

    func hitTest(_ point: CGPoint) -> Bool {
        let tolerance = max(6, lineWidth / 2 + 4)
        switch kind {
        case .text, .mosaic:
            return rect.insetBy(dx: -4, dy: -4).contains(point)
        case .rect:
            return rect.insetBy(dx: -tolerance, dy: -tolerance).contains(point)
                && !rect.insetBy(dx: tolerance, dy: tolerance).contains(point)
        case .oval:
            let rx = rect.width / 2
            let ry = rect.height / 2
            guard rx > 0, ry > 0 else { return false }
            let nx = (point.x - rect.midX) / rx
            let ny = (point.y - rect.midY) / ry
            return abs(sqrt(nx * nx + ny * ny) - 1) * min(rx, ry) <= tolerance
        case .arrow, .pen:
            guard points.count >= 2 else { return false }
            for index in 1..<points.count where distance(point, toSegmentFrom: points[index - 1], to: points[index]) <= tolerance {
                return true
            }
            return false
        }
    }

    private func distance(_ point: CGPoint, toSegmentFrom start: CGPoint, to end: CGPoint) -> CGFloat {
        let dx = end.x - start.x
        let dy = end.y - start.y
        let lengthSquared = dx * dx + dy * dy
        if lengthSquared == 0 {
            return hypot(point.x - start.x, point.y - start.y)
        }

        let projection = max(0, min(1, ((point.x - start.x) * dx + (point.y - start.y) * dy) / lengthSquared))
        let nearest = CGPoint(x: start.x + projection * dx, y: start.y + projection * dy)
        return hypot(point.x - nearest.x, point.y - nearest.y)
    }
}

extension NSColor {
    func matches(_ other: NSColor) -> Bool {
        guard let lhs = usingColorSpace(.sRGB), let rhs = other.usingColorSpace(.sRGB) else {
            return false
        }
        return abs(lhs.redComponent - rhs.redComponent) < 0.01
            && abs(lhs.greenComponent - rhs.greenComponent) < 0.01
            && abs(lhs.blueComponent - rhs.blueComponent) < 0.01
    }
}

extension NSImage {
    var pngData: Data? {
        guard let tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiffRepresentation) else {
            return nil
        }
        return bitmap.representation(using: .png, properties: [:])
    }

    func pixelated(blockSize: CGFloat) -> NSImage? {
        guard let cgImage = cgImage(forProposedRect: nil, context: nil, hints: nil),
              let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) else {
            return nil
        }
        let block = blockSize * CGFloat(cgImage.width) / size.width
        let smallWidth = max(1, Int(CGFloat(cgImage.width) / block))
        let smallHeight = max(1, Int(CGFloat(cgImage.height) / block))
        let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue

        guard let small = CGContext(data: nil, width: smallWidth, height: smallHeight, bitsPerComponent: 8, bytesPerRow: 0, space: colorSpace, bitmapInfo: bitmapInfo) else {
            return nil
        }
        small.interpolationQuality = .medium
        small.draw(cgImage, in: CGRect(x: 0, y: 0, width: smallWidth, height: smallHeight))

        guard let smallImage = small.makeImage(),
              let large = CGContext(data: nil, width: cgImage.width, height: cgImage.height, bitsPerComponent: 8, bytesPerRow: 0, space: colorSpace, bitmapInfo: bitmapInfo) else {
            return nil
        }
        large.interpolationQuality = .none
        large.draw(smallImage, in: CGRect(x: 0, y: 0, width: cgImage.width, height: cgImage.height))

        guard let output = large.makeImage() else { return nil }
        return NSImage(cgImage: output, size: size)
    }
}
