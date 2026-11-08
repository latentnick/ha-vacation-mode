import XCTest
@testable import LightsMenubar

@MainActor
final class MainActorTimerTests: XCTestCase {
    func testTimerRunsActorIsolatedCallback() async {
        let fired = expectation(description: "Timer callback")
        let status = ScheduleStatus()
        let timer = MainActorTimer.schedule(at: Date().addingTimeInterval(0.02)) {
            MainActor.assertIsolated()
            status.lastError = "timer fired"
            fired.fulfill()
        }
        defer { timer.cancel() }
        await fulfillment(of: [fired], timeout: 2)
        XCTAssertEqual(status.lastError, "timer fired")
    }

    func testCancelledTimerDoesNotFire() async {
        let fired = expectation(description: "Cancelled callback")
        fired.isInverted = true
        let timer = MainActorTimer.schedule(at: Date().addingTimeInterval(0.02)) {
            fired.fulfill()
        }
        timer.cancel()
        await fulfillment(of: [fired], timeout: 0.1)
    }
}
