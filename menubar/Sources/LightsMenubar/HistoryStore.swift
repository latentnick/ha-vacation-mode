import Foundation
import SQLite3

/// Small WAL database shared by the main-actor recorder and migration/generation.
/// Coverage is explicit: absence of events is never evidence of uninterrupted recording.
@MainActor
final class HistoryStore {
    private var db: OpaquePointer?
    static var url: URL { AppConfig.directoryURL.appendingPathComponent("history.sqlite") }
    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    init(url: URL = HistoryStore.url) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard sqlite3_open(url.path, &db) == SQLITE_OK else {
            sqlite3_close(db); db = nil
            throw LutronError("Could not open local history database")
        }
        sqlite3_busy_timeout(db, 5000)
        do {
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            try execute("PRAGMA journal_mode=WAL")
            try execute("CREATE TABLE IF NOT EXISTS states (entity TEXT NOT NULL, time REAL NOT NULL, state INTEGER NOT NULL CHECK(state IN (0,1)), source TEXT NOT NULL, PRIMARY KEY(entity,time,source))")
            try execute("CREATE TABLE IF NOT EXISTS coverage (entity TEXT NOT NULL, start REAL NOT NULL, end REAL NOT NULL, session TEXT NOT NULL, PRIMARY KEY(entity,session,start))")
            try execute("CREATE TABLE IF NOT EXISTS metadata (key TEXT PRIMARY KEY, value REAL NOT NULL)")
        } catch { sqlite3_close(db); db = nil; throw error }
    }
    isolated deinit { sqlite3_close(db) }

    enum Value { case text(String), number(Double), integer(Int) }
    private func statement(_ sql: String, _ values: [Value]) throws -> OpaquePointer {
        var result: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &result, nil) == SQLITE_OK, let result else { throw failure() }
        for (offset, value) in values.enumerated() {
            let index = Int32(offset + 1)
            switch value {
            case .text(let text): sqlite3_bind_text(result, index, text, -1, Self.transient)
            case .number(let number): sqlite3_bind_double(result, index, number)
            case .integer(let integer): sqlite3_bind_int64(result, index, Int64(integer))
            }
        }
        return result
    }
    private func failure() -> Error { LutronError("Local history: \(String(cString: sqlite3_errmsg(db)))") }
    private func execute(_ sql: String, _ values: [Value] = []) throws {
        let query = try statement(sql, values)
        defer { sqlite3_finalize(query) }
        let result = sqlite3_step(query)
        guard result == SQLITE_DONE || result == SQLITE_ROW else { throw failure() }
    }
    private func number(_ sql: String, _ values: [Value] = []) throws -> Double? {
        let query = try statement(sql, values)
        defer { sqlite3_finalize(query) }
        let result = sqlite3_step(query)
        if result == SQLITE_DONE { return nil }
        guard result == SQLITE_ROW else { throw failure() }
        return sqlite3_column_double(query, 0)
    }
    private func transaction(_ work: () throws -> Void) throws {
        try execute("BEGIN IMMEDIATE")
        do { try work(); try execute("COMMIT") }
        catch { try? execute("ROLLBACK"); throw error }
    }
    func cutover(now: Date = Date()) throws -> Date {
        try execute("INSERT OR IGNORE INTO metadata VALUES ('cutover', ?)", [.number(now.timeIntervalSince1970)])
        return Date(timeIntervalSince1970: try number("SELECT value FROM metadata WHERE key='cutover'")!)
    }
    var imported: Bool { get throws { try number("SELECT value FROM metadata WHERE key='imported'") != nil } }

    func record(_ row: RawStateRow) throws {
        guard row.state == 0 || row.state == 1 else { throw LutronError("Invalid light state") }
        let previous = try number("SELECT state FROM states WHERE entity=? ORDER BY time DESC LIMIT 1", [.text(row.entity)])
        if previous == Double(row.state) { return }
        try execute("INSERT OR IGNORE INTO states VALUES (?,?,?,'lutron')", [.text(row.entity), .number(row.time.timeIntervalSince1970), .integer(row.state)])
    }

    func cover(entities: [String], from start: Date, to end: Date, session: String) throws {
        guard end > start, end.timeIntervalSince(start) <= 35 else { return }
        try transaction {
            for entity in entities {
                let values: [Value] = [.number(end.timeIntervalSince1970), .text(entity), .text(session), .number(start.timeIntervalSince1970)]
                try execute("UPDATE coverage SET end=? WHERE entity=? AND session=? AND end=?", values)
                if sqlite3_changes(db) == 0 {
                    try execute("INSERT INTO coverage VALUES (?,?,?,?)", [.text(entity), .number(start.timeIntervalSince1970), .number(end.timeIntervalSince1970), .text(session)])
                }
            }
        }
    }

    func importHistory(_ rows: [RawStateRow], entities: [String], until cutoff: Date) throws {
        let historical = rows.filter { $0.time < cutoff && entities.contains($0.entity) }
        guard !entities.isEmpty, entities.allSatisfy({ entity in historical.contains { $0.entity == entity } }) else {
            throw LutronError("Influx import is missing history for one or more selected lights; local history was not marked migrated")
        }
        try transaction {
            for row in historical {
                try execute("INSERT OR IGNORE INTO states VALUES (?,?,?,'influx')", [.text(row.entity), .number(row.time.timeIntervalSince1970), .integer(row.state)])
            }
            for entity in entities {
                let start = historical.filter { $0.entity == entity }.map(\.time).min()!
                try execute("INSERT INTO coverage VALUES (?,?,?,'influx') ON CONFLICT(entity,session,start) DO UPDATE SET end=MAX(end,excluded.end)", [.text(entity), .number(start.timeIntervalSince1970), .number(cutoff.timeIntervalSince1970)])
            }
            try execute("INSERT OR REPLACE INTO metadata VALUES ('imported', ?)", [.number(Date().timeIntervalSince1970)])
        }
    }

    struct Training: Sendable { let rows: [RawStateRow]; let days: [Date] }
    func training(entities: [String], since: Date, now: Date = Date()) throws -> Training {
        var rows: [RawStateRow] = []
        var intervals: [String: [(Double, Double)]] = [:]
        for entity in entities {
            let query = try statement("SELECT time,state FROM states WHERE entity=? AND time<=? ORDER BY time", [.text(entity), .number(now.timeIntervalSince1970)])
            var baseline: RawStateRow?
            while true {
                let status = sqlite3_step(query)
                if status == SQLITE_DONE { break }
                guard status == SQLITE_ROW else { sqlite3_finalize(query); throw failure() }
                let row = RawStateRow(time: Date(timeIntervalSince1970: sqlite3_column_double(query, 0)), entity: entity, state: Int(sqlite3_column_int(query, 1)))
                if row.time < since { baseline = row } else { rows.append(row) }
            }
            sqlite3_finalize(query)
            if let baseline { rows.append(baseline) }
            let coverage = try statement("SELECT start,end FROM coverage WHERE entity=? AND end>=? ORDER BY start", [.text(entity), .number(since.timeIntervalSince1970)])
            while true {
                let status = sqlite3_step(coverage)
                if status == SQLITE_DONE { break }
                guard status == SQLITE_ROW else { sqlite3_finalize(coverage); throw failure() }
                intervals[entity, default: []].append((sqlite3_column_double(coverage, 0), sqlite3_column_double(coverage, 1)))
            }
            sqlite3_finalize(coverage)
        }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = Resampler.pacific
        var day = calendar.startOfDay(for: since)
        if day < since { day = calendar.date(byAdding: .day, value: 1, to: day)! }
        var days: [Date] = []
        while let end = calendar.date(byAdding: .day, value: 1, to: day), end <= now {
            let covered = !entities.isEmpty && entities.allSatisfy { entity in
                var cursor = day.timeIntervalSince1970
                for (start, stop) in intervals[entity] ?? [] {
                    if stop <= cursor { continue }
                    if start > cursor { return false }
                    cursor = max(cursor, stop)
                    if cursor >= end.timeIntervalSince1970 { return true }
                }
                return false
            }
            if covered { days.append(day) }
            day = end
        }
        return Training(rows: rows.sorted { $0.time < $1.time }, days: days)
    }
}
