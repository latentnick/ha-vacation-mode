import Foundation
import Combine
import os

@MainActor
final class ScheduleStatus: ObservableObject {
    @Published var lastGenerated: Date? = nil
    @Published var lastError: String? = nil
    @Published var isRunning: Bool = false

    init() {
        if let attrs = try? FileManager.default.attributesOfItem(atPath: AppConfig.scheduleURL.path),
           let m = attrs[.modificationDate] as? Date {
            lastGenerated = m
        }
    }
}

enum ScheduleGenerator {

    static let log = Logger(subsystem: "com.nicklee.lights-menubar", category: "ScheduleGenerator")

    static func runOnce(config: AppConfig, status: ScheduleStatus) async {
        await MainActor.run { status.isRunning = true; status.lastError = nil }
        defer { Task { @MainActor in status.isRunning = false } }

        guard !config.ha.url.isEmpty, !config.influx.host.isEmpty, !config.entities.isEmpty,
              let baseURL = URL(string: config.ha.url) else {
            await MainActor.run { status.lastError = "Configuration incomplete" }
            return
        }

        // Read credentials explicitly so a Keychain *access* failure (e.g. the
        // ACL no longer matches this build's signature) surfaces as a clear
        // error, rather than being mistaken for "not configured" or silently
        // turning into an empty password that 401s against InfluxDB.
        let token: String
        let influxPassword: String
        do {
            guard let t = try KeychainStore.read(account: AppConfig.haTokenAccount) else {
                await MainActor.run { status.lastError = "Configuration incomplete (no HA token saved)" }
                return
            }
            token = t
            // A missing Influx password is legitimate (some setups have none);
            // only a read *error* throws and is handled below.
            influxPassword = try KeychainStore.read(account: AppConfig.influxPasswordAccount) ?? ""
        } catch {
            log.error("Keychain read failed: \(String(describing: error), privacy: .public)")
            await MainActor.run {
                status.lastError = "Couldn't read credentials from Keychain (\(error)). If you just rebuilt the app, open Configure and re-save the password to re-authorize access."
            }
            return
        }

        do {
            // Map full HA entity ids -> short InfluxDB names.
            var entityMap: [String: String] = [:]
            var shortNames: [String] = []
            for full in config.entities {
                let short = full.split(separator: ".", maxSplits: 1).last.map(String.init) ?? full
                entityMap[short] = full
                shortNames.append(short)
            }

            let influx = InfluxClient(
                host: config.influx.host, port: config.influx.port,
                user: config.influx.user, password: influxPassword,
                database: config.influx.database
            )
            _ = baseURL // baseURL only used for HA service calls; not needed here
            _ = token

            let since = Calendar.current.date(byAdding: .day, value: -config.schedule.historyDays, to: Date())!
            log.info("Fetching InfluxDB history for \(shortNames.count, privacy: .public) entities since \(since, privacy: .public)")
            let rows = try await influx.fetchStateHistory(shortEntityNames: shortNames, since: since)
            log.info("Fetched \(rows.count, privacy: .public) raw rows")

            // Vacation window: today (Pacific midnight) .. today + N days.
            var cal = Calendar(identifier: .gregorian)
            cal.timeZone = Resampler.pacific
            let start = cal.startOfDay(for: Date())
            let end = cal.date(byAdding: .day, value: config.schedule.vacationDays, to: start)!

            let events = Resampler.generate(
                rows: rows,
                entityMap: entityMap,
                vacationStart: start,
                vacationEnd: end,
                options: ResamplerOptions(
                    blocks: config.schedule.blocks,
                    jitterMinutes: config.schedule.jitterMinutes
                )
            )

            try FileManager.default.createDirectory(at: AppConfig.directoryURL, withIntermediateDirectories: true)
            let json = try Resampler.encodeJSON(events)
            try json.write(to: AppConfig.scheduleURL, options: .atomic)
            log.info("Wrote \(events.count, privacy: .public) events to \(AppConfig.scheduleURL.path, privacy: .public)")
            await MainActor.run { status.lastGenerated = Date() }
        } catch {
            log.error("Schedule generation failed: \(String(describing: error), privacy: .public)")
            await MainActor.run { status.lastError = String(describing: error) }
        }
    }
}
