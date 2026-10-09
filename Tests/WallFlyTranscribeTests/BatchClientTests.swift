import Foundation
import Testing
@testable import WallFlyTranscribe

@Suite("The batch path: a whole file in, a transcript out")
struct BatchClientTests {
    private func word(_ content: String, _ start: Double, _ end: Double, _ speaker: String?) -> TranscriptWord {
        TranscriptWord(content: content, start: start, end: end,
                       speaker: speaker, isPunctuation: false)
    }

    private func mark(_ content: String, _ at: Double) -> TranscriptWord {
        TranscriptWord(content: content, start: at, end: at, speaker: nil, isPunctuation: true)
    }

    @Test("sends a job to the batch host, not the real-time one")
    func batchHosts() {
        let europe = SpeechmaticsBatchConfig(apiKey: "k", region: .eu)
        #expect(europe.jobsURL.absoluteString == "https://asr.api.speechmatics.com/v2/jobs")

        let unitedStates = SpeechmaticsBatchConfig(apiKey: "k", region: .us)
        #expect(unitedStates.jobsURL.absoluteString == "https://us2.asr.api.speechmatics.com/v2/jobs")

        #expect(europe.transcriptURL("abc").absoluteString
                == "https://asr.api.speechmatics.com/v2/jobs/abc/transcript")
    }

    @Test("names the job as a transcription with speaker labels")
    func configShape() throws {
        let config = SpeechmaticsBatchConfig(apiKey: "k", language: "en")
        let root = try #require(
            try JSONSerialization.jsonObject(with: Data(config.configJSON().utf8)) as? [String: Any]
        )
        #expect(root["type"] as? String == "transcription")

        let transcription = try #require(root["transcription_config"] as? [String: Any])
        #expect(transcription["language"] as? String == "en")
        #expect(transcription["diarization"] as? String == "speaker")

        let diarization = try #require(transcription["speaker_diarization_config"] as? [String: Any])
        #expect(diarization["prefer_current_speaker"] as? Bool == true)
    }

    @Test("never asks for a speaker cap, which the batch settings refuse")
    func noSpeakerCap() throws {
        // The service rejected a job with "Additional property max_speakers is
        // not allowed", so the key must stay out of this message. The real-time
        // settings do accept it; the two are not the same shape.
        let config = SpeechmaticsBatchConfig(apiKey: "k")
        #expect(!config.configJSON().contains("max_speakers"))
    }

    @Test("asks for the transcript format the service knows")
    func transcriptFormat() {
        let url = SpeechmaticsBatchClient.addingQuery(
            to: SpeechmaticsBatchConfig(apiKey: "k").transcriptURL("abc"),
            items: [URLQueryItem(name: "format", value: "json-v2")]
        )
        #expect(url.absoluteString
                == "https://asr.api.speechmatics.com/v2/jobs/abc/transcript?format=json-v2")
    }

    @Test("asks the service to wait instead of answering at once")
    func waitIsAdded() {
        let config = SpeechmaticsBatchConfig(apiKey: "k", pollSeconds: 7)
        let url = SpeechmaticsBatchClient.addingWait(to: config.jobURL("abc"), seconds: config.pollSeconds)
        #expect(url.absoluteString == "https://asr.api.speechmatics.com/v2/jobs/abc?wait=7")
    }

    @Test("never puts the key in the job settings")
    func configHidesKey() {
        let config = SpeechmaticsBatchConfig(apiKey: "super-secret-key")
        #expect(!config.configJSON().contains("super-secret-key"))
    }

    @Test("starts a new line when the speaker changes")
    func splitsOnSpeaker() {
        let words = [word("Hello", 0, 0.5, "S1"), mark(".", 0.5),
                     word("Hi", 0.6, 1.0, "S2")]
        let lines = SpeechmaticsBatchClient.segments(from: words, gap: 2)
        #expect(lines.count == 2)
        #expect(lines[0].speaker == "S1")
        #expect(lines[0].text == "Hello.")
        #expect(lines[1].speaker == "S2")
        #expect(lines[1].text == "Hi")
    }

    @Test("keeps one speaker's words together through a short pause")
    func joinsShortPause() {
        let words = [word("One", 0, 0.5, "S1"), word("two", 1.0, 1.5, "S1")]
        let lines = SpeechmaticsBatchClient.segments(from: words, gap: 2)
        #expect(lines.count == 1)
        #expect(lines[0].text == "One two")
        #expect(lines[0].start == 0)
        #expect(lines[0].end == 1.5)
    }

    @Test("starts a new line when one speaker pauses for longer than the gap")
    func splitsOnLongPause() {
        let words = [word("One", 0, 0.5, "S1"), word("two", 5.0, 5.5, "S1")]
        let lines = SpeechmaticsBatchClient.segments(from: words, gap: 2)
        #expect(lines.count == 2)
        #expect(lines[0].text == "One")
        #expect(lines[1].text == "two")
    }

    @Test("puts punctuation on the words before it, and never at the start")
    func punctuationBelongsToWhatCameBefore() {
        let words = [mark(",", 0), word("Hello", 0.1, 0.5, "S1"), mark(".", 0.5)]
        let lines = SpeechmaticsBatchClient.segments(from: words, gap: 2)
        #expect(lines.count == 1)
        #expect(lines[0].text == "Hello.")
    }

    @Test("marks every line settled, because a batch result is done")
    func linesAreFinal() {
        let words = [word("Hello", 0, 0.5, "S1")]
        let lines = SpeechmaticsBatchClient.segments(from: words, gap: 2)
        #expect(lines.count == 1)
        #expect(lines[0].isFinal)
    }

    @Test("returns nothing for a file with no words")
    func emptyWords() {
        #expect(SpeechmaticsBatchClient.segments(from: [], gap: 2).isEmpty)
    }

    @Test("builds an upload body that carries the settings and the file")
    func multipartBodyHasBothParts() throws {
        // Two bytes of audio, so the body is easy to check without a real clip.
        let audio = Data([0x01, 0x02])
        let clip = FileManager.default.temporaryDirectory
            .appendingPathComponent("wallfly-test-\(UUID().uuidString).wav")
        try audio.write(to: clip)
        defer { try? FileManager.default.removeItem(at: clip) }

        let boundary = "test-boundary"
        let config = SpeechmaticsBatchConfig(apiKey: "k").configJSON()
        let body = try SpeechmaticsBatchClient.multipartBody(fileAt: clip,
                                                             boundary: boundary,
                                                             config: config)
        defer { try? FileManager.default.removeItem(at: body) }

        let bytes = try Data(contentsOf: body)
        let text = String(decoding: bytes, as: UTF8.self)

        #expect(text.contains("name=\"config\""))
        #expect(text.contains("\"type\":\"transcription\""))
        #expect(text.contains("name=\"data_file\"; filename=\"\(clip.lastPathComponent)\""))
        #expect(text.hasSuffix("\r\n--\(boundary)--\r\n"))
        // The audio must be in the body untouched.
        #expect(bytes.range(of: audio) != nil)
    }

    @Test("repeats the reason the service gave for a refusal")
    func refusalReason() {
        let body = Data(#"{"detail":"no audio found"}"#.utf8)
        #expect(SpeechmaticsBatchClient.reason(in: body) == "no audio found")
    }

    @Test("falls back to the raw text when the refusal has no reason field")
    func refusalWithoutReason() {
        #expect(SpeechmaticsBatchClient.reason(in: Data("Not Authorized".utf8)) == "Not Authorized")
    }
}
