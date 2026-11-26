import AppKit
import SwiftUI

/// The Verb symbol: a V written with a broad pen, the thick downstroke on the left and the
/// lighter upstroke on the right, its wings lifted like a swallow's. Spoken words fly; this is
/// the moment they land as ink. The outlines are on a 100 x 100 grid and match
/// Design/verb-mark.svg point for point.
enum MarkGeometry {
    struct Curve { let c1: CGPoint; let c2: CGPoint; let end: CGPoint }
    struct Outline { let start: CGPoint; let curves: [Curve]; let bounds: CGRect }

    /// For 24 pt and larger.
    static let display = Outline(start: CGPoint(x: 2, y: 21), curves: [
        Curve(c1: CGPoint(x: 17, y: 25), c2: CGPoint(x: 39, y: 55), end: CGPoint(x: 50, y: 88)),
        Curve(c1: CGPoint(x: 61, y: 55), c2: CGPoint(x: 83, y: 25), end: CGPoint(x: 98, y: 21)),
        Curve(c1: CGPoint(x: 81, y: 26.5), c2: CGPoint(x: 61, y: 45.5), end: CGPoint(x: 51.2, y: 61)),
        Curve(c1: CGPoint(x: 42, y: 42), c2: CGPoint(x: 23, y: 25), end: CGPoint(x: 2, y: 21)),
    ], bounds: CGRect(x: 2, y: 21, width: 96, height: 67))

    /// A heavier optical size for the menu bar and anything under 24 pt: thicker wings with square-cut
    /// tips, so at 16 px they stay solid instead of fading into a few pale pixels.
    static let small = Outline(start: CGPoint(x: 4, y: 31), curves: [
        Curve(c1: CGPoint(x: 19, y: 34), c2: CGPoint(x: 39, y: 57), end: CGPoint(x: 50, y: 90)),
        Curve(c1: CGPoint(x: 60, y: 58), c2: CGPoint(x: 78, y: 33), end: CGPoint(x: 96, y: 27)),
        Curve(c1: CGPoint(x: 96, y: 27), c2: CGPoint(x: 96, y: 18), end: CGPoint(x: 96, y: 18)),
        Curve(c1: CGPoint(x: 78, y: 21), c2: CGPoint(x: 61, y: 40), end: CGPoint(x: 52, y: 61)),
        Curve(c1: CGPoint(x: 43, y: 41), c2: CGPoint(x: 23, y: 20), end: CGPoint(x: 4, y: 19)),
    ], bounds: CGRect(x: 4, y: 18, width: 92, height: 72))

    /// The outline scaled to fit `rect`, centred, in top-left-origin coordinates.
    static func path(small: Bool, in rect: CGRect) -> CGPath {
        let outline = small ? Self.small : display
        let scale = min(rect.width / outline.bounds.width, rect.height / outline.bounds.height)
        let dx = rect.midX - outline.bounds.midX * scale, dy = rect.midY - outline.bounds.midY * scale
        let map = { (point: CGPoint) in CGPoint(x: point.x * scale + dx, y: point.y * scale + dy) }
        let path = CGMutablePath()
        path.move(to: map(outline.start))
        for curve in outline.curves { path.addCurve(to: map(curve.end), control1: map(curve.c1), control2: map(curve.c2)) }
        path.closeSubpath()
        return path
    }
}

struct VerbMark: Shape {
    var small = false
    func path(in rect: CGRect) -> Path { Path(MarkGeometry.path(small: small, in: rect)) }
}

/// Template images for the status item, so macOS tints them for the menu bar.
enum MenuBarIcon {
    /// `attention`: dictating can't work until something is fixed, as when Accessibility is off.
    enum State { case idle, recording, working, attention }
    static func image(_ state: State, description: String) -> NSImage {
        let width: CGFloat = state == .idle ? 20 : 27
        let image = NSImage(size: NSSize(width: width, height: 16), flipped: true) { _ in
            guard let context = NSGraphicsContext.current?.cgContext else { return false }
            context.setFillColor(NSColor.black.cgColor)
            context.addPath(MarkGeometry.path(small: true, in: CGRect(x: 1, y: 1.5, width: 18, height: 13)))
            context.fillPath()
            switch state {
            case .idle: break
            case .recording: context.fillEllipse(in: CGRect(x: 21.5, y: 9, width: 5, height: 5))
            case .working:
                context.setStrokeColor(NSColor.black.cgColor); context.setLineWidth(1.3)
                context.strokeEllipse(in: CGRect(x: 22, y: 9.5, width: 4, height: 4))
            case .attention:
                context.addPath(CGPath(roundedRect: CGRect(x: 23, y: 3, width: 2, height: 7.5), cornerWidth: 1, cornerHeight: 1, transform: nil))
                context.fillPath()
                context.fillEllipse(in: CGRect(x: 23, y: 12, width: 2, height: 2))
            }
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = description
        return image
    }
}
