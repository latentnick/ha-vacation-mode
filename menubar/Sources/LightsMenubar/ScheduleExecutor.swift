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
    private let playback = SchedulePlayback()
    private var isStoppingLights = false
    private var reconcileTask: Task<Void, Never>?
    private var timer: DispatchSourceTimer?
    private let timerQueue = DispatchQueue(label: "com.nicklee.lights-menubar.executor")

    private var fileSource: DispatchSourceFileSystemObject?
    private var dirSource: DispatchSourceFileSystemObject?

    init(watcher: StateWatcher, configProvider: @escaping () -> AppConfig) {
        self.configProvider = configProvider
        awaySub = watcher.$awayState
            .removeDuplicates { $0 == $1 }
            .receive(on: RunLoop.main)
            .sink { [weak self] state in
                guard let self else { return }
                switch state {
                case .on:  self.activate()
                case .off: self.deactivate(turnOff: true)
                case .unknown: self.deactivate(turnOff: false)
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
        isStoppingLights = false
        lastError = nil
        startWatchingScheduleFile()
        reloadAndApply()
    }

    private func deactivate(turnOff: Bool) {
        let wasActive = isActive
        log.info("Deactivating executor")
        isActive = false
        nextEvent = nil
        timer?.cancel()
        timer = nil
        fileSource?.cancel()
        fileSource = nil
        dirSource?.cancel()
        dirSource = nil
        if turnOff && wasActive {
            isStoppingLights = true
            // Include scheduled entities in case configuration changed while armed.
            playback.disarm(entities: configProvider().entities + events.map(\.entity_id), at: Date())
            processDueEvents()
        } else if isStoppingLights {
            processDueEvents()
        } else {
            reconcileTask?.cancel()
            playback.reset()
        }
    }

    private func reloadAndApply() {
        guard isActive else { return }
        do {
            events = try loadEvents()
        } catch {
            log.error("Failed to load schedule: \(String(describing: error), privacy: .public)")
            lastError = "Load failed: \(error)"
            events = []
            playback.events = []
            reconcileTask?.cancel()
            playback.reset()
            timer?.cancel(); timer = nil
            nextEvent = nil
            return
        }

        playback.events = events
        timer?.cancel(); timer = nil
        nextEvent = nil
        lastError = nil
        processDueEvents()
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

    // MARK: - Reconciliation and timer scheduling

    private func processDueEvents() {
        guard (isActive || isStoppingLights), !playback.events.isEmpty, reconcileTask == nil else { return }
        reconcileTask = Task { [weak self] in
            guard let self else { return }
            let error = await self.playback.reconcile(now: Date.init) { event in
                try await self.send(event)
            }
            self.reconcileTask = nil
            guard self.isActive || self.isStoppingLights else { return }
            if Task.isCancelled {
                self.processDueEvents()
                return
            }
            self.lastError = error
            self.scheduleNextFutureEvent()
        }
    }

    private func scheduleNextFutureEvent() {
        timer?.cancel(); timer = nil
        let now = Date()
        nextEvent = isActive ? events.first { $0.time > now } : nil
        // Reconcile failed requests even if the schedule has no future events.
        let pending = playback.hasPending(at: now)
        if !pending { isStoppingLights = false }
        let retryAt = pending ? now.addingTimeInterval(5) : nil
        guard let deadline = [nextEvent?.time, retryAt].compactMap({ $0 }).min() else { return }
        let t = DispatchSource.makeTimerSource(queue: timerQueue)
        t.schedule(wallDeadline: .now() + max(0, deadline.timeIntervalSinceNow))
        t.setEventHandler { [weak self] in
            Task { @MainActor in self?.processDueEvents() }
        }
        timer = t
        t.resume()
    }

    // MARK: - HA call

    private func send(_ ev: ScheduledEvent) async throws {
        let cfg = configProvider()
        guard let token = KeychainStore.get(account: AppConfig.haTokenAccount),
              let baseURL = URL(string: cfg.ha.url) else {
            log.error("Missing HA url/token; cannot fire event")
            throw NSError(domain: "ScheduleExecutor", code: -1,
                          userInfo: [NSLocalizedDescriptionKey: "Missing HA url or token"])
        }
        let domain = ev.entity_id.split(separator: ".").first.map(String.init) ?? "switch"
        let url = baseURL.appendingPathComponent("api/services/\(domain)/\(ev.action)")
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: ["entity_id": ev.entity_id])
        req.timeoutInterval = 10

        let (_, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let code = (resp as? HTTPURLResponse)?.statusCode ?? -1
            throw NSError(domain: "ScheduleExecutor", code: code,
                          userInfo: [NSLocalizedDescriptionKey: "HA HTTP \(code)"])
        }
        log.info("Fired \(ev.action, privacy: .public) \(ev.entity_id, privacy: .public)")
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
            self.reloadAndApply()
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
                self.reloadAndApply()
                self.startWatchingFile(url: url)
            }
        }
        src.setCancelHandler { close(fd) }
        dirSource = src
        src.resume()
    }
}
