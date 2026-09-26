// Draws the Verb app icon: ivory card stock with the V-swallow pressed into it in red pencil.
//
//     swift scripts/make-icon.swift /tmp/Verb.iconset && iconutil -c icns /tmp/Verb.iconset -o Resources/Verb.icns
//
// The two outlines below are the same points as MarkGeometry in Sources/Verb/VerbMark.swift
// and Design/verb-mark.svg, on a 100 x 100 grid.
import AppKit

typealias Outline = (start: CGPoint, curves: [(CGPoint, CGPoint, CGPoint)], bounds: CGRect)
let display: Outline = (CGPoint(x: 2, y: 21), [
    (CGPoint(x: 17, y: 25), CGPoint(x: 39, y: 55), CGPoint(x: 50, y: 88)),
    (CGPoint(x: 61, y: 55), CGPoint(x: 83, y: 25), CGPoint(x: 98, y: 21)),
    (CGPoint(x: 81, y: 26.5), CGPoint(x: 61, y: 45.5), CGPoint(x: 51.2, y: 61)),
    (CGPoint(x: 42, y: 42), CGPoint(x: 23, y: 25), CGPoint(x: 2, y: 21)),
], CGRect(x: 2, y: 21, width: 96, height: 67))
let small: Outline = (CGPoint(x: 2, y: 20), [
    (CGPoint(x: 18, y: 23), CGPoint(x: 39, y: 53), CGPoint(x: 50, y: 90)),
    (CGPoint(x: 61, y: 53), CGPoint(x: 82, y: 23), CGPoint(x: 98, y: 20)),
    (CGPoint(x: 82, y: 23), CGPoint(x: 63, y: 40), CGPoint(x: 52, y: 58)),
    (CGPoint(x: 42, y: 40), CGPoint(x: 24, y: 23), CGPoint(x: 2, y: 20)),
], CGRect(x: 2, y: 20, width: 96, height: 70))

/// The outline fitted into `rect` (y grows upward, as in Core Graphics).
func markPath(_ outline: Outline, in rect: CGRect) -> CGPath {
    let scale = min(rect.width / outline.bounds.width, rect.height / outline.bounds.height)
    let map = { (p: CGPoint) in CGPoint(x: rect.midX + (p.x - outline.bounds.midX) * scale, y: rect.midY - (p.y - outline.bounds.midY) * scale) }
    let path = CGMutablePath()
    path.move(to: map(outline.start))
    for (c1, c2, end) in outline.curves { path.addCurve(to: map(end), control1: map(c1), control2: map(c2)) }
    path.closeSubpath()
    return path
}

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}

func render(pixels: Int) -> Data {
    let space = CGColorSpace(name: CGColorSpace.sRGB)!
    let context = CGContext(data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0, space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    let scale = CGFloat(pixels) / 1024
    context.scaleBy(x: scale, y: scale)
    context.interpolationQuality = .high
    let tiny = pixels <= 64

    // The card: Apple's 824 pt body on the 1024 grid, with the standard soft drop shadow.
    let body = CGRect(x: 100, y: 100, width: 824, height: 824)
    let card = CGPath(roundedRect: body, cornerWidth: 185, cornerHeight: 185, transform: nil)
    context.saveGState()
    context.setShadow(offset: CGSize(width: 0, height: -10), blur: 24, color: color(0x2A1F14, 0.34))
    context.addPath(card); context.setFillColor(color(0xF6F0E4)); context.fillPath()
    context.restoreGState()

    // Ivory stock, a touch warmer toward the bottom, like paper under a desk lamp.
    context.saveGState()
    context.addPath(card); context.clip()
    let paper = CGGradient(colorsSpace: space, colors: [color(0xFFFCF7), color(0xF4EDE1), color(0xEBE2D2)] as CFArray, locations: [0, 0.55, 1])!
    context.drawLinearGradient(paper, start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 100), options: [])
    if !tiny {
        // A faint fibre texture, fixed so every build is identical.
        var seed: UInt64 = 0x5645524241
        func next() -> CGFloat { seed = seed &* 6364136223846793005 &+ 1442695040888963407; return CGFloat(seed >> 33) / CGFloat(UInt32.max >> 1) }
        for _ in 0..<2600 {
            let x = 100 + next() * 824, y = 100 + next() * 824, length = 3 + next() * 9, angle = next() * .pi
            context.setStrokeColor(next() > 0.5 ? color(0x8A7A62, 0.045) : color(0xFFFFFF, 0.08))
            context.setLineWidth(0.9)
            context.move(to: CGPoint(x: x, y: y)); context.addLine(to: CGPoint(x: x + cos(angle) * length, y: y + sin(angle) * length)); context.strokePath()
        }
        // Card edges: light catches the top, the bottom sits in shadow.
        context.setLineWidth(3)
        context.setStrokeColor(color(0xFFFFFF, 0.85)); context.addPath(CGPath(roundedRect: body.insetBy(dx: 1.5, dy: 1.5), cornerWidth: 184, cornerHeight: 184, transform: nil))
        context.saveGState(); context.clip(to: CGRect(x: 0, y: 700, width: 1024, height: 324)); context.strokePath(); context.restoreGState()
        context.setStrokeColor(color(0xC9BBA3, 0.55)); context.addPath(CGPath(roundedRect: body.insetBy(dx: 1.5, dy: 1.5), cornerWidth: 184, cornerHeight: 184, transform: nil))
        context.saveGState(); context.clip(to: CGRect(x: 0, y: 0, width: 1024, height: 300)); context.strokePath(); context.restoreGState()
    }
    context.restoreGState()

    // The mark, set a little above centre where the eye expects it.
    let markBox = tiny ? CGRect(x: 212, y: 262, width: 600, height: 480) : CGRect(x: 232, y: 290, width: 560, height: 440)
    let mark = markPath(tiny ? small : display, in: markBox)
    if !tiny {
        // Letterpress, first half: the paper catches light along the lower lip of the bite.
        context.saveGState()
        context.translateBy(x: 0, y: -3)
        context.setShadow(offset: .zero, blur: 2, color: color(0xFFFFFF, 0.9))
        context.addPath(mark); context.setFillColor(color(0xFFFFFF, 0.7)); context.fillPath()
        context.restoreGState()
    }
    context.addPath(mark); context.setFillColor(color(0xB43B27)); context.fillPath()
    if !tiny {
        // Second half: an inner shadow along the upper edge, as if the ink sits below the surface.
        context.saveGState()
        context.addPath(mark); context.clip()
        let outside = CGMutablePath(); outside.addRect(CGRect(x: -200, y: -200, width: 1424, height: 1424)); outside.addPath(mark)
        context.setShadow(offset: CGSize(width: 0, height: -5), blur: 7, color: color(0x4A140C, 0.55))
        context.addPath(outside); context.setFillColor(color(0x000000)); context.fillPath(using: .evenOdd)
        context.restoreGState()
    }
    let image = context.makeImage()!
    return NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])!
}

let output = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
for (points, scales) in [(16, [1, 2]), (32, [1, 2]), (128, [1, 2]), (256, [1, 2]), (512, [1, 2])] {
    for factor in scales {
        let name = factor == 1 ? "icon_\(points)x\(points).png" : "icon_\(points)x\(points)@2x.png"
        try render(pixels: points * factor).write(to: output.appendingPathComponent(name))
    }
}
try render(pixels: 1024).write(to: output.appendingPathComponent("../Verb-1024.png").standardizedFileURL)
