import Foundation

/// Everything that can go wrong before audio starts flowing.
public enum CaptureError: Error, LocalizedError, Sendable {
    case microphoneDenied
    case screenRecordingDenied
    case noMicrophoneDevice
    case noDisplay
    /// These tracks never delivered a buffer. Usually a missing permission.
    case trackDidNotStart([AudioTrack])
    case systemAudioFailed(String)
    case unsupportedAudioFormat(String)
    case alreadyRunning

    public var errorDescription: String? {
        switch self {
        case .microphoneDenied:
            return "Microphone access was refused. Grant it in System Settings, then try again."
        case .screenRecordingDenied:
            return "Screen Recording is not granted. System audio needs it. Grant it in System Settings, then try again."
        case .noMicrophoneDevice:
            return "No microphone found."
        case .noDisplay:
            return "No display found to capture system audio from."
        case .trackDidNotStart(let tracks):
            let names = tracks.map(\.rawValue).joined(separator: ", ")
            return "These tracks delivered no audio: \(names). Check the permission each one needs."
        case .systemAudioFailed(let reason):
            return "System audio capture failed: \(reason)"
        case .unsupportedAudioFormat(let reason):
            return "Could not read captured audio: \(reason)"
        case .alreadyRunning:
            return "Capture is already running."
        }
    }
}
