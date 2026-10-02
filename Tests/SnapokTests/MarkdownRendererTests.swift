import AppKit

@main
@MainActor
struct MarkdownRendererTests {
    static func main() throws {
        _ = NSApplication.shared
        let source = """
        # Translation interface

        This screenshot shows a **translation interface**, with *formatted* text.

        - **Translate to** is the label.
        - **简体中文** is the selected language.
          1. First nested item
          2. Second nested item

        See [Apple](https://apple.com) or use `translate()`.

        > A quoted explanation.

        ```swift
        let text = "**literal**"
            print(text)
        ```

        | Language | Name |
        | --- | --- |
        | Chinese | 简体中文 |
        """
        let rendered = MarkdownRenderer.render(source)
        let text = rendered.string as NSString
        precondition(!rendered.string.contains("**translation interface**"))
        precondition(rendered.string.contains("•\tTranslate to"))
        precondition(rendered.string.contains("1.\tFirst nested item"))
        precondition(rendered.string.contains("2.\tSecond nested item"))
        precondition(rendered.string.contains("\nSee Apple"), "Paragraphs must remain separate from list items")
        let strong = rendered.attribute(.font, at: text.range(of: "translation interface").location, effectiveRange: nil) as! NSFont
        precondition(NSFontManager.shared.traits(of: strong).contains(.boldFontMask))
        let heading = rendered.attribute(.font, at: 0, effectiveRange: nil) as! NSFont
        precondition(heading.pointSize > strong.pointSize)
        let link = rendered.attribute(.link, at: text.range(of: "Apple").location, effectiveRange: nil) as? URL
        precondition(link?.absoluteString == "https://apple.com")
        precondition(rendered.string.contains("let text = \"**literal**\"\n    print(text)"))
        let code = rendered.attribute(.font, at: text.range(of: "let text").location, effectiveRange: nil) as! NSFont
        precondition(code.isFixedPitch)
        let cell = rendered.attribute(.paragraphStyle, at: text.range(of: "Chinese").location, effectiveRange: nil) as! NSParagraphStyle
        precondition(cell.textBlocks.first is NSTextTableBlock)
        precondition(MarkdownRenderer.render("Plain text 中文").string == "Plain text 中文")
        precondition(MarkdownRenderer.render("").length == 0)
        let localLink = MarkdownRenderer.render("[local](file:///tmp/test)")
        precondition(localLink.attribute(.link, at: 0, effectiveRange: nil) == nil)

        // Verify real text layout, not just semantic table attributes. TextKit 2
        // ignores NSTextTable blocks; the result window uses TextKit 1.
        let layoutView = NSTextView(usingTextLayoutManager: false)
        layoutView.frame = CGRect(x: 0, y: 0, width: 640, height: 750)
        layoutView.textStorage?.setAttributedString(rendered)
        let manager = layoutView.layoutManager!
        manager.ensureLayout(for: layoutView.textContainer!)
        func bounds(_ word: String) -> CGRect {
            let glyphs = manager.glyphRange(forCharacterRange: text.range(of: word), actualCharacterRange: nil)
            return manager.boundingRect(forGlyphRange: glyphs, in: layoutView.textContainer!)
        }
        precondition(abs(bounds("Language").minY - bounds("Name").minY) < 1)
        precondition(bounds("Name").minX > bounds("Language").maxX)
        precondition(bounds("Chinese").minY > bounds("Language").maxY)

        if CommandLine.arguments.count > 1 {
            let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 640, height: 750), styleMask: [.borderless], backing: .buffered, defer: false)
            window.appearance = NSAppearance(named: .aqua)
            let view = NSTextView(usingTextLayoutManager: false)
            view.frame = window.contentView!.bounds
            view.textContainerInset = CGSize(width: 20, height: 20)
            view.textContainer?.widthTracksTextView = true
            view.textStorage?.setAttributedString(rendered)
            window.contentView!.addSubview(view)
            window.contentView!.layoutSubtreeIfNeeded()
            let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds)!
            view.cacheDisplay(in: view.bounds, to: bitmap)
            try bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
        }
        print("Passed Markdown checks: headings, emphasis, nested lists, paragraphs, links, code, tables, plain text and empty output")
    }
}
