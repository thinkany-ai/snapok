import AppKit
@preconcurrency import ScreenCaptureKit

/// Captures the selected area repeatedly and stitches the frames, off the main thread.
/// Snapok's own windows (the frame and the control panel) are excluded from every capture.
actor ScrollCaptureEngine {
    struct Update: Sendable {
        let step: ScrollStitcher.Step
        let height: Int
        /// The bottom of the stitched image, for the live preview; only when it grew.
        let preview: CGImage?
    }

    private let displayID: CGDirectDisplayID
    private let sourceRect: CGRect
    private let pixelSize: CGSize
    private var filter: SCContentFilter?
    private var configuration: SCStreamConfiguration?
    private var stitcher: ScrollStitcher?

    /// `sourceRect` is in points, relative to the display's top-left corner.
    init(displayID: CGDirectDisplayID, sourceRect: CGRect, scale: CGFloat) {
        self.displayID = displayID
        self.sourceRect = sourceRect
        pixelSize = CGSize(width: (sourceRect.width * scale).rounded(), height: (sourceRect.height * scale).rounded())
    }

    func prepare() async throws {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = content.displays.first(where: { $0.displayID == displayID }) else {
            throw UpdateError(L("The display for this capture is no longer available.", "截图所在的显示器已不可用。"))
        }
        let ownPID = ProcessInfo.processInfo.processIdentifier
        let own = content.applications.filter { $0.processID == ownPID }
        filter = SCContentFilter(display: display, excludingApplications: own, exceptingWindows: [])
        let configuration = SCStreamConfiguration()
        configuration.sourceRect = sourceRect
        configuration.width = Int(pixelSize.width)
        configuration.height = Int(pixelSize.height)
        configuration.showsCursor = false
        configuration.colorSpaceName = CGColorSpace.sRGB
        self.configuration = configuration
    }

    func capture(expectedOffset: Int?) async -> Update? {
        guard let filter, let configuration,
              let image = try? await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration),
              let frame = ScrollFrame(image: image) else { return nil }
        guard var stitcher else {
            stitcher = ScrollStitcher(first: frame)
            return Update(step: .grew(frame.height), height: frame.height, preview: image)
        }
        let step = stitcher.add(frame, expectedOffset: expectedOffset)
        self.stitcher = stitcher
        let grew: Bool
        switch step {
        case .grew(let rows), .estimated(let rows): grew = rows != 0
        case .unchanged, .lostTrack, .full: grew = false
        }
        return Update(step: step, height: stitcher.height, preview: grew ? stitcher.makeImage(bottomRows: frame.height * 3) : nil)
    }

    func result() -> CGImage? { stitcher?.makeImage() }
}

/// A scrolling capture of one area: a frame marks it, a small panel shows the stitched result so far, and the
/// user scrolls the content themselves or lets Snapok scroll it. Done hands the tall image to `onFinish`.
@MainActor
final class ScrollingCaptureSession {
    var onFinish: ((NSImage, _ automatic: Bool) -> Void)?
    var onCancel: (() -> Void)?

    private let rect: CGRect
    private let screen: NSScreen
    private let engine: ScrollCaptureEngine
    private let frameWindow: NSWindow
    private let panel: ScrollingCapturePanel
    private var loop: Task<Void, Never>?
    private var keyMonitor: Any?
    private var automatic = false
    private var usedAutomatic = false
    private var idleSteps = 0
    private var estimatedSteps = 0
    private var full = false

    /// `rect` is the selected area in global screen coordinates (points).
    init?(rect: CGRect, screen: NSScreen) {
        guard let displayID = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID,
              rect.width >= 40, rect.height >= 40 else { return nil }
        self.rect = rect.integral
        self.screen = screen
        let local = CGRect(x: self.rect.minX - screen.frame.minX, y: screen.frame.maxY - self.rect.maxY,
                           width: self.rect.width, height: self.rect.height)
        engine = ScrollCaptureEngine(displayID: displayID, sourceRect: local, scale: screen.backingScaleFactor)

        frameWindow = NSWindow(contentRect: self.rect.insetBy(dx: -3, dy: -3), styleMask: .borderless, backing: .buffered, defer: false)
        frameWindow.isOpaque = false
        frameWindow.backgroundColor = .clear
        frameWindow.hasShadow = false
        frameWindow.ignoresMouseEvents = true
        frameWindow.level = .floating
        frameWindow.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        frameWindow.isReleasedWhenClosed = false
        frameWindow.contentView = ScrollingFrameView()

        panel = ScrollingCapturePanel()
    }

    func start() {
        panel.onAutomatic = { [weak self] in self?.toggleAutomatic() }
        panel.onDone = { [weak self] in self?.finish() }
        panel.onCancel = { [weak self] in self?.cancel() }
        panel.place(beside: rect, on: screen)
        frameWindow.orderFrontRegardless()
        panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            switch Int(event.keyCode) {
            case 53: self?.cancel(); return nil                 // Esc
            case 36, 76: self?.finish(); return nil             // Return, Enter
            default: return event
            }
        }
        loop = Task { [weak self] in await self?.run() }
    }

    private func run() async {
        do {
            try await engine.prepare()
        } catch {
            log("scrolling capture failed to start", error: error)
            panel.status = error.localizedDescription
            return
        }
        while !Task.isCancelled {
            var expected: Int?
            if automatic {
                expected = scrollOnce()
                try? await Task.sleep(for: .milliseconds(350))
            } else {
                try? await Task.sleep(for: .milliseconds(90))
            }
            guard !Task.isCancelled, let update = await engine.capture(expectedOffset: expected) else { continue }
            apply(update)
        }
    }

    private func apply(_ update: ScrollCaptureEngine.Update) {
        if let preview = update.preview { panel.preview = preview }
        let points = Int((CGFloat(update.height) / screen.backingScaleFactor).rounded())
        switch update.step {
        case .grew(let rows) where rows > 0:
            idleSteps = 0
            estimatedSteps = 0
        case .estimated:
            estimatedSteps += 1
        case .full:
            full = true
        default:
            idleSteps += 1
        }
        if full {
            panel.status = L("Maximum length reached · \(points) pt", "已达到最大长度 · \(points) pt")
            stopAutomatic()
        } else if automatic, idleSteps >= 3 || estimatedSteps >= 6 {
            // Nothing moves any more (the end of the page), or only blank space does.
            stopAutomatic()
            panel.status = L("Reached the end · \(points) pt", "已滚动到底 · \(points) pt")
        } else if case .lostTrack = update.step, !automatic {
            panel.status = L("Scroll more slowly · \(points) pt", "请滚动得慢一些 · \(points) pt")
        } else {
            panel.status = automatic
                ? L("Scrolling… · \(points) pt", "正在自动滚动… · \(points) pt")
                : L("Scroll inside the frame · \(points) pt", "在框内向下滚动 · \(points) pt")
        }
    }

    // MARK: Automatic scrolling

    private func toggleAutomatic() {
        if automatic { stopAutomatic(); return }
        guard AXIsProcessTrusted() else {
            ComponentSnappingPermission.request()
            panel.status = L("Allow Accessibility for Snapok to scroll automatically.", "请允许 Snapok 使用辅助功能，才能自动滚动。")
            return
        }
        guard !full else { return }
        automatic = true
        usedAutomatic = true
        idleSteps = 0
        estimatedSteps = 0
        panel.automatic = true
        // Scroll events go to the window under the pointer.
        CGWarpMouseCursorPosition(quartzPoint(CGPoint(x: rect.midX, y: rect.midY)))
    }

    private func stopAutomatic() {
        automatic = false
        panel.automatic = false
    }

    /// Scrolls the content under the frame by about half its height; returns that distance in pixels.
    private func scrollOnce() -> Int {
        let points = max(20, Int(rect.height * 0.45))
        let center = quartzPoint(CGPoint(x: rect.midX, y: rect.midY))
        guard let event = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1, wheel1: Int32(-points), wheel2: 0, wheel3: 0)
        else { return 0 }
        event.location = center
        event.post(tap: .cghidEventTap)
        return Int(CGFloat(points) * screen.backingScaleFactor)
    }

    private func quartzPoint(_ point: CGPoint) -> CGPoint {
        CGPoint(x: point.x, y: (NSScreen.screens.first?.frame.maxY ?? 0) - point.y)
    }

    // MARK: Finishing

    private func finish() {
        guard loop != nil else { return }
        stopAutomatic()
        loop?.cancel()
        loop = nil
        let scale = screen.backingScaleFactor
        Task {
            let image = await engine.result()
            close()
            guard let image else { onCancel?(); return }
            onFinish?(NSImage(cgImage: image, size: CGSize(width: CGFloat(image.width) / scale, height: CGFloat(image.height) / scale)),
                      usedAutomatic)
        }
    }

    private func cancel() {
        loop?.cancel()
        loop = nil
        close()
        onCancel?()
    }

    private func close() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
        frameWindow.orderOut(nil)
        panel.orderOut(nil)
    }
}

/// The dashed outline around the area being captured.
private final class ScrollingFrameView: NSView {
    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(rect: bounds.insetBy(dx: 1.5, dy: 1.5))
        path.lineWidth = 3
        path.setLineDash([8, 5], count: 2, phase: 0)
        Brand.accent.setStroke()
        path.stroke()
    }
}

/// The floating panel beside the frame: live preview, status, and the controls.
@MainActor
final class ScrollingCapturePanel: NSPanel {
    var onAutomatic: (() -> Void)?
    var onDone: (() -> Void)?
    var onCancel: (() -> Void)?

    private let previewView = NSImageView()
    private let statusLabel = NSTextField(wrappingLabelWithString: "")
    private let automaticButton = NSButton(title: "", target: nil, action: nil)
    private static let width: CGFloat = 220

    var status: String {
        get { statusLabel.stringValue }
        set { statusLabel.stringValue = newValue }
    }

    var preview: CGImage? {
        get { nil }
        set { previewView.image = newValue.map { NSImage(cgImage: $0, size: CGSize(width: $0.width, height: $0.height)) } }
    }

    var automatic = false {
        didSet { updateAutomaticButton() }
    }

    init() {
        super.init(contentRect: CGRect(x: 0, y: 0, width: Self.width, height: 360), styleMask: [.titled, .fullSizeContentView, .utilityWindow],
                   backing: .buffered, defer: false)
        title = L("Scrolling Capture", "长截图")
        titlebarAppearsTransparent = true
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
        isMovableByWindowBackground = true

        previewView.imageScaling = .scaleProportionallyUpOrDown
        previewView.imageAlignment = .alignBottom
        previewView.wantsLayer = true
        previewView.layer?.cornerRadius = 8
        previewView.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.06).cgColor
        statusLabel.font = .systemFont(ofSize: 12)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.stringValue = L("Scroll down inside the frame, or let Snapok scroll.", "在框内向下滚动，或让 Snapok 自动滚动。")

        automaticButton.bezelStyle = .rounded
        automaticButton.target = self
        automaticButton.action = #selector(toggleAutomatic)
        updateAutomaticButton()
        let cancel = NSButton(title: L("Cancel", "取消"), target: self, action: #selector(cancelCapture))
        cancel.bezelStyle = .rounded
        let done = NSButton(title: L("Done", "完成"), target: self, action: #selector(doneCapture))
        done.bezelStyle = .rounded
        done.keyEquivalent = "\r"
        let buttons = NSStackView(views: [cancel, done])
        buttons.distribution = .fillEqually

        let stack = NSStackView(views: [previewView, statusLabel, automaticButton, buttons])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 34, left: 14, bottom: 14, right: 14)
        stack.translatesAutoresizingMaskIntoConstraints = false
        let content = NSVisualEffectView()
        content.material = .hudWindow
        content.blendingMode = .behindWindow
        content.state = .active
        content.addSubview(stack)
        contentView = content
        let inner = Self.width - 28
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: content.topAnchor),
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            previewView.widthAnchor.constraint(equalToConstant: inner),
            previewView.heightAnchor.constraint(equalToConstant: 200),
            statusLabel.widthAnchor.constraint(equalToConstant: inner),
            automaticButton.widthAnchor.constraint(equalToConstant: inner),
            buttons.widthAnchor.constraint(equalToConstant: inner)
        ])
    }

    override var canBecomeKey: Bool { true }

    /// Right of the area if there is room, else left, else inside its bottom-right corner.
    func place(beside rect: CGRect, on screen: NSScreen) {
        layoutIfNeeded()
        let size = frame.size, visible = screen.visibleFrame, gap: CGFloat = 12
        var origin = CGPoint(x: rect.maxX + gap, y: rect.maxY - size.height)
        if origin.x + size.width > visible.maxX { origin.x = rect.minX - gap - size.width }
        if origin.x < visible.minX { origin.x = rect.maxX - size.width - gap }
        origin.x = min(max(origin.x, visible.minX), visible.maxX - size.width)
        origin.y = min(max(origin.y, visible.minY), visible.maxY - size.height)
        setFrameOrigin(origin)
    }

    private func updateAutomaticButton() {
        automaticButton.title = automatic ? L("Stop Scrolling", "停止自动滚动") : L("Scroll Automatically", "自动滚动")
        automaticButton.image = NSImage(systemSymbolName: automatic ? "stop.fill" : "arrow.down.circle", accessibilityDescription: nil)
        automaticButton.imagePosition = .imageLeading
    }

    @objc private func toggleAutomatic() { onAutomatic?() }
    @objc private func doneCapture() { onDone?() }
    @objc private func cancelCapture() { onCancel?() }
}
