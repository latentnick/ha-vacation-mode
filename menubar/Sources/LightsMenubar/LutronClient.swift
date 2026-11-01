import Foundation
import Synchronization

/// Serializes launch/cancel so a cancellation before launch cannot start a command.
private final class LutronProcess: Sendable {
    let process: Process
    private let cancelled = Mutex(false)
    init(_ process: Process) { self.process = process }
    func launch() throws {
        try cancelled.withLock { value in
            guard !value else { throw CancellationError() }
            try process.run()
        }
    }
    func cancel() {
        cancelled.withLock { value in
            value = true
            if process.isRunning { process.terminate() }
        }
    }
}

struct LutronError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

struct LutronDevice: Decodable, Identifiable, Sendable {
    let zone: String
    let name: String
    var id: String { zone }
}

struct LutronIdentity: Codable, Sendable {
    let ca: String
    let cert: String
    let key: String
}

struct LutronClient: Sendable {
    let host: String
    let identity: LutronIdentity?
    // Explicit paths support development builds and hermetic subprocess tests.
    var runtime: URL? = nil
    var helperScript: URL? = nil

    static func saved(host: String) throws -> LutronClient {
        guard let value = try KeychainStore.read(account: AppConfig.lutronIdentityAccount) else {
            throw LutronError("Pair with your Lutron hub in Settings")
        }
        return LutronClient(host: host, identity: try JSONDecoder().decode(LutronIdentity.self, from: Data(value.utf8)))
    }

    func discover() async throws -> [LutronDevice] {
        struct Response: Decodable { let devices: [LutronDevice] }
        return try JSONDecoder().decode(Response.self, from: await run(command: "discover")).devices
    }

    func pair(progress: @escaping @Sendable (String) -> Void) async throws -> LutronIdentity {
        struct Response: Decodable { let identity: LutronIdentity }
        return try JSONDecoder().decode(Response.self, from: await run(command: "pair", progress: progress)).identity
    }

    func monitor(zones: [String], receive: @escaping @Sendable (Data) -> Void) async throws {
        _ = try await run(command: "monitor", zones: zones, receive: receive)
    }

    func set(zone: String, action: String) async throws {
        guard action == "turn_on" || action == "turn_off" else { throw LutronError("Unknown lighting action: \(action)") }
        struct Response: Decodable { let verified: Bool; let zone: String; let on: Bool }
        let data = try await run(command: "set", zone: zone, action: action == "turn_on" ? "on" : "off")
        let response = try JSONDecoder().decode(Response.self, from: data)
        guard response.verified, response.zone == zone, response.on == (action == "turn_on") else {
            throw LutronError("Lutron did not confirm the requested light state")
        }
    }

    private func run(command: String, zone: String? = nil, action: String? = nil,
                     progress: @escaping @Sendable (String) -> Void = { _ in },
                     zones: [String]? = nil, receive: @escaping @Sendable (Data) -> Void = { _ in }) async throws -> Data {
        struct Request: Encodable {
            let command: String; let host: String; let identity: LutronIdentity?
            let zone: String?; let action: String?
            let zones: [String]?
        }
        var input = try JSONEncoder().encode(Request(command: command, host: host, identity: command == "pair" ? nil : identity, zone: zone, action: action, zones: zones))
        input.append(10)
        let requestData = input
        let env = ProcessInfo.processInfo.environment
        let resources = Bundle.main.resourceURL
        let node = runtime ?? env["LIGHTS_NODE_BIN"].map { URL(fileURLWithPath: $0) }
            ?? resources?.appendingPathComponent("node/bin/node")
        let helper = helperScript ?? env["LIGHTS_LUTRON_DIR"].map { URL(fileURLWithPath: $0).appendingPathComponent("app-helper.js") }
            ?? resources?.appendingPathComponent("lutron/app-helper.js")
        guard let node, let helper, FileManager.default.isExecutableFile(atPath: node.path),
              FileManager.default.fileExists(atPath: helper.path) else {
            throw LutronError("Lutron helper is not bundled. Rebuild the app.")
        }
        // The helper enforces a 30s lifetime (120s for physical-button pairing).
        // Drain its merged pipe on a background task so the UI stays responsive.
        let process = Process()
        process.executableURL = node
        process.arguments = [helper.path]
        // Avoid injected Node options or module paths from the launching shell.
        process.environment = ["PATH": "/usr/bin:/bin", "HOME": NSHomeDirectory()]
        let stdin = Pipe()
        let output = Pipe()
        process.standardInput = stdin
        process.standardOutput = output
        process.standardError = output
        let operation = LutronProcess(process)
        let result = try await withTaskCancellationHandler {
            try await Task.detached {
                try operation.launch()
                defer {
                    try? stdin.fileHandleForWriting.close()
                    try? output.fileHandleForReading.close()
                }
                do {
                    try stdin.fileHandleForWriting.write(contentsOf: requestData)
                    if command != "monitor" { try stdin.fileHandleForWriting.close() }
                } catch {
                    process.terminate()
                    throw error
                }
                var data = Data()
                var pending = Data()
                while true {
                    let chunk = output.fileHandleForReading.availableData
                    if chunk.isEmpty { break }
                    pending.append(chunk)
                    guard pending.count + data.count <= 1_048_576 else {
                        process.terminate()
                        throw LutronError("Lutron helper response exceeded its limit")
                    }
                    while let newline = pending.firstIndex(of: 10) {
                        let line = Data(pending[..<newline])
                        pending.removeSubrange(...newline)
                        struct Progress: Decodable { let progress: String }
                        if command == "monitor", (try? JSONSerialization.jsonObject(with: line)) != nil {
                            receive(line)
                        } else if let event = try? JSONDecoder().decode(Progress.self, from: line) {
                            progress(event.progress)
                        } else {
                            data.append(line)
                            data.append(10)
                        }
                    }
                }
                data.append(pending)
                process.waitUntilExit()
                guard process.terminationStatus == 0 else {
                    // Pairing output can contain private keys. Never surface a
                    // partial JSON credential response in an error message.
                    let text = String(data: data.prefix(2048), encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "Lutron helper failed"
                    let message = command == "pair" && (text.contains("{") || text.contains("PRIVATE KEY")) ? "Pairing failed. Please try again." : text
                    throw LutronError(message)
                }
                return data
            }.value
        } onCancel: {
            operation.cancel()
        }
        try Task.checkCancellation()
        return result
    }
}
