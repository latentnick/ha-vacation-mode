import Foundation

struct LearningCoverage {
    private var previous: Date?
    mutating func reset() { previous = nil }
    mutating func observe(at time: Date, learning: Bool) -> DateInterval? {
        guard learning else { reset(); return nil }
        defer { previous = time }
        guard let previous else { return nil }
        let duration = time.timeIntervalSince(previous)
        guard duration > 0, duration <= 35 else { return nil }
        return DateInterval(start: previous, end: time)
    }
}
