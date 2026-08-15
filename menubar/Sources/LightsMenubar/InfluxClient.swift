import Foundation

struct InfluxClient {
    let host: String
    let port: Int
    let user: String
    let password: String
    let database: String

    /// Fetch state-history rows from InfluxDB v1.8 for the given short entity names since `since` (UTC).
    /// Mirrors fetch_ha_data.py: one query per entity, filter to "on"/"off", convert to RawStateRow.
    func fetchStateHistory(shortEntityNames: [String], since: Date) async throws -> [RawStateRow] {
        let rfc3339 = ISO8601DateFormatter()
        rfc3339.formatOptions = [.withInternetDateTime]
        let rfc = rfc3339.string(from: since)
        var all: [RawStateRow] = []
        for name in shortEntityNames {
            let escaped = name.replacingOccurrences(of: "'", with: "\\'")
            let query = """
            SELECT time, entity_id, state FROM "state" \
            WHERE entity_id = '\(escaped)' AND time >= '\(rfc)' ORDER BY time ASC
            """
            let rows = try await runQuery(query)
            for row in rows {
                guard row.count >= 3,
                      let timeNs = row[0] as? NSNumber,
                      let stateStr = row[2] as? String else { continue }
                let state: Int
                if stateStr == "on" { state = 1 }
                else if stateStr == "off" { state = 0 }
                else { continue }
                let secs = timeNs.doubleValue / 1_000_000_000.0
                let time = Date(timeIntervalSince1970: secs)
                all.append(RawStateRow(time: time, entity: name, state: state))
            }
        }
        all.sort { $0.time < $1.time }
        return all
    }

    private func runQuery(_ q: String) async throws -> [[Any]] {
        var comps = URLComponents()
        comps.scheme = "http"
        comps.host = host
        comps.port = port
        comps.path = "/query"
        comps.queryItems = [
            URLQueryItem(name: "db", value: database),
            URLQueryItem(name: "q", value: q),
            URLQueryItem(name: "epoch", value: "ns"),
        ]
        guard let url = comps.url else { throw NSError(domain: "InfluxClient", code: -1) }
        var req = URLRequest(url: url)
        let creds = "\(user):\(password)".data(using: .utf8)!.base64EncodedString()
        req.setValue("Basic \(creds)", forHTTPHeaderField: "Authorization")
        let (data, resp) = try await URLSession.shared.data(for: req)
        if let http = resp as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw NSError(domain: "InfluxClient", code: http.statusCode,
                          userInfo: [NSLocalizedDescriptionKey: "Influx HTTP \(http.statusCode): \(body)"])
        }
        // Response shape: { results: [ { series: [ { columns:[...], values:[[...], ...] } ] } ] }
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let results = obj["results"] as? [[String: Any]] else { return [] }
        var rows: [[Any]] = []
        for result in results {
            guard let series = result["series"] as? [[String: Any]] else { continue }
            for s in series {
                if let values = s["values"] as? [[Any]] {
                    rows.append(contentsOf: values)
                }
            }
        }
        return rows
    }
}
