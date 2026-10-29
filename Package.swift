// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "NetPilot",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(name: "NetPilot", path: "Sources/NetPilot")
    ]
)
