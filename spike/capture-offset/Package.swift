// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "capture-offset",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "capture-offset", path: "Sources/capture-offset")
    ]
)
