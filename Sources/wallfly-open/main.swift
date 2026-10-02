import Darwin
import Foundation
import WallFlyTranscribe

// Open a meeting that has already been recorded, to read it back and fix it.
//
//   swift run wallfly-open 2026-10-02T18-33-44Z
//   swift run wallfly-open 2026-10-02T18-33-44Z --no-open
//   swift run wallfly-open 2026-10-02T18-33-44Z --port 8765
//
// The page is served the same way a live run serves it, so the same gestures and
// the same saving work. The only difference is where the transcript comes from: a
// folder, not a microphone. A change made on the page is written back to that
// folder's edits.json.
//
// The folder holds three files:
//
//   transcript.txt  what a person reads
//   turns.jsonl     the same turns, for the app to read back exactly
//   edits.json      the changes made on the page
//
// A folder written before turns.jsonl existed still opens. The transcript is read
// instead, and the end of each line has to be guessed.

let arguments = Array(CommandLine.arguments.dropFirst())

func value(after flag: String, in arguments: [String]) -> String? {
    guard let index = arguments.firstIndex(of: flag), index + 1 < arguments.count else { return nil }
    return arguments[index + 1]
}

/// The folder is the first plain word. A flag's value is skipped.
func folderArgument(in arguments: [String]) -> String? {
    var skipNext = false
    for argument in arguments {
        if skipNext { skipNext = false; continue }
        if argument == "--port" { skipNext = true; continue }
        if argument.hasPrefix("--") { continue }
        return argument
    }
    return nil
}

func tell(_ text: String) {
    FileHandle.standardError.write(Data((text + "\n").utf8))
}

func fail(_ text: String) -> Never {
    FileHandle.standardError.write(Data((text + "\n").utf8))
    exit(1)
}

guard let given = folderArgument(in: arguments) else {
    fail("""
    Which meeting?

        swift run wallfly-open 2026-10-02T18-33-44Z

    Give the run's folder. It holds transcript.txt, and turns.jsonl and
    edits.json when the run wrote them.
    """)
}

// A folder, a file inside it, or a file path all work.
let givenURL = URL(fileURLWithPath: given)
var isDirectory: ObjCBool = false
let folder: URL
if FileManager.default.fileExists(atPath: givenURL.path, isDirectory: &isDirectory) {
    folder = isDirectory.boolValue ? givenURL : givenURL.deletingLastPathComponent()
} else {
    folder = givenURL
}

let meeting: SavedMeeting
do {
    meeting = try SavedMeeting.load(from: folder)
} catch {
    fail("Could not open \(folder.path): \(error)")
}

tell("meeting:    \(folder.path)")
tell("turns:      \(meeting.turns.count) from \(meeting.source.description)")
tell("changes:    \(meeting.changes) kept")

// MARK: - The page

/// Ctrl-C stops the server. A page left open after that can still be read, but it
/// cannot save.
var signalSources: [DispatchSourceSignal] = []
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

let page: LivePage
do {
    let port = value(after: "--port", in: arguments).flatMap(UInt16.init) ?? 0
    let started = try LivePage.start(banner: meeting.label, port: port,
                                     editsURL: meeting.editsURL, restoring: meeting.turns)
    page = started.page
    tell("page:       \(started.url.absoluteString)")
    if !arguments.contains("--no-open") {
        let opener = Process()
        opener.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        opener.arguments = [started.url.absoluteString]
        do {
            try opener.run()
        } catch {
            tell("could not open the browser: \(error.localizedDescription)")
        }
    }
} catch {
    fail("Could not start the page: \(error)")
}

tell("Press Ctrl-C to stop.")
for await _ in interrupt { break }
page.stop()
