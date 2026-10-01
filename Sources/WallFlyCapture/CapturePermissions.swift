import AVFoundation
import CoreGraphics
import Foundation

/// Permission checks and requests for the two things capture needs.
///
/// Always check live. A saved flag goes stale the moment someone revokes access
/// in System Settings, and macOS lets them do that while the app runs.
public enum CapturePermissions {
    public static var microphoneGranted: Bool {
        AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
    }

    /// Asks the first time. Later runs return the stored answer straight away.
    public static func requestMicrophone() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            return true
        case .notDetermined:
            return await AVCaptureDevice.requestAccess(for: .audio)
        default:
            return false
        }
    }

    /// System audio needs Screen Recording approval.
    public static var screenRecordingGranted: Bool {
        CGPreflightScreenCaptureAccess()
    }

    /// Opens the prompt. macOS does not apply the answer until the app runs again,
    /// so treat the first call as a request, not a grant.
    @discardableResult
    public static func requestScreenRecording() -> Bool {
        CGRequestScreenCaptureAccess()
    }
}
