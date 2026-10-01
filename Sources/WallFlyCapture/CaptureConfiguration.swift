import Foundation

/// Which tracks to open, and how long to wait for them to wake up.
public struct CaptureConfiguration: Sendable {
    public var captureMicrophone: Bool
    public var captureSystemAudio: Bool
    /// Seconds to wait for the first buffer on each track before giving up.
    /// Both tracks normally deliver within a tenth of a second or two.
    public var startTimeout: Double

    public init(captureMicrophone: Bool = true,
                captureSystemAudio: Bool = true,
                startTimeout: Double = 5) {
        self.captureMicrophone = captureMicrophone
        self.captureSystemAudio = captureSystemAudio
        self.startTimeout = startTimeout
    }

    public static let `default` = CaptureConfiguration()

    /// Just the microphone. Useful for a quick check, and it needs no Screen
    /// Recording approval.
    public static let microphoneOnly = CaptureConfiguration(captureMicrophone: true,
                                                            captureSystemAudio: false)
}
