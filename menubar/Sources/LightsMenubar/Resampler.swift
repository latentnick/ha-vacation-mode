import Foundation

struct RawStateRow {
    let time: Date
    let entity: String
    let state: Int
}

struct ScheduleEvent {
    let time: Date
    let entityId: String
    let action: String
}

struct ResamplerOptions {
    var blocks: Int = 2
    var jitterMinutes: Int = 10
    var seed: UInt64? = nil
}

struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { self.state = seed == 0 ? 0xdead_beef_cafe_babe : seed }
    mutating func next() -> UInt64 {
        // SplitMix64
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

enum Resampler {

    static let pacific = TimeZone(identifier: "America/Los_Angeles")!

    private static var pacificCalendar: Calendar {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = pacific
        return cal
    }

    /// Per-entity dedup of consecutive same-state rows. Input rows are sorted globally; we sort within entity.
    static func transitions(from rows: [RawStateRow]) -> (transitions: [RawStateRow], entities: [String]) {
        var byEntity: [String: [RawStateRow]] = [:]
        for r in rows {
            byEntity[r.entity, default: []].append(r)
        }
        var out: [RawStateRow] = []
        for (entity, entityRows) in byEntity {
            let sorted = entityRows.sorted { $0.time < $1.time }
            var prev: Int? = nil
            for r in sorted {
                if r.state != prev {
                    out.append(RawStateRow(time: r.time, entity: entity, state: r.state))
                    prev = r.state
                }
            }
        }
        out.sort { $0.time < $1.time }
        let entities = Array(byEntity.keys).sorted()
        return (out, entities)
    }

    /// Local-midnight (Pacific) days that have any transitions, dropping the first and last.
    static func candidateDates(transitions: [RawStateRow]) -> [Date] {
        let cal = pacificCalendar
        var seen = Set<Date>()
        var ordered: [Date] = []
        for t in transitions {
            let d = cal.startOfDay(for: t.time)
            if seen.insert(d).inserted { ordered.append(d) }
        }
        ordered.sort()
        if ordered.count <= 2 { return ordered }
        return Array(ordered[1..<(ordered.count - 1)])
    }

    private static func dayOfYear(_ d: Date) -> Int {
        pacificCalendar.ordinality(of: .day, in: .year, for: d) ?? 1
    }

    private static func weekday(_ d: Date) -> Int {
        // 1 = Sunday in Calendar; we just need stable equality across dates
        pacificCalendar.component(.weekday, from: d)
    }

    static func pickDonor<G: RandomNumberGenerator>(
        target: Date, candidates: [Date], rng: inout G
    ) -> Date {
        let targetDow = weekday(target)
        let sameDow = candidates.filter { weekday($0) == targetDow }
        let pool = sameDow.isEmpty ? candidates : sameDow
        let targetDoy = dayOfYear(target)
        let weights = pool.map { c -> Double in
            let d = abs(dayOfYear(c) - targetDoy)
            let circ = min(d, 365 - d)
            return 1.0 / Double(1 + circ)
        }
        let total = weights.reduce(0, +)
        let r = Double.random(in: 0..<total, using: &rng)
        var acc = 0.0
        for (i, w) in weights.enumerated() {
            acc += w
            if r < acc { return pool[i] }
        }
        return pool.last!
    }

    /// Blocks per 24h, equal width, in seconds. Returns n+1 offsets ending at 86400.
    static func blockOffsets(_ n: Int) -> [TimeInterval] {
        precondition(n >= 1)
        let widthMinutes = (24 * 60) / n
        var out: [TimeInterval] = []
        for i in 0..<n { out.append(TimeInterval(i * widthMinutes * 60)) }
        out.append(TimeInterval(24 * 60 * 60))
        return out
    }

    /// State of each entity immediately before time `t`, scanning the (already-sorted) transitions.
    static func stateAtTime(_ transitions: [RawStateRow], t: Date, entities: [String]) -> [String: Int] {
        var state: [String: Int] = [:]
        for e in entities { state[e] = 0 }
        for r in transitions {
            if r.time >= t { break }
            state[r.entity] = r.state
        }
        return state
    }

    static func replayBlock<G: RandomNumberGenerator>(
        targetStart: Date, targetEnd: Date,
        donorStart: Date, donorEnd: Date,
        transitions: [RawStateRow],
        entities: [String],
        sim: inout [String: Int],
        lastEmittedTime: inout [String: Date],
        jitterMinutes: Int,
        rng: inout G
    ) -> [ScheduleEvent] {
        var out: [ScheduleEvent] = []
        let donorState = stateAtTime(transitions, t: donorStart, entities: entities)
        // Alignment.
        for e in entities {
            let cur = sim[e] ?? 0
            let want = donorState[e] ?? 0
            if cur != want {
                let action = want == 1 ? "turn_on" : "turn_off"
                out.append(ScheduleEvent(time: targetStart, entityId: e, action: action))
                sim[e] = want
                lastEmittedTime[e] = targetStart
            }
        }
        // Replay donor events in [donorStart, donorEnd).
        let jitterSeconds = Double(jitterMinutes) * 60.0
        let blockEndMinusOne = targetEnd.addingTimeInterval(-1)
        for ev in transitions where ev.time >= donorStart && ev.time < donorEnd {
            let offset = ev.time.timeIntervalSince(donorStart)
            let j = Double.random(in: -jitterSeconds...jitterSeconds, using: &rng)
            var t = targetStart.addingTimeInterval(offset + j)
            if t < targetStart { t = targetStart }
            if t >= targetEnd { t = blockEndMinusOne }
            // Preserve per-entity event order: a brief ON/OFF pair must not
            // reorder under independent jitter (otherwise the post-sort dedup
            // would silently drop the OFF). Clamp to >= last emitted time.
            if let prev = lastEmittedTime[ev.entity], t <= prev {
                t = prev.addingTimeInterval(0.001)
            }
            let cur = sim[ev.entity] ?? 0
            if cur == ev.state { continue }
            sim[ev.entity] = ev.state
            lastEmittedTime[ev.entity] = t
            let action = ev.state == 1 ? "turn_on" : "turn_off"
            out.append(ScheduleEvent(time: t, entityId: ev.entity, action: action))
        }
        return out
    }

    /// Generate a vacation schedule. `vacationStart` and `vacationEnd` are local-midnight Pacific dates.
    /// `entityMap` maps short InfluxDB names to full HA entity IDs.
    static func generate(
        rows: [RawStateRow],
        entityMap: [String: String],
        vacationStart: Date,
        vacationEnd: Date,
        options: ResamplerOptions = .init()
    ) -> [ScheduleEvent] {
        let (trans, entities) = transitions(from: rows)
        let candidates = candidateDates(transitions: trans)
        precondition(!candidates.isEmpty, "no historical days available")
        precondition(vacationEnd > vacationStart)

        let cal = pacificCalendar
        var targetDates: [Date] = []
        var d = vacationStart
        while d < vacationEnd {
            targetDates.append(d)
            d = cal.date(byAdding: .day, value: 1, to: d)!
        }

        let offsets = blockOffsets(options.blocks)
        var sim: [String: Int] = [:]
        for e in entities { sim[e] = 0 }
        var lastEmittedTime: [String: Date] = [:]
        var raw: [ScheduleEvent] = []

        var rng = SeededGenerator(seed: options.seed ?? UInt64.random(in: 1...UInt64.max))

        for target in targetDates {
            for b in 0..<options.blocks {
                let donor = pickDonor(target: target, candidates: candidates, rng: &rng)
                let events = replayBlock(
                    targetStart: target.addingTimeInterval(offsets[b]),
                    targetEnd: target.addingTimeInterval(offsets[b + 1]),
                    donorStart: donor.addingTimeInterval(offsets[b]),
                    donorEnd: donor.addingTimeInterval(offsets[b + 1]),
                    transitions: trans,
                    entities: entities,
                    sim: &sim,
                    lastEmittedTime: &lastEmittedTime,
                    jitterMinutes: options.jitterMinutes,
                    rng: &rng
                )
                raw.append(contentsOf: events)
            }
        }

        // All lights off at end - 1s.
        let endMarker = vacationEnd.addingTimeInterval(-1)
        for e in entities where (sim[e] ?? 0) == 1 {
            raw.append(ScheduleEvent(time: endMarker, entityId: e, action: "turn_off"))
            sim[e] = 0
        }

        raw.sort { $0.time < $1.time }

        // Final dedup pass — jitter can reorder events.
        var finalState: [String: Int] = [:]
        for e in entities { finalState[e] = 0 }
        var deduped: [ScheduleEvent] = []
        for ev in raw {
            let new = ev.action == "turn_on" ? 1 : 0
            if (finalState[ev.entityId] ?? 0) == new { continue }
            finalState[ev.entityId] = new
            deduped.append(ev)
        }

        // Map short -> full HA ids.
        return deduped.map { ev in
            ScheduleEvent(time: ev.time, entityId: entityMap[ev.entityId] ?? ev.entityId, action: ev.action)
        }
    }

    static let isoFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSSXXX"
        f.timeZone = pacific
        return f
    }()

    static func encodeJSON(_ events: [ScheduleEvent]) throws -> Data {
        struct Out: Encodable {
            let time: String
            let entity_id: String
            let action: String
        }
        let arr = events.map { Out(time: isoFormatter.string(from: $0.time), entity_id: $0.entityId, action: $0.action) }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted]
        return try encoder.encode(arr)
    }
}

