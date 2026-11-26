import XCTest
@testable import VerbCore

final class LivePreviewTests: XCTestCase {
    private let rate = 16000
    func testShortPartIsNotSettled() {
        XCTAssertNil(LivePreviewCut.settle(Array(repeating: Float(0.3), count: rate * 3)[...]))
    }
    func testLongPartSettlesAtItsQuietestMoment() throws {
        var samples = Array(repeating: Float(0.3), count: rate * 5)
        for i in (rate * 2)..<(rate * 2 + 400) { samples[i] = 0 }
        let cut = try XCTUnwrap(LivePreviewCut.settle(samples[...]))
        XCTAssertEqual(Double(cut), Double(rate * 2 + 200), accuracy: 400)
    }
    func testCutKeepsTheLastFractionOfASecondUnsettled() throws {
        let samples = Array(repeating: Float(0.3), count: rate * 4)
        let cut = try XCTUnwrap(LivePreviewCut.settle(samples[...]))
        XCTAssertLessThanOrEqual(cut, samples.count - rate * 2 / 5)
        XCTAssertGreaterThanOrEqual(cut, rate)
    }
    func testParakeetUltraIsInTheCatalog() throws {
        let model = try SpeechCatalog.model("parakeet-ultra")
        XCTAssertEqual(model.downloadBytes, 244093 + 1254184462 + 360916 + 101024 + 46772)
        XCTAssertTrue(model.recognizes(.it))
    }
}
