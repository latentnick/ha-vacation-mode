import Foundation
import Combine

enum AwayState { case unknown, off, on }

@MainActor
final class StateWatcher: ObservableObject {
    @Published var on: Bool = false
    @Published var lastUpdated: Date? = nil
    @Published var awayState: AwayState = .unknown

    private let stateURL: URL
    private var fileSource: DispatchSourceFileSystemObject?
    private var dirSource: DispatchSourceFileSystemObject?

    init() {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        self.stateURL = appSupport
            .appendingPathComponent("lights-virtual-switch", isDirectory: true)
            .appendingPathComponent("state.json")
        readNow()
        startWatching()
    }

    deinit {
        fileSource?.cancel()
        dirSource?.cancel()
    }

    private func readNow() {
        struct Payload: Decodable { let on: Bool; let updated: String }
        guard let data = try? Data(contentsOf: stateURL),
              let payload = try? JSONDecoder().decode(Payload.self, from: data) else {
            awayState = .unknown
            return
        }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        on = payload.on
        lastUpdated = formatter.date(from: payload.updated)
        awayState = payload.on ? .on : .off
    }

    private func startWatching() {
        if FileManager.default.fileExists(atPath: stateURL.path) {
            startWatchingFile()
        } else {
            startWatchingDir()
        }
    }

    private func startWatchingFile() {
        let fd = open(stateURL.path, O_EVTONLY)
        guard fd >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .rename, .delete],
            queue: .main
        )
        // The handler queue is `.main`, so the assumption always holds.
        source.setEventHandler { [weak self, weak source] in
            MainActor.assumeIsolated {
                guard let self, let source else { return }
                let event = source.data
                self.readNow()
                if event.contains(.delete) || event.contains(.rename) {
                    source.cancel()
                    self.fileSource = nil
                    if FileManager.default.fileExists(atPath: self.stateURL.path) {
                        self.startWatchingFile()
                    } else {
                        self.startWatchingDir()
                    }
                }
            }
        }
        source.setCancelHandler { close(fd) }
        fileSource = source
        source.resume()
    }

    private func startWatchingDir() {
        let dirURL = stateURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dirURL, withIntermediateDirectories: true)
        let fd = open(dirURL.path, O_EVTONLY)
        guard fd >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write],
            queue: .main
        )
        source.setEventHandler { [weak self, weak source] in
            MainActor.assumeIsolated {
                guard let self, let source else { return }
                if FileManager.default.fileExists(atPath: self.stateURL.path) {
                    source.cancel()
                    self.dirSource = nil
                    self.readNow()
                    self.startWatchingFile()
                }
            }
        }
        source.setCancelHandler { close(fd) }
        dirSource = source
        source.resume()
    }
}
