import Foundation

@main
struct ScrollStitcherTests {
    static let width = 120

    /// A page row: a few blocks of "text" whose layout depends on the row, so rows are distinct.
    static func pageRow(_ y: Int, plain: Bool = false) -> [UInt8] {
        var row = [UInt8](repeating: 255, count: width * 4)
        guard !plain else { return row }
        var seed = UInt64(y &* 2654435761 &+ 12345)
        for block in 0..<6 {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            let start = min(width - 1, block * 20 + Int(seed >> 59)), length = 3 + Int((seed >> 40) % 12)
            let gray = UInt8(40 + (seed >> 20) % 120)
            for x in start..<min(width, start + length) { row[x * 4] = gray; row[x * 4 + 1] = gray; row[x * 4 + 2] = gray }
        }
        return row
    }

    static func bar(_ color: UInt8, label: Int) -> [UInt8] {
        var row = [UInt8](repeating: color, count: width * 4)
        for x in 0..<(10 + label % 30) { row[x * 4] = 0 }
        for x in 0..<width { row[x * 4 + 3] = 255 }
        return row
    }

    struct Page {
        let rows: [[UInt8]]
        let header: [[UInt8]]
        let footer: [[UInt8]]
        let viewport: Int
        var content: Int { viewport - header.count - footer.count }

        func frame(at scroll: Int, noise: Bool = false) -> ScrollFrame {
            var pixels = (header + Array(rows[scroll..<(scroll + content)]) + footer).flatMap { $0 }
            if noise { for i in stride(from: 0, to: pixels.count, by: 7) where pixels[i] > 2 && pixels[i] < 250 { pixels[i] &+= 1 } }
            return ScrollFrame(width: width, height: viewport, pixels: pixels)
        }

        func expected(through scroll: Int) -> [UInt8] {
            (header + Array(rows[0..<(scroll + content)]) + footer).flatMap { $0 }
        }
    }

    static func makePage(length: Int, header: Int, footer: Int, viewport: Int, blank: Range<Int> = 0..<0) -> Page {
        Page(rows: (0..<length).map { pageRow($0, plain: blank.contains($0)) },
             header: (0..<header).map { bar(230, label: $0) }, footer: (0..<footer).map { bar(210, label: $0 * 7) },
             viewport: viewport)
    }

    static func pixels(_ stitcher: ScrollStitcher) -> [UInt8] {
        let image = stitcher.makeImage()!
        return ScrollFrame(image: image)!.pixels
    }

    static func main() {
        // Fixed header and footer, uneven scroll steps, a repeated frame, and a jump back up.
        let page = makePage(length: 900, header: 40, footer: 30, viewport: 300)
        var stitcher = ScrollStitcher(first: page.frame(at: 0))
        precondition(stitcher.height == 300)
        precondition(stitcher.add(page.frame(at: 0)) == .unchanged)
        for scroll in [37, 90, 151, 260, 400] { _ = stitcher.add(page.frame(at: scroll)) }
        precondition(stitcher.add(page.frame(at: 100)) == .lostTrack, "scrolling back up is ignored")
        precondition(stitcher.add(page.frame(at: 400)) == .unchanged)
        for scroll in [520, 640, 670] { _ = stitcher.add(page.frame(at: scroll)) }
        let expected = page.expected(through: 670)
        precondition(stitcher.height == expected.count / (width * 4), "height \(stitcher.height)")
        precondition(pixels(stitcher) == expected, "header and footer appear once, every page row once, in order")

        // A jump bigger than what stays on screen can't be placed.
        var far = ScrollStitcher(first: page.frame(at: 0))
        precondition(far.add(page.frame(at: 300)) == .lostTrack)

        // No fixed bars, and faint rendering noise between frames.
        let plainPage = makePage(length: 600, header: 0, footer: 0, viewport: 200)
        var noisy = ScrollStitcher(first: plainPage.frame(at: 0))
        for (index, scroll) in [50, 110, 180, 260, 330].enumerated() {
            if case .grew = noisy.add(plainPage.frame(at: scroll, noise: index % 2 == 0)) {} else { fatalError("noisy step \(scroll)") }
        }
        precondition(noisy.height == 530)
        let noisyPixels = pixels(noisy), clean = plainPage.expected(through: 330)
        precondition(zip(noisyPixels, clean).allSatisfy { abs(Int($0) - Int($1)) <= 1 }, "rows land in the right place")

        // A blank stretch: unmeasurable on its own, placed with the distance automatic scrolling just used.
        let gappy = makePage(length: 700, header: 20, footer: 0, viewport: 220, blank: 150..<520)
        var gaps = ScrollStitcher(first: gappy.frame(at: 0))
        precondition(gaps.add(gappy.frame(at: 120)) == .grew(120))
        precondition(gaps.add(gappy.frame(at: 300)) == .lostTrack, "a blank frame can't be measured")
        precondition(gaps.add(gappy.frame(at: 300), expectedOffset: 180) == .estimated(180))
        precondition(gaps.add(gappy.frame(at: 300)) == .unchanged, "identical blank frames without a known scroll")
        precondition(gaps.add(gappy.frame(at: 400)) == .lostTrack, "content entering a blank frame can't be measured")
        precondition(gaps.add(gappy.frame(at: 400), expectedOffset: 100) == .estimated(100))
        precondition(gaps.add(gappy.frame(at: 480)) == .grew(80), "content again: measured, not assumed")
        precondition(pixels(gaps) == gappy.expected(through: 480))

        // The size limit.
        var capped = ScrollStitcher(first: page.frame(at: 0), maxHeight: 400)
        _ = capped.add(page.frame(at: 90))
        _ = capped.add(page.frame(at: 180))
        precondition(capped.height <= 400 && capped.add(page.frame(at: 260)) == .full)

        // A fixed sidebar beside the scrolling content (a chat list, a navigation pane): matched on the
        // content only, and cropped off the result.
        let sidebarWidth = 30, wide = width + sidebarWidth, viewport = 240
        let sidebar = (0..<viewport).map { y -> [UInt8] in
            (0..<sidebarWidth).flatMap { x -> [UInt8] in let v = UInt8((x * 7 + y * 13) % 200 + 20); return [v, v, v, 255] }
        }
        let content = (0..<800).map { pageRow($0) }
        func sideFrame(_ scroll: Int) -> ScrollFrame {
            ScrollFrame(width: wide, height: viewport, pixels: (0..<viewport).flatMap { sidebar[$0] + content[scroll + $0] })
        }
        var side = ScrollStitcher(first: sideFrame(0))
        for scroll in [30, 85, 150, 230, 320, 400] {
            if case .grew = side.add(sideFrame(scroll)) {} else { fatalError("sidebar step \(scroll) did not line up") }
        }
        let sideImage = side.makeImage()!
        precondition(sideImage.height == 400 + viewport)
        precondition(sideImage.width <= width && sideImage.width >= width - 20, "sidebar cropped, content kept (\(sideImage.width))")
        let sidePixels = ScrollFrame(image: sideImage)!.pixels, cut = width - sideImage.width
        precondition(sidePixels == (0..<(400 + viewport)).flatMap { Array(content[$0][(cut * 4)...]) })

        // An overlay scroll bar knob moving down the right edge while the content scrolls.
        let barWidth = 400
        let barPage = (0..<1200).map { y in (0..<3).flatMap { _ in pageRow(y) } + [UInt8](repeating: 255, count: (barWidth - 3 * width) * 4) }
        func barFrame(_ scroll: Int) -> ScrollFrame {
            let knob = scroll * viewport / 1200
            return ScrollFrame(width: barWidth, height: viewport, pixels: (0..<viewport).flatMap { row -> [UInt8] in
                var line = barPage[scroll + row]
                if row >= knob && row < knob + 50 { for x in (barWidth - 12)..<(barWidth - 4) { line[x * 4] = 90; line[x * 4 + 1] = 90; line[x * 4 + 2] = 90 } }
                return line
            })
        }
        var knob = ScrollStitcher(first: barFrame(0))
        for scroll in stride(from: 40, through: 960, by: 40) {
            if case .grew = knob.add(barFrame(scroll)) {} else { fatalError("scroll bar step \(scroll) did not line up") }
        }
        precondition(knob.height == 960 + viewport)

        print("Passed scroll stitching checks: fixed bars, uneven steps, repeats, back-scroll, jumps, noise, blank stretches, size limit, sidebars, scroll bars")
    }
}
