import Foundation
import Combine
import os

struct ScheduledEvent: Decodable, Equatable {
    let time: Date
    let entity_id: String
    let action: String
}

@MainActor
final class ScheduleExecutor: ObservableObject {
    @Published var isActive: Bool = false
    @Published var nextEvent: ScheduledEvent? = nil
    @Published var lastError: String? = nil

    private let log = Logger(subsystem: "com.nicklee.lights-menubar", category: "ScheduleExecutor")
    private let configProvider: () -> AppConfig
    private var awaySub: AnyCancellable?

    private var events: [ScheduledEvent] = []
    private var pendingIndex: Int = 0
    private var timer: DispatchSourceTimer?
    private let timerQueue = DispatchQueue(label: "com.nicklee.lights-menubar.executor")

    private var fileSource: DispatchSourceFileSystemObject?
    private var dirSource: DispatchSourceFileSystemObject?

    private var lastAppliedState: [String: String] = [:]

    init(watcher: StateWatcher, configProvider: @escaping () -> AppConfig) {
        self.configProvider = configProvider
        awaySub = watcher.$awayState
            .removeDuplicates { $0 == $1 }
            .receive(on: RunLoop.main)
            .sink { [weak self] state in
                guard let self else { return }
                switch state {
                case .on:  self.activate()
                case .off, .unknown: self.deactivate()
                }
            }
    }

    deinit {
        timer?.cancel()
        fileSource?.cancel()
        dirSource?.cancel()
    }

    // MARK: - Activation

    private func activate() {
        log.info("Activating executor")
        isActive = true
        lastError = nil
        startWatchingScheduleFile()
        reloadAndApply(runCatchUp: true)
    }

    private func deactivate() {
        log.info("Deactivating executor")
        isActive = false
        nextEvent = nil
        timer?.cancel()
        timer = nil
        fileSource?.cancel()
        fileSource = nil
        dirSource?.cancel()
        dirSource = nil
        lastAppliedState = [:]
    }

    private func reloadAndApply(runCatchUp: Bool) {
        guard isActive else { return }
        do {
            events = try loadEvents()
        } catch {
            log.error("Failed to load schedule: \(String(describing: error), privacy: .public)")
            lastError = "Load failed: \(error)"
            events = []
            timer?.cancel(); timer = nil
            nextEvent = nil
            return
        }

        if runCatchUp {
            runCatchUpPass()
        }
        scheduleNextFutureEvent()
    }

    private func loadEvents() throws -> [ScheduledEvent] {
        let url = AppConfig.scheduleURL
        let data = try Data(contentsOf: url)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { dec in
            let c = try dec.singleValueContainer()
            let s = try c.decode(String.self)
            let iso = ISO8601DateFormatter()
            iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let d = iso.date(from: s) { return d }
            iso.formatOptions = [.withInternetDateTime]
            if let d = iso.date(from: s) { return d }
            throw DecodingError.dataCorruptedError(in: c, debugDescription: "Bad ISO date: \(s)")
        }
        var arr = try decoder.decode([ScheduledEvent].self, from: data)
        arr.sort { $0.time < $1.time }
        return arr
    }

    // MARK: - Catch-up

    private func runCatchUpPass() {
        let now = Date()
        var latestByEntity: [String: ScheduledEvent] = [:]
        for ev in events where ev.time <= now {
            latestByEntity[ev.entity_id] = ev
        }
        var newState: [String: String] = [:]
        var toFire: [ScheduledEvent] = []
        for (eid, ev) in latestByEntity {
            newState[eid] = ev.action
            if lastAppliedState[eid] != ev.action {
                toFire.append(ev)
            }
        }
        lastAppliedState = newState
        if toFire.isEmpty {
            log.info("Catch-up: no changes needed")
            return
        }
        log.info("Catch-up: firing \(toFire.count, privacy: .public) event(s)")
        for ev in toFire {
            fireAndForget(ev)
        }
    }

    // MARK: - Timer scheduling

    private func scheduleNextFutureEvent() {
        timer?.cancel(); timer = nil

        let now = Date()
        guard let idx = events.firstIndex(where: { $0.time > now }) else {
            log.info("No future events remaining")
            nextEvent = nil
            return
        }
        pendingIndex = idx
        let ev = events[idx]
        nextEvent = ev

        let delay = max(0, ev.time.timeIntervalSinceNow)
        log.info("Scheduling next event \(ev.action, privacy: .public) \(ev.entity_id, privacy: .public) in \(Int(delay), privacy: .public)s")

        let t = DispatchSource.makeTimerSource(queue: timerQueue)
        t.schedule(deadline: .now() + delay)
        t.setEventHandler { [weak self] in
            guard let self else { return }
            Task { @MainActor in
                guard self.isActive else { return }
                self.fireAndForget(ev)
                self.lastAppliedState[ev.entity_id] = ev.action
                self.scheduleNextFutureEvent()
            }
        }
        timer = t
        t.resume()
    }

    // MARK: - HA call

    private func fireAndForget(_ ev: ScheduledEvent) {
        let cfg = configProvider()
        guard let token = KeychainStore.get(account: AppConfig.haTokenAccount),
              let baseURL = URL(string: cfg.ha.url) else {
            log.error("Missing HA url/token; cannot fire event")
            lastError = "Missing HA url or token"
            return
        }
        let domain = ev.entity_id.split(separator: ".").first.map(String.init) ?? "switch"
        let url = baseURL.appendingPathComponent("api/services/\(domain)/\(ev.action)")
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: ["entity_id": ev.entity_id])
        req.timeoutInterval = 10

        let logger = log
        Task.detached {
            do {
                let (_, resp) = try await URLSession.shared.data(for: req)
                if let http = resp as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                    logger.error("HA HTTP \(http.statusCode, privacy: .public) for \(ev.action, privacy: .public) \(ev.entity_id, privacy: .public)")
                    await MainActor.run { [weak self] in
                        self?.lastError = "HA HTTP \(http.statusCode)"
                    }
                } else {
                    logger.info("Fired \(ev.action, privacy: .public) \(ev.entity_id, privacy: .public)")
                }
            } catch {
                logger.error("HA call failed: \(String(describing: error), privacy: .public)")
                await MainActor.run { [weak self] in
                    self?.lastError = "HA call failed: \(error.localizedDescription)"
                }
            }
        }
    }

    // MARK: - Schedule file watching

    private func startWatchingScheduleFile() {
        fileSource?.cancel(); fileSource = nil
        dirSource?.cancel(); dirSource = nil
        let url = AppConfig.scheduleURL
        if FileManager.default.fileExists(atPath: url.path) {
            startWatchingFile(url: url)
        } else {
            startWatchingDir(url: url)
        }
    }

    private func startWatchingFile(url: URL) {
        let fd = open(url.path, O_EVTONLY)
        guard fd >= 0 else { return }
        let src = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .rename, .delete],
            queue: .main
        )
        src.setEventHandler { [weak self, weak src] in
            guard let self, let src else { return }
            let evt = src.data
            self.reloadAndApply(runCatchUp: true)
            if evt.contains(.delete) || evt.contains(.rename) {
                src.cancel()
                self.fileSource = nil
                if FileManager.default.fileExists(atPath: url.path) {
                    self.startWatchingFile(url: url)
                } else {
                    self.startWatchingDir(url: url)
                }
            }
        }
        src.setCancelHandler { close(fd) }
        fileSource = src
        src.resume()
    }

    private func startWatchingDir(url: URL) {
        let dir = url.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let fd = open(dir.path, O_EVTONLY)
        guard fd >= 0 else { return }
        let src = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write],
            queue: .main
        )
        src.setEventHandler { [weak self, weak src] in
            guard let self, let src else { return }
            if FileManager.default.fileExists(atPath: url.path) {
                src.cancel()
                self.dirSource = nil
                self.reloadAndApply(runCatchUp: true)
                self.startWatchingFile(url: url)
            }
        }
        src.setCancelHandler { close(fd) }
        dirSource = src
        src.resume()
    }
}
