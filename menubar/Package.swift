// swift-tools-version:6.3
import PackageDescription

// Note: tools-version 6.x defaults targets to the Swift 6 language mode, whose
// strict concurrency checking currently flags pre-existing data races in
// StateWatcher, NightlyScheduler, KeychainStore, and InfluxClient. Pin the
// language mode to v5 so this stays a build-settings change; migrating to
// Swift 6 concurrency is separate work.
let swift5Mode: [SwiftSetting] = [.swiftLanguageMode(.v5)]

let package = Package(
    name: "LightsMenubar",
    platforms: [.macOS(.v26)],
    targets: [
        .executableTarget(name: "LightsMenubar", swiftSettings: swift5Mode),
        .testTarget(
            name: "LightsMenubarTests",
            dependencies: ["LightsMenubar"],
            swiftSettings: swift5Mode
        ),
    ]
)
