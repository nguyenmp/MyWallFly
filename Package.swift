// swift-tools-version: 5.9
import Foundation
import PackageDescription

// The swift-testing macros live in a plugin directory inside the toolchain.
// On a Command Line Tools only install, the compiler sometimes fails to load
// them through the plugin server and reports:
//
//     plugin for module 'TestingMacros' not found
//
// Pointing the compiler straight at the plugin directory avoids that. This
// happened on about a third of runs before the flag was added. The flag is
// skipped when the directory is missing, so a full Xcode install is unaffected.
let macroPluginDirectories = [
    "/Library/Developer/CommandLineTools/usr/lib/swift/host/plugins/testing",
    "/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/lib/swift/host/plugins/testing",
]

let macroPluginSettings: [SwiftSetting] = macroPluginDirectories
    .filter { FileManager.default.fileExists(atPath: $0) }
    .map { .unsafeFlags(["-plugin-path", $0]) }

let package = Package(
    name: "MyWallFly",
    platforms: [.macOS(.v14)],
    targets: [
        // Listens to the microphone and the system audio.
        .target(name: "WallFlyCapture", path: "Sources/WallFlyCapture"),
        // Talks to the transcription provider.
        .target(
            name: "WallFlyTranscribe",
            dependencies: ["WallFlyCapture"],
            path: "Sources/WallFlyTranscribe"
        ),
        // A live view of what capture hears.
        .executableTarget(
            name: "wallfly-capture-probe",
            dependencies: ["WallFlyCapture"],
            path: "Sources/wallfly-capture-probe"
        ),
        // Capture in, transcript out.
        .executableTarget(
            name: "wallfly-transcribe",
            dependencies: ["WallFlyCapture", "WallFlyTranscribe"],
            path: "Sources/wallfly-transcribe"
        ),
        .testTarget(
            name: "WallFlyTranscribeTests",
            dependencies: ["WallFlyTranscribe"],
            path: "Tests/WallFlyTranscribeTests",
            swiftSettings: macroPluginSettings
        ),
    ]
)
