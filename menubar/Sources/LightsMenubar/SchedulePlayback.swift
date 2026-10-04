import Foundation

/// Reconciles due states, including ties and delayed timers. Calls are serialized so
/// an older request cannot finish after a newer request for the same light.
@MainActor
final class SchedulePlayback {
    var events: [ScheduledEvent] = []
    private(set) var confirmed: [String: String] = [:]
    private var generation = 0

    func reset() {
        generation += 1
        confirmed = [:]
    }

    private func desired(at now: Date) -> [ScheduledEvent] {
        var latest: [String: ScheduledEvent] = [:]
        for event in events.sorted(by: { $0.time < $1.time }) where event.time <= now {
            latest[event.entity_id] = event
        }
        return latest.values.sorted { $0.entity_id < $1.entity_id }
    }

    func hasPending(at now: Date) -> Bool {
        desired(at: now).contains { confirmed[$0.entity_id] != $0.action }
    }

    func reconcile(now: () -> Date, send: (ScheduledEvent) async throws -> Void) async -> String? {
        let currentGeneration = generation
        var failed = Set<String>()
        var lastError: String?
        while !Task.isCancelled, generation == currentGeneration {
            guard let event = desired(at: now()).first(where: {
                !failed.contains($0.entity_id) && confirmed[$0.entity_id] != $0.action
            }) else { break }
            do {
                try await send(event)
                guard !Task.isCancelled, generation == currentGeneration else { break }
                confirmed[event.entity_id] = event.action
            } catch {
                guard !Task.isCancelled, generation == currentGeneration else { break }
                // A transport failure may occur after HA applied the request. Its
                // state is unknown, so even a later opposite action must be sent.
                confirmed.removeValue(forKey: event.entity_id)
                failed.insert(event.entity_id)
                lastError = error.localizedDescription
            }
        }
        return lastError
    }
}
