import CoreGraphics
import Foundation

/// One captured frame of the scrolling area, as tightly packed RGBA8 pixels.
struct ScrollFrame: Sendable {
    let width: Int
    let height: Int
    let pixels: [UInt8]

    init(width: Int, height: Int, pixels: [UInt8]) {
        precondition(pixels.count == width * height * 4)
        self.width = width
        self.height = height
        self.pixels = pixels
    }

    init?(image: CGImage) {
        let width = image.width, height = image.height
        guard width > 0, height > 0 else { return nil }
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                          bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { return nil }
        self.init(width: width, height: height, pixels: pixels)
    }

    /// A row's fingerprint: the gray level of up to 256 column bands (fine enough to tell lines of text apart),
    /// quantized so faint rendering noise still matches.
    /// Rows of one flat color are "plain"; they match anywhere, so they never decide an offset.
    fileprivate func signatures() -> [RowSignature] {
        let bands = min(256, width)
        return (0..<height).map { row in
            var hasher = Hasher()
            var first = -1, plain = true
            let base = row * width * 4
            for band in 0..<bands {
                let start = band * width / bands, end = (band + 1) * width / bands
                var sum = 0
                for x in start..<end {
                    let i = base + x * 4
                    sum += Int(pixels[i]) * 3 + Int(pixels[i + 1]) * 6 + Int(pixels[i + 2])
                }
                let level = sum / max(1, end - start) / 10 / 6
                if first < 0 { first = level } else if level != first { plain = false }
                hasher.combine(level)
            }
            return RowSignature(hash: hasher.finalize(), plain: plain)
        }
    }
}

private struct RowSignature: Equatable {
    let hash: Int
    let plain: Bool
}

/// Joins frames of an area that scrolls vertically into one tall image.
///
/// Each new frame is compared with the previous one: rows that stay put at the top and bottom are fixed
/// bars (a toolbar, a message box) and appear once; the rest gives the scroll distance, and only the rows
/// that scrolled into view are added. Frames that don't line up with the previous one (scrolling back up,
/// or too far between two captures) are ignored until one does.
struct ScrollStitcher {
    enum Step: Equatable {
        /// New rows were added (or rows that turned out to be a fixed bar were taken back off).
        case grew(Int)
        /// Like `grew`, but the frame was blank where it moves, so the distance is the one scrolled automatically.
        case estimated(Int)
        /// Nothing scrolled.
        case unchanged
        /// The frame doesn't line up with the previous one; it was ignored.
        case lostTrack
        /// The image reached `maxHeight`; nothing more is added.
        case full
    }

    let width: Int
    let maxHeight: Int
    private var body: [UInt8]
    private var last: ScrollFrame
    private var lastSignatures: [RowSignature]
    /// The body ends at this row of the last frame; the rows below it are added at the end.
    private var lastEnd: Int
    /// The largest fixed bars seen so far, used where a single step can't tell padding from blank page.
    private var provenHeader = 0
    private var provenFooter = 0

    init(first: ScrollFrame, maxHeight: Int = 30_000) {
        width = first.width
        self.maxHeight = maxHeight
        body = first.pixels
        last = first
        lastSignatures = first.signatures()
        lastEnd = first.height
    }

    /// Height of the image `makeImage()` would return now.
    var height: Int { body.count / (width * 4) + last.height - lastEnd }

    /// `expectedOffset` is the distance just scrolled programmatically (automatic scrolling). It is used only when
    /// the moving part of the frame is plain (blank page margins) and the distance can't be measured.
    mutating func add(_ frame: ScrollFrame, expectedOffset: Int? = nil) -> Step {
        guard frame.width == width, frame.height == last.height else { return .lostTrack }
        let rows = frame.height
        let current = frame.signatures()

        var header = 0
        while header < rows, current[header] == lastSignatures[header] { header += 1 }
        // Identical frames: nothing scrolled, unless all that moves is blank and we know it was scrolled.
        if header == rows, expectedOffset == nil || current.contains(where: { !$0.plain }) && !bandIsBlank(current) {
            return .unchanged
        }
        var footer = 0
        while footer < rows - header, current[rows - 1 - footer] == lastSignatures[rows - 1 - footer] { footer += 1 }
        // Blank rows match wherever they are, so for now a fixed bar ends at its innermost row with content;
        // once the scroll distance is known, blank rows next to it are sorted out below.
        while header > 0, current[header - 1].plain { header -= 1 }
        while footer > 0, current[rows - footer].plain { footer -= 1 }

        let band = header..<(rows - footer)
        let offset: Int
        var estimated = false
        switch Self.offset(previous: lastSignatures, current: current, band: band) {
        case .found(let found): offset = found
        case .featureless:
            estimated = true
            // A caret blinking or a spinner turning in an otherwise still frame.
            if band.count < 8 { return .unchanged }
            guard let expectedOffset, expectedOffset > 0, expectedOffset < band.count else { return .lostTrack }
            offset = expectedOffset
        case .noMatch: return .lostTrack
        }
        // A still blank row next to a bar is the bar's padding if what should have scrolled into its place
        // differs, or if an earlier step proved the bar reaches that far; otherwise it is blank page.
        func fixed(_ row: Int, proven: Bool) -> Bool {
            guard current[row].plain, current[row] == lastSignatures[row] else { return false }
            if row + offset < rows { return lastSignatures[row + offset] != current[row] }
            return proven
        }
        while header < rows - footer, fixed(header, proven: header < provenHeader) { header += 1 }
        while footer < rows - header, fixed(rows - 1 - footer, proven: footer < provenFooter) { footer += 1 }
        provenHeader = max(provenHeader, header)
        provenFooter = max(provenFooter, footer)
        if height >= maxHeight { return .full }

        let rowBytes = width * 4
        let contentEnd = rows - footer
        let before = height
        // The footer sits at the same rows in both frames, so in the previous frame it wasn't content either:
        // take it back off the body (it is added once, from the last frame, at the end).
        if lastEnd > contentEnd {
            body.removeLast(min(body.count, (lastEnd - contentEnd) * rowBytes))
            lastEnd = contentEnd
        }
        // Current row r shows what the previous frame had at r + offset. The body runs to previous row lastEnd,
        // that is current row lastEnd - offset; it should end where the fixed footer starts.
        let bodyEnd = lastEnd - offset
        if bodyEnd > contentEnd {
            body.removeLast(min(body.count, (bodyEnd - contentEnd) * rowBytes))
        } else if bodyEnd < contentEnd {
            let start = max(bodyEnd, header)
            let room = max(0, maxHeight - height)
            let end = min(contentEnd, start + room)
            body.append(contentsOf: frame.pixels[(start * rowBytes)..<(end * rowBytes)])
        }
        last = frame
        lastSignatures = current
        lastEnd = contentEnd
        return estimated ? .estimated(height - before) : .grew(height - before)
    }

    /// True when every row between the outermost rows with content is blank, i.e. nothing there could move visibly.
    private func bandIsBlank(_ signatures: [RowSignature]) -> Bool {
        guard let first = signatures.firstIndex(where: { !$0.plain }), let last = signatures.lastIndex(where: { !$0.plain })
        else { return true }
        // Content only at the edges (bars); the middle is blank.
        let middle = signatures[(first + 1)..<max(first + 1, last)]
        guard let gapStart = middle.firstIndex(where: { $0.plain }), let gapEnd = middle.lastIndex(where: { $0.plain }) else { return false }
        return signatures[gapStart...gapEnd].allSatisfy(\.plain) && gapEnd - gapStart + 1 >= signatures.count / 2
    }

    private enum Measurement { case found(Int), featureless, noMatch }

    /// The scroll distance in rows: the shift that lines up the most distinctive rows of `band`.
    private static func offset(previous: [RowSignature], current: [RowSignature], band: Range<Int>) -> Measurement {
        var rowsByHash: [Int: [Int]] = [:]
        for row in band where !previous[row].plain { rowsByHash[previous[row].hash, default: []].append(row) }
        var votes: [Int: Int] = [:]
        var distinctive = 0
        for row in band where !current[row].plain {
            distinctive += 1
            for match in rowsByHash[current[row].hash] ?? [] where match > row { votes[match - row, default: 0] += 1 }
        }
        // Nothing distinctive on one side (blank before, or blank now) leaves nothing to line up.
        guard distinctive >= 3, rowsByHash.values.reduce(0, { $0 + $1.count }) >= 3 else { return .featureless }
        guard let (offset, count) = votes.max(by: { $0.value < $1.value || ($0.value == $1.value && $0.key > $1.key) })
        else { return .noMatch }
        // Rows still on screen after the shift must agree; the ones that scrolled in can't be checked.
        let overlap = band.filter { $0 + offset < band.upperBound && !current[$0].plain }.count
        guard overlap >= 3, Double(count) >= Double(overlap) * 0.8 else { return .noMatch }
        return .found(offset)
    }

    /// The stitched image, or only its last `bottomRows` rows (for a preview).
    func makeImage(bottomRows: Int? = nil) -> CGImage? {
        let rowBytes = width * 4
        let tail = last.pixels[(lastEnd * rowBytes)...]
        let bodyBytes = bottomRows.map { min(body.count, max(0, $0 * rowBytes - tail.count)) } ?? body.count
        let pixels = body[(body.count - bodyBytes)...] + tail
        let rows = pixels.count / rowBytes
        guard rows > 0, let provider = CGDataProvider(data: Data(pixels) as CFData) else { return nil }
        return CGImage(width: width, height: rows, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: rowBytes,
                       space: CGColorSpace(name: CGColorSpace.sRGB)!,
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }
}
