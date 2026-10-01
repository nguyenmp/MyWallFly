import Foundation

/// One word, number, or punctuation mark the service heard.
public struct TranscriptWord: Sendable, Equatable {
    public let content: String
    /// Seconds from the start of this stream. See `TranscriptionPipe` for why
    /// that equals the meeting clock.
    public let start: Double
    public let end: Double
    /// A label like `S1`. Punctuation carries none.
    public let speaker: String?
    /// Punctuation joins the text with no space in front of it.
    public let isPunctuation: Bool

    public init(content: String, start: Double, end: Double,
                speaker: String?, isPunctuation: Bool) {
        self.content = content
        self.start = start
        self.end = end
        self.speaker = speaker
        self.isPunctuation = isPunctuation
    }
}

/// A run of words from one speaker, with no one else in between.
public struct TranscriptSegment: Sendable, Equatable {
    public let speaker: String?
    public let start: Double
    public let end: Double
    public let text: String
    /// Partial text may still change. Final text is settled.
    public let isFinal: Bool

    public init(speaker: String?, start: Double, end: Double, text: String, isFinal: Bool) {
        self.speaker = speaker
        self.start = start
        self.end = end
        self.text = text
        self.isFinal = isFinal
    }
}

/// What a client reports as it reads the socket.
public enum SpeechmaticsEvent: Sendable {
    /// The service accepted the start message and is ready for audio.
    case recognising(id: String)
    /// Words so far. The next partial replaces this one.
    case partial([TranscriptWord])
    /// A settled stretch of words. Append it.
    case final([TranscriptWord])
    case endOfTranscript
    /// The service heard a pause. The current speaker's turn is over.
    case endOfUtterance
    case info(String)
    case warning(String)
    case failure(String)
    /// A message we do not act on, like `AudioAdded`.
    case ignored(String)
}

public enum SpeechmaticsError: Error, CustomStringConvertible {
    case startTimedOut
    case rejected(String)

    public var description: String {
        switch self {
        case .startTimedOut:
            return "Speechmatics never confirmed the start. Check the key and the network."
        case .rejected(let reason):
            return "Speechmatics refused the stream: \(reason)"
        }
    }
}

/// Turns a server message into an event. Kept separate from the socket so it is
/// easy to test against recorded messages.
public enum TranscriptParser {
    public static func event(fromJSON data: Data) throws -> SpeechmaticsEvent {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let message = root["message"] as? String else {
            let text = String(data: data, encoding: .utf8) ?? "<not text>"
            throw SpeechmaticsError.rejected("unreadable message: \(text)")
        }

        switch message {
        case "RecognitionStarted":
            return .recognising(id: root["id"] as? String ?? "unknown")
        case "AddPartialTranscript":
            return .partial(words(from: root["results"]))
        case "AddTranscript":
            return .final(words(from: root["results"]))
        case "EndOfTranscript":
            return .endOfTranscript
        case "EndOfUtterance":
            return .endOfUtterance
        case "Info":
            return .info(reason(from: root))
        case "Warning":
            return .warning(reason(from: root))
        case "Error":
            return .failure(reason(from: root))
        default:
            return .ignored(message)
        }
    }

    /// Pulls the words out of a `results` array. Takes the top alternative of
    /// each item, which is the one the service believes.
    static func words(from results: Any?) -> [TranscriptWord] {
        guard let items = results as? [[String: Any]] else { return [] }
        return items.compactMap { item in
            let type = item["type"] as? String ?? "word"
            guard let alternatives = item["alternatives"] as? [[String: Any]],
                  let best = alternatives.first,
                  let content = best["content"] as? String,
                  !content.isEmpty else { return nil }
            let start = number(item["start_time"]) ?? 0
            let end = number(item["end_time"]) ?? start
            return TranscriptWord(content: content,
                                  start: start,
                                  end: end,
                                  speaker: best["speaker"] as? String,
                                  isPunctuation: type == "punctuation")
        }
    }

    private static func reason(from root: [String: Any]) -> String {
        if let reason = root["reason"] as? String { return reason }
        if let type = root["type"] as? String { return type }
        return "no reason given"
    }

    /// JSON numbers arrive as `NSNumber`, which bridges to both `Double` and
    /// `Int`. `as? Double` alone misses whole numbers in some payloads.
    private static func number(_ value: Any?) -> Double? {
        if let double = value as? Double { return double }
        if let int = value as? Int { return Double(int) }
        return nil
    }
}

/// Joins words into runs, one per speaker. This is what a transcript line is.
public enum TranscriptSegmenter {
    public static func segments(from words: [TranscriptWord], isFinal: Bool) -> [TranscriptSegment] {
        var segments: [TranscriptSegment] = []
        var started = false
        var speaker: String?
        var start: Double = 0
        var end: Double = 0
        var text = ""

        func flush() {
            guard !text.isEmpty else { return }
            segments.append(TranscriptSegment(speaker: speaker,
                                              start: start,
                                              end: end,
                                              text: text,
                                              isFinal: isFinal))
            text = ""
            end = 0
        }

        for word in words {
            if word.isPunctuation {
                // Punctuation belongs to whatever came before it, and carries no
                // speaker of its own. Drop it if nothing came before.
                if started { text += word.content }
                continue
            }
            if !started {
                started = true
                speaker = word.speaker
                start = word.start
            } else if word.speaker != speaker {
                flush()
                speaker = word.speaker
                start = word.start
            }
            text += text.isEmpty ? word.content : " " + word.content
            end = max(end, word.end)
        }
        flush()
        return segments
    }
}

/// Collects final words into one line per speaker turn.
///
/// The service commits a final every second or two, so one sentence arrives as
/// several finals. A transcript wants one line per turn, not per fragment. Two
/// things end a turn: the service says the speaker paused (`EndOfUtterance`), or
/// a different speaker starts talking.
public struct TurnAccumulator {
    private var words: [TranscriptWord] = []

    public init() {}

    /// Adds a final batch. Returns a finished line when the speaker changed
    /// part way through the batch.
    public mutating func add(_ batch: [TranscriptWord]) -> [TranscriptSegment] {
        if let current = speaker,
           let incoming = batch.first(where: { !$0.isPunctuation })?.speaker,
           current != incoming {
            let finished = flush()
            words.append(contentsOf: batch)
            return finished.map { [$0] } ?? []
        }
        words.append(contentsOf: batch)
        return []
    }

    /// Everything settled so far, joined the way a line reads.
    public var settledText: String {
        TranscriptSegmenter.segments(from: words, isFinal: false).map(\.text).joined(separator: " ")
    }

    /// The open line: the settled words, plus the parts of a partial that are
    /// not already in them.
    ///
    /// A partial on its own loses the start of the sentence. The service trims
    /// the words it has already committed off the front of every partial, so a
    /// long sentence arrives as a sliding window: "Hello. This is Samantha",
    /// then "This is Samantha speaking", then "Samantha speaking. We are". The
    /// word times say where the settled words end and the new ones begin.
    public func openLine(with partial: [TranscriptWord]) -> TranscriptSegment? {
        let settledEnd = words.map(\.end).max() ?? 0
        let fresh = partial.filter { $0.start >= settledEnd - 0.02 }
        let freshParts = TranscriptSegmenter.segments(from: fresh, isFinal: false)
        let freshText = freshParts.map(\.text).joined(separator: " ")

        let settled = settledText
        let text = freshText.isEmpty ? settled
            : (settled.isEmpty ? freshText : settled + " " + freshText)
        guard !text.isEmpty else { return nil }

        let start = words.first?.start ?? freshParts.first?.start ?? 0
        let end = max(freshParts.last?.end ?? 0, settledEnd)
        let speaker = words.first(where: { !$0.isPunctuation })?.speaker ?? freshParts.first?.speaker
        return TranscriptSegment(speaker: speaker, start: start, end: end, text: text, isFinal: false)
    }

    /// Closes the current line. Returns nil when there is nothing to close.
    public mutating func flush() -> TranscriptSegment? {
        guard !words.isEmpty else { return nil }
        let pending = words
        words = []
        let parts = TranscriptSegmenter.segments(from: pending, isFinal: true)
        guard let first = parts.first, let last = parts.last else { return nil }
        return TranscriptSegment(speaker: first.speaker,
                                 start: first.start,
                                 end: last.end,
                                 text: parts.map(\.text).joined(separator: " "),
                                 isFinal: true)
    }

    private var speaker: String? {
        words.first(where: { !$0.isPunctuation })?.speaker
    }
}
