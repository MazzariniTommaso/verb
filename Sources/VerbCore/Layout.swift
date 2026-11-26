import CoreGraphics

/// The sizes a window may take on a screen. The numbers themselves are design tokens; this is
/// what is done with them.
public enum WindowLayout {
    public struct Limits: Equatable, Sendable {
        public var min: CGSize
        public var max: CGSize
        public init(min: CGSize, max: CGSize) { self.min = min; self.max = max }
    }

    /// The limits on a screen with `room` free (its visible frame): never larger than the screen,
    /// and the smallest never larger than the largest, as on a small display with Larger Text.
    public static func limits(_ wanted: Limits, room: CGSize) -> Limits {
        let largest = CGSize(width: Swift.min(wanted.max.width, room.width), height: Swift.min(wanted.max.height, room.height))
        let smallest = CGSize(width: Swift.min(wanted.min.width, largest.width), height: Swift.min(wanted.min.height, largest.height))
        return Limits(min: smallest, max: largest)
    }

    /// A size brought within the limits, such as a frame saved on a larger screen.
    public static func fit(_ size: CGSize, in limits: Limits) -> CGSize {
        CGSize(width: Swift.min(Swift.max(size.width, limits.min.width), limits.max.width),
               height: Swift.min(Swift.max(size.height, limits.min.height), limits.max.height))
    }
}

/// How a page lays itself out in the room beside the sidebar. The room only grows with the
/// window: the sidebar changes width when you ask, never by itself, so no step of the window
/// makes a page narrower. Each size steps the margins up by at most 8 pt a side, so the column
/// loses at most 16 pt where one size gives way to the next. Columns start at the margin, by the
/// sidebar, and what is left over goes to the trailing side or to a second column.
public struct PageLayout: Equatable, Sendable {
    public enum Size: Int, Comparable, Sendable {
        case small, medium, large, extraLarge
        public static func < (a: Size, b: Size) -> Bool { a.rawValue < b.rawValue }
    }
    /// Where each size starts, in points of room, and its margin and gutter.
    public struct Spec: Equatable, Sendable {
        public var mediumFrom: CGFloat, largeFrom: CGFloat, extraLargeFrom: CGFloat
        public var margins: [CGFloat]
        public var gutters: [CGFloat]
        public init(mediumFrom: CGFloat, largeFrom: CGFloat, extraLargeFrom: CGFloat, margins: [CGFloat], gutters: [CGFloat]) {
            self.mediumFrom = mediumFrom; self.largeFrom = largeFrom; self.extraLargeFrom = extraLargeFrom
            self.margins = margins; self.gutters = gutters
        }
    }

    public let room: CGFloat
    public let size: Size
    public let margin: CGFloat
    public let gutter: CGFloat

    public init(room: CGFloat, spec: Spec) {
        self.room = room
        size = room < spec.mediumFrom ? .small : room < spec.largeFrom ? .medium : room < spec.extraLargeFrom ? .large : .extraLarge
        margin = spec.margins[size.rawValue]
        gutter = spec.gutters[size.rawValue]
    }

    /// The width a column takes: what the margins leave, up to `cap`.
    public func column(cap: CGFloat = .infinity) -> CGFloat { min(cap, max(0, room - margin * 2)) }

    /// Side by side from large on; one above the other below it.
    public var sideBySide: Bool { size >= .large }

    /// One of two panes that share `width`, such as a list beside the note it opens: its share,
    /// kept between `least` and `most`.
    public static func pane(of width: CGFloat, share: CGFloat, least: CGFloat, most: CGFloat) -> CGFloat {
        min(most, max(least, (width * share).rounded()))
    }
}

/// The window's buttons, close, minimise and zoom, where macOS draws them: the sidebar with its
/// icons alone is as wide as they need with the same margin on both sides, and its icons stand
/// on their middle.
public struct WindowButtons: Equatable, Sendable {
    /// From the window's top left corner.
    public var frame: CGRect
    public init(frame: CGRect) { self.frame = frame }

    public var railWidth: CGFloat { (frame.maxX + frame.minX).rounded(.up) }
    public var center: CGPoint { CGPoint(x: frame.midX, y: frame.midY) }
}

/// The notch style on one screen: under the notch where the screen has one, hanging from the top
/// edge where it has none. Measures are in points, from the screen's left edge.
public struct IslandGeometry: Equatable, Sendable {
    /// The notch, or nil on a screen without one.
    public var notch: CGSize?
    /// The menu bar's height on that screen, 0 where there is none.
    public var menuBar: CGFloat
    /// The middle of the notch, or of the screen without one.
    public var center: CGFloat

    public init(notch: CGSize? = nil, menuBar: CGFloat = 0, center: CGFloat = 0) {
        self.notch = notch; self.menuBar = menuBar; self.center = center
    }

    /// A screen as AppKit describes it: its width, the free areas left and right of the notch
    /// (nil without one), the safe area's top inset and the menu bar's height.
    public static func screen(width: CGFloat, left: CGSize?, right: CGSize?, safeTop: CGFloat, menuBar: CGFloat) -> IslandGeometry {
        let bar = max(0, menuBar)
        guard let left, let right, safeTop > 0 else { return IslandGeometry(notch: nil, menuBar: bar, center: width / 2) }
        let notch = width - left.width - right.width
        guard notch > 0 else { return IslandGeometry(notch: nil, menuBar: bar, center: width / 2) }
        return IslandGeometry(notch: CGSize(width: notch, height: safeTop), menuBar: bar, center: left.width + notch / 2)
    }

    public var hasNotch: Bool { notch != nil }

    /// The band at the top the island's content stays below: the notch hides it. Without a notch
    /// the content starts at the top, as on a pill.
    public var band: CGFloat { notch?.height ?? 0 }

    /// Where the island's left edge goes for a width, keeping it on the notch's middle.
    public func left(for width: CGFloat) -> CGFloat { (center - width / 2).rounded() }
}
