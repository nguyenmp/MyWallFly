import Foundation
import QuartzCore
import os

/// Opens the microphone and the system audio as two tracks and hands the rest
/// of the app mono 16 kHz PCM.
///
/// The two tracks run on different clocks and start at different moments. Both
/// are stamped with the host clock instead, and `start()` reports where each one
/// began on that shared clock. The rest of the app uses those offsets to line
/// the tracks up.
///
/// The offsets are good to about 20 ms. A buffer's arrival time runs late by
/// about one buffer, and the two tracks use different buffer sizes. That is
/// close enough to tell who spoke.
///
/// One instance runs one meeting. Make a new one for the next meeting.
public final class AudioCapture {
    public let configuration: CaptureConfiguration

    /// Frames arrive here, in the order each track produced them. Buffers hold
    /// until you read them, so subscribe before calling `start()`.
    public let frames: AsyncStream<AudioFrame>

    private let normalizer: PCMNormalizer
    private let continuation: AsyncStream<AudioFrame>.Continuation
    /// The scoped form of the lock is safe to call from `async` code. A plain
    /// `NSLock` there is a warning now and an error under Swift 6.
    private let running = OSAllocatedUnfairLock(initialState: false)

    private var microphone: MicrophoneTrack?
    private var system: SystemAudioTrack?

    public init(configuration: CaptureConfiguration = .default) throws {
        self.configuration = configuration
        self.normalizer = try PCMNormalizer()

        var captured: AsyncStream<AudioFrame>.Continuation?
        self.frames = AsyncStream<AudioFrame> { captured = $0 }
        self.continuation = captured!
    }

    /// Checks permissions, opens both tracks, and waits until each one has
    /// delivered its first buffer. Returns where each track began.
    public func start() async throws -> CaptureStart {
        let alreadyRunning = running.withLock { state -> Bool in
            defer { state = true }
            return state
        }
        guard !alreadyRunning else {
            throw CaptureError.alreadyRunning
        }

        if configuration.captureMicrophone {
            guard await CapturePermissions.requestMicrophone() else {
                throw CaptureError.microphoneDenied
            }
        }
        if configuration.captureSystemAudio {
            // System audio needs Screen Recording, and macOS will not grant it
            // from inside a running app. Ask, then let the caller try again.
            guard CapturePermissions.screenRecordingGranted else {
                CapturePermissions.requestScreenRecording()
                throw CaptureError.screenRecordingDenied
            }
        }

        if configuration.captureMicrophone {
            let track = try MicrophoneTrack(normalizer: normalizer)
            track.onFrame = { [weak self] frame in self?.continuation.yield(frame) }
            track.onError = { [weak self] error in self?.debugSink?(error.localizedDescription) }
            microphone = track
        }
        if configuration.captureSystemAudio {
            let track = SystemAudioTrack(normalizer: normalizer)
            try await track.open()
            track.onFrame = { [weak self] frame in self?.continuation.yield(frame) }
            track.onError = { [weak self] error in self?.debugSink?(error.localizedDescription) }
            system = track
        }

        microphone?.start()
        try await system?.start()

        let starts: [TrackStart]
        do {
            starts = try await waitForFirstBuffers()
        } catch {
            stopNow()
            throw error
        }

        let base = starts.map(\.hostTime).min() ?? CACurrentMediaTime()
        return CaptureStart(base: base, starts: starts)
    }

    /// Stops both tracks and closes the frame stream. Safe to call twice.
    public func stop() async {
        let wasRunning = running.withLock { state -> Bool in
            defer { state = false }
            return state
        }
        guard wasRunning else { return }
        microphone?.stop()
        await system?.stop()
        continuation.finish()
    }

    /// Set this to see what each track really sends, as raw format lines.
    /// Leave it nil in the app.
    public var debugLog: ((String) -> Void)? {
        get { debugSink }
        set { debugSink = newValue; normalizer.debugSink = newValue }
    }

    /// Kept next to `debugLog` so the tracks can report drops the same way.
    private var debugSink: ((String) -> Void)?

    /// Live numbers for each track. Read them any time while capture runs.
    public func stats() -> CaptureStats {
        var tracks: [TrackStats] = []
        if let microphone { tracks.append(microphone.stats()) }
        if let system { tracks.append(system.stats()) }
        return CaptureStats(tracks: tracks,
                            discardedVideoFrames: system?.discardedVideoFrameCount() ?? 0)
    }

    // MARK: - Getting both tracks awake

    private func waitForFirstBuffers() async throws -> [TrackStart] {
        var pending: [(track: AudioTrack, read: () -> Double?)] = []
        if let microphone {
            pending.append((.microphone, { microphone.firstHostTime() }))
        }
        if let system {
            pending.append((.system, { system.firstHostTime() }))
        }

        let deadline = Date().addingTimeInterval(configuration.startTimeout)
        var found: [AudioTrack: Double] = [:]

        while found.count < pending.count {
            for waiting in pending where found[waiting.track] == nil {
                if let host = waiting.read() {
                    found[waiting.track] = host
                }
            }
            if found.count == pending.count { break }
            if Date() >= deadline {
                let missing = pending.map(\.track).filter { found[$0] == nil }
                throw CaptureError.trackDidNotStart(missing)
            }
            try await Task.sleep(nanoseconds: 10_000_000)
        }

        let base = found.values.min() ?? 0
        return found
            .map { TrackStart(track: $0.key, hostTime: $0.value, offset: $0.value - base) }
            .sorted { order(of: $0.track) < order(of: $1.track) }
    }

    private func order(of track: AudioTrack) -> Int {
        AudioTrack.allCases.firstIndex(of: track) ?? 0
    }

    private func stopNow() {
        microphone?.stop()
        if let system {
            Task { await system.stop() }
        }
        running.withLock { $0 = false }
    }
}
