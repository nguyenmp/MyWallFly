import Foundation
import Testing
@testable import WallFlyTranscribe

@Suite("Reading a meeting back from a folder")
struct SavedMeetingTests {
    private func emptyFolder() throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("wallfly-meeting-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test("a settled line is read back")
    func readsALine() {
        let turn = SavedMeeting.parseLine("[   4.68s] mic S2: this is Daniel.")
        #expect(turn?.track == "mic")
        #expect(turn?.label == "S2")
        #expect(turn?.t0 == 4680)
        #expect(turn?.text == "this is Daniel.")
    }

    @Test("the line for words still being spoken is not a settled turn")
    func ignoresTheLiveLine() {
        #expect(SavedMeeting.parseLine("   … mic S2: out right") == nil)
    }

    @Test("the second track is called sys in the transcript and system in the page")
    func sysBecomesSystem() {
        #expect(SavedMeeting.parseLine("[   0.00s] sys S1: hello")?.track == "system")
    }

    @Test("the record is exact, and is preferred over the transcript")
    func prefersTheRecord() throws {
        let dir = try emptyFolder()
        defer { try? FileManager.default.removeItem(at: dir) }
        // The record and the transcript disagree, so the test can tell them apart.
        try "{\"track\":\"mic\",\"label\":\"S9\",\"t0\":100,\"t1\":900,\"text\":\"from the record\"}\n"
            .write(to: dir.appendingPathComponent("turns.jsonl"), atomically: true, encoding: .utf8)
        try "[   0.00s] mic S1: from the transcript\n"
            .write(to: dir.appendingPathComponent("transcript.txt"), atomically: true, encoding: .utf8)

        let meeting = try SavedMeeting.load(from: dir)
        #expect(meeting.source == .record)
        #expect(meeting.turns.count == 1)
        #expect(meeting.turns[0].text == "from the record")
        #expect(meeting.turns[0].t1 == 900)
    }

    @Test("an older folder falls back to the transcript, and guesses the ends")
    func fallsBackToTheTranscript() throws {
        let dir = try emptyFolder()
        defer { try? FileManager.default.removeItem(at: dir) }
        try """
        [   0.00s] mic S1: Hello there.
        [   4.68s] mic S1: This is Samantha.
        [   1.00s] sys S1: Can you hear me?
        """.write(to: dir.appendingPathComponent("transcript.txt"), atomically: true, encoding: .utf8)

        let meeting = try SavedMeeting.load(from: dir)
        #expect(meeting.source == .transcript)
        #expect(meeting.turns.count == 3)
        // A line's end is the next line on its own track, whatever the other track
        // was doing.
        let firstMic = meeting.turns.first { $0.track == "mic" }
        #expect(firstMic?.t0 == 0)
        #expect(firstMic?.t1 == 4680)
        // The last line on a track has nothing after it, so its end is guessed at
        // about 2.7 words a second: three words is 1110 ms.
        let lastMic = meeting.turns.last { $0.track == "mic" }
        #expect(lastMic?.t1 == 4680 + 1110)
    }

    @Test("a folder with no meeting says so")
    func emptyFolderThrows() throws {
        let dir = try emptyFolder()
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(throws: SavedMeeting.LoadError.self) {
            try SavedMeeting.load(from: dir)
        }
    }

    @Test("the changes kept beside the transcript are counted")
    func countsChanges() throws {
        let dir = try emptyFolder()
        defer { try? FileManager.default.removeItem(at: dir) }
        try "[   0.00s] mic S1: hi\n"
            .write(to: dir.appendingPathComponent("transcript.txt"), atomically: true, encoding: .utf8)
        try "[{\"n\":1},{\"n\":2}]"
            .write(to: dir.appendingPathComponent("edits.json"), atomically: true, encoding: .utf8)
        #expect(try SavedMeeting.load(from: dir).changes == 2)
    }
}
