import Foundation

/// Retry only transient transport failures, never authentication or server errors.
/// Intended for idempotent reads, not Home Assistant service calls.
enum NetworkRetry {
    static func run<Value: Sendable>(
        delays: [Duration] = [.seconds(1), .seconds(3), .seconds(7)],
        sleep: @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
        operation: () async throws -> Value
    ) async throws -> Value {
        var attempt = 0
        while true {
            try Task.checkCancellation()
            do {
                return try await operation()
            } catch {
                guard attempt < delays.count, isTransient(error) else { throw error }
                try await sleep(delays[attempt])
                attempt += 1
            }
        }
    }

    static func isTransient(_ error: Error) -> Bool {
        guard let error = error as? URLError else { return false }
        switch error.code {
        case .notConnectedToInternet, .networkConnectionLost, .timedOut,
             .cannotFindHost, .dnsLookupFailed, .cannotConnectToHost:
            return true
        default:
            return false
        }
    }
}
