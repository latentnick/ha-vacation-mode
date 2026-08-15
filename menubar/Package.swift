// swift-tools-version:6.3
import PackageDescription

let package = Package(
    name: "LightsMenubar",
    platforms: [.macOS(.v26)],
    targets: [
        .executableTarget(name: "LightsMenubar"),
        .testTarget(name: "LightsMenubarTests", dependencies: ["LightsMenubar"]),
    ]
)
