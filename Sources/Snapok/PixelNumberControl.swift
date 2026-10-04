import AppKit

/// Integer pixels with direct entry, one-pixel steps, and hover scrolling.
@MainActor
final class PixelNumberControl: NSView, NSTextFieldDelegate {
    // One app-lifetime monitor, with only a weak reference to the current editor.
    private static weak var editingControl: PixelNumberControl?
    private static let outsideClickMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { event in
        editingControl?.finishEditingIfClickedOutside(event)
        return event
    }
    let input: NSTextField = PixelNumberField()
    private let minus = NSButton(image: NSImage(systemSymbolName: "minus", accessibilityDescription: nil)!, target: nil, action: nil)
    private let plus = NSButton(image: NSImage(systemSymbolName: "plus", accessibilityDescription: nil)!, target: nil, action: nil)
    private let unit = NSTextField(labelWithString: "px")
    let range: ClosedRange<Int>
    private(set) var value: Int
    var onChange: ((Int) -> Void)?
    var onEndEditing: (() -> Void)?
    private var wheelRemainder: CGFloat = 0
    private(set) var validationMessage: String?
    private var validationPopover: NSPopover?
    private var inputHint: String {
        L("Enter \(range.lowerBound)–\(range.upperBound) px; press Enter or leave the field to apply. Scroll to adjust immediately.",
          "输入 \(range.lowerBound)–\(range.upperBound) px，按 Enter 或移开焦点应用；滚轮调整即时生效。")
    }
    var isEditing: Bool { input.currentEditor() != nil }

    init(value: Int, range: ClosedRange<Int>, label: String) {
        self.range = range
        self.value = min(range.upperBound, max(range.lowerBound, value))
        super.init(frame: .zero)
        input.alignment = .center
        input.font = .monospacedDigitSystemFont(ofSize: 13, weight: .regular)
        input.isBordered = false
        input.drawsBackground = false
        input.focusRingType = .none
        input.delegate = self
        input.setAccessibilityLabel(label)
        input.toolTip = inputHint
        for button in [minus, plus] {
            button.isBordered = false
            button.controlSize = .small
            button.imagePosition = .imageOnly
            button.imageScaling = .scaleNone
            button.symbolConfiguration = .init(pointSize: 10, weight: .semibold)
            button.target = self
            button.action = #selector(step(_:))
        }
        minus.setAccessibilityLabel(L("Decrease ", "减小") + label)
        plus.setAccessibilityLabel(L("Increase ", "增大") + label)
        unit.font = .systemFont(ofSize: 11)
        unit.textColor = .secondaryLabelColor
        [minus, input, plus, unit].forEach { addSubview($0) }
        setValue(self.value)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override var intrinsicContentSize: NSSize { NSSize(width: 112, height: 26) }
    override func layout() {
        super.layout()
        minus.frame = CGRect(x: 1, y: 1, width: 24, height: 24)
        input.frame = CGRect(x: 25, y: 4, width: 40, height: 18)
        plus.frame = CGRect(x: 65, y: 1, width: 24, height: 24)
        unit.frame = CGRect(x: 92, y: 5, width: 20, height: 16)
    }

    override func draw(_ dirtyRect: NSRect) {
        let outline = NSBezierPath(roundedRect: CGRect(x: 0.5, y: 1.5, width: 89, height: 23), xRadius: 6, yRadius: 6)
        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.08)
        shadow.shadowBlurRadius = 2
        shadow.shadowOffset = CGSize(width: 0, height: -1)
        shadow.set()
        NSColor.controlBackgroundColor.setFill()
        outline.fill()
        NSGraphicsContext.restoreGraphicsState()
        (validationMessage != nil ? NSColor.systemOrange : isEditing ? NSColor.keyboardFocusIndicatorColor : NSColor.separatorColor).setStroke()
        outline.lineWidth = isEditing || validationMessage != nil ? 1.5 : 0.5
        outline.stroke()

        NSColor.separatorColor.withAlphaComponent(0.4).setStroke()
        let separators = NSBezierPath()
        for x: CGFloat in [25, 65] {
            separators.move(to: CGPoint(x: x, y: 6))
            separators.line(to: CGPoint(x: x, y: 20))
        }
        separators.lineWidth = 0.5
        separators.stroke()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
    func setValue(_ newValue: Int) {
        if validationMessage != nil, newValue != value { clearValidation() }
        value = min(range.upperBound, max(range.lowerBound, newValue))
        if !isEditing { input.integerValue = value }
        minus.isEnabled = value > range.lowerBound
        plus.isEnabled = value < range.upperBound
    }
    private func publish(_ newValue: Int) {
        let previous = value
        setValue(newValue)
        if value != previous { onChange?(value) }
    }
    func commitInput() {
        guard let number = Int(input.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            input.integerValue = value
            showValidation(L("Enter a whole number from \(range.lowerBound) to \(range.upperBound) px. Kept \(value) px.",
                             "请输入 \(range.lowerBound)–\(range.upperBound) px 范围内的整数，已保留 \(value) px。"))
            return
        }
        if range.contains(number), number != value { clearValidation() }
        publish(number)
        input.integerValue = value
        if !range.contains(number) {
            showValidation(L("The range is \(range.lowerBound)–\(range.upperBound) px. Adjusted to \(value) px.",
                             "允许范围为 \(range.lowerBound)–\(range.upperBound) px，已调整为 \(value) px。"))
        }
    }
    func controlTextDidChange(_ obj: Notification) { clearValidation() }
    private func clearValidation() {
        validationMessage = nil
        validationPopover?.close()
        validationPopover = nil
        input.toolTip = inputHint
        input.setAccessibilityHelp(inputHint)
        needsDisplay = true
    }
    private func showValidation(_ message: String) {
        validationMessage = message
        input.toolTip = message
        input.setAccessibilityHelp(message)
        needsDisplay = true
        guard window?.isVisible == true else { return }
        validationPopover?.close()
        let label = NSTextField(wrappingLabelWithString: message)
        label.font = .systemFont(ofSize: 12)
        label.frame = CGRect(x: 12, y: 10, width: 240, height: 44)
        let controller = NSViewController()
        controller.view = NSView(frame: CGRect(x: 0, y: 0, width: 264, height: 64))
        controller.view.addSubview(label)
        let popover = NSPopover()
        popover.contentViewController = controller
        popover.behavior = .transient
        validationPopover = popover
        popover.show(relativeTo: input.frame, of: self, preferredEdge: .maxY)
    }
    func controlTextDidBeginEditing(_ obj: Notification) {
        Self.editingControl = self
        _ = Self.outsideClickMonitor
        needsDisplay = true
    }
    func finishEditingIfClickedOutside(_ event: NSEvent) {
        guard isEditing, let window else { return }
        if event.window === window {
            let point = convert(event.locationInWindow, from: nil)
            // Preserve caret placement and selection inside the actual text field.
            if input.frame.contains(point) { return }
        }
        window.makeFirstResponder(nil)
        onEndEditing?()
        needsDisplay = true
    }
    func controlTextDidEndEditing(_ obj: Notification) {
        if Self.editingControl === self { Self.editingControl = nil }
        commitInput()
        needsDisplay = true
    }
    func control(_ control: NSControl, textView: NSTextView, doCommandBy command: Selector) -> Bool {
        guard !textView.hasMarkedText() else { return false }
        if command == #selector(NSResponder.insertNewline(_:)) || command == #selector(NSResponder.cancelOperation(_:)) {
            commitInput()
            window?.makeFirstResponder(nil)
            onEndEditing?()
            return true
        }
        if command == #selector(NSResponder.moveUp(_:)) || command == #selector(NSResponder.moveDown(_:)) {
            adjust(by: command == #selector(NSResponder.moveUp(_:)) ? 1 : -1)
            return true
        }
        return false
    }
    func adjust(by delta: Int) {
        commitInput()
        // Stepping from a valid value clears any previous validation feedback.
        if range.contains(value + delta) { clearValidation() }
        publish(value + delta)
        input.integerValue = value
    }
    @objc private func step(_ sender: NSButton) { adjust(by: sender === plus ? 1 : -1) }
    override func scrollWheel(with event: NSEvent) {
        guard event.momentumPhase.isEmpty else { return }
        if event.phase == .began { wheelRemainder = 0 }
        wheelRemainder += event.scrollingDeltaY
        let threshold: CGFloat = event.hasPreciseScrollingDeltas ? 10 : 1
        let steps = Int(wheelRemainder / threshold)
        if steps != 0 {
            wheelRemainder -= CGFloat(steps) * threshold
            adjust(by: steps)
        }
        if event.phase == .ended || event.phase == .cancelled { wheelRemainder = 0 }
    }
}

@MainActor
private final class PixelNumberField: NSTextField {
    override func scrollWheel(with event: NSEvent) { superview?.scrollWheel(with: event) }
}
