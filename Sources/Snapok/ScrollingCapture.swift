import AppKit
@preconcurrency import ScreenCaptureKit

/// Receives the capture stream's frames on its own queue and keeps only the newest one.
final class ScrollFrameReceiver: NSObject, SCStreamOutput, @unchecked Sendable {
    private let lock = NSLock()
    private var latest: ScrollFrame?
    private var serial = 0

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        // The stream also sends "idle" frames when nothing changed; only complete frames carry pixels.
        guard type == .screen, sampleBuffer.isValid,
              let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let raw = attachments.first?[.status] as? Int, SCFrameStatus(rawValue: raw) == .complete,
              let buffer = sampleBuffer.imageBuffer, let frame = ScrollFrame(bgra: buffer) else { return }
        lock.withLock {
            latest = frame
            serial += 1
        }
    }

    /// The newest frame, if one arrived after `serial`.
    func take(after serial: Int) -> (frame: ScrollFrame, serial: Int)? {
        lock.withLock { self.serial > serial ? latest.map { ($0, self.serial) } : nil }
    }
}

extension ScrollFrame {
    /// Copies a BGRA pixel buffer from the capture stream, row by row (rows may be padded).
    init?(bgra buffer: CVPixelBuffer) {
        guard CVPixelBufferGetPixelFormatType(buffer) == kCVPixelFormatType_32BGRA,
              CVPixelBufferLockBaseAddress(buffer, .readOnly) == kCVReturnSuccess else { return nil }
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        let width = CVPixelBufferGetWidth(buffer), height = CVPixelBufferGetHeight(buffer)
        let stride = CVPixelBufferGetBytesPerRow(buffer), rowBytes = width * 4
        guard width > 0, height > 0, let base = CVPixelBufferGetBaseAddress(buffer) else { return nil }
        var pixels = [UInt8](repeating: 0, count: rowBytes * height)
        pixels.withUnsafeMutableBytes { out in
            for y in 0..<height { (out.baseAddress! + y * rowBytes).copyMemory(from: base + y * stride, byteCount: rowBytes) }
        }
        self.init(width: width, height: height, pixels: pixels, isBGRA: true)
    }
}

/// Streams the selected area and stitches its frames, off the main thread.
/// Snapok's own windows (the frame and the control panel) are excluded from the stream.
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
    private let receiver = ScrollFrameReceiver()
    private let queue = DispatchQueue(label: "app.snapok.scrolling-capture")
    private var stream: SCStream?
    private var stitcher: ScrollStitcher?
    private var seen = 0
    private var counts: [String: Int] = [:]
    private var lastPreview = Date.distantPast

    /// `sourceRect` is in points, relative to the display's top-left corner.
    init(displayID: CGDirectDisplayID, sourceRect: CGRect, scale: CGFloat) {
        self.displayID = displayID
        self.sourceRect = sourceRect
        pixelSize = CGSize(width: (sourceRect.width * scale).rounded(), height: (sourceRect.height * scale).rounded())
    }

    func start() async throws {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = content.displays.first(where: { $0.displayID == displayID }) else {
            throw UpdateError(L("The display for this capture is no longer available.", "截图所在的显示器已不可用。"))
        }
        let ownPID = ProcessInfo.processInfo.processIdentifier
        let filter = SCContentFilter(display: display, excludingApplications: content.applications.filter { $0.processID == ownPID },
                                     exceptingWindows: [])
        let configuration = SCStreamConfiguration()
        configuration.sourceRect = sourceRect
        configuration.width = Int(pixelSize.width)
        configuration.height = Int(pixelSize.height)
        configuration.pixelFormat = kCVPixelFormatType_32BGRA
        configuration.colorSpaceName = CGColorSpace.sRGB
        configuration.showsCursor = false
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: 30)
        configuration.queueDepth = 4
        let stream = SCStream(filter: filter, configuration: configuration, delegate: nil)
        try stream.addStreamOutput(receiver, type: .screen, sampleHandlerQueue: queue)
        try await stream.startCapture()
        self.stream = stream
    }

    func stop() async {
        try? await stream?.stopCapture()
        stream = nil
    }

    /// Stitches the newest frame, if a new one arrived; `expectedOffset` is the distance just scrolled automatically.
    func process(expectedOffset: Int?) -> Update? {
        guard let (frame, serial) = receiver.take(after: seen) else { return nil }
        seen = serial
        guard var stitcher else {
            let first = ScrollStitcher(first: frame)
            stitcher = first
            return Update(step: .grew(frame.height), height: frame.height, preview: preview(of: first, rows: frame.height))
        }
        let step = stitcher.add(frame, expectedOffset: expectedOffset)
        self.stitcher = stitcher
        let grew: Bool
        switch step {
        case .grew(let rows): grew = rows != 0; counts["grew", default: 0] += 1
        case .estimated(let rows): grew = rows != 0; counts["estimated", default: 0] += 1
        case .unchanged: grew = false; counts["unchanged", default: 0] += 1
        case .lostTrack: grew = false; counts["lost", default: 0] += 1
        case .full: grew = false; counts["full", default: 0] += 1
        }
        // The panel shows a small preview; refreshing it a few times a second is plenty.
        let showPreview = grew && Date().timeIntervalSince(lastPreview) > 0.25
        return Update(step: step, height: stitcher.height, preview: showPreview ? preview(of: stitcher, rows: frame.height * 2) : nil)
    }

    /// The bottom of the stitched image, scaled down to the panel's width.
    private func preview(of stitcher: ScrollStitcher, rows: Int) -> CGImage? {
        lastPreview = Date()
        guard let image = stitcher.makeImage(bottomRows: rows) else { return nil }
        let scale = min(1, 400 / CGFloat(image.width))
        let width = Int(CGFloat(image.width) * scale), height = Int(CGFloat(image.height) * scale)
        guard width > 0, height > 0,
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.interpolationQuality = .medium
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()
    }

    func result() -> CGImage? { stitcher?.makeImage() }

    /// Frame size and step counts, for the log.
    func summary() -> String {
        "\(Int(pixelSize.width))x\(Int(pixelSize.height)) px, frames \(seen), steps \(counts.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: " ")), height \(stitcher?.height ?? 0)"
    }
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
            try await engine.start()
        } catch {
            log("scrolling capture failed to start", error: error)
            panel.status = error.localizedDescription
            return
        }
        while !Task.isCancelled {
            var expected: Int?
            if automatic {
                // Let the app finish its scroll animation, then take the frame it settled on.
                expected = scrollOnce()
                try? await Task.sleep(for: .milliseconds(300))
            } else {
                try? await Task.sleep(for: .milliseconds(30))
            }
            guard !Task.isCancelled, let update = await engine.process(expectedOffset: expected) else { continue }
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
        } else if case .lostTrack = update.step {
            // Frames are compared with the last one that lined up, so scrolling back up to it recovers.
            panel.status = L("Lost the position. Scroll back up a little, then continue more slowly · \(points) pt",
                             "跟丢了位置，请往回滚一点，再慢一些往下滚 · \(points) pt")
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
            await engine.stop()
            let image = await engine.result()
            log("scrolling capture finished: \(await engine.summary()), automatic=\(usedAutomatic)")
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
        Task { [engine] in
            await engine.stop()
            log("scrolling capture cancelled: \(await engine.summary())")
        }
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
