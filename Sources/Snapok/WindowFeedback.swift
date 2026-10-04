import AppKit

/// Visible operation feedback that stays outside the image canvas and never takes keyboard focus.
@MainActor
final class WindowFeedback {
    private var toast: FeedbackToast?
    private var dismissal: Task<Void, Never>?

    func show(_ message: String, in window: NSWindow?, success: Bool = true) {
        dismiss()
        guard let root = window?.contentView else { return }
        let view = FeedbackToast(message: message, success: success)
        view.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(view, positioned: .above, relativeTo: nil)
        NSLayoutConstraint.activate([
            view.centerXAnchor.constraint(equalTo: root.centerXAnchor),
            view.topAnchor.constraint(equalTo: root.topAnchor, constant: 94),
            view.widthAnchor.constraint(lessThanOrEqualTo: root.widthAnchor, constant: -48),
            view.widthAnchor.constraint(lessThanOrEqualToConstant: 560)
        ])
        toast = view
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        dismissal = Task { [weak self] in
            try? await Task.sleep(until: deadline, clock: .continuous)
            guard !Task.isCancelled else { return }
            self?.dismiss()
        }
    }

    func dismiss() {
        dismissal?.cancel()
        dismissal = nil
        toast?.removeFromSuperview()
        toast = nil
    }

    func showError(_ message: String, in window: NSWindow?) {
        dismiss()
        guard let window else { return }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = message
        alert.addButton(withTitle: L("OK", "好"))
        alert.beginSheetModal(for: window)
    }
}

@MainActor
final class FeedbackToast: NSView {
    let messageLabel: NSTextField

    init(message: String, success: Bool) {
        messageLabel = NSTextField(wrappingLabelWithString: message)
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor(srgbRed: 0.10, green: 0.11, blue: 0.13, alpha: 1).cgColor
        layer?.cornerRadius = 12
        layer?.borderWidth = 1
        layer?.borderColor = NSColor.white.withAlphaComponent(0.2).cgColor
        layer?.shadowColor = NSColor.black.cgColor
        layer?.shadowOpacity = 0.35
        layer?.shadowRadius = 12
        layer?.shadowOffset = CGSize(width: 0, height: -4)
        messageLabel.font = .systemFont(ofSize: 17, weight: .bold)
        messageLabel.textColor = .white
        messageLabel.alignment = .center
        messageLabel.preferredMaxLayoutWidth = 480
        let icon = NSImageView(image: NSImage(systemSymbolName: success ? "checkmark.circle.fill" : "info.circle.fill", accessibilityDescription: nil)!)
        icon.contentTintColor = success
            ? NSColor(srgbRed: 0.3, green: 0.95, blue: 0.5, alpha: 1)
            : NSColor(srgbRed: 0.4, green: 0.75, blue: 1, alpha: 1)
        for view in [icon, messageLabel] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 22),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 28),
            icon.heightAnchor.constraint(equalToConstant: 28),
            messageLabel.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 12),
            messageLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -22),
            messageLabel.topAnchor.constraint(equalTo: topAnchor, constant: 18),
            messageLabel.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -18)
        ])
        setAccessibilityLabel(message)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
