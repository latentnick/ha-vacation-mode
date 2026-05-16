import Foundation

struct HAEntity: Identifiable, Hashable {
    var id: String { entityId }
    let entityId: String
    let friendlyName: String
}

struct HAClient {
    let baseURL: URL
    let token: String

    func fetchEntities() async throws -> [HAEntity] {
        var req = URLRequest(url: baseURL.appendingPathComponent("api/states"))
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (data, resp) = try await URLSession.shared.data(for: req)
        try Self.checkOK(resp)
        struct State: Decodable {
            let entity_id: String
            let attributes: [String: AnyCodable]?
        }
        let states = try JSONDecoder().decode([State].self, from: data)
        return states.compactMap { s in
            let id = s.entity_id
            guard id.hasPrefix("light.") || id.hasPrefix("switch.") else { return nil }
            let name = (s.attributes?["friendly_name"]?.value as? String) ?? id
            return HAEntity(entityId: id, friendlyName: name)
        }.sorted { $0.entityId < $1.entityId }
    }

    private static func checkOK(_ resp: URLResponse) throws {
        guard let http = resp as? HTTPURLResponse else { return }
        guard (200..<300).contains(http.statusCode) else {
            throw NSError(domain: "HAClient", code: http.statusCode,
                          userInfo: [NSLocalizedDescriptionKey: "HA HTTP \(http.statusCode)"])
        }
    }
}

/// Minimal AnyCodable so we can decode HA's `attributes` blob without a full schema.
struct AnyCodable: Decodable {
    let value: Any
    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let v = try? c.decode(String.self) { value = v }
        else if let v = try? c.decode(Int.self) { value = v }
        else if let v = try? c.decode(Double.self) { value = v }
        else if let v = try? c.decode(Bool.self) { value = v }
        else if let v = try? c.decode([String: AnyCodable].self) { value = v }
        else if let v = try? c.decode([AnyCodable].self) { value = v }
        else { value = NSNull() }
    }
}
