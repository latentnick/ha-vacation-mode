import XCTest
@testable import LightsMenubar

@MainActor
final class SchedulePlaybackTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1000)
    private func event(_ seconds: Double, _ entity: String, _ action: String) -> ScheduledEvent {
        ScheduledEvent(time: start.addingTimeInterval(seconds), entity_id: entity, action: action)
    }

    func testSimultaneousShutdownsAllExecute() async {
        let playback = SchedulePlayback()
        playback.events = [event(0, "a", "turn_on"), event(0, "b", "turn_on"),
                           event(10, "a", "turn_off"), event(10, "b", "turn_off")]
        var sent: [ScheduledEvent] = []
        _ = await playback.reconcile(now: { self.start }) { sent.append($0) }
        sent = []
        _ = await playback.reconcile(now: { self.start.addingTimeInterval(10) }) { sent.append($0) }
        XCTAssertEqual(sent.map(\.entity_id), ["a", "b"])
        XCTAssertTrue(sent.allSatisfy { $0.action == "turn_off" })
    }

    func testDelayedTimerReconcilesEveryEntityWithoutReplayingStaleOn() async {
        let playback = SchedulePlayback()
        playback.events = [event(1, "a", "turn_on"), event(2, "b", "turn_on"), event(3, "a", "turn_off")]
        var sent: [ScheduledEvent] = []
        _ = await playback.reconcile(now: { self.start.addingTimeInterval(4) }) { sent.append($0) }
        XCTAssertEqual(sent, [event(3, "a", "turn_off"), event(2, "b", "turn_on")])
        XCTAssertFalse(playback.hasPending(at: start.addingTimeInterval(4)))
    }

    func testFailedRequestRemainsPendingAndIsRetried() async {
        for error in [URLError(.networkConnectionLost) as Error,
                      NSError(domain: "HA", code: 503)] {
            let playback = SchedulePlayback()
            playback.events = [event(0, "a", "turn_off"), event(0, "b", "turn_off")]
            let message = await playback.reconcile(now: { self.start }) { event in
                if event.entity_id == "a" { throw error }
            }
            XCTAssertNotNil(message)
            XCTAssertNil(playback.confirmed["a"])
            XCTAssertEqual(playback.confirmed["b"], "turn_off")
            XCTAssertTrue(playback.hasPending(at: start))
            var retried: [String] = []
            let recovered = await playback.reconcile(now: { self.start }) { retried.append($0.entity_id) }
            XCTAssertNil(recovered)
            XCTAssertEqual(retried, ["a"])
            XCTAssertFalse(playback.hasPending(at: start))
        }
    }

    func testFailedOnDoesNotSuppressLaterOffMatchingOldConfirmedState() async {
        let playback = SchedulePlayback()
        playback.events = [event(0, "a", "turn_off"), event(1, "a", "turn_on"), event(2, "a", "turn_off")]
        _ = await playback.reconcile(now: { self.start }) { _ in }
        _ = await playback.reconcile(now: { self.start.addingTimeInterval(1) }) { _ in throw URLError(.timedOut) }
        var sent: [String] = []
        _ = await playback.reconcile(now: { self.start.addingTimeInterval(2) }) { sent.append($0.action) }
        XCTAssertEqual(sent, ["turn_off"])
    }

    func testEventBecomingDueDuringRequestIsAppliedBeforeFinishing() async {
        let playback = SchedulePlayback()
        playback.events = [event(0, "a", "turn_on"), event(1, "a", "turn_off")]
        var now = start
        var sent: [String] = []
        _ = await playback.reconcile(now: { now }) {
            sent.append($0.action)
            now = self.start.addingTimeInterval(2)
        }
        XCTAssertEqual(sent, ["turn_on", "turn_off"])
    }

    func testResetDiscardsInflightConfirmation() async {
        let playback = SchedulePlayback()
        playback.events = [event(0, "a", "turn_on")]
        _ = await playback.reconcile(now: { self.start }) { _ in playback.reset() }
        XCTAssertTrue(playback.confirmed.isEmpty)
    }
}
