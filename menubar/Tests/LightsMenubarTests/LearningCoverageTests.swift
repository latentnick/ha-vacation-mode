import XCTest
@testable import LightsMenubar

final class LearningCoverageTests: XCTestCase {
    func testAwayOrUnknownStateBreaksLearningUntilTwoFreshHomeSamples() {
        var coverage = LearningCoverage()
        let start = Date(timeIntervalSince1970: 1000)
        XCTAssertNil(coverage.observe(at: start, learning: true))
        XCTAssertNotNil(coverage.observe(at: start.addingTimeInterval(15), learning: true))
        XCTAssertNil(coverage.observe(at: start.addingTimeInterval(30), learning: false))
        XCTAssertNil(coverage.observe(at: start.addingTimeInterval(45), learning: true))
        XCTAssertEqual(coverage.observe(at: start.addingTimeInterval(60), learning: true)?.start, start.addingTimeInterval(45))
    }
    func testSleepClockReversalAndReconnectCannotBridgeGaps() {
        var coverage = LearningCoverage()
        let start = Date(timeIntervalSince1970: 1000)
        _ = coverage.observe(at: start, learning: true)
        XCTAssertNil(coverage.observe(at: start.addingTimeInterval(60), learning: true))
        XCTAssertNil(coverage.observe(at: start, learning: true))
        coverage.reset()
        XCTAssertNil(coverage.observe(at: start.addingTimeInterval(15), learning: true))
    }
}
