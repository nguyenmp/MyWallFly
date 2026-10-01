import Foundation
import Testing
@testable import WallFlyTranscribe

@Suite("The Speechmatics connection settings")
struct SpeechmaticsConfigTests {
    @Test("puts the language on the end of the url")
    func urlCarriesLanguage() {
        let config = SpeechmaticsConfig(apiKey: "k", region: .eu, language: "en")
        #expect(config.url.absoluteString == "wss://eu2.rt.speechmatics.com/v2/en")
    }

    @Test("offers a United States region")
    func unitedStatesRegion() {
        let config = SpeechmaticsConfig(apiKey: "k", region: .us)
        #expect(config.url.absoluteString == "wss://us2.rt.speechmatics.com/v2/en")
    }

    @Test("builds a start message the service accepts")
    func startMessageShape() throws {
        let config = SpeechmaticsConfig(apiKey: "k", language: "en", maxSpeakers: 6, maxDelay: 1.5)
        let root = try #require(
            try JSONSerialization.jsonObject(with: Data(config.startMessage().utf8)) as? [String: Any]
        )

        #expect(root["message"] as? String == "StartRecognition")

        let format = try #require(root["audio_format"] as? [String: Any])
        #expect(format["type"] as? String == "raw")
        #expect(format["encoding"] as? String == "pcm_s16le")
        #expect(format["sample_rate"] as? Int == 16000)

        let transcription = try #require(root["transcription_config"] as? [String: Any])
        #expect(transcription["language"] as? String == "en")
        #expect(transcription["diarization"] as? String == "speaker")
        #expect(transcription["enable_partials"] as? Bool == true)
        #expect(transcription["max_delay"] as? Double == 1.5)

        let diarization = try #require(transcription["speaker_diarization_config"] as? [String: Any])
        #expect(diarization["max_speakers"] as? Int == 6)
        #expect(diarization["prefer_current_speaker"] as? Bool == true)
    }

    @Test("never puts the key in the start message")
    func startMessageHidesKey() {
        let config = SpeechmaticsConfig(apiKey: "super-secret-key")
        #expect(!config.startMessage().contains("super-secret-key"))
    }

    @Test("the start message is text, not bytes")
    func startMessageIsText() throws {
        // Speechmatics reads text frames as control messages and binary frames
        // as audio. Sending this as bytes made the service treat the start
        // message itself as audio and refuse the stream. This test pins the
        // shape: the API returns a String, so it can only be sent as text.
        let config = SpeechmaticsConfig(apiKey: "k")
        let message: String = config.startMessage()
        #expect(!message.isEmpty)
        #expect(try JSONSerialization.jsonObject(with: Data(message.utf8)) is [String: Any])
    }
}
