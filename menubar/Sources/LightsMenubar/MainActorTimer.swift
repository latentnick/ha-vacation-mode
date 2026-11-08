import Foundation

/// Dispatch invokes its handler on the source queue before any nested Task runs.
/// Main-actor callbacks must therefore use the main queue at that boundary.
@MainActor
enum MainActorTimer {
    static func schedule(at date: Date, handler: @escaping @MainActor @Sendable () -> Void) -> DispatchSourceTimer {
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(wallDeadline: .now() + max(0, date.timeIntervalSinceNow))
        timer.setEventHandler {
            MainActor.assumeIsolated { handler() }
        }
        timer.resume()
        return timer
    }
}
