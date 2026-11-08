import XCTest
@testable import LightsMenubar

@MainActor
final class HistoryStoreTests: XCTestCase {
    private let day = ISO8601DateFormatter().date(from: "2026-10-10T07:00:00Z")!
    private func withStore(_ body: (HistoryStore) throws -> Void) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try HistoryStore(url: directory.appendingPathComponent("history.sqlite"))
        try body(store)
    }
    private func row(_ offset: Double, _ state: Int = 0, entity: String = "a") -> RawStateRow {
        .init(time: day.addingTimeInterval(offset), entity: entity, state: state)
    }

    func testObservationsWithoutCoverageDoNotBecomeDonors() throws {
        try withStore { store in
            try store.record(row(-1, 1))
            XCTAssertTrue(try store.training(entities: ["a"], since: day, now: day.addingTimeInterval(86400)).days.isEmpty)
            try store.cover(entities: ["a"], from: day, to: day.addingTimeInterval(86400), session: "invalid-gap")
            XCTAssertTrue(try store.training(entities: ["a"], since: day, now: day.addingTimeInterval(86400)).days.isEmpty)
        }
    }

    func testResamplerUsesExplicitQuietDayInsteadOfInferringCoverageFromEvents() throws {
        let events = try Resampler.generate(rows: [row(-60, 1)], entityMap: ["a": "a"],
            vacationStart: day.addingTimeInterval(86400), vacationEnd: day.addingTimeInterval(172800),
            options: .init(jitterMinutes: 0, seed: 1), donorDates: [day])
        XCTAssertEqual(events.map(\.action), ["turn_on", "turn_off"])
        XCTAssertThrowsError(try Resampler.generate(rows: [row(-60, 1)], entityMap: ["a": "a"],
            vacationStart: day, vacationEnd: day.addingTimeInterval(86400), donorDates: []))
    }

    func testContinuousLocalHeartbeatsQualifyACompleteDay() throws {
        try withStore { store in
            try store.record(row(-1, 1))
            for index in 0..<2880 {
                let start = day.addingTimeInterval(Double(index * 30))
                try store.cover(entities: ["a"], from: start, to: start.addingTimeInterval(30), session: "continuous")
            }
            let history = try store.training(entities: ["a"], since: day, now: day.addingTimeInterval(86400))
            XCTAssertEqual(history.days, [day])
            XCTAssertEqual(history.rows.count, 1)
            XCTAssertTrue(try store.training(entities: ["a", "b"], since: day, now: day.addingTimeInterval(86400)).days.isEmpty)
        }
    }
}
