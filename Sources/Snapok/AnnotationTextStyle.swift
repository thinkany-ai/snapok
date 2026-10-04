import AppKit

struct AnnotationTextStyle: Codable, Equatable {
    var family: String? = nil
    var pointSize: CGFloat = 20
    var bold = false

    init(family: String? = nil, pointSize: CGFloat = 20, bold: Bool = false) {
        self.family = family
        self.pointSize = pointSize
        self.bold = bold
    }

    private enum CodingKeys: String, CodingKey { case family, pointSize, bold }
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        family = try values.decodeIfPresent(String.self, forKey: .family)
        pointSize = try values.decode(CGFloat.self, forKey: .pointSize)
        bold = try values.decodeIfPresent(Bool.self, forKey: .bold) ?? false
    }

    func pixelSize(at scale: CGFloat) -> CGFloat { pointSize * max(1, scale) }
    mutating func setPixelSize(_ pixels: CGFloat, scale: CGFloat) {
        pointSize = pixels / max(1, scale)
    }

    @MainActor var font: NSFont {
        let size = pointSize.isFinite ? min(288, max(0.1, pointSize)) : 20
        if let family, let font = NSFontManager.shared.font(withFamily: family, traits: [], weight: 5, size: size) {
            return bold ? NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask) : font
        }
        return .systemFont(ofSize: size, weight: bold ? .bold : .medium)
    }
}

@MainActor
final class AnnotationTextControls: NSView {
    private let family = NSPopUpButton()
    private let size = PixelNumberControl(value: 20, range: 1...288, label: L("Font size", "字号"))
    private let boldButton = NSButton(title: "B", target: nil, action: nil)
    private var pixelScale: CGFloat = 1
    private let families = NSFontManager.shared.availableFontFamilies.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    var onChange: ((AnnotationTextStyle) -> Void)?
    private var style = AnnotationTextStyle()

    override init(frame: NSRect) {
        super.init(frame: frame)
        family.addItems(withTitles: [L("System Font", "系统字体")] + families)
        size.onChange = { [weak self] value in
            guard let self else { return }
            self.style.setPixelSize(CGFloat(value), scale: self.pixelScale)
            self.onChange?(self.style)
        }
        addSubview(size)
        family.setAccessibilityLabel(L("Font", "字体"))
        family.toolTip = L("Font", "字体")
        size.setAccessibilityLabel(L("Font size", "字号"))
        size.toolTip = L("Font size (image pixels)", "字号（图片像素）")
        for control in [family] {
            control.controlSize = .regular
            control.font = .systemFont(ofSize: 13)
            control.target = self
            control.action = #selector(changed)
            addSubview(control)
        }
        boldButton.setButtonType(.toggle)
        boldButton.bezelStyle = .rounded
        boldButton.font = .boldSystemFont(ofSize: 13)
        boldButton.target = self
        boldButton.action = #selector(changed)
        boldButton.toolTip = L("Bold", "加粗")
        boldButton.setAccessibilityLabel(L("Bold", "加粗"))
        addSubview(boldButton)
        update(style)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override var intrinsicContentSize: NSSize { NSSize(width: 288, height: 26) }
    override func layout() {
        super.layout()
        family.frame = CGRect(x: 0, y: 2, width: 136, height: 26)
        size.frame = CGRect(x: 140, y: 0, width: 112, height: 26)
        boldButton.frame = CGRect(x: 256, y: 1, width: 32, height: 26)
    }
    func update(_ style: AnnotationTextStyle, pixelScale: CGFloat = 1) {
        self.pixelScale = pixelScale
        self.style = style
        family.selectItem(at: style.family.flatMap { families.firstIndex(of: $0) }.map { $0 + 1 } ?? 0)
        size.setValue(Int(style.pixelSize(at: pixelScale).rounded()))
        boldButton.state = style.bold ? .on : .off
    }
    @objc private func changed() {
        style.family = family.indexOfSelectedItem > 0 ? families[family.indexOfSelectedItem - 1] : nil
        style.bold = boldButton.state == .on
        onChange?(style)
    }
}

extension Annotation {
    var effectiveTextStyle: AnnotationTextStyle {
        textStyle ?? AnnotationTextStyle(pointSize: Style.lineWidth(for: .text, level: sizeLevel))
    }
    @MainActor var textFont: NSFont { effectiveTextStyle.font }
}
