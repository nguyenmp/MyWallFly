// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "MyWallFly",
    platforms: [.macOS(.v14)],
    targets: [
        .target(name: "WallFlyCapture", path: "Sources/WallFlyCapture"),
        .executableTarget(
            name: "wallfly-capture-probe",
            dependencies: ["WallFlyCapture"],
            path: "Sources/wallfly-capture-probe"
        ),
    ]
)
