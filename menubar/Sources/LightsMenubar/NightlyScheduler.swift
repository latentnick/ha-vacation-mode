import Foundation
import os

@MainActor
final class NightlyScheduler {
    private var timer: DispatchSourceTimer?
    private let log = Logger(subsystem: "com.nicklee.lights-menubar", category: "NightlyScheduler")
    private let configProvider: () -> AppConfig
    private let status: ScheduleStatus
    private let hour: Int

    init(configProvider: @escaping () -> AppConfig, status: ScheduleStatus, hour: Int = 4) {
        self.configProvider = configProvider
        self.status = status
        self.hour = hour
    }

    func start() {
        scheduleNext()
    }

    func stop() {
        timer?.cancel()
        timer = nil
    }

    private func scheduleNext() {
        let next = nextFire(after: Date())
        let delay = next.timeIntervalSinceNow
        log.info("Next schedule generation at \(next, privacy: .public) (in \(Int(delay), privacy: .public)s)")
        let t = MainActorTimer.schedule(at: next) { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                await ScheduleGenerator.runOnce(config: self.configProvider(), status: self.status)
                self.scheduleNext()
            }
        }
        timer?.cancel()
        timer = t
    }

    private func nextFire(after now: Date) -> Date {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = Resampler.pacific
        var comps = cal.dateComponents([.year, .month, .day], from: now)
        comps.hour = hour
        comps.minute = 0
        comps.second = 0
        var fire = cal.date(from: comps)!
        if fire <= now {
            fire = cal.date(byAdding: .day, value: 1, to: fire)!
        }
        return fire
    }
}
