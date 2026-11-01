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

    @MainActor
    static func runOnce(config: AppConfig, status: ScheduleStatus) async {
        guard !status.isRunning else { return }
        status.isRunning = true
        status.lastError = nil
        defer { status.isRunning = false }
        await generate(config: config, status: status)
    }

    private static func generate(config: AppConfig, status: ScheduleStatus) async {
        guard !config.entities.isEmpty else {
            await MainActor.run { status.lastError = "Select lights in Settings" }
            return
        }
        do {
            let since = Calendar.current.date(byAdding: .day, value: -config.schedule.historyDays, to: Date())!
            let rows: [RawStateRow]
            let entityMap: [String: String]
            let donorDates: [Date]?
            if config.usesLocalHistory {
                let training = try await MainActor.run {
                    try HistoryStore().training(entities: config.entities, since: since)
                }
                guard !training.days.isEmpty else {
                    throw LutronError("No complete local-history days yet. Import existing history in Settings or leave the app recording for a full day.")
                }
                rows = training.rows
                entityMap = Dictionary(uniqueKeysWithValues: config.entities.map { ($0, $0) })
                donorDates = training.days
            } else {
                let password = try KeychainStore.read(account: AppConfig.influxPasswordAccount) ?? ""
                let names = config.entities.map { $0.split(separator: ".", maxSplits: 1).last.map(String.init) ?? $0 }
                guard Set(names).count == names.count else { throw LutronError("Ambiguous history entity names") }
                entityMap = Dictionary(uniqueKeysWithValues: zip(names, config.entities))
                rows = try await InfluxClient(host: config.influx.host, port: config.influx.port,
                    user: config.influx.user, password: password, database: config.influx.database)
                    .fetchStateHistory(shortEntityNames: names, since: since)
                donorDates = nil
            }

            // Vacation window: today (Pacific midnight) .. today + N days.
            var cal = Calendar(identifier: .gregorian)
            cal.timeZone = Resampler.pacific
            let start = cal.startOfDay(for: Date())
            let end = cal.date(byAdding: .day, value: config.schedule.vacationDays, to: start)!

            let events = try Resampler.generate(
                rows: rows,
                entityMap: entityMap,
                vacationStart: start,
                vacationEnd: end,
                options: ResamplerOptions(
                    blocks: config.schedule.blocks,
                    jitterMinutes: config.schedule.jitterMinutes
                ),
                donorDates: donorDates
            )

            try FileManager.default.createDirectory(at: AppConfig.directoryURL, withIntermediateDirectories: true)
            let json = try Resampler.encodeJSON(events)
            try json.write(to: AppConfig.scheduleURL, options: .atomic)
            log.info("Wrote \(events.count, privacy: .public) events to \(AppConfig.scheduleURL.path, privacy: .public)")
            await MainActor.run { status.lastGenerated = Date() }
        } catch {
            log.error("Schedule generation failed: \(String(describing: error), privacy: .public)")
            await MainActor.run { status.lastError = error.localizedDescription }
        }
    }
}
