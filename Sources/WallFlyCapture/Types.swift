import Foundation

/// The one format every track leaves this module in. The rest of the app can
/// assume it and stop worrying about what the hardware gave us.
public enum CaptureFormat {
    /// Sample rate in hertz. Speech needs no more, and the provider charges by the minute.
    public static let sampleRate: Double = 16_000
    /// Mono. The provider wants one channel per track.
    public static let channels: Int = 1
    /// 16-bit signed integers, little-endian.
    public static let bytesPerSample = 2
    /// Target bytes per second of audio, handy for buffer sizing.
    public static let bytesPerSecond = Int(sampleRate) * channels * bytesPerSample
}

/// Which input a frame came from.
public enum AudioTrack: String, Sendable, CaseIterable {
    case microphone
    case system
}

/// One chunk of audio on its way to the rest of the app.
public struct AudioFrame: Sendable {
    public let track: AudioTrack
    /// Host clock seconds when this chunk arrived. See `CaptureClock`.
    public let hostTime: Double
    /// Mono 16-bit little-endian PCM at `CaptureFormat.sampleRate`.
    public let pcm: Data

    public init(track: AudioTrack, hostTime: Double, pcm: Data) {
        self.track = track
        self.hostTime = hostTime
        self.pcm = pcm
    }

    public var sampleCount: Int { pcm.count / CaptureFormat.bytesPerSample }
    public var seconds: Double { Double(sampleCount) / CaptureFormat.sampleRate }
}

/// Where one track began, measured on the shared clock.
public struct TrackStart: Sendable {
    public let track: AudioTrack
    /// Host clock seconds at this track's first buffer.
    public let hostTime: Double
    /// Seconds after the earliest track. Use this to line the tracks up.
    public let offset: Double

    public init(track: AudioTrack, hostTime: Double, offset: Double) {
        self.track = track
        self.hostTime = hostTime
        self.offset = offset
    }
}

/// What `AudioCapture.start()` returns once both tracks are alive.
public struct CaptureStart: Sendable {
    /// Host clock seconds of the earliest track. Meeting time starts here.
    public let base: Double
    public let starts: [TrackStart]

    public init(base: Double, starts: [TrackStart]) {
        self.base = base
        self.starts = starts
    }

    public func start(of track: AudioTrack) -> TrackStart? {
        starts.first { $0.track == track }
    }
}

/// Live numbers for one track.
public struct TrackStats: Sendable {
    public let track: AudioTrack
    /// Buffers turned into frames.
    public let frames: Int
    /// Seconds of audio delivered so far.
    public let seconds: Double
    /// Host clock minus this track's own clock, in seconds. If this grows over a
    /// long meeting, the two tracks will not line up on their own.
    public let drift: Double
    /// Buffers we could not convert or keep. Anything above zero means a hole in
    /// the transcript.
    public let dropped: Int
    /// Why the last buffer was dropped, if any was.
    public let lastError: String?
}

/// Live numbers for the whole capture.
public struct CaptureStats: Sendable {
    public let tracks: [TrackStats]
    /// Video frames ScreenCaptureKit sent next to the audio. We asked for the
    /// smallest possible picture and throw every frame away.
    public let discardedVideoFrames: Int
}
