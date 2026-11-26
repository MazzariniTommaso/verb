import CoreGraphics
import XCTest
@testable import VerbCore

final class WindowLayoutTests: XCTestCase {
    private let main = WindowLayout.Limits(min: CGSize(width: 720, height: 560), max: CGSize(width: 1600, height: 1200))

    func testTheLimitsStayWithinTheScreen() {
        // A 14-inch MacBook: the largest window is the screen's room, the smallest is unchanged.
        let laptop = WindowLayout.limits(main, room: CGSize(width: 1512, height: 890))
        XCTAssertEqual(laptop.max, CGSize(width: 1512, height: 890))
        XCTAssertEqual(laptop.min, main.min)
        // A large display keeps the largest window as designed.
        XCTAssertEqual(WindowLayout.limits(main, room: CGSize(width: 2560, height: 1400)).max, main.max)
        // A small display with Larger Text: even the smallest window gives way to the screen.
        let tiny = WindowLayout.limits(main, room: CGSize(width: 1024, height: 500))
        XCTAssertEqual(tiny.min, CGSize(width: 720, height: 500))
        XCTAssertEqual(tiny.max, CGSize(width: 1024, height: 500))
    }

    func testASavedSizeIsBroughtWithinTheLimits() {
        XCTAssertEqual(WindowLayout.fit(CGSize(width: 2400, height: 1300), in: main), CGSize(width: 1600, height: 1200))
        XCTAssertEqual(WindowLayout.fit(CGSize(width: 500, height: 300), in: main), CGSize(width: 720, height: 560))
        XCTAssertEqual(WindowLayout.fit(CGSize(width: 1080, height: 780), in: main), CGSize(width: 1080, height: 780))
    }

}

final class PageLayoutTests: XCTestCase {
    /// Verb's own sizes: margins 32, 40, 48 and 56, gutters 16, 24, 24 and 32.
    private let spec = PageLayout.Spec(mediumFrom: 640, largeFrom: 1040, extraLargeFrom: 1360, margins: [32, 40, 48, 56], gutters: [16, 24, 24, 32])

    func testEachSizeHasItsMarginAndGutter() {
        let small = PageLayout(room: 499, spec: spec), medium = PageLayout(room: 859, spec: spec)
        let large = PageLayout(room: 1219, spec: spec), extraLarge = PageLayout(room: 1379, spec: spec)
        XCTAssertEqual([small.size, medium.size, large.size, extraLarge.size], [.small, .medium, .large, .extraLarge])
        XCTAssertEqual([small.margin, medium.margin, large.margin, extraLarge.margin], [32, 40, 48, 56])
        XCTAssertEqual([small.gutter, medium.gutter, large.gutter, extraLarge.gutter], [16, 24, 24, 32])
        XCTAssertFalse(medium.sideBySide)
        XCTAssertTrue(large.sideBySide)
    }

    func testAWiderWindowNeverMakesThePageMuchNarrower() {
        // Point by point from the narrowest room to the widest: a column grows, or loses at most
        // 16 pt where the margins step up.
        var previous = PageLayout(room: 400, spec: spec).column()
        for room in stride(from: CGFloat(401), through: 1600, by: 1) {
            let column = PageLayout(room: room, spec: spec).column()
            XCTAssertGreaterThanOrEqual(column, previous - 16, "at \(room) pt of room")
            previous = column
        }
    }

    func testAColumnStopsAtItsCap() {
        let wide = PageLayout(room: 1379, spec: spec)
        XCTAssertEqual(wide.column(), 1267)
        XCTAssertEqual(wide.column(cap: 880), 880)
        XCTAssertEqual(PageLayout(room: 499, spec: spec).column(cap: 880), 435)
        XCTAssertEqual(PageLayout(room: 20, spec: spec).column(), 0)
    }

    func testAPaneTakesItsShareWithinBounds() {
        XCTAssertEqual(PageLayout.pane(of: 600, share: 0.28, least: 240, most: 320), 240)
        XCTAssertEqual(PageLayout.pane(of: 1000, share: 0.28, least: 240, most: 320), 280)
        XCTAssertEqual(PageLayout.pane(of: 1400, share: 0.28, least: 240, most: 320), 320)
    }

    func testTheIconSidebarCentresTheWindowButtons() {
        // Close, minimise and zoom 9 pt from the left edge, 54 pt across.
        let buttons = WindowButtons(frame: CGRect(x: 9, y: 6, width: 54, height: 16))
        XCTAssertEqual(buttons.railWidth, 72)
        XCTAssertEqual(buttons.railWidth - buttons.frame.maxX, buttons.frame.minX)
        XCTAssertEqual(buttons.center, CGPoint(x: 36, y: 14))
        // Wider buttons, as another macOS draws them, widen the sidebar to match.
        XCTAssertEqual(WindowButtons(frame: CGRect(x: 9, y: 9, width: 60, height: 14)).railWidth, 78)
    }
}

final class IslandGeometryTests: XCTestCase {
    /// A 14-inch MacBook Pro at its default scale, and a 27-inch display without a menu bar.
    private let laptop = IslandGeometry.screen(width: 1512, left: CGSize(width: 663.5, height: 32), right: CGSize(width: 663.5, height: 32), safeTop: 32, menuBar: 33)
    private let display = IslandGeometry.screen(width: 1920, left: nil, right: nil, safeTop: 0, menuBar: 0)

    func testTheNotchIsFoundBetweenTheFreeAreas() {
        XCTAssertEqual(laptop.notch, CGSize(width: 185, height: 32))
        XCTAssertEqual(laptop.center, 756)
        XCTAssertTrue(laptop.hasNotch)
        XCTAssertEqual(laptop.band, 32)
        XCTAssertNil(display.notch)
        XCTAssertEqual(display.center, 960)
        XCTAssertEqual(display.band, 0)
        // Free areas without a safe inset, or that leave no gap, are not a notch.
        XCTAssertNil(IslandGeometry.screen(width: 1512, left: CGSize(width: 663.5, height: 32), right: CGSize(width: 663.5, height: 32), safeTop: 0, menuBar: 33).notch)
        XCTAssertNil(IslandGeometry.screen(width: 1512, left: CGSize(width: 756, height: 32), right: CGSize(width: 756, height: 32), safeTop: 32, menuBar: 33).notch)
    }

    func testAnOffCentreNotchKeepsTheIslandOnIt() {
        let skewed = IslandGeometry.screen(width: 1000, left: CGSize(width: 400, height: 30), right: CGSize(width: 400, height: 30), safeTop: 30, menuBar: 30)
        XCTAssertEqual(skewed.center, 500)
        let shifted = IslandGeometry.screen(width: 1000, left: CGSize(width: 420, height: 30), right: CGSize(width: 380, height: 30), safeTop: 30, menuBar: 30)
        XCTAssertEqual(shifted.center, 520)
        XCTAssertEqual(shifted.left(for: 300), 370)
    }
}
