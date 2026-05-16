import Foundation
import os

final class NightlyScheduler {
    private var timer: DispatchSourceTimer?
    private let queue = DispatchQueue(label: "com.nicklee.lights-menubar.nightly")
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
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + delay)
        t.setEventHandler { [weak self] in
            guard let self else { return }
            Task {
                await ScheduleGenerator.runOnce(config: self.configProvider(), status: self.status)
                self.scheduleNext()
            }
        }
        timer?.cancel()
        timer = t
        t.resume()
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
