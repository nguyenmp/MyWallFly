import Darwin
import Foundation
import WallFlyCapture
import WallFlyTranscribe

// Captures a meeting and streams it to Speechmatics, then prints the transcript
// line by line as people talk.
//
//   swift run wallfly-transcribe                  run until you press Ctrl-C
//   swift run wallfly-transcribe 60               stop by itself after 60 seconds
//   swift run wallfly-transcribe mic-only         microphone only, one stream
//   swift run wallfly-transcribe --file clip.wav  replay a recording, no microphone
//   swift run wallfly-transcribe --out notes.txt  write to a file to watch with tail -f
//   swift run wallfly-transcribe --final-only     do not follow the words being spoken
//   swift run wallfly-transcribe --check          open a stream and stop: tests the key
//   swift run wallfly-transcribe 60 --verbose     log every message from the service
//
// While it runs, the bottom line of the terminal shows the words so far.
// Finished lines scroll up above it.
//
// The key comes from SPEECHMATICS_API_KEY, in the environment or in .env.
// The app never holds a key of its own, and never writes one to a log.

// MARK: - Reading the command line

let arguments = Array(CommandLine.arguments.dropFirst())
/// Seconds to run for. Nil means run until someone stops it.
let runSeconds = arguments.first { Double($0) != nil }.flatMap(Double.init)
let microphoneOnly = arguments.contains("mic-only")
let showPartials = arguments.contains("--partials")
/// Drafts out. Useful for a file you want to keep as a clean transcript.
let finalOnly = arguments.contains("--final-only")
let verbose = arguments.contains("--verbose")

func value(after flag: String, in arguments: [String]) -> String? {
    guard let index = arguments.firstIndex(of: flag), index + 1 < arguments.count else { return nil }
    return arguments[index + 1]
}

/// Writes straight through, so a line shows up the moment it is made. `print`
/// sits in a buffer when the output is a pipe, which hides a live transcript.
///
/// Transcript lines go to standard output, so `> notes.txt` works and a pipe
/// gets nothing but the transcript. Everything about the run goes to standard
/// error, so it never lands in the middle of a transcript.
enum Console {
    /// A finished transcript line, with no file set.
    static func line(_ text: String) {
        FileHandle.standardOutput.write(Data((text + "\n").utf8))
    }

    /// Something about the run: settings, totals, warnings.
    static func note(_ text: String) {
        FileHandle.standardError.write(Data((text + "\n").utf8))
    }

    /// Part of a line that is already open, so no newline is added.
    static func err(_ text: String) {
        FileHandle.standardError.write(Data(text.utf8))
    }

    /// True when the error output is a terminal, so it can be redrawn in place.
    static var canRedraw: Bool { isatty(STDERR_FILENO) == 1 }
}

let environment = DotEnv.load(path: DotEnv.defaultPath())
guard let apiKey = environment["SPEECHMATICS_API_KEY"], !apiKey.isEmpty else {
    Console.err("""
    No Speechmatics key found.

    Copy .env.example to .env, then put your key in it:

        SPEECHMATICS_API_KEY=your-key-here

    Or set it in the shell:

        export SPEECHMATICS_API_KEY=your-key-here

    Get a key at https://portal.speechmatics.com

    """)
    exit(2)
}

let region: SpeechmaticsRegion = (value(after: "--region", in: arguments) == "us") ? .us : .eu
let maxSpeakers = value(after: "--max-speakers", in: arguments).flatMap(Int.init) ?? 50
let providerConfiguration = SpeechmaticsConfig(apiKey: apiKey,
                                               region: region,
                                               maxSpeakers: maxSpeakers)

// MARK: - Stopping on Ctrl-C

/// Keeps the signal sources alive for the life of the process.
var signalSources: [DispatchSourceSignal] = []

/// Fires once when the user presses Ctrl-C.
let interrupt = AsyncStream<Void> { continuation in
    signal(SIGINT, SIG_IGN)
    let source = DispatchSource.makeSignalSource(signal: SIGINT, queue: .global())
    source.setEventHandler {
        continuation.yield(())
        continuation.finish()
    }
    source.resume()
    signalSources.append(source)
}

// MARK: - Check the key without holding a meeting

if arguments.contains("--check") {
    Console.note("Testing the key against \(region.rawValue)…")
    let client = SpeechmaticsClient(config: providerConfiguration)
    let listener = Task {
        for await event in client.events {
            switch event {
            case .recognising(let id):
                Console.note("The key works. Speechmatics opened stream \(id).")
            case .failure(let reason):
                Console.err("Refused: \(reason)\n")
            case .warning(let text):
                Console.note("Warning: \(text)")
            default:
                break
            }
        }
    }
    do {
        try await client.start()
    } catch {
        Console.err("Could not open a stream: \(error)\n")
        await client.close()
        exit(1)
    }
    await client.close()
    _ = await listener.value
    exit(0)
}

// MARK: - Where the transcript goes

/// `--out` keeps the transcript in a file, which always holds it as it stands:
/// every settled line, plus one open line for the words still being spoken.
/// That open line is rewritten in place on every update, so the file is never
/// half a sentence behind.
var transcriptFile: FileHandle?
if let outPath = value(after: "--out", in: arguments) {
    if !FileManager.default.fileExists(atPath: outPath) {
        FileManager.default.createFile(atPath: outPath, contents: nil)
    }
    guard let handle = FileHandle(forWritingAtPath: outPath) else {
        Console.err("Could not open \(outPath) for writing.\n")
        exit(1)
    }
    // A run owns its file. An older transcript in it would only confuse.
    try? handle.truncate(atOffset: 0)
    transcriptFile = handle
    Console.note("transcript: \(outPath)")
    if !finalOnly {
        Console.note("one line is kept open for the words still being spoken, and rewritten as they change.")
    }
}

// MARK: - Replay a recording

if let filePath = value(after: "--file", in: arguments) {
    let url = URL(fileURLWithPath: filePath)
    let recording: [AudioFrame]
    do {
        recording = try AudioFileSource.frames(from: url)
    } catch {
        Console.err("Could not read \(filePath): \(error)\n")
        exit(1)
    }
    guard !recording.isEmpty else {
        Console.err("\(filePath) holds no audio.\n")
        exit(1)
    }

    let length = Double(recording.count) * AudioFileSource.chunkSeconds
    Console.note("Replaying \(filePath) — \(String(format: "%.1f", length)) s through \(region.rawValue)")

    // Feed the frames at real time. The service expects a live pace.
    let stream = AsyncStream<AudioFrame> { continuation in
        Task {
            let began = Date()
            for (index, frame) in recording.enumerated() {
                let due = Double(index) * AudioFileSource.chunkSeconds
                let elapsed = Date().timeIntervalSince(began)
                if due > elapsed {
                    try? await Task.sleep(nanoseconds: UInt64((due - elapsed) * 1_000_000_000))
                }
                continuation.yield(frame)
            }
            continuation.finish()
        }
    }

    let printer = SegmentPrinter(showPartials: showPartials,
                                 canRedraw: Console.canRedraw,
                                 file: transcriptFile,
                                 followDrafts: !finalOnly)
    var pipe = TranscriptionPipe(config: providerConfiguration, tracks: [.microphone])
    if verbose {
        pipe.debugLog = { Console.note("  · \($0)") }
    }

    do {
        let report = try await pipe.run(captureStart: AudioFileSource.captureStart(),
                                        frames: stream) { event in
            printer.show(event)
        }
        printer.finishLine()
        Console.note("")
        Console.note("sent \(report.framesSent) buffers, dropped \(report.framesDropped), \(report.segments) segments")
        try? transcriptFile?.close()
    } catch {
        printer.finishLine()
        Console.err("Transcription failed: \(error)\n")
        exit(1)
    }
    exit(0)
}

// MARK: - Listen to a meeting

let captureConfiguration: CaptureConfiguration = microphoneOnly ? .microphoneOnly : .default
let tracks: [AudioTrack] = microphoneOnly ? [.microphone] : AudioTrack.allCases

Console.note("MyWallFly → Speechmatics"
            + (runSeconds.map { " — running for \($0) s" } ?? " — press Ctrl-C to stop"))
Console.note("region: \(region.rawValue)   tracks: \(tracks.map(\.rawValue).joined(separator: ", "))")
Console.note("microphone: \(CapturePermissions.microphoneGranted ? "granted" : "not granted yet")")
if !microphoneOnly {
    Console.note("screen recording: \(CapturePermissions.screenRecordingGranted ? "granted" : "not granted yet")")
}

let capture: AudioCapture
do {
    capture = try AudioCapture(configuration: captureConfiguration)
} catch {
    Console.err("Could not set up capture: \(error.localizedDescription)\n")
    exit(1)
}

let start: CaptureStart
do {
    start = try await capture.start()
} catch {
    Console.err("Could not start capture: \(error.localizedDescription)\n")
    if !microphoneOnly && !CapturePermissions.screenRecordingGranted {
        Console.note("Grant Screen Recording in System Settings, then run again.")
    }
    exit(1)
}

for trackStart in start.starts {
    let pad = TranscriptionPipe.leadingSilenceByteCount(offset: trackStart.offset)
    Console.note("\(trackStart.track.rawValue) started \(String(format: "+%.0f ms", trackStart.offset * 1000)) into the meeting"
                + (pad > 0 ? " (padding \(pad) bytes of silence)" : ""))
}

let printer = SegmentPrinter(showPartials: showPartials,
                             canRedraw: Console.canRedraw,
                             file: transcriptFile,
                             followDrafts: !finalOnly)
var pipe = TranscriptionPipe(config: providerConfiguration, tracks: tracks)
if verbose {
    pipe.debugLog = { Console.note("  · \($0)") }
}

let runner = Task {
    try await pipe.run(captureStart: start, frames: capture.frames) { event in
        printer.show(event)
    }
}

// Stop on the clock, on Ctrl-C, or never.
await withTaskGroup(of: Void.self) { group in
    group.addTask {
        for await _ in interrupt { break }
    }
    if let runSeconds {
        group.addTask {
            try? await Task.sleep(nanoseconds: UInt64(runSeconds * 1_000_000_000))
        }
    }
    await group.next()
    group.cancelAll()
}

await capture.stop()

do {
    let report = try await runner.value
    printer.finishLine()
    Console.note("")
    Console.note("sent \(report.framesSent) buffers, dropped \(report.framesDropped), \(report.segments) segments")
    if let lastError = report.lastError {
        Console.note("last drop: \(lastError)")
    }
    for track in capture.stats().tracks {
        Console.note("\(track.track.rawValue): \(String(format: "%.1f", track.seconds)) s of audio, "
                    + "\(track.dropped) dropped buffers, drift \(String(format: "%.0f ms", track.drift * 1000))")
    }
    try? transcriptFile?.close()
} catch {
    printer.finishLine()
    Console.err("Transcription failed: \(error)\n")
    exit(1)
}

/// Keeps the transcript up to date: settled lines, plus one open line for the
/// words still being spoken.
///
/// On a terminal the open line is redrawn at the bottom. In a file it is
/// rewritten in place, so the file always holds the whole transcript and the
/// words being spoken are always on the last line.
final class SegmentPrinter: @unchecked Sendable {
    private let lock = NSLock()
    private let showPartials: Bool
    private let canRedraw: Bool
    private let file: FileHandle?
    /// Whether the open line should follow the words that are still changing.
    private let followDrafts: Bool
    /// True while a redrawn line sits on the bottom of the terminal.
    private var openLine = false
    /// Where the open line starts in the file. Nil when the next write starts a
    /// new line.
    private var draftStart: UInt64?
    /// How far the file has been written.
    private var endOffset: UInt64 = 0

    init(showPartials: Bool, canRedraw: Bool, file: FileHandle? = nil, followDrafts: Bool = true) {
        self.showPartials = showPartials
        self.canRedraw = canRedraw
        self.file = file
        self.followDrafts = followDrafts
    }

    /// Redraws the bottom line of the terminal. Does nothing when the output is
    /// not a terminal, where redrawing would fill a log with junk.
    func status(_ text: String) {
        guard canRedraw else { return }
        lock.lock(); defer { lock.unlock() }
        let clipped = String(text.prefix(240))
        Console.err("\r\u{1B}[K" + clipped)
        openLine = true
    }

    func show(_ event: TranscriptionEvent) {
        let segment = event.segment

        if !segment.isFinal {
            let draft = "   … \(label(for: event)): \(segment.text)"
            if canRedraw { status(draft) }
            if file != nil {
                guard followDrafts else { return }
                lock.lock(); defer { lock.unlock() }
                rewriteOpenLine(draft)
            } else if !canRedraw && showPartials {
                lock.lock(); defer { lock.unlock() }
                clearLocked()
                Console.line(draft)
            }
            return
        }

        lock.lock(); defer { lock.unlock() }
        clearLocked()
        if file != nil {
            rewriteOpenLine(line(for: event))
            // The line is settled. The next draft opens a new line after it.
            draftStart = nil
        } else {
            Console.line(line(for: event))
        }
    }

    func finishLine() {
        lock.lock(); defer { lock.unlock() }
        clearLocked()
    }

    /// Puts `text` where the open line is, and cuts back whatever was there.
    /// Writing the shorter text without cutting back would leave old words
    /// behind it.
    private func rewriteOpenLine(_ text: String) {
        guard let file else { return }
        let start = draftStart ?? endOffset
        let bytes = Data((text + "\n").utf8)
        try? file.seek(toOffset: start)
        try? file.truncate(atOffset: start)
        try? file.write(contentsOf: bytes)
        endOffset = start + UInt64(bytes.count)
        draftStart = start
    }

    private func clearLocked() {
        guard openLine else { return }
        Console.err("\r\u{1B}[K")
        openLine = false
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
