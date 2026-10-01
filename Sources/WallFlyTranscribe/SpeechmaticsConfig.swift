import Foundation
import WallFlyCapture

/// Which Speechmatics data centre to use. Pick the one closest to you; latency
/// and, in some regions, data rules follow.
public enum SpeechmaticsRegion: String, Sendable, CaseIterable {
    case eu = "eu2"
    case us = "us2"

    var host: String { "\(rawValue).rt.speechmatics.com" }
}

/// Everything one real-time stream needs to open and transcribe.
public struct SpeechmaticsConfig: Sendable {
    /// The user's own key. The app never holds one for them.
    public var apiKey: String
    public var region: SpeechmaticsRegion
    /// A language pack code, like `en`.
    public var language: String
    /// Highest speaker number the service may use. Speechmatics allows 50.
    public var maxSpeakers: Int
    /// Send partial transcripts while a person is still talking.
    public var enablePartials: Bool
    /// Seconds the service may wait before it commits a word. Lower is
    /// snappier and less accurate.
    public var maxDelay: Double

    public init(apiKey: String,
                region: SpeechmaticsRegion = .eu,
                language: String = "en",
                maxSpeakers: Int = 50,
                enablePartials: Bool = true,
                maxDelay: Double = 2) {
        self.apiKey = apiKey
        self.region = region
        self.language = language
        self.maxSpeakers = maxSpeakers
        self.enablePartials = enablePartials
        self.maxDelay = maxDelay
    }

    /// The websocket address. Speechmatics wants the language as a path segment.
    public var url: URL {
        URL(string: "wss://\(region.host)/v2/\(language)")!
    }

    /// The first message on the socket. It names the audio format and says how
    /// to transcribe.
    ///
    /// Returns text, not bytes. Speechmatics reads text frames as control
    /// messages and binary frames as audio. Send this as bytes and the service
    /// treats the start message itself as the first chunk of audio, then
    /// refuses the stream for starting the handshake with audio.
    public func startMessage() -> String {
        let message = StartRecognition(
            audioFormat: .init(sampleRate: Int(CaptureFormat.sampleRate)),
            transcriptionConfig: .init(
                language: language,
                enablePartials: enablePartials,
                maxDelay: maxDelay,
                speakerDiarizationConfig: .init(maxSpeakers: maxSpeakers)
            )
        )
        let encoder = JSONEncoder()
        // Stable key order keeps the message easy to read in a log.
        encoder.outputFormatting = [.sortedKeys]
        return String(decoding: try! encoder.encode(message), as: UTF8.self)
    }
}

/// The wire shape of the `StartRecognition` message.
///
/// Kept as a type rather than a dictionary so a wrong key fails at compile time
/// instead of silently. See the Speechmatics real-time API reference.
struct StartRecognition: Encodable {
    let message = "StartRecognition"
    let audioFormat: AudioFormat
    let transcriptionConfig: TranscriptionConfig

    enum CodingKeys: String, CodingKey {
        case message
        case audioFormat = "audio_format"
        case transcriptionConfig = "transcription_config"
    }

    struct AudioFormat: Encodable {
        let type = "raw"
        /// The capture helper always hands us 16 kHz mono 16-bit little-endian.
        let encoding = "pcm_s16le"
        let sampleRate: Int

        enum CodingKeys: String, CodingKey {
            case type, encoding
            case sampleRate = "sample_rate"
        }
    }

    struct TranscriptionConfig: Encodable {
        let language: String
        let diarization = "speaker"
        let enablePartials: Bool
        let maxDelay: Double
        let speakerDiarizationConfig: SpeakerDiarizationConfig

        enum CodingKeys: String, CodingKey {
            case language, diarization
            case enablePartials = "enable_partials"
            case maxDelay = "max_delay"
            case speakerDiarizationConfig = "speaker_diarization_config"
        }
    }

    struct SpeakerDiarizationConfig: Encodable {
        let maxSpeakers: Int
        /// Stay with the current speaker unless someone else is clearly closer.
        /// Cuts the flipping between two similar voices.
        let preferCurrentSpeaker = true

        enum CodingKeys: String, CodingKey {
            case maxSpeakers = "max_speakers"
            case preferCurrentSpeaker = "prefer_current_speaker"
        }
    }
}

/// The message that says no more audio is coming.
///
/// It must carry the sequence number of the last audio chunk. The service
/// replies to each chunk with that number, and it rejects the message without
/// it, then never commits the words it still holds.
struct EndOfStream: Encodable {
    let message = "EndOfStream"
    let lastSeqNo: Int

    enum CodingKeys: String, CodingKey {
        case message
        case lastSeqNo = "last_seq_no"
    }

    /// The wire text for the end message. Text frame, like the start message.
    static func text(lastSeqNo: Int) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return String(decoding: try! encoder.encode(EndOfStream(lastSeqNo: lastSeqNo)), as: UTF8.self)
    }
}
