import XCTest
@testable import LightsMenubar

/// Tests for the schedule generator. These replace the old workflow of diffing
/// `LightsMenubar --resample` output against the retired Python `generate_resample.py`.
final class ResamplerTests: XCTestCase {

    // MARK: - Helpers

    private static let cal: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = Resampler.pacific
        return c
    }()

    /// A Pacific wall-clock instant.
    private func date(_ y: Int, _ mo: Int, _ d: Int, _ h: Int = 0, _ mi: Int = 0) -> Date {
        var dc = DateComponents()
        dc.year = y; dc.month = mo; dc.day = d; dc.hour = h; dc.minute = mi
        return Self.cal.date(from: dc)!
    }

    /// Local Pacific midnight for a day.
    private func day(_ y: Int, _ mo: Int, _ d: Int) -> Date {
        Self.cal.startOfDay(for: date(y, mo, d))
    }

    // MARK: - transitions

    func testTransitionsDedupsConsecutiveSameState() {
        let rows = [
            RawStateRow(time: date(2026, 1, 1, 8), entity: "a", state: 1),
            RawStateRow(time: date(2026, 1, 1, 9), entity: "a", state: 1), // dup, dropped
            RawStateRow(time: date(2026, 1, 1, 10), entity: "a", state: 0),
            RawStateRow(time: date(2026, 1, 1, 11), entity: "a", state: 0), // dup, dropped
            RawStateRow(time: date(2026, 1, 1, 12), entity: "a", state: 1),
        ]
        let (trans, entities) = Resampler.transitions(from: rows)
        XCTAssertEqual(trans.map(\.state), [1, 0, 1])
        XCTAssertEqual(entities, ["a"])
    }

    func testTransitionsSortsGloballyAndListsEntitiesSorted() {
        let rows = [
            RawStateRow(time: date(2026, 1, 1, 12), entity: "b", state: 1),
            RawStateRow(time: date(2026, 1, 1, 8), entity: "a", state: 1),
            RawStateRow(time: date(2026, 1, 1, 10), entity: "b", state: 0),
        ]
        let (trans, entities) = Resampler.transitions(from: rows)
        // Globally time-sorted.
        XCTAssertEqual(trans.map(\.time), trans.map(\.time).sorted())
        XCTAssertEqual(entities, ["a", "b"])
    }

    // MARK: - candidateDates

    func testCandidateDatesDropsFirstAndLast() {
        let rows = (1...5).map { d in
            RawStateRow(time: date(2026, 1, d, 9), entity: "a", state: d.isMultiple(of: 2) ? 1 : 0)
        }
        let (trans, _) = Resampler.transitions(from: rows)
        let candidates = Resampler.candidateDates(transitions: trans)
        XCTAssertEqual(candidates, [day(2026, 1, 2), day(2026, 1, 3), day(2026, 1, 4)])
    }

    func testCandidateDatesKeepsAllWhenTwoOrFewer() {
        let rows = [
            RawStateRow(time: date(2026, 1, 1, 9), entity: "a", state: 1),
            RawStateRow(time: date(2026, 1, 2, 9), entity: "a", state: 0),
        ]
        let (trans, _) = Resampler.transitions(from: rows)
        XCTAssertEqual(Resampler.candidateDates(transitions: trans).count, 2)
    }

    // MARK: - blockOffsets

    func testBlockOffsets() {
        XCTAssertEqual(Resampler.blockOffsets(1), [0, 86400])
        XCTAssertEqual(Resampler.blockOffsets(2), [0, 43200, 86400])
        XCTAssertEqual(Resampler.blockOffsets(3), [0, 28800, 57600, 86400])
        // Always spans a full day and ends exactly at 86400.
        XCTAssertEqual(Resampler.blockOffsets(4).last, 86400)
    }

    // MARK: - stateAtTime

    func testStateAtTimeReflectsPriorTransitionsOnly() {
        let rows = [
            RawStateRow(time: date(2026, 1, 1, 8), entity: "a", state: 1),
            RawStateRow(time: date(2026, 1, 1, 20), entity: "a", state: 0),
            RawStateRow(time: date(2026, 1, 1, 9), entity: "b", state: 1),
        ]
        let (trans, entities) = Resampler.transitions(from: rows)
        // At 10:00 a is on (since 08:00), b is on (since 09:00).
        let s10 = Resampler.stateAtTime(trans, t: date(2026, 1, 1, 10), entities: entities)
        XCTAssertEqual(s10, ["a": 1, "b": 1])
        // At 21:00 a has turned off, b still on.
        let s21 = Resampler.stateAtTime(trans, t: date(2026, 1, 1, 21), entities: entities)
        XCTAssertEqual(s21, ["a": 0, "b": 1])
        // Boundary is exclusive: exactly at 08:00 a is not yet on.
        let s8 = Resampler.stateAtTime(trans, t: date(2026, 1, 1, 8), entities: entities)
        XCTAssertEqual(s8["a"], 0)
    }

    // MARK: - pickDonor

    func testPickDonorPrefersSameWeekday() {
        // 2026-01-01 is a Thursday. Build candidates spanning a couple weeks.
        let target = day(2026, 2, 5) // Thursday
        let candidates = (1...20).map { day(2026, 1, $0) }
        var rng = SeededGenerator(seed: 42)
        for _ in 0..<50 {
            let donor = Resampler.pickDonor(target: target, candidates: candidates, rng: &rng)
            XCTAssertEqual(Self.cal.component(.weekday, from: donor),
                           Self.cal.component(.weekday, from: target),
                           "donor should share the target's weekday when such donors exist")
        }
    }

    func testPickDonorIsDeterministicForASeed() {
        let target = day(2026, 2, 5)
        let candidates = (1...20).map { day(2026, 1, $0) }
        var a = SeededGenerator(seed: 7)
        var b = SeededGenerator(seed: 7)
        let seqA = (0..<10).map { _ in Resampler.pickDonor(target: target, candidates: candidates, rng: &a) }
        let seqB = (0..<10).map { _ in Resampler.pickDonor(target: target, candidates: candidates, rng: &b) }
        XCTAssertEqual(seqA, seqB)
    }

    // MARK: - generate (end-to-end invariants)

    /// A week of history for two entities: a morning light and an evening light.
    private func sampleHistory() -> [RawStateRow] {
        var rows: [RawStateRow] = []
        for d in 1...14 {
            rows.append(RawStateRow(time: date(2026, 1, d, 7), entity: "kitchen", state: 1))
            rows.append(RawStateRow(time: date(2026, 1, d, 9), entity: "kitchen", state: 0))
            rows.append(RawStateRow(time: date(2026, 1, d, 18), entity: "living", state: 1))
            rows.append(RawStateRow(time: date(2026, 1, d, 23), entity: "living", state: 0))
        }
        return rows
    }

    func testGenerateIsDeterministicWithSeed() {
        let rows = sampleHistory()
        let map = ["kitchen": "switch.kitchen", "living": "switch.living"]
        let start = day(2026, 3, 1), end = day(2026, 3, 4)
        let opts = ResamplerOptions(blocks: 2, jitterMinutes: 10, seed: 12345)
        let a = Resampler.generate(rows: rows, entityMap: map, vacationStart: start, vacationEnd: end, options: opts)
        let b = Resampler.generate(rows: rows, entityMap: map, vacationStart: start, vacationEnd: end, options: opts)
        XCTAssertEqual(a.map(\.time), b.map(\.time))
        XCTAssertEqual(a.map(\.entityId), b.map(\.entityId))
        XCTAssertEqual(a.map(\.action), b.map(\.action))
    }

    func testGenerateSortsEventsByTime() {
        let events = Resampler.generate(
            rows: sampleHistory(),
            entityMap: [:],
            vacationStart: day(2026, 3, 1), vacationEnd: day(2026, 3, 4),
            options: ResamplerOptions(seed: 99)
        )
        XCTAssertEqual(events.map(\.time), events.map(\.time).sorted())
    }

    func testGenerateNeverEmitsConsecutiveSameStatePerEntity() {
        let events = Resampler.generate(
            rows: sampleHistory(),
            entityMap: [:],
            vacationStart: day(2026, 3, 1), vacationEnd: day(2026, 3, 8),
            options: ResamplerOptions(seed: 3)
        )
        var last: [String: String] = [:]
        for e in events {
            XCTAssertNotEqual(last[e.entityId], e.action,
                              "\(e.entityId) got two consecutive \(e.action) events")
            last[e.entityId] = e.action
        }
    }

    func testGenerateLeavesEveryLightOffAtTheEnd() {
        let events = Resampler.generate(
            rows: sampleHistory(),
            entityMap: [:],
            vacationStart: day(2026, 3, 1), vacationEnd: day(2026, 3, 6),
            options: ResamplerOptions(seed: 55)
        )
        var state: [String: Int] = [:]
        for e in events { state[e.entityId] = e.action == "turn_on" ? 1 : 0 }
        XCTAssertTrue(state.values.allSatisfy { $0 == 0 }, "all lights should be off after the schedule ends")
    }

    func testGenerateMapsShortNamesToFullEntityIds() {
        let map = ["kitchen": "switch.kitchen", "living": "light.living"]
        let events = Resampler.generate(
            rows: sampleHistory(),
            entityMap: map,
            vacationStart: day(2026, 3, 1), vacationEnd: day(2026, 3, 3),
            options: ResamplerOptions(seed: 8)
        )
        XCTAssertFalse(events.isEmpty)
        for e in events {
            XCTAssertTrue(e.entityId == "switch.kitchen" || e.entityId == "light.living",
                          "unexpected entity id \(e.entityId)")
        }
    }

    func testGenerateHonorsJitterBounds() {
        // With zero jitter, replayed morning "kitchen on" events must land exactly
        // on the donor's 07:00 offset within each vacation day's first block.
        let events = Resampler.generate(
            rows: sampleHistory(),
            entityMap: [:],
            vacationStart: day(2026, 3, 1), vacationEnd: day(2026, 3, 2),
            options: ResamplerOptions(blocks: 2, jitterMinutes: 0, seed: 1)
        )
        let kitchenOn = events.first { $0.entityId == "kitchen" && $0.action == "turn_on" }
        let onHour = kitchenOn.map { Self.cal.component(.hour, from: $0.time) }
        XCTAssertEqual(onHour, 7)
    }

    // MARK: - encodeJSON

    func testEncodeJSONRoundTripsFields() throws {
        let events = [
            ScheduleEvent(time: date(2026, 3, 1, 7, 30), entityId: "switch.kitchen", action: "turn_on"),
            ScheduleEvent(time: date(2026, 3, 1, 23, 0), entityId: "switch.living", action: "turn_off"),
        ]
        let data = try Resampler.encodeJSON(events)
        let decoded = try JSONSerialization.jsonObject(with: data) as! [[String: String]]
        XCTAssertEqual(decoded.count, 2)
        XCTAssertEqual(decoded[0]["entity_id"], "switch.kitchen")
        XCTAssertEqual(decoded[0]["action"], "turn_on")
        XCTAssertTrue(decoded[0]["time"]!.hasPrefix("2026-03-01T07:30:00"))
    }
}

/// Tests for the headless `--resample` CLI's parsing helpers.
final class ResampleCLITests: XCTestCase {

    func testParseCSVSkipsHeaderAndUnquotesFields() {
        let csv = """
        time,entity_id,state.value
        "2026-01-01T08:00:00Z","kitchen","1"
        "2026-01-01T09:00:00Z","kitchen","0"

        """
        let rows = ResampleCLI.parseCSV(csv)
        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(rows[0].entity, "kitchen")
        XCTAssertEqual(rows[0].state, 1)
        XCTAssertEqual(rows[1].state, 0)
    }

    func testParseCSVSkipsMalformedRows() {
        let csv = """
        time,entity_id,state.value
        "2026-01-01T08:00:00Z","kitchen","1"
        garbage,row
        "bad-timestamp","kitchen","1"
        """
        let rows = ResampleCLI.parseCSV(csv)
        XCTAssertEqual(rows.count, 1)
    }

    func testParseUTCTimestampWithFraction() {
        let base = ResampleCLI.parseUTCTimestamp("2026-01-01T08:00:00Z")
        let frac = ResampleCLI.parseUTCTimestamp("2026-01-01T08:00:00.5Z")
        XCTAssertNotNil(base)
        XCTAssertNotNil(frac)
        XCTAssertEqual(frac!.timeIntervalSince(base!), 0.5, accuracy: 1e-6)
    }

    func testParseUTCTimestampRejectsNonZulu() {
        XCTAssertNil(ResampleCLI.parseUTCTimestamp("2026-01-01T08:00:00"))
        XCTAssertNil(ResampleCLI.parseUTCTimestamp("not a date"))
    }
}
