import Foundation
import WallFlyCapture

// A small command line check for the capture helper.
//
// It prints the numbers the rest of the app needs: where each track began on the
// shared clock, and how far each track's own clock has drifted. It can also drop
// the two tracks on disk as WAV files, so you can listen and check they line up.
//
//   swift run wallfly-capture-probe 20                both tracks, 20 seconds
//   swift run wallfly-capture-probe 20 mic-only       microphone only
//   swift run wallfly-capture-probe 20 --out          also write WAV files here
//   swift run wallfly-capture-probe 20 --out out      also write them to out/
//
// Each run names its files after the moment it started, so two runs never
// overwrite each other and the two tracks of one run sort together.
//
// Audio goes to disk as it arrives, so a long run stays out of memory.

let arguments = Array(CommandLine.arguments.dropFirst())
let runSeconds = arguments.first { Double($0) != nil }.flatMap(Double.init) ?? 20
let microphoneOnly = arguments.contains("mic-only")
// `--out` on its own writes here. `--out <directory>` writes there. No flag, no files.
let outDirectory = arguments.contains("--out") ? (value(after: "--out", in: arguments) ?? ".") : nil

func value(after flag: String, in arguments: [String]) -> String? {
    guard let index = arguments.firstIndex(of: flag), index + 1 < arguments.count else { return nil }
    // A following flag means this one took no value: `--out mic-only` is not a
    // folder named "mic-only". Neither is `--out 20`, so a number counts as no
    // value too. Runs always put the seconds first, so nothing is lost.
    let next = arguments[index + 1]
    return next.hasPrefix("-") || next == "mic-only" || Double(next) != nil ? nil : next
}

func secs(_ value: Double?) -> String {
    guard let value else { return "never" }
    return String(format: "%.3f", value)
}

func signed(_ value: Double) -> String {
    String(format: "%+.3f", value)
}

let configuration: CaptureConfiguration = microphoneOnly ? .microphoneOnly : .default
let recordedTracks: [AudioTrack] = microphoneOnly ? [.microphone] : AudioTrack.allCases

print("MyWallFly capture helper — running for \(secs(runSeconds)) s")
print("microphone: \(CapturePermissions.microphoneGranted ? "granted" : "not granted yet")")
if !microphoneOnly {
    print("screen recording: \(CapturePermissions.screenRecordingGranted ? "granted" : "not granted yet")")
}

// Open the files before capture starts. That way the paths are known up front,
// and each buffer can go straight to disk as it arrives.
var opened: [AudioTrack: WavWriter] = [:]
if let outDirectory {
    let directory = URL(fileURLWithPath: outDirectory, isDirectory: true)
    let stamp = RunStamp.now()
    print("")
    print("writing WAV files to \(directory.path)")
    do {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for track in recordedTracks {
            let url = directory.appendingPathComponent("wallfly-\(stamp)-\(track.rawValue).wav")
            opened[track] = try WavWriter(path: url.path)
            print("  \(track.rawValue): \(url.path)")
        }
    } catch {
        print("Could not open the WAV files: \(error)")
        exit(1)
    }
}
let writers = opened

/// Fills in every file's header and closes it. Returns anything that went wrong.
func closeWriters() -> [String] {
    var failures: [String] = []
    for track in recordedTracks {
        guard let writer = writers[track] else { continue }
        let size = String(format: "%.3f", writer.seconds)
        print("\(writer.path) — \(size) s")
        if let failure = writer.close() {
            failures.append("\(track.rawValue): \(failure)")
        }
    }
    return failures
}

let capture: AudioCapture
do {
    capture = try AudioCapture(configuration: configuration)
} catch {
    print("Could not set up capture: \(error.localizedDescription)")
    exit(1)
}

if ProcessInfo.processInfo.environment["WALLFLY_DEBUG"] != nil {
    capture.debugLog = { print("format: \($0)") }
}

let reader = Task {
    for await frame in capture.frames {
        writers[frame.track]?.append(frame.pcm)
    }
}

let setupBegan = Date()
let start: CaptureStart
do {
    start = try await capture.start()
} catch {
    print("Capture did not start: \(error.localizedDescription)")
    for trackStats in capture.stats().tracks {
        if let reason = trackStats.lastError {
            print("  \(trackStats.track.rawValue) dropped \(trackStats.dropped) buffers: \(reason)")
        }
    }
    reader.cancel()
    exit(1)
}

print("")
print("tracks open after \(String(format: "%.1f", Date().timeIntervalSince(setupBegan))) s")
print("--- where each track began ---")
for trackStart in start.starts {
    print("\(trackStart.track.rawValue): host \(secs(trackStart.hostTime)) s, offset \(signed(trackStart.offset)) s")
}
print("Use the offset to line the two tracks up on one clock.")

if microphoneOnly {
    print("Mic-only run. Talk, so the microphone sees audio.")
} else {
    print("Both tracks are open. Talk, and play something out loud, so both tracks see audio.")
}

try? await Task.sleep(nanoseconds: UInt64(runSeconds * 1_000_000_000))

await capture.stop()
await reader.value

print("")
print("--- result ---")
let stats = capture.stats()
for trackStats in stats.tracks {
    print("\(trackStats.track.rawValue): \(trackStats.frames) frames, \(secs(trackStats.seconds)) s of audio, drift \(signed(trackStats.drift)) s, dropped \(trackStats.dropped)")
}
print("video frames captured and thrown away: \(stats.discardedVideoFrames)")

if !writers.isEmpty {
    print("")
    print("--- files ---")
    for failure in closeWriters() {
        print("could not finish \(failure)")
    }
}
