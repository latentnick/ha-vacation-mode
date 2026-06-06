import Foundation
import Combine
import os

/// Supervises the bundled Node.js virtual-HomeKit-switch daemon (`switch/index.js`,
/// using `hap-nodejs`). The daemon publishes a HAP accessory and writes its on/off
/// state to `~/Library/Application Support/lights-virtual-switch/state.json`, which
/// `StateWatcher` consumes. This class just keeps that process alive for the lifetime
/// of the menubar app.
@MainActor
final class SwitchDaemon: ObservableObject {
    enum DaemonState: Equatable {
        case stopped
        case running
        case notConfigured(String)
        case failed(String)
    }

    @Published private(set) var state: DaemonState = .stopped
    /// Pairing PIN read from credentials.json, shown until the switch is paired.
    @Published private(set) var pin: String? = nil

    private let log = Logger(subsystem: "com.nicklee.lights-menubar", category: "SwitchDaemon")

    private var process: Process?
    private var logHandle: FileHandle?
    /// True while we are intentionally stopping, so the termination handler does not restart.
    private var stopping = false

    /// Consecutive rapid failures, used for capped backoff.
    private var failureCount = 0
    private let backoffSchedule: [TimeInterval] = [1, 2, 5, 30]
    private let maxFailures = 6
    private var lastLaunch: Date?

    // MARK: - Paths

    private static var appSupportDir: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("lights-virtual-switch", isDirectory: true)
    }

    private static var credentialsURL: URL {
        appSupportDir
            .appendingPathComponent("data", isDirectory: true)
            .appendingPathComponent("credentials.json")
    }

    /// Separate from index.js's own `switch.log`: this captures the node process's
    /// raw stdout/stderr (e.g. uncaught-exception stack traces) as a crash safety
    /// net, without duplicating the lines index.js already writes itself.
    private static var logURL: URL {
        FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first!
            .appendingPathComponent("Logs", isDirectory: true)
            .appendingPathComponent("lights-virtual-switch", isDirectory: true)
            .appendingPathComponent("daemon.out.log")
    }

    /// Resolves the `node` binary and the `index.js` script, honoring dev env overrides
    /// first, then falling back to resources bundled inside the .app.
    private struct ResolvedPaths {
        let node: URL
        let script: URL
        let workingDir: URL
    }

    private func resolvePaths() -> ResolvedPaths? {
        let env = ProcessInfo.processInfo.environment

        // 1. Dev overrides.
        if let nodePath = env["LIGHTS_NODE_BIN"], let switchDir = env["LIGHTS_SWITCH_DIR"] {
            let dir = URL(fileURLWithPath: switchDir, isDirectory: true)
            return ResolvedPaths(
                node: URL(fileURLWithPath: nodePath),
                script: dir.appendingPathComponent("index.js"),
                workingDir: dir
            )
        }

        // 2. Bundled resources: Contents/Resources/{node/bin/node, switch/index.js}.
        guard let resources = Bundle.main.resourceURL else { return nil }
        let node = resources.appendingPathComponent("node/bin/node")
        let switchDir = resources.appendingPathComponent("switch", isDirectory: true)
        let script = switchDir.appendingPathComponent("index.js")
        let fm = FileManager.default
        if fm.isExecutableFile(atPath: node.path), fm.fileExists(atPath: script.path) {
            return ResolvedPaths(node: node, script: script, workingDir: switchDir)
        }
        return nil
    }

    // MARK: - Lifecycle

    func start() {
        guard process == nil else { return }
        stopping = false
        loadPin()

        guard let paths = resolvePaths() else {
            state = .notConfigured("Daemon resources not bundled (dev build)")
            log.error("Could not resolve bundled node/switch resources")
            return
        }

        // The daemon self-bootstraps credentials.json on first run, so we launch
        // unconditionally; on a fresh setup the pincode appears once it's written.
        launch(paths)
    }

    private func launch(_ paths: ResolvedPaths) {
        let proc = Process()
        proc.executableURL = paths.node
        proc.arguments = [paths.script.path]
        proc.currentDirectoryURL = paths.workingDir

        // Capture stdout/stderr as a safety net for crashes before index.js opens its log.
        if let handle = openLogHandle() {
            proc.standardOutput = handle
            proc.standardError = handle
            logHandle = handle
        }

        proc.terminationHandler = { [weak self] p in
            // Hop to the main actor; the termination handler runs on an arbitrary queue.
            Task { @MainActor [weak self] in
                self?.handleTermination(status: p.terminationStatus)
            }
        }

        do {
            try proc.run()
            process = proc
            lastLaunch = Date()
            state = .running
            log.info("Started switch daemon (pid \(proc.processIdentifier, privacy: .public))")
            if pin == nil { schedulePinReload() }
        } catch {
            process = nil
            state = .failed("Launch failed: \(error.localizedDescription)")
            log.error("Failed to launch daemon: \(String(describing: error), privacy: .public)")
        }
    }

    private func handleTermination(status: Int32) {
        process = nil
        try? logHandle?.close()
        logHandle = nil

        if stopping {
            state = .stopped
            return
        }

        // Treat a quick exit as a failure for backoff purposes.
        let ranBriefly = (lastLaunch.map { Date().timeIntervalSince($0) < 5 } ?? true)
        failureCount = ranBriefly ? failureCount + 1 : 1

        log.error("Daemon exited (status \(status, privacy: .public)), failure #\(self.failureCount, privacy: .public)")

        guard failureCount < maxFailures else {
            state = .failed("Daemon keeps exiting (status \(status)). Stopped retrying.")
            log.error("Giving up after \(self.maxFailures, privacy: .public) failures")
            return
        }

        let delay = backoffSchedule[min(failureCount - 1, backoffSchedule.count - 1)]
        state = .failed("Restarting in \(Int(delay))s…")
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard let self, !self.stopping, self.process == nil else { return }
            self.start()
        }
    }

    /// Stops the daemon. Sends SIGINT (index.js handles it) and waits briefly.
    func stop() {
        stopping = true
        guard let proc = process, proc.isRunning else {
            state = .stopped
            return
        }
        log.info("Stopping switch daemon")
        proc.interrupt() // SIGINT
        // Give it a moment to shut down cleanly, then force-kill if needed.
        let deadline = Date().addingTimeInterval(2)
        while proc.isRunning, Date() < deadline {
            usleep(50_000)
        }
        if proc.isRunning {
            proc.terminate() // SIGTERM
        }
    }

    /// Manual restart from the menu.
    func restart() {
        failureCount = 0
        if process != nil {
            stop()
        }
        stopping = false
        start()
    }

    // MARK: - Helpers

    private func openLogHandle() -> FileHandle? {
        let url = Self.logURL
        let fm = FileManager.default
        try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !fm.fileExists(atPath: url.path) {
            fm.createFile(atPath: url.path, contents: nil)
        }
        guard let handle = try? FileHandle(forWritingTo: url) else { return nil }
        handle.seekToEndOfFile()
        return handle
    }

    /// On first run the daemon writes credentials.json a moment after launch.
    /// Poll a few times so the generated pincode appears in the UI without a restart.
    private func schedulePinReload(attempt: Int = 0) {
        guard attempt < 6 else { return }
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            guard let self, self.pin == nil else { return }
            self.loadPin()
            if self.pin == nil { self.schedulePinReload(attempt: attempt + 1) }
        }
    }

    private func loadPin() {
        struct Credentials: Decodable { let pincode: String? }
        guard let data = try? Data(contentsOf: Self.credentialsURL),
              let creds = try? JSONDecoder().decode(Credentials.self, from: data) else {
            pin = nil
            return
        }
        pin = creds.pincode
    }
}
