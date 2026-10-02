import CoreGraphics
import Foundation

/// One captured frame of the scrolling area, as tightly packed 8-bit RGBA pixels, or BGRA as the capture
/// stream delivers them (comparisons don't depend on the channel order; only the final image does).
struct ScrollFrame: Sendable {
    let width: Int
    let height: Int
    let pixels: [UInt8]
    let isBGRA: Bool

    init(width: Int, height: Int, pixels: [UInt8], isBGRA: Bool = false) {
        precondition(pixels.count == width * height * 4)
        self.width = width
        self.height = height
        self.pixels = pixels
        self.isBGRA = isBGRA
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

    /// The gray level of each row in `bands` column bands (fine enough to tell lines of text apart),
    /// quantized so faint rendering noise still matches; row-major.
    ///
    /// Hot path (every frame, also in unoptimized development builds), hence raw pointers and every other pixel
    /// in wide bands.
    fileprivate func levels(bands: Int) -> [UInt8] {
        var levels = [UInt8](repeating: 0, count: height * bands)
        let starts = (0...bands).map { $0 * width / bands }
        let step = max(1, width / bands / 3)
        pixels.withUnsafeBufferPointer { source in
            levels.withUnsafeMutableBufferPointer { out in
                guard let pixels = source.baseAddress, let levels = out.baseAddress else { return }
                for row in 0..<height {
                    let line = pixels + row * width * 4
                    for band in 0..<bands {
                        var sum = 0, count = 0, x = starts[band]
                        let end = starts[band + 1]
                        while x < end {
                            let p = line + x * 4
                            sum += Int(p[0]) &* 3 &+ Int(p[1]) &* 6 &+ Int(p[2])
                            count += 1
                            x += step
                        }
                        levels[row * bands + band] = UInt8(sum / max(1, count) / 60)
                    }
                }
            }
        }
        return levels
    }
}

/// A row's fingerprint over some column bands. Rows of one flat color are "plain": they match anywhere,
/// so they never decide an offset.
private struct RowSignature: Equatable {
    let hash: Int
    let plain: Bool

    static func rows(_ levels: [UInt8], bands: Int, using columns: [Int]) -> [RowSignature] {
        levels.withUnsafeBufferPointer { levels in
            columns.withUnsafeBufferPointer { columns in
                (0..<(levels.count / bands)).map { row in
                    let line = levels.baseAddress! + row * bands
                    let first = line[columns.first ?? 0]
                    var hash: UInt64 = 0xcbf29ce484222325, plain = true
                    for band in columns {
                        let level = line[band]
                        if level != first { plain = false }
                        hash = (hash ^ UInt64(level)) &* 0x100000001b3
                    }
                    return RowSignature(hash: Int(truncatingIfNeeded: hash), plain: plain)
                }
            }
        }
    }
}

/// Joins frames of an area that scrolls vertically into one tall image.
///
/// Each new frame is compared with the previous one. Columns that never change (a sidebar next to the
/// scrolling content) are left out of the comparison and cropped off the result; rows that stay put at the
/// top and bottom are fixed bars (a toolbar, a message box) and appear once; the rest gives the scroll
/// distance, and only the rows that scrolled into view are added. Frames that don't line up with the
/// previous one (scrolling back up, or too far between two captures) are ignored until one does, so
/// scrolling back up a little after losing track picks up again.
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
    private var lastLevels: [UInt8]
    private let bands: Int
    /// Bands used to measure the scroll: all but a strip at the right edge, where overlay scroll bars appear.
    private let measurable: [Int]
    /// Bands that changed in an accepted step; the others at the edges are fixed and cropped off.
    private var moved: [Bool]
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
        bands = min(256, first.width)
        lastLevels = first.levels(bands: bands)
        lastEnd = first.height
        moved = [Bool](repeating: false, count: bands)
        let scrollBar = first.width >= 300 ? 32 : 0
        measurable = (0..<bands).filter { [width = first.width, bands] band in (band + 1) * width / bands <= width - scrollBar }
    }

    /// Height of the image `makeImage()` would return now.
    var height: Int { body.count / (width * 4) + last.height - lastEnd }

    /// `expectedOffset` is the distance just scrolled programmatically (automatic scrolling). It is used only when
    /// the moving part of the frame is plain (blank page margins) and the distance can't be measured.
    mutating func add(_ frame: ScrollFrame, expectedOffset: Int? = nil) -> Step {
        guard frame.width == width, frame.height == last.height, frame.isBGRA == last.isBGRA else { return .lostTrack }
        let rows = frame.height
        let levels = frame.levels(bands: bands)
        // Bands that differ in more than a few rows moved; measure with those (the content), not with
        // columns that stayed the same (a sidebar), which would make every row a mismatch.
        var changed = [Int](repeating: 0, count: bands)
        levels.withUnsafeBufferPointer { now in
            lastLevels.withUnsafeBufferPointer { before in
                changed.withUnsafeMutableBufferPointer { changed in
                    for i in 0..<(rows * bands) where now[i] != before[i] { changed[i % bands] += 1 }
                }
            }
        }
        let moving = changed.map { $0 * 100 > rows * 3 }
        let movingColumns = measurable.filter { moving[$0] }
        let columns = movingColumns.isEmpty ? measurable : movingColumns
        let current = RowSignature.rows(levels, bands: bands, using: columns)
        let lastSignatures = RowSignature.rows(lastLevels, bands: bands, using: columns)

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
        switch Self.offset(previous: lastLevels, current: levels, bands: bands, columns: columns,
                           previousRows: lastSignatures, currentRows: current, band: band) {
        case .found(let found): offset = found
        case .featureless:
            estimated = true
            // A caret blinking or a spinner turning in an otherwise still frame.
            if band.count < 8 { return .unchanged }
            guard let expectedOffset, expectedOffset > 0, expectedOffset < band.count else { return .lostTrack }
            offset = expectedOffset
        case .still: return .unchanged
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
        lastLevels = levels
        lastEnd = contentEnd
        for band in 0..<bands where moving[band] { moved[band] = true }
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

    private enum Measurement { case found(Int), still, featureless, noMatch }

    /// The scroll distance in rows: the shift under which the frames differ least, measured as the mean gray
    /// difference over the moving columns. Not exact equality: apps that scroll by fractions of a pixel
    /// (browsers, with a trackpad) redraw the content slightly blurred, so the same row never matches exactly.
    ///
    /// Every shift is ranked on one brightness value per row; the best 40 are checked on 8 column groups and
    /// the best 6 of those on all columns. The winner has to be clearly better than not moving at all and than
    /// the runner-up elsewhere. Runs on every frame, also in unoptimized development builds, hence raw pointers.
    private static func offset(previous: [UInt8], current: [UInt8], bands: Int, columns: [Int],
                               previousRows: [RowSignature], currentRows: [RowSignature], band: Range<Int>) -> Measurement {
        let distinctive = band.filter { !currentRows[$0].plain }
        guard distinctive.count >= 3, band.filter({ !previousRows[$0].plain }).count >= 3 else { return .featureless }
        let groups = min(8, columns.count)
        let groupStarts = (0...groups).map { $0 * columns.count / groups }
        // Per row: the mean level of each column group, and of all of them.
        func profiles(_ levels: [UInt8]) -> (groups: [Float], mean: [Float]) {
            var grouped = [Float](repeating: 0, count: band.upperBound * groups)
            var mean = [Float](repeating: 0, count: band.upperBound)
            levels.withUnsafeBufferPointer { levels in
                columns.withUnsafeBufferPointer { columns in
                    for row in band {
                        let line = levels.baseAddress! + row * bands
                        var all = 0
                        for group in 0..<groups {
                            var sum = 0
                            for i in groupStarts[group]..<groupStarts[group + 1] { sum += Int(line[columns[i]]) }
                            all += sum
                            grouped[row * groups + group] = Float(sum) / Float(max(1, groupStarts[group + 1] - groupStarts[group]))
                        }
                        mean[row] = Float(all) / Float(columns.count)
                    }
                }
            }
            return (grouped, mean)
        }
        let before = profiles(previous), now = profiles(current)
        // Enough of the frame must still overlap after the shift to judge it.
        let minimumOverlap = max(12, distinctive.count / 6)
        let upper = band.upperBound

        func rank(_ offsets: [Int], keep: Int, cost: (Int) -> Float?) -> [(offset: Int, cost: Float)] {
            Array(offsets.compactMap { offset in cost(offset).map { (offset, $0) } }.sorted { $0.1 < $1.1 }.prefix(keep))
        }
        let rows = distinctive
        // The first ranking only has to keep the right shift among its 40 best, so every third row will do.
        let sampled = stride(from: 0, to: rows.count, by: rows.count > 300 ? 3 : 1).map { rows[$0] }
        let coarseMinimum = max(4, minimumOverlap * sampled.count / rows.count)
        let coarse = sampled.withUnsafeBufferPointer { rows in
            now.mean.withUnsafeBufferPointer { a in
                before.mean.withUnsafeBufferPointer { b in
                    rank(Array(1..<band.count), keep: 40) { offset in
                        var cost: Float = 0, count = 0
                        for row in rows where row + offset < upper {
                            cost += abs(a[row] - b[row + offset])
                            count += 1
                        }
                        return count >= coarseMinimum ? cost / Float(count) : nil
                    }
                }
            }
        }
        let medium = rows.withUnsafeBufferPointer { rows in
            now.groups.withUnsafeBufferPointer { a in
                before.groups.withUnsafeBufferPointer { b in
                    rank(coarse.map(\.offset), keep: 6) { offset in
                        var cost: Float = 0, count = 0
                        for row in rows where row + offset < upper {
                            for group in 0..<groups { cost += abs(a[row * groups + group] - b[(row + offset) * groups + group]) }
                            count += 1
                        }
                        return count == 0 ? nil : cost / Float(count)
                    }
                }
            }
        }
        func cost(_ offset: Int) -> Float {
            rows.withUnsafeBufferPointer { rows in
                columns.withUnsafeBufferPointer { columns in
                    current.withUnsafeBufferPointer { a in
                        previous.withUnsafeBufferPointer { b in
                            var total = 0, count = 0
                            for row in rows where row + offset < upper {
                                let x = a.baseAddress! + row * bands, y = b.baseAddress! + (row + offset) * bands
                                for column in columns { total += abs(Int(x[column]) - Int(y[column])) }
                                count += 1
                            }
                            return count == 0 ? .infinity : Float(total) / Float(count * columns.count)
                        }
                    }
                }
            }
        }
        let scored = medium.map { ($0.offset, cost($0.offset)) }.sorted { $0.1 < $1.1 }
        guard let (best, bestCost) = scored.first else { return .noMatch }
        let still = cost(0)
        // Redrawn in place (a fraction of a pixel, or not at all).
        if still < 1, still <= bestCost { return .still }
        // Not moving at all must fit worse, and so must any shift that isn't next to the winner
        // (repeating content, such as table rows, can line up at several distances).
        let runnerUp = scored.dropFirst().first { abs($0.0 - best) > 2 }?.1 ?? .infinity
        guard bestCost < 1.5, bestCost < still * 0.6, bestCost < runnerUp * 0.75 else { return .noMatch }
        return .found(best)
    }

    /// The finished image: the stitched rows without fixed sidebars (columns with content that never moved).
    func makeImage() -> CGImage? {
        guard let image = makeImage(bottomRows: nil), let first = moved.firstIndex(of: true), let lastMoved = moved.lastIndex(of: true)
        else { return makeImage(bottomRows: nil) }
        // Fixed columns of one flat color (in the scrolling rows, not across a toolbar) are margins
        // around the content; keep those.
        let rows = provenHeader..<max(provenHeader + 1, last.height - provenFooter)
        func flat(_ band: Int) -> Bool {
            let level = lastLevels[rows.lowerBound * bands + band]
            return rows.allSatisfy { lastLevels[$0 * bands + band] == level }
        }
        let left = (0..<first).allSatisfy(flat) ? 0 : first * width / bands
        let right = ((lastMoved + 1)..<bands).allSatisfy(flat) ? width : (lastMoved + 1) * width / bands
        guard left > 0 || right < width else { return image }
        return image.cropping(to: CGRect(x: left, y: 0, width: right - left, height: image.height))
    }

    /// The stitched image, or only its last `bottomRows` rows (for a preview).
    func makeImage(bottomRows: Int?) -> CGImage? {
        let rowBytes = width * 4
        let tail = last.pixels[(lastEnd * rowBytes)...]
        let bodyBytes = bottomRows.map { min(body.count, max(0, $0 * rowBytes - tail.count)) } ?? body.count
        let pixels = body[(body.count - bodyBytes)...] + tail
        let rows = pixels.count / rowBytes
        guard rows > 0, let provider = CGDataProvider(data: Data(pixels) as CFData) else { return nil }
        return CGImage(width: width, height: rows, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: rowBytes,
                       space: CGColorSpace(name: CGColorSpace.sRGB)!,
                       bitmapInfo: last.isBGRA
                           ? CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
                           : CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }
}
