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

let arguments = Array(CommandLine.arguments.dropFirst())
let runSeconds = arguments.first { Double($0) != nil }.flatMap(Double.init) ?? 20
let microphoneOnly = arguments.contains("mic-only")
// `--out` on its own writes here. `--out <directory>` writes there. No flag, no files.
let outDirectory = arguments.contains("--out") ? (value(after: "--out", in: arguments) ?? ".") : nil
// Read the time once, so both tracks carry the same stamp.
let stamp = runStamp()

func value(after flag: String, in arguments: [String]) -> String? {
    guard let index = arguments.firstIndex(of: flag), index + 1 < arguments.count else { return nil }
    // A following flag means this one took no value: `--out mic-only` is not a
    // folder named "mic-only". Neither is `--out 20`, so a number counts as no
    // value too. Runs always put the seconds first, so nothing is lost.
    let next = arguments[index + 1]
    return next.hasPrefix("-") || next == "mic-only" || Double(next) != nil ? nil : next
}

/// The moment this run started, as ISO 8601 in UTC, with dashes in place of the
/// colons. Finder shows a colon in a file name as a slash, so keep it out.
func runStamp(_ date: Date = Date()) -> String {
    let formatter = ISO8601DateFormatter()
    formatter.timeZone = TimeZone(secondsFromGMT: 0)
    formatter.formatOptions = [.withInternetDateTime]
    return formatter.string(from: date).replacingOccurrences(of: ":", with: "-")
}

func secs(_ value: Double?) -> String {
    guard let value else { return "never" }
    return String(format: "%.3f", value)
}

func signed(_ value: Double) -> String {
    String(format: "%+.3f", value)
}

let configuration: CaptureConfiguration = microphoneOnly ? .microphoneOnly : .default

print("MyWallFly capture helper — running for \(secs(runSeconds)) s")
print("microphone: \(CapturePermissions.microphoneGranted ? "granted" : "not granted yet")")
if !microphoneOnly {
    print("screen recording: \(CapturePermissions.screenRecordingGranted ? "granted" : "not granted yet")")
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

// Collect the frames, so we can count them and write them out afterwards.
actor Collector {
    private var audio: [AudioTrack: Data] = [:]
    private var frames: [AudioTrack: Int] = [:]

    func add(_ frame: AudioFrame) {
        audio[frame.track, default: Data()].append(frame.pcm)
        frames[frame.track, default: 0] += 1
    }

    func summary() -> (frames: [AudioTrack: Int], audio: [AudioTrack: Data]) {
        (frames, audio)
    }
}

let collector = Collector()
let reader = Task {
    for await frame in capture.frames {
        await collector.add(frame)
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

if let outDirectory {
    let (_, audio) = await collector.summary()
    let directory = URL(fileURLWithPath: outDirectory, isDirectory: true)
    print("")
    print("writing WAV files to \(directory.path)")
    do {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        // Walk the tracks in a fixed order, so the paths always print the same way.
        for track in AudioTrack.allCases {
            guard let pcm = audio[track] else { continue }
            let url = directory.appendingPathComponent("wallfly-\(stamp)-\(track.rawValue).wav")
            try wav(from: pcm).write(to: url)
            print("  \(url.path) — \(pcm.count / CaptureFormat.bytesPerSecond) s")
        }
    } catch {
        print("Could not write the WAV files: \(error.localizedDescription)")
    }
}

/// Mates are two tracks, not one file. Wrapping the raw PCM in a WAV header
/// makes each one playable, so you can hear whether they line up.
func wav(from pcm: Data) -> Data {
    var file = Data()
    let byteRate = UInt32(CaptureFormat.bytesPerSecond)
    let blockAlign = UInt16(CaptureFormat.channels * CaptureFormat.bytesPerSample)

    func append(_ text: String) { file.append(contentsOf: Array(text.utf8)) }
    func append32(_ number: UInt32) { withUnsafeBytes(of: number.littleEndian) { file.append(contentsOf: $0) } }
    func append16(_ number: UInt16) { withUnsafeBytes(of: number.littleEndian) { file.append(contentsOf: $0) } }

    append("RIFF")
    append32(UInt32(36 + pcm.count))
    append("WAVE")
    append("fmt ")
    append32(16)                                   // size of the format block
    append16(1)                                    // 1 means plain PCM
    append16(UInt16(CaptureFormat.channels))
    append32(UInt32(CaptureFormat.sampleRate))
    append32(byteRate)
    append16(blockAlign)
    append16(UInt16(CaptureFormat.bytesPerSample * 8))
    append("data")
    append32(UInt32(pcm.count))
    file.append(pcm)
    return file
}
