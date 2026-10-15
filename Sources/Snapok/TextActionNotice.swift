import AppKit

@MainActor
private final class TextNoticePanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// Non-activating, click-through feedback on the screen where the action started.
@MainActor
final class TextActionNotice {
    private(set) var panel: NSPanel?
    private var dismissal: Task<Void, Never>?

    static func frame(in visible: CGRect, size: CGSize) -> CGRect {
        let width = min(size.width, max(1, visible.width - 32))
        let height = min(size.height, max(1, visible.height - 40))
        return CGRect(x: visible.maxX - width - 16, y: visible.maxY - height - 24, width: width, height: height)
    }

    private static var bodyAttributes: [NSAttributedString.Key: Any] {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byWordWrapping
        paragraph.lineSpacing = 3
        return [.font: NSFont.systemFont(ofSize: 13), .paragraphStyle: paragraph, .foregroundColor: NSColor.labelColor]
    }

    static func textHeight(_ text: String, width: CGFloat) -> CGFloat {
        let measured = NSAttributedString(string: text.isEmpty ? " " : text, attributes: bodyAttributes)
            .boundingRect(with: CGSize(width: max(1, width - 4), height: .greatestFiniteMagnitude),
                          options: [.usesLineFragmentOrigin, .usesFontLeading])
        return max(18, ceil(measured.height) + 4)
    }

    /// Bound rendering cost, not the original result. Full text remains in the result controller.
    static func preview(_ text: String, width: CGFloat, maxHeight: CGFloat) -> (text: String, height: CGFloat, truncated: Bool) {
        let bounded = String(text.prefix(4000))
        if bounded.count == text.count && textHeight(bounded, width: width) <= maxHeight {
            return (bounded, textHeight(bounded, width: width), false)
        }
        let characters = Array(bounded)
        var low = 0
        var high = characters.count
        while low < high {
            let middle = (low + high + 1) / 2
            let candidate = String(characters.prefix(middle)) + "…"
            if textHeight(candidate, width: width) <= maxHeight { low = middle }
            else { high = middle - 1 }
        }
        let result = String(characters.prefix(low)).trimmingCharacters(in: .whitespacesAndNewlines) + "…"
        return (result, min(maxHeight, textHeight(result, width: width)), true)
    }

    func show(title: String, detail: String, success: Bool = true, screen: NSScreen? = nil,
              duration: Double = 5, status: String? = nil) {
        dismiss()
        guard let display = screen ?? NSScreen.main ?? NSScreen.screens.first else { return }
        let width = min(360, max(1, display.visibleFrame.width - 32))
        let bodyWidth = max(1, width - 32)
        let maximumBodyHeight = min(190, max(18, display.visibleFrame.height - 160))
        let content = Self.preview(detail, width: bodyWidth, maxHeight: maximumBodyHeight)
        var footerParts: [String] = []
        if let status, !status.isEmpty { footerParts.append(status) }
        if content.truncated {
            footerParts.append(L("Full text: menu → Show Last OCR / Translation Result", "完整内容：菜单 → 查看上次识别 / 翻译结果"))
        }
        let footer = footerParts.joined(separator: "\n")
        let footerHeight: CGFloat = footer.isEmpty ? 0 : (footerParts.count > 1 ? 36 : 22)
        let height = 14 + 17 + 8 + content.height + (footer.isEmpty ? 0 : 8 + footerHeight) + 14
        let bounds = Self.frame(in: display.visibleFrame, size: CGSize(width: width, height: height))
        let panel = TextNoticePanel(contentRect: bounds, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.hidesOnDeactivate = false
        panel.isFloatingPanel = true
        panel.becomesKeyOnlyIfNeeded = true
        panel.ignoresMouseEvents = true
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.sharingType = .none

        let background = NSView(frame: CGRect(origin: .zero, size: bounds.size))
        background.wantsLayer = true
        background.layer?.cornerRadius = 12
        background.layer?.masksToBounds = true
        background.layer?.borderWidth = 0.5
        background.layer?.borderColor = NSColor.labelColor.withAlphaComponent(0.12).cgColor
        let reduceTransparency = NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency
        background.layer?.backgroundColor = NSColor.windowBackgroundColor.withAlphaComponent(reduceTransparency ? 1 : 0.18).cgColor
        let glass = NSVisualEffectView(frame: background.bounds)
        glass.identifier = NSUserInterfaceItemIdentifier("textNotice.glass")
        glass.autoresizingMask = [.width, .height]
        glass.material = .hudWindow
        glass.blendingMode = .behindWindow
        glass.state = .active
        glass.alphaValue = reduceTransparency ? 1 : 0.55
        background.addSubview(glass)

        let heading = NSTextField(labelWithString: title)
        heading.font = .systemFont(ofSize: 12, weight: .medium)
        heading.textColor = .secondaryLabelColor
        heading.lineBreakMode = .byTruncatingTail
        let body = NSTextField(wrappingLabelWithString: content.text)
        body.identifier = NSUserInterfaceItemIdentifier("textNotice.body")
        body.attributedStringValue = NSAttributedString(string: content.text, attributes: Self.bodyAttributes)
        body.maximumNumberOfLines = 0
        body.lineBreakMode = .byWordWrapping
        body.cell?.wraps = true
        body.cell?.usesSingleLineMode = false
        let icon = NSImageView(image: NSImage(systemSymbolName: success ? "checkmark" : "info.circle", accessibilityDescription: nil) ?? NSImage())
        icon.contentTintColor = success ? .secondaryLabelColor : .systemOrange
        [heading, body, icon].forEach { $0.translatesAutoresizingMaskIntoConstraints = false; background.addSubview($0) }
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: background.leadingAnchor, constant: 16),
            icon.topAnchor.constraint(equalTo: background.topAnchor, constant: 15),
            icon.widthAnchor.constraint(equalToConstant: 13), icon.heightAnchor.constraint(equalToConstant: 13),
            heading.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 6),
            heading.trailingAnchor.constraint(equalTo: background.trailingAnchor, constant: -16),
            heading.topAnchor.constraint(equalTo: background.topAnchor, constant: 14),
            heading.heightAnchor.constraint(equalToConstant: 17),
            body.leadingAnchor.constraint(equalTo: background.leadingAnchor, constant: 16),
            body.trailingAnchor.constraint(equalTo: background.trailingAnchor, constant: -16),
            body.topAnchor.constraint(equalTo: heading.bottomAnchor, constant: 8),
            body.heightAnchor.constraint(equalToConstant: content.height)
        ])
        if !footer.isEmpty {
            let label = NSTextField(wrappingLabelWithString: footer)
            label.identifier = NSUserInterfaceItemIdentifier("textNotice.footer")
            label.font = .systemFont(ofSize: 10.5)
            label.textColor = .secondaryLabelColor
            label.maximumNumberOfLines = 3
            label.translatesAutoresizingMaskIntoConstraints = false
            background.addSubview(label)
            NSLayoutConstraint.activate([
                label.leadingAnchor.constraint(equalTo: body.leadingAnchor),
                label.trailingAnchor.constraint(equalTo: body.trailingAnchor),
                label.topAnchor.constraint(equalTo: body.bottomAnchor, constant: 8),
                label.heightAnchor.constraint(equalToConstant: footerHeight)
            ])
        }
        panel.contentView = background
        panel.setAccessibilityLabel(title + "\n" + detail + "\n" + (status ?? ""))
        background.layoutSubtreeIfNeeded()
        self.panel = panel
        panel.orderFrontRegardless()
        // Short messages stay brief; longer previews allow time for several lines.
        let readingDuration = duration == 5 ? min(12, max(5, Double(content.text.count) / 22)) : duration
        dismissal = Task { [weak self] in
            try? await Task.sleep(for: .seconds(readingDuration))
            guard !Task.isCancelled else { return }
            self?.dismiss()
        }
    }

    func dismiss() {
        dismissal?.cancel()
        dismissal = nil
        panel?.orderOut(nil)
        panel = nil
    }
}
