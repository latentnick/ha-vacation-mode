import XCTest
@testable import LightsMenubar

final class NetworkRetryTests: XCTestCase {
    func testStartupOfflineErrorRecovers() async throws {
        var attempts = 0
        let result = try await NetworkRetry.run(sleep: { _ in }) {
            attempts += 1
            if attempts < 3 { throw URLError(.notConnectedToInternet) }
            return "history"
        }
        XCTAssertEqual(result, "history")
        XCTAssertEqual(attempts, 3)
    }

    func testPersistentFailureStopsAfterFourAttempts() async {
        var attempts = 0
        do {
            let _: Int = try await NetworkRetry.run(sleep: { _ in }) {
                attempts += 1
                throw URLError(.cannotFindHost)
            }
            XCTFail("Expected transport error")
        } catch {
            XCTAssertEqual((error as? URLError)?.code, .cannotFindHost)
        }
        XCTAssertEqual(attempts, 4)
    }

    func testAuthenticationFailureIsNotRetried() async {
        var attempts = 0
        do {
            let _: Int = try await NetworkRetry.run(sleep: { _ in }) {
                attempts += 1
                throw NSError(domain: "InfluxClient", code: 401)
            }
            XCTFail("Expected authentication error")
        } catch {
            XCTAssertEqual((error as NSError).code, 401)
        }
        XCTAssertEqual(attempts, 1)
    }

    func testCancellationDuringBackoffStopsRetries() async {
        var attempts = 0
        do {
            let _: Int = try await NetworkRetry.run(sleep: { _ in throw CancellationError() }) {
                attempts += 1
                throw URLError(.networkConnectionLost)
            }
            XCTFail("Expected cancellation")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
        XCTAssertEqual(attempts, 1)
    }
}
