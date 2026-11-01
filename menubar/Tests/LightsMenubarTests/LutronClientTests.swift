import XCTest
import Synchronization
@testable import LightsMenubar

@MainActor
final class LutronClientTests: XCTestCase {
    private func withClient(_ script: String, run: (LutronClient) async throws -> Void) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let helper = directory.appendingPathComponent("helper.sh")
        try script.write(to: helper, atomically: true, encoding: .utf8)
        let client = LutronClient(host: "example.invalid", identity: .init(ca: "test", cert: "test", key: "test"),
                                  runtime: URL(fileURLWithPath: "/bin/sh"), helperScript: helper)
        try await run(client)
    }

    func testDiscoveryDecodesHelperOutput() async throws {
        try await withClient("cat >/dev/null\nprintf '%s' '{\"devices\":[{\"zone\":\"/zone/2\",\"name\":\"Office\"}]}'") { client in
            let devices = try await client.discover()
            XCTAssertEqual(devices.map(\.zone), ["/zone/2"])
        }
    }

    func testOnlyMatchingVerifiedStateCountsAsSuccess() async throws {
        for (response, succeeds) in [
            (#"{"verified":true,"zone":"/zone/2","on":true}"#, true),
            (#"{"verified":true,"zone":"/zone/9","on":true}"#, false),
            (#"{"verified":false,"zone":"/zone/2","on":true}"#, false),
            (#"{"verified":true,"zone":"/zone/2","on":false}"#, false)
        ] {
            try await withClient("cat >/dev/null\nprintf '%s' '\(response)'") { client in
                do {
                    try await client.set(zone: "/zone/2", action: "turn_on")
                    XCTAssertTrue(succeeds)
                } catch { XCTAssertFalse(succeeds) }
            }
        }
    }

    func testHelperFailureSurfacesInsteadOfConfirmingCommand() async throws {
        try await withClient("cat >/dev/null\nprintf '%s' 'Certificate verification failed' >&2\nexit 1") { client in
            do {
                try await client.set(zone: "/zone/2", action: "turn_on")
                XCTFail("Expected helper failure")
            } catch { XCTAssertTrue(error.localizedDescription.contains("Certificate verification failed")) }
        }
    }

    func testPairingProgressIsSeparateFromCredentials() async throws {
        let script = """
        cat >/dev/null
        printf '%s\\n' '{"progress":"connecting"}' '{"progress":"press_button"}' '{"progress":"verifying"}' '{"identity":{"ca":"test-ca","cert":"test-cert","key":"private-test-key"}}'
        """
        try await withClient(script) { client in
            let stages = Mutex<[String]>([])
            let identity = try await client.pair { stage in stages.withLock { $0.append(stage) } }
            XCTAssertEqual(stages.withLock { $0 }, ["connecting", "press_button", "verifying"])
            XCTAssertEqual(identity.key, "private-test-key")
        }
    }

    func testPairingFailureDoesNotExposePartialCredentials() async throws {
        try await withClient("cat >/dev/null\nprintf '%s' '{\"identity\":{\"key\":\"private-test-key\"}}'\nexit 1") { client in
            do {
                _ = try await client.pair { _ in }
                XCTFail("Expected failure")
            } catch {
                XCTAssertFalse(error.localizedDescription.contains("private-test-key"))
                XCTAssertTrue(error.localizedDescription.contains("Pairing failed"))
            }
        }
    }

    func testCancellationStopsPairingHelper() async throws {
        try await withClient("cat >/dev/null\nexec /bin/sleep 20") { client in
            let task = Task { try await client.pair { _ in } }
            try await Task.sleep(for: .milliseconds(100))
            task.cancel()
            do {
                _ = try await task.value
                XCTFail("Cancelled pairing must not succeed")
            } catch { /* cancellation or terminated-helper failure */ }
        }
    }

    func testMonitorDeliversSnapshotBeforeHelperExits() async throws {
        try await withClient("read -r request\nprintf '%s\\n' '{\"kind\":\"sample\",\"states\":[]}'\nexec /bin/sleep 20") { client in
            let received = expectation(description: "Live snapshot")
            let task = Task {
                try await client.monitor(zones: ["/zone/2"]) { _ in received.fulfill() }
            }
            await fulfillment(of: [received], timeout: 2)
            task.cancel()
            _ = try? await task.value
        }
    }
}
