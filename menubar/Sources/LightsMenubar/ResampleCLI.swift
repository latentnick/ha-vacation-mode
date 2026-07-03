import Foundation

/// Headless generation entry point (`LightsMenubar --resample`): builds a schedule from
/// an exported state CSV without launching the UI. Useful for debugging and reproducing a
/// schedule from a fixed seed. Correctness of the underlying `Resampler` is covered by the
/// unit tests in `Tests/LightsMenubarTests`.
///
/// Usage: LightsMenubar --resample <start YYYY-MM-DD> <end YYYY-MM-DD> <data.csv> <entity_map.json> <out.json> [seed]
enum ResampleCLI {
    static func run(args: [String]) {
        guard args.count >= 7 else {
            FileHandle.standardError.write(Data("Usage: --resample <start> <end> <data.csv> <entity_map.json> <out.json> [seed]\n".utf8))
            exit(2)
        }
        let startStr = args[2]
        let endStr = args[3]
        let csvPath = args[4]
        let entityMapPath = args[5]
        let outPath = args[6]
        let seed = args.count >= 8 ? UInt64(args[7]) : nil

        do {
            let csv = try String(contentsOfFile: csvPath, encoding: .utf8)
            let rows = parseCSV(csv)
            let mapData = try Data(contentsOf: URL(fileURLWithPath: entityMapPath))
            let entityMap = try JSONDecoder().decode([String: String].self, from: mapData)

            var cal = Calendar(identifier: .gregorian)
            cal.timeZone = Resampler.pacific
            let dayFmt = DateFormatter()
            dayFmt.dateFormat = "yyyy-MM-dd"
            dayFmt.timeZone = Resampler.pacific
            guard let start = dayFmt.date(from: startStr).flatMap({ cal.startOfDay(for: $0) }),
                  let end = dayFmt.date(from: endStr).flatMap({ cal.startOfDay(for: $0) }) else {
                FileHandle.standardError.write(Data("Invalid dates\n".utf8))
                exit(2)
            }

            let events = Resampler.generate(
                rows: rows,
                entityMap: entityMap,
                vacationStart: start,
                vacationEnd: end,
                options: ResamplerOptions(blocks: 2, jitterMinutes: 10, seed: seed)
            )
            let json = try Resampler.encodeJSON(events)
            try json.write(to: URL(fileURLWithPath: outPath), options: .atomic)
            FileHandle.standardError.write(Data("Wrote \(events.count) events to \(outPath)\n".utf8))
        } catch {
            FileHandle.standardError.write(Data("Error: \(error)\n".utf8))
            exit(1)
        }
    }

    /// Parses the project's data.csv shape: quoted fields, columns time,entity_id,state.value, no commas inside fields.
    static func parseCSV(_ text: String) -> [RawStateRow] {
        var rows: [RawStateRow] = []
        var first = true
        let lines = text.components(separatedBy: .newlines)
        for rawLine in lines {
            if rawLine.isEmpty { continue }
            if first { first = false; continue }
            let fields = rawLine.components(separatedBy: ",").map { f -> String in
                var s = f.trimmingCharacters(in: .whitespacesAndNewlines)
                if s.hasPrefix("\"") && s.hasSuffix("\"") { s = String(s.dropFirst().dropLast()) }
                return s
            }
            guard fields.count >= 3 else { continue }
            guard let time = parseUTCTimestamp(fields[0]) else { continue }
            guard let state = Int(fields[2]) else { continue }
            rows.append(RawStateRow(time: time, entity: fields[1], state: state))
        }
        return rows
    }

    /// Parse "YYYY-MM-DDTHH:MM:SS[.ffffff...]Z" — supports any fractional precision.
    static func parseUTCTimestamp(_ s: String) -> Date? {
        var str = s
        guard str.hasSuffix("Z") else { return nil }
        str.removeLast()
        let parts = str.split(separator: ".", maxSplits: 1)
        let base = parts[0]
        let frac: Double = parts.count == 2 ? (Double("0.\(parts[1])") ?? 0) : 0
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        guard let d = f.date(from: String(base)) else { return nil }
        return d.addingTimeInterval(frac)
    }
}
