import Foundation

struct AppConfig: Codable, Equatable {
    struct Lutron: Codable, Equatable, Sendable {
        var host: String = "192.168.86.61"
        // Preserve schedule/history IDs; never infer a control target at execution.
        var zones: [String: String] = [:]

        func zone(for entity: String) throws -> String {
            guard let zone = zones[entity], zone.range(of: #"^/zone/[1-9][0-9]*$"#, options: .regularExpression) != nil else {
                throw LutronError("No Lutron zone mapped for \(entity)")
            }
            return zone
        }

        func validate(entities: [String]) throws {
            guard !host.isEmpty else { throw LutronError("Enter the Lutron hub address") }
            let targets = try entities.map { try zone(for: $0) }
            guard Set(targets).count == targets.count else { throw LutronError("Each light must map to a different Lutron zone") }
        }
    }
    struct HA: Codable, Equatable {
        var url: String = "http://homeassistant.local:8123"
    }
    struct Influx: Codable, Equatable {
        var host: String = "homeassistant.local"
        var port: Int = 8086
        var user: String = "homeassistant"
        var database: String = "homeassistant"
    }
    struct Schedule: Codable, Equatable {
        var vacationDays: Int = 10
        var blocks: Int = 2
        var jitterMinutes: Int = 10
        var historyDays: Int = 183
    }

    var ha: HA = HA()
    var lutron: Lutron? = nil
    var localHistory: Bool? = nil
    var usesLocalHistory: Bool { localHistory ?? (lutron != nil) }
    var influx: Influx = Influx()
    var entities: [String] = []
    var schedule: Schedule = Schedule()

    static let haTokenAccount = "ha_token"
    static let lutronIdentityAccount = "lutron_identity"
    static let influxPasswordAccount = "influx_password"

    var isComplete: Bool {
        if let lutron {
            return (usesLocalHistory || !influx.host.isEmpty) && !entities.isEmpty &&
                (try? lutron.validate(entities: entities)) != nil &&
                KeychainStore.get(account: Self.lutronIdentityAccount) != nil
        }
        return !ha.url.isEmpty && !influx.host.isEmpty && !entities.isEmpty &&
            KeychainStore.get(account: AppConfig.haTokenAccount) != nil
    }

    static var directoryURL: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return appSupport.appendingPathComponent("lights-menubar", isDirectory: true)
    }

    static var configURL: URL { directoryURL.appendingPathComponent("config.json") }
    static var scheduleURL: URL { directoryURL.appendingPathComponent("schedule_events.json") }

    static func load() -> AppConfig {
        guard let data = try? Data(contentsOf: configURL),
              let cfg = try? JSONDecoder().decode(AppConfig.self, from: data) else {
            return AppConfig()
        }
        return cfg
    }

    func save() throws {
        try FileManager.default.createDirectory(at: AppConfig.directoryURL, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(self)
        try data.write(to: AppConfig.configURL, options: .atomic)
    }
}
