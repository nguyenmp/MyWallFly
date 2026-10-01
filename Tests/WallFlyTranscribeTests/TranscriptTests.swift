import Foundation
import Testing
@testable import WallFlyTranscribe

/// The shape a real partial comes back in. Taken from Speechmatics' own mock
/// server, with a speaker added because we ask for diarization.
private let partialJSON = """
{
  "message": "AddPartialTranscript",
  "format": "2.1",
  "metadata": {"start_time": 0.0, "end_time": 1.0, "transcript": "foo"},
  "results": [
    {"type": "word", "start_time": 0.0, "end_time": 1.0,
     "alternatives": [{"content": "foo", "confidence": 1.0, "language": "en", "speaker": "S1"}]}
  ]
}
"""

private let finalJSON = """
{
  "message": "AddTranscript",
  "format": "2.1",
  "metadata": {"start_time": 0.0, "end_time": 2.0, "transcript": "Foo\\nBar."},
  "results": [
    {"type": "word", "start_time": 0.0, "end_time": 1.0,
     "alternatives": [{"content": "foo", "confidence": 1.0, "speaker": "S1"}]},
    {"type": "word", "start_time": 1.0, "end_time": 2.0,
     "alternatives": [{"content": "bar", "confidence": 1.0, "speaker": "S1"}]},
    {"type": "punctuation", "start_time": 2.0, "end_time": 2.0,
     "alternatives": [{"content": ".", "confidence": 1.0}]}
  ]
}
"""

private func parse(_ json: String) throws -> SpeechmaticsEvent {
    try TranscriptParser.event(fromJSON: Data(json.utf8))
}

@Suite("Reading messages from the service")
struct TranscriptParserTests {
    @Test("a start confirmation carries the job id")
    func recognisingCarriesJobId() throws {
        let event = try parse(#"{"message": "RecognitionStarted", "id": "job-1"}"#)
        guard case .recognising(let id) = event else {
            Issue.record("expected a recognising event, got \(event)")
            return
        }
        #expect(id == "job-1")
    }

    @Test("a partial carries words and a speaker")
    func partialWords() throws {
        let event = try parse(partialJSON)
        guard case .partial(let words) = event else {
            Issue.record("expected a partial, got \(event)")
            return
        }
        #expect(words.count == 1)
        #expect(words[0].content == "foo")
        #expect(words[0].speaker == "S1")
        #expect(words[0].start == 0)
        #expect(words[0].end == 1)
        #expect(words[0].isPunctuation == false)
    }

    @Test("a final keeps punctuation")
    func finalKeepsPunctuation() throws {
        let event = try parse(finalJSON)
        guard case .final(let words) = event else {
            Issue.record("expected a final, got \(event)")
            return
        }
        #expect(words.map(\.content) == ["foo", "bar", "."])
        #expect(words[2].isPunctuation)
        #expect(words[2].speaker == nil)
    }

    @Test("whole numbers become times, not zeros")
    func wholeNumbersBecomeDoubles() throws {
        // JSON sends whole seconds as whole numbers, and they must not fall
        // through the double cast and land on zero.
        let json = """
        {"message": "AddTranscript", "results": [
          {"type": "word", "start_time": 2, "end_time": 3,
           "alternatives": [{"content": "hi", "speaker": "S1"}]}]}
        """
        let event = try parse(json)
        guard case .final(let words) = event else {
            Issue.record("expected a final, got \(event)")
            return
        }
        #expect(words[0].start == 2)
        #expect(words[0].end == 3)
    }

    @Test("an error becomes a failure with its reason")
    func errorBecomesFailure() throws {
        let event = try parse(#"{"message": "Error", "type": "invalid_config", "reason": "bad language"}"#)
        guard case .failure(let reason) = event else {
            Issue.record("expected a failure, got \(event)")
            return
        }
        #expect(reason == "bad language")
    }

    @Test("warnings and info pass through")
    func warningAndInfo() throws {
        let warning = try parse(#"{"message": "Warning", "reason": "slow"}"#)
        guard case .warning(let text) = warning else {
            Issue.record("expected a warning, got \(warning)")
            return
        }
        #expect(text == "slow")

        let info = try parse(#"{"message": "Info", "reason": "hello"}"#)
        guard case .info(let text) = info else {
            Issue.record("expected info, got \(info)")
            return
        }
        #expect(text == "hello")
    }

    @Test("a pause is its own event")
    func endOfUtterance() throws {
        let event = try parse(#"{"message": "EndOfUtterance", "metadata": {"start_time": 3.0, "end_time": 3.0}}"#)
        guard case .endOfUtterance = event else {
            Issue.record("expected the end of an utterance, got \(event)")
            return
        }
    }

    @Test("the end of the transcript is its own event")
    func endOfTranscript() throws {
        let event = try parse(#"{"message": "EndOfTranscript"}"#)
        guard case .endOfTranscript = event else {
            Issue.record("expected the end, got \(event)")
            return
        }
    }

    @Test("a receipt for audio is ignored, not mistaken for words")
    func audioAddedIsIgnored() throws {
        let event = try parse(#"{"message": "AudioAdded", "seq_no": 3}"#)
        guard case .ignored(let name) = event else {
            Issue.record("expected an ignored event, got \(event)")
            return
        }
        #expect(name == "AudioAdded")
    }

    @Test("an unreadable message is an error, not silence")
    func unreadableMessageThrows() {
        #expect(throws: (any Error).self) {
            try TranscriptParser.event(fromJSON: Data("not json".utf8))
        }
    }
}

private func word(_ content: String, _ start: Double, _ end: Double,
                  speaker: String? = "S1", punctuation: Bool = false) -> TranscriptWord {
    TranscriptWord(content: content, start: start, end: end,
                   speaker: speaker, isPunctuation: punctuation)
}

@Suite("Joining words into transcript lines")
struct TranscriptSegmenterTests {
    @Test("one speaker makes one line")
    func oneSpeakerOneSegment() {
        let segments = TranscriptSegmenter.segments(
            from: [word("hello", 0, 0.5), word("there", 0.5, 1)], isFinal: true)
        #expect(segments.count == 1)
        #expect(segments[0].text == "hello there")
        #expect(segments[0].speaker == "S1")
        #expect(segments[0].start == 0)
        #expect(segments[0].end == 1)
    }

    @Test("a new speaker starts a new line")
    func speakerChangeSplits() {
        let segments = TranscriptSegmenter.segments(
            from: [word("yes", 0, 1), word("no", 1, 2, speaker: "S2")], isFinal: true)
        #expect(segments.map(\.speaker) == ["S1", "S2"])
        #expect(segments.map(\.text) == ["yes", "no"])
        #expect(segments[1].start == 1)
    }

    @Test("punctuation clings to the words before it")
    func punctuationJoins() {
        let segments = TranscriptSegmenter.segments(
            from: [word("hello", 0, 1), word("world", 1, 2),
                   word(".", 2, 2, speaker: nil, punctuation: true)], isFinal: true)
        #expect(segments.count == 1)
        #expect(segments[0].text == "hello world.")
    }

    @Test("punctuation with nothing before it is dropped")
    func leadingPunctuationDropped() {
        let segments = TranscriptSegmenter.segments(
            from: [word(",", 0, 0, speaker: nil, punctuation: true), word("hi", 0, 1)], isFinal: true)
        #expect(segments.map(\.text) == ["hi"])
    }

    @Test("words with no speaker still show up")
    func noSpeakerStillMakesALine() {
        let segments = TranscriptSegmenter.segments(from: [word("hi", 0, 1, speaker: nil)], isFinal: true)
        #expect(segments.count == 1)
        #expect(segments[0].speaker == nil)
    }

    @Test("each line remembers whether it can still change")
    func carriesFinalFlag() {
        let words = [word("hi", 0, 1)]
        #expect(TranscriptSegmenter.segments(from: words, isFinal: false)[0].isFinal == false)
        #expect(TranscriptSegmenter.segments(from: words, isFinal: true)[0].isFinal == true)
    }

    @Test("no words make no line")
    func emptyMakesNothing() {
        #expect(TranscriptSegmenter.segments(from: [], isFinal: true).isEmpty)
    }
}

@Suite("Mapping capture onto the provider stream")
struct PipeMappingTests {
    @Test("the silence pad covers the offset")
    func silencePadMatchesOffset() {
        // 16 kHz mono 16-bit is 32,000 bytes a second.
        #expect(TranscriptionPipe.leadingSilenceByteCount(offset: 0.09) == 2880)
        #expect(TranscriptionPipe.leadingSilenceByteCount(offset: 0) == 0)
        #expect(TranscriptionPipe.leadingSilenceByteCount(offset: -1) == 0)
    }

    @Test("the pad is silent")
    func padIsSilent() {
        let data = TranscriptionPipe.silence(byteCount: 64)
        #expect(data.count == 64)
        #expect(data.allSatisfy { $0 == 0 })
    }

    @Test("finals gather into one line until the turn ends")
    func finalsGatherIntoOneLine() {
        var turn = TurnAccumulator()
        let hello = [TranscriptWord(content: "hello", start: 0, end: 0.4, speaker: "S1", isPunctuation: false)]
        let there = [TranscriptWord(content: "there", start: 0.5, end: 0.9, speaker: "S1", isPunctuation: false)]

        // Two finals from one speaker stay open. Nothing is emitted yet.
        #expect(turn.add(hello).isEmpty)
        #expect(turn.add(there).isEmpty)

        // The pause ends the turn, and the whole sentence comes out at once.
        let line = turn.flush()
        #expect(line?.text == "hello there")
        #expect(line?.speaker == "S1")
        #expect(line?.start == 0)
        #expect(line?.end == 0.9)
        #expect(line?.isFinal == true)
    }

    @Test("a new speaker closes the line before it")
    func newSpeakerClosesTheLine() {
        var turn = TurnAccumulator()
        _ = turn.add([TranscriptWord(content: "yes", start: 0, end: 1, speaker: "S1", isPunctuation: false)])
        let finished = turn.add([TranscriptWord(content: "no", start: 1, end: 2, speaker: "S2", isPunctuation: false)])

        #expect(finished.map(\.speaker) == ["S1"])
        #expect(finished.first?.text == "yes")
        #expect(turn.flush()?.text == "no")
    }

    @Test("punctuation does not count as a speaker change")
    func punctuationKeepsTheTurnOpen() {
        var turn = TurnAccumulator()
        _ = turn.add([TranscriptWord(content: "hi", start: 0, end: 1, speaker: "S1", isPunctuation: false)])
        let finished = turn.add([TranscriptWord(content: ".", start: 1, end: 1, speaker: nil, isPunctuation: true)])
        #expect(finished.isEmpty)
        #expect(turn.flush()?.text == "hi.")
    }

    @Test("flushing an empty turn gives nothing")
    func emptyTurnFlushesNothing() {
        var turn = TurnAccumulator()
        #expect(turn.flush() == nil)
    }

    @Test("the end message carries the last audio sequence number")
    func endOfStreamCarriesSeqNo() throws {
        let root = try #require(
            try JSONSerialization.jsonObject(with: Data(EndOfStream.text(lastSeqNo: 7).utf8)) as? [String: Any]
        )
        #expect(root["message"] as? String == "EndOfStream")
        #expect(root["last_seq_no"] as? Int == 7)
    }
}
