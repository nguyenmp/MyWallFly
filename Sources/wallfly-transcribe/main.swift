import Foundation
import WallFlyCapture
import WallFlyTranscribe

// Captures a meeting and streams it to Speechmatics, then prints the transcript.
//
//   swift run wallfly-transcribe 60                 both tracks, 60 seconds
//   swift run wallfly-transcribe 60 mic-only        microphone only
//   swift run wallfly-transcribe 60 --partials      also show the live partials
//   swift run wallfly-transcribe --check            open a stream and stop, to test the key
//
// The key comes from SPEECHMATICS_API_KEY, in the environment or in .env.
// The app never holds a key of its own, and never writes one to a log.

let arguments = Array(CommandLine.arguments.dropFirst())
let runSeconds = arguments.first { Double($0) != nil }.flatMap(Double.init) ?? 60
let microphoneOnly = arguments.contains("mic-only")
let showPartials = arguments.contains("--partials")

func value(after flag: String, in arguments: [String]) -> String? {
    guard let index = arguments.firstIndex(of: flag), index + 1 < arguments.count else { return nil }
    return arguments[index + 1]
}

let environment = DotEnv.load(path: DotEnv.defaultPath())
guard let apiKey = environment["SPEECHMATICS_API_KEY"], !apiKey.isEmpty else {
    FileHandle.standardError.write(Data("""
    No Speechmatics key found.

    Copy .env.example to .env, then put your key in it:

        SPEECHMATICS_API_KEY=your-key-here

    Or set it in the shell:

        export SPEECHMATICS_API_KEY=your-key-here

    Get a key at https://portal.speechmatics.com

    """.utf8))
    exit(2)
}

let region: SpeechmaticsRegion =
    (value(after: "--region", in: arguments) == "us") ? .us : .eu

let maxSpeakers = value(after: "--max-speakers", in: arguments).flatMap(Int.init) ?? 50

let captureConfiguration: CaptureConfiguration = microphoneOnly ? .microphoneOnly : .default

// Which tracks to send. Each one costs a stream.
let tracks: [AudioTrack] = microphoneOnly ? [.microphone] : AudioTrack.allCases

let providerConfiguration = SpeechmaticsConfig(apiKey: apiKey,
                                               region: region,
                                               maxSpeakers: maxSpeakers)

// Test the key without opening the microphone or spending a meeting's time.
if arguments.contains("--check") {
    print("Testing the key against \(region.rawValue)…")
    let client = SpeechmaticsClient(config: providerConfiguration)
    let listener = Task {
        for await event in client.events {
            switch event {
            case .recognising(let id):
                print("The key works. Speechmatics opened stream \(id).")
            case .failure(let reason):
                FileHandle.standardError.write(Data("Refused: \(reason)\n".utf8))
            case .warning(let text):
                print("Warning: \(text)")
            default:
                break
            }
        }
    }
    do {
        try await client.start()
    } catch {
        FileHandle.standardError.write(Data("Could not open a stream: \(error)\n".utf8))
        await client.close()
        exit(1)
    }
    await client.close()
    _ = await listener.value
    exit(0)
}

print("MyWallFly → Speechmatics — running for \(runSeconds) s")
print("region: \(region.rawValue)   tracks: \(tracks.map(\.rawValue).joined(separator: ", "))")
print("microphone: \(CapturePermissions.microphoneGranted ? "granted" : "not granted yet")")
if !microphoneOnly {
    print("screen recording: \(CapturePermissions.screenRecordingGranted ? "granted" : "not granted yet")")
}

let capture: AudioCapture
do {
    capture = try AudioCapture(configuration: captureConfiguration)
} catch {
    FileHandle.standardError.write(Data("Could not set up capture: \(error.localizedDescription)\n".utf8))
    exit(1)
}

let start: CaptureStart
do {
    start = try await capture.start()
} catch {
    FileHandle.standardError.write(Data("Could not start capture: \(error.localizedDescription)\n".utf8))
    if !microphoneOnly && !CapturePermissions.screenRecordingGranted {
        print("Grant Screen Recording in System Settings, then run again.")
    }
    exit(1)
}

for trackStart in start.starts {
    let pad = TranscriptionPipe.leadingSilenceByteCount(offset: trackStart.offset)
    print("\(trackStart.track.rawValue) started \(String(format: "+%.0f ms", trackStart.offset * 1000)) into the meeting"
          + (pad > 0 ? " (padding \(pad) bytes of silence)" : ""))
}

/// Prints one line per segment. Partial lines reuse the same line, so the
/// terminal does not scroll while someone is still talking.
let printer = SegmentPrinter(showPartials: showPartials)

let pipe = TranscriptionPipe(config: providerConfiguration, tracks: tracks)
let runner = Task {
    try await pipe.run(captureStart: start, frames: capture.frames) { event in
        printer.show(event)
    }
}

try? await Task.sleep(nanoseconds: UInt64(runSeconds * 1_000_000_000))
await capture.stop()

do {
    let report = try await runner.value
    printer.finishLine()
    print("")
    print("sent \(report.framesSent) buffers, dropped \(report.framesDropped), \(report.segments) segments")
    if let lastError = report.lastError {
        print("last drop: \(lastError)")
    }
    let stats = capture.stats()
    for track in stats.tracks {
        print("\(track.track.rawValue): \(String(format: "%.1f", track.seconds)) s of audio, "
              + "\(track.dropped) dropped buffers, drift \(String(format: "%.0f ms", track.drift * 1000))")
    }
} catch {
    printer.finishLine()
    FileHandle.standardError.write(Data("Transcription failed: \(error)\n".utf8))
    exit(1)
}

/// Keeps partial lines and final lines from fighting over the same row.
final class SegmentPrinter: @unchecked Sendable {
    private let lock = NSLock()
    private let showPartials: Bool
    private var openPartial = false

    init(showPartials: Bool) {
        self.showPartials = showPartials
    }

    func show(_ event: TranscriptionEvent) {
        let segment = event.segment
        guard segment.isFinal else {
            guard showPartials else { return }
            lock.lock(); defer { lock.unlock() }
            clearLocked()
            let text = "   … \(label(for: event)): \(segment.text)"
            FileHandle.standardError.write(Data(text.prefix(200).utf8))
            openPartial = true
            return
        }

        lock.lock(); defer { lock.unlock() }
        clearLocked()
        print(line(for: event))
    }

    func finishLine() {
        lock.lock(); defer { lock.unlock() }
        clearLocked()
    }

    private func clearLocked() {
        guard openPartial else { return }
        FileHandle.standardError.write(Data("\r\u{1B}[K".utf8))
        openPartial = false
    }

    private func line(for event: TranscriptionEvent) -> String {
        let stamp = String(format: "%7.2f", event.segment.start)
        return "[\(stamp)s] \(label(for: event)): \(event.segment.text)"
    }

    private func label(for event: TranscriptionEvent) -> String {
        let track = event.track == .microphone ? "mic" : "sys"
        let speaker = event.segment.speaker ?? "??"
        return "\(track) \(speaker)"
    }
}
