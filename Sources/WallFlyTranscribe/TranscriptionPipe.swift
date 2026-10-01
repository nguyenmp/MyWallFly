import Foundation
import os
import WallFlyCapture

/// One line of transcript, placed on the meeting clock.
public struct TranscriptionEvent: Sendable {
    public let track: AudioTrack
    /// Starts and ends are seconds from the start of the meeting. Both tracks
    /// share this timeline because the pipe pads each stream with silence up to
    /// that track's offset.
    public let segment: TranscriptSegment
}

/// Joins the capture helper to Speechmatics.
///
/// One stream per track, so the service diarizes each input on its own. The two
/// streams start at the same meeting instant: the pipe sends silence at the
/// front of whichever track began later. After that, a timestamp from the
/// service is already a meeting timestamp.
///
/// This costs one stream per track. The Speechmatics trial allows two at once,
/// so one meeting uses the whole trial quota. Paying for more streams, or
/// mixing the tracks, is still an open question in the README.
public struct TranscriptionPipe: Sendable {
    public struct Report: Sendable {
        public var framesSent = 0
        public var framesDropped = 0
        public var segments = 0
        /// Why the last frame was dropped, if any was.
        public var lastError: String?
    }

    public let config: SpeechmaticsConfig
    public let tracks: [AudioTrack]

    /// Every event from the service, for chasing a problem. Leave it nil in the app.
    public var debugLog: (@Sendable (String) -> Void)?

    public init(config: SpeechmaticsConfig, tracks: [AudioTrack] = AudioTrack.allCases) {
        self.config = config
        self.tracks = tracks
    }

    /// Opens every track's stream, forwards audio, and returns when the frame
    /// stream ends and the service has sent the last words.
    ///
    /// `onEvent` runs on a background task, so it must be safe to call from
    /// anywhere and should not block.
    @discardableResult
    public func run(captureStart: CaptureStart,
                    frames: AsyncStream<AudioFrame>,
                    onEvent: @escaping @Sendable (TranscriptionEvent) -> Void) async throws -> Report {
        var clients: [AudioTrack: SpeechmaticsClient] = [:]
        for track in tracks {
            let client = SpeechmaticsClient(config: config)
            try await client.start()
            clients[track] = client
        }

        // Line both streams up on the meeting clock before any real audio.
        for track in tracks {
            guard let client = clients[track], let start = captureStart.start(of: track) else { continue }
            let pad = Self.leadingSilenceByteCount(offset: start.offset)
            if pad > 0 {
                try await client.send(Self.silence(byteCount: pad))
            }
        }

        let report = ReportBox()
        let eventPumps = Task {
            await withTaskGroup(of: Void.self) { group in
                for (track, client) in clients {
                    group.addTask {
                        var turn = TurnAccumulator()
                        func emit(_ segment: TranscriptSegment) {
                            report.countSegment()
                            onEvent(TranscriptionEvent(track: track, segment: segment))
                        }
                        for await event in client.events {
                            debugLog?("\(track.rawValue): \(Self.name(of: event))")
                            switch event {
                            case .final(let words):
                                for segment in turn.add(words) { emit(segment) }
                            case .endOfUtterance:
                                if let segment = turn.flush() { emit(segment) }
                            case .partial(let words):
                                // The open line carries the settled words too,
                                // or the start of a long sentence would vanish.
                                if let segment = turn.openLine(with: words) { emit(segment) }
                            default:
                                break
                            }
                        }
                        // The stream ended. Anything still open is a real line.
                        if let segment = turn.flush() { emit(segment) }
                        debugLog?("\(track.rawValue): event stream closed")
                    }
                }
            }
        }

        for await frame in frames {
            guard let client = clients[frame.track] else { continue }
            do {
                try await client.send(frame.pcm)
                report.countSent()
            } catch {
                report.countDropped(error.localizedDescription)
            }
        }

        for client in clients.values {
            await client.finish()
        }
        _ = await eventPumps.value

        for client in clients.values {
            await client.close()
        }
        return report.snapshot()
    }

    /// A short name for an event, for the debug log.
    static func name(of event: SpeechmaticsEvent) -> String {
        switch event {
        case .recognising(let id): return "started \(id)"
        case .partial(let words): return "partial (\(words.count) words)"
        case .final(let words): return "final (\(words.count) words)"
        case .endOfTranscript: return "end of transcript"
        case .endOfUtterance: return "end of utterance"
        case .info(let text): return "info: \(text)"
        case .warning(let text): return "warning: \(text)"
        case .failure(let text): return "failure: \(text)"
        case .ignored(let name): return "ignored \(name)"
        }
    }

    /// How many bytes of silence to put in front of a track that started late,
    /// so its stream begins at the meeting start.
    public static func leadingSilenceByteCount(offset: Double) -> Int {
        guard offset > 0 else { return 0 }
        return Int(offset * Double(CaptureFormat.bytesPerSecond))
    }

    static func silence(byteCount: Int) -> Data {
        Data(count: byteCount)
    }
}

/// Collects report numbers from several tasks. The scoped lock is safe to call
/// from `async` code, where a plain `NSLock` warns now and fails under Swift 6.
final class ReportBox: @unchecked Sendable {
    private let state = OSAllocatedUnfairLock(initialState: TranscriptionPipe.Report())

    func countSent() {
        state.withLock { $0.framesSent += 1 }
    }

    func countDropped(_ reason: String) {
        state.withLock {
            $0.framesDropped += 1
            $0.lastError = reason
        }
    }

    func countSegment() {
        state.withLock { $0.segments += 1 }
    }

    func snapshot() -> TranscriptionPipe.Report {
        state.withLock { $0 }
    }
}
