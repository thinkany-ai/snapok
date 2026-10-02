import AppKit

/// Map Foundation's Markdown semantics to native text styles without loading web content.
@MainActor
enum MarkdownRenderer {
    static func render(_ source: String) -> NSAttributedString {
        let body: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 14), .foregroundColor: NSColor.labelColor]
        guard let parsed = try? AttributedString(markdown: source, options: .init(interpretedSyntax: .full)) else {
            return NSAttributedString(string: source, attributes: body)
        }
        let output = NSMutableAttributedString(string: "")
        var previousBlock: Int?
        var previousItem: Int?
        var tables: [Int: NSTextTable] = [:]
        var blockStyle = NSMutableParagraphStyle()
        for run in parsed.runs {
            let components = run.presentationIntent?.components ?? []
            let blockID = components.first?.identity
            var attributes = body
            var font = NSFont.systemFont(ofSize: 14)
            var codeBlock = false
            var tableHeader = false
            var listItem: (id: Int, ordinal: Int)?
            var ordered = false
            var listDepth = 0
            var row = 0
            var column = 0
            var tableInfo: (id: Int, columns: Int)?
            var quote = false
            for component in components {
                switch component.kind {
                case .header(let level): font = .systemFont(ofSize: CGFloat(max(15, 26 - level * 2)), weight: .bold)
                case .codeBlock: codeBlock = true
                case .blockQuote: quote = true
                case .listItem(let ordinal): if listItem == nil { listItem = (component.identity, ordinal) }
                case .orderedList:
                    if listDepth == 0 { ordered = true }
                    listDepth += 1
                case .unorderedList: listDepth += 1
                case .table(let columns): tableInfo = (component.identity, columns.count)
                case .tableHeaderRow: tableHeader = true
                case .tableRow(let index): row = index
                case .tableCell(let index): column = index
                default: break
                }
            }
            if blockID != previousBlock || output.length == 0 {
                if output.length > 0, !output.string.hasSuffix("\n") {
                    output.append(NSAttributedString(string: "\n", attributes: [.paragraphStyle: blockStyle]))
                }
                blockStyle = NSMutableParagraphStyle()
                blockStyle.lineSpacing = 3
                blockStyle.paragraphSpacing = codeBlock ? 0 : listItem == nil ? 12 : 4
                if quote {
                    blockStyle.headIndent = 16
                    blockStyle.firstLineHeadIndent = 16
                }
                if let item = listItem {
                    let indent = CGFloat(max(listDepth - 1, 0)) * 20 + (quote ? 16 : 0)
                    blockStyle.firstLineHeadIndent = indent
                    blockStyle.headIndent = indent + 24
                    blockStyle.tabStops = [NSTextTab(textAlignment: .left, location: indent + 24)]
                    if item.id != previousItem {
                        let marker = ordered ? "\(item.ordinal).\t" : "•\t"
                        output.append(NSAttributedString(string: marker, attributes: [
                            .font: font, .foregroundColor: NSColor.labelColor, .paragraphStyle: blockStyle,
                        ]))
                    } else {
                        blockStyle.firstLineHeadIndent = blockStyle.headIndent
                    }
                }
                if let info = tableInfo, info.columns > 0 {
                    let table = tables[info.id] ?? NSTextTable()
                    table.numberOfColumns = info.columns
                    table.collapsesBorders = true
                    tables[info.id] = table
                    let cell = NSTextTableBlock(table: table, startingRow: row, rowSpan: 1, startingColumn: column, columnSpan: 1)
                    cell.setValue(100 / CGFloat(info.columns), type: .percentageValueType, for: .width)
                    cell.setWidth(8, type: .absoluteValueType, for: .padding)
                    cell.setWidth(0.5, type: .absoluteValueType, for: .border)
                    cell.setBorderColor(.separatorColor)
                    if tableHeader { cell.backgroundColor = .controlBackgroundColor }
                    blockStyle.textBlocks = [cell]
                    blockStyle.paragraphSpacing = 0
                }
                previousBlock = blockID
                previousItem = listItem?.id
            }
            let inline = run.inlinePresentationIntent ?? []
            if codeBlock || inline.contains(.code) {
                font = .monospacedSystemFont(ofSize: 13, weight: .regular)
                attributes[.backgroundColor] = NSColor.labelColor.withAlphaComponent(0.06)
            }
            if inline.contains(.stronglyEmphasized) || tableHeader { font = NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask) }
            if inline.contains(.emphasized) { font = NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask) }
            if inline.contains(.strikethrough) { attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
            if quote { attributes[.foregroundColor] = NSColor.secondaryLabelColor }
            if let link = run.link, ["http", "https", "mailto"].contains(link.scheme?.lowercased() ?? "") {
                attributes[.link] = link
                attributes[.foregroundColor] = NSColor.linkColor
            }
            attributes[.font] = font
            attributes[.paragraphStyle] = blockStyle
            var text = String(parsed[run.range].characters)
            if inline.contains(.softBreak), !codeBlock { text = " " }
            output.append(NSAttributedString(string: text, attributes: attributes))
        }
        return output
    }
}
