// Renders the Snapok app icon: swift scripts/render-icon.swift Resources/Brand/SnapokFamily.png
// Development icon: swift scripts/render-icon.swift --dev Resources/Brand/SnapokFamily-Dev.png
// Family style shared with TypeAny / MailAny: gradient tile on the 824pt macOS grid,
// soft white shapes, vertical pill eyes. Snapok's character is the selection itself:
// a nearly closed rounded frame, open at the top-right and bottom-left corners, with the eyes inside.
import AppKit

// Pass --dev to add the "DEV" badge used by development builds.
let arguments = CommandLine.arguments.dropFirst()
let isDev = arguments.contains("--dev")
let out = arguments.first { $0 != "--dev" } ?? "icon.png"

func rgb(_ hex: UInt32, _ a: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: a)
}

// Palette: a soft, light pink rather than a red-leaning rose.
let tileTop = rgb(0xFFA9D4)
let tileBottom = rgb(0xF472B6)
let shapeShadow = rgb(0xBE185D, 0.32)
let shapeBottom = rgb(0xFDF0F7)

func superellipse(_ rect: CGRect, n: CGFloat = 4) -> CGPath {
    let path = CGMutablePath()
    let a = rect.width / 2, b = rect.height / 2
    for i in 0...720 {
        let t = CGFloat(i) / 720 * 2 * .pi
        let c = cos(t), s = sin(t)
        let p = CGPoint(
            x: rect.midX + pow(abs(c), 2 / n) * a * (c < 0 ? -1 : 1),
            y: rect.midY + pow(abs(s), 2 / n) * b * (s < 0 ? -1 : 1)
        )
        i == 0 ? path.move(to: p) : path.addLine(to: p)
    }
    path.closeSubpath()
    return path
}

let ctx = CGContext(
    data: nil, width: 1024, height: 1024, bitsPerComponent: 8, bytesPerRow: 0,
    space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
)!

func gradient(_ path: CGPath, _ top: CGColor, _ bottom: CGColor, box: CGRect? = nil) {
    let box = box ?? path.boundingBox
    ctx.saveGState()
    ctx.addPath(path)
    ctx.clip()
    let g = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: [top, bottom] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(g, start: CGPoint(x: box.midX, y: box.maxY), end: CGPoint(x: box.midX, y: box.minY), options: [])
    ctx.restoreGState()
}

/// Soft white shape with a drop shadow and a faint blush toward the bottom.
func softWhite(_ path: CGPath, shadowOffset: CGFloat = 16, blur: CGFloat = 36, box: CGRect? = nil) {
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -shadowOffset), blur: blur, color: shapeShadow)
    ctx.addPath(path)
    ctx.setFillColor(rgb(0xFFFFFF))
    ctx.fillPath()
    ctx.restoreGState()
    gradient(path, rgb(0xFFFFFF), shapeBottom, box: box)
}

// Tile.
let tile = superellipse(CGRect(x: 100, y: 100, width: 824, height: 824))
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 24, color: rgb(0x000000, 0.25))
ctx.addPath(tile)
ctx.setFillColor(tileBottom)
ctx.fillPath()
ctx.restoreGState()
gradient(tile, tileTop, tileBottom)

// Frame: sample the rounded-square centerline clockwise, starting at the left end of the top edge,
// then stroke every run between the gaps with round caps.
let outer: CGFloat = 520
let thickness: CGFloat = 84
let visibleGap: CGFloat = 32
let side = outer - thickness
let radius: CGFloat = 122
let center = CGRect(x: 512 - side / 2, y: 512 - side / 2, width: side, height: side)

var points: [CGPoint] = []
func line(_ a: CGPoint, _ b: CGPoint) {
    for i in 0..<40 {
        let f = CGFloat(i) / 40
        points.append(CGPoint(x: a.x + (b.x - a.x) * f, y: a.y + (b.y - a.y) * f))
    }
}
func arc(_ c: CGPoint, _ from: CGFloat, _ to: CGFloat) {
    for i in 0..<40 {
        let a = from + (to - from) * CGFloat(i) / 40
        points.append(CGPoint(x: c.x + cos(a) * radius, y: c.y + sin(a) * radius))
    }
}
line(CGPoint(x: center.minX + radius, y: center.maxY), CGPoint(x: center.maxX - radius, y: center.maxY))
arc(CGPoint(x: center.maxX - radius, y: center.maxY - radius), .pi / 2, 0)
line(CGPoint(x: center.maxX, y: center.maxY - radius), CGPoint(x: center.maxX, y: center.minY + radius))
arc(CGPoint(x: center.maxX - radius, y: center.minY + radius), 0, -.pi / 2)
line(CGPoint(x: center.maxX - radius, y: center.minY), CGPoint(x: center.minX + radius, y: center.minY))
arc(CGPoint(x: center.minX + radius, y: center.minY + radius), -.pi / 2, -.pi)
line(CGPoint(x: center.minX, y: center.minY + radius), CGPoint(x: center.minX, y: center.maxY - radius))
arc(CGPoint(x: center.minX + radius, y: center.maxY - radius), .pi, .pi / 2)

var lengths: [CGFloat] = [0]
for i in 1..<points.count {
    lengths.append(lengths[i - 1] + hypot(points[i].x - points[i - 1].x, points[i].y - points[i - 1].y))
}
let perimeter = lengths.last! + hypot(points[0].x - points.last!.x, points[0].y - points.last!.y)

func point(at distance: CGFloat) -> CGPoint {
    var s = distance.truncatingRemainder(dividingBy: perimeter)
    if s < 0 { s += perimeter }
    var i = 0
    while i + 1 < lengths.count && lengths[i + 1] < s { i += 1 }
    let a = points[i]
    let b = i + 1 < points.count ? points[i + 1] : points[0]
    let segment = (i + 1 < lengths.count ? lengths[i + 1] : perimeter) - lengths[i]
    let f = segment > 0 ? (s - lengths[i]) / segment : 0
    return CGPoint(x: a.x + (b.x - a.x) * f, y: a.y + (b.y - a.y) * f)
}

let straight = side - 2 * radius
let quarter = CGFloat.pi / 2 * radius
// Gap centers along the perimeter: middle of the top-right and bottom-left corners.
let gaps = [straight + quarter / 2, 3 * straight + 2.5 * quarter]
// Round caps extend half the thickness into each gap.
let halfGap = (visibleGap + thickness) / 2
let frameBox = center.insetBy(dx: -thickness / 2, dy: -thickness / 2)

for (i, gap) in gaps.enumerated() {
    let start = gap + halfGap
    var end = (i + 1 < gaps.count ? gaps[i + 1] : gaps[0] + perimeter) - halfGap
    if end < start { end += perimeter }
    let path = CGMutablePath()
    var s = start
    path.move(to: point(at: s))
    while s < end {
        s = min(s + 3, end)
        path.addLine(to: point(at: s))
    }
    softWhite(path.copy(strokingWithWidth: thickness, lineCap: .round, lineJoin: .round, miterLimit: 10), box: frameBox)
}

// Eyes.
let eye = CGSize(width: 62, height: 146)
for dx: CGFloat in [-78, 78] {
    let rect = CGRect(x: 512 + dx - eye.width / 2, y: 512 - eye.height / 2, width: eye.width, height: eye.height)
    softWhite(CGPath(roundedRect: rect, cornerWidth: eye.width / 2, cornerHeight: eye.width / 2, transform: nil), shadowOffset: 8, blur: 20)
}

// Development badge: a dark pill under the frame, readable down to Dock size.
if isDev {
    let badge = CGRect(x: 512 - 150, y: 128, width: 300, height: 104)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -6), blur: 14, color: rgb(0x000000, 0.3))
    ctx.addPath(CGPath(roundedRect: badge, cornerWidth: 52, cornerHeight: 52, transform: nil))
    ctx.setFillColor(rgb(0x1F2937))
    ctx.fillPath()
    ctx.restoreGState()
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
    let text = NSAttributedString(string: "DEV", attributes: [
        .font: NSFont.systemFont(ofSize: 72, weight: .heavy),
        .foregroundColor: NSColor.white,
        .kern: 6
    ])
    let size = text.size()
    text.draw(at: CGPoint(x: badge.midX - size.width / 2 + 3, y: badge.midY - size.height / 2))
    NSGraphicsContext.restoreGraphicsState()
}

let rep = NSBitmapImageRep(cgImage: ctx.makeImage()!)
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
print("wrote \(out)")
