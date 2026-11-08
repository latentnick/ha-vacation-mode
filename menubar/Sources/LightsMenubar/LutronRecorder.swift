import Foundation
import Combine

@MainActor
final class HistoryStatus: ObservableObject {
    static let shared = HistoryStatus()
    @Published var recording = false
    @Published var lastRecorded: Date?
    @Published var monitorError: String?
}

@MainActor
final class LutronRecorder {
    private var task: Task<Void, Never>?
    private var awaySubscription: AnyCancellable?
    private var learning = false
    private var coverage = LearningCoverage()
    private var generation = UUID()
    private var activeSession: String?
    private var store: HistoryStore?
    private let status = HistoryStatus.shared

    init(watcher: StateWatcher) {
        awaySubscription = watcher.$awayState.removeDuplicates().sink { [weak self] state in
            guard let self else { return }
            self.learning = state == .off
            self.coverage.reset()
        }
    }
    func stop() {
        generation = UUID()
        task?.cancel()
        task = nil
        coverage.reset()
        activeSession = nil
        status.recording = false
        status.monitorError = nil
    }
    func start(config: AppConfig) {
        stop()
        guard let settings = config.lutron, !config.entities.isEmpty else { return }
        let token = generation
        do {
            try settings.validate(entities: config.entities)
            store = try HistoryStore()
        } catch { status.monitorError = error.localizedDescription; return }
        let mapping = Dictionary(uniqueKeysWithValues: config.entities.map { (settings.zones[$0]!, $0) })
        task = Task { [weak self] in
            var failures = 0
            while !Task.isCancelled {
                guard let self, self.generation == token else { return }
                self.coverage.reset()
                let session = UUID().uuidString
                self.activeSession = session
                do {
                    try await LutronClient.saved(host: settings.host).monitor(zones: mapping.keys.sorted()) { [weak self] data in
                        Task { @MainActor [weak self] in
                            guard let self, self.generation == token, self.activeSession == session else { return }
                            self.consume(data, mapping: mapping, session: session)
                        }
                    }
                } catch {
                    if Task.isCancelled { return }
                    self.status.monitorError = error.localizedDescription
                }
                self.status.recording = false
                self.activeSession = nil
                self.coverage.reset()
                if self.status.lastRecorded.map({ Date().timeIntervalSince($0) < 60 }) == true { failures = 0 }
                failures = min(failures + 1, 5)
                do { try await Task.sleep(for: .seconds(min(30, 1 << failures))) }
                catch { return }
            }
        }
    }

    private struct Observation: Decodable {
        struct State: Decodable { let zone: String; let on: Bool }
        let kind: String
        let time: Double
        let zone: String?
        let on: Bool?
        let states: [State]?
    }
    private func consume(_ data: Data, mapping: [String: String], session: String) {
        do {
            guard let store else { return }
            let event = try JSONDecoder().decode(Observation.self, from: data)
            let time = Date(timeIntervalSince1970: event.time)
            guard abs(time.timeIntervalSinceNow) < 30 else { coverage.reset(); return }
            if event.kind == "state", let zone = event.zone, let entity = mapping[zone], let on = event.on {
                try store.record(.init(time: time, entity: entity, state: on ? 1 : 0))
            } else if event.kind == "sample", let states = event.states {
                guard Set(states.map(\.zone)) == Set(mapping.keys), states.count == mapping.count else {
                    throw LutronError("Incomplete Lutron state snapshot")
                }
                for state in states {
                    try store.record(.init(time: time, entity: mapping[state.zone]!, state: state.on ? 1 : 0))
                }
                if let interval = coverage.observe(at: time, learning: learning) {
                    try store.cover(entities: Array(mapping.values), from: interval.start, to: interval.end, session: session)
                }
                status.lastRecorded = time
                status.recording = true
                status.monitorError = nil
            }
        } catch {
            coverage.reset()
            status.recording = false
            status.monitorError = error.localizedDescription
        }
    }
}
