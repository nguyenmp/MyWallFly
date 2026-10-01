import AVFoundation
import CoreMedia
import Foundation
import QuartzCore

/// Captures the microphone as its own track.
///
/// We ask the device for 16 kHz mono 16-bit PCM, so the busiest path needs no
/// conversion. That is a request, not a promise, so `PCMNormalizer` still checks
/// what actually arrives.
final class MicrophoneTrack: NSObject {
    let track: AudioTrack = .microphone

    private let normalizer: PCMNormalizer
    private let session = AVCaptureSession()
    private let queue = DispatchQueue(label: "wallfly.capture.microphone")
    private let lock = NSLock()

    private var firstHost: Double?
    private var firstPresentationTime: Double?
    private var driftSeconds: Double = 0
    private var frameCount = 0
    private var deliveredSeconds: Double = 0
    private var droppedCount = 0
    private var lastErrorDescription: String?

    /// Called on the capture queue with every frame. The rest of the app listens here.
    var onFrame: ((AudioFrame) -> Void)?
    /// Called when a buffer could not be read, so the reason does not vanish.
    var onError: ((Error) -> Void)?

    init(normalizer: PCMNormalizer) throws {
        self.normalizer = normalizer
        super.init()
        try open()
    }

    private func open() throws {
        guard let device = AVCaptureDevice.default(for: .audio) else {
            throw CaptureError.noMicrophoneDevice
        }
        let input = try AVCaptureDeviceInput(device: device)
        let output = AVCaptureAudioDataOutput()
        output.audioSettings = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: CaptureFormat.sampleRate,
            AVNumberOfChannelsKey: CaptureFormat.channels,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ]
        // The output holds its delegate weakly. This object is the delegate, so
        // whoever owns this track must keep it alive. A delegate held in a local
        // variable dies at the end of that scope and no audio ever arrives.
        output.setSampleBufferDelegate(self, queue: queue)

        session.beginConfiguration()
        session.addInput(input)
        session.addOutput(output)
        session.commitConfiguration()
    }

    func start() {
        session.startRunning()
    }

    func stop() {
        guard session.isRunning else { return }
        session.stopRunning()
    }

    /// Host clock seconds at the first buffer, or nil if none has arrived yet.
    func firstHostTime() -> Double? {
        lock.lock(); defer { lock.unlock() }
        return firstHost
    }

    func stats() -> TrackStats {
        lock.lock(); defer { lock.unlock() }
        return TrackStats(track: track,
                          frames: frameCount,
                          seconds: deliveredSeconds,
                          drift: driftSeconds,
                          dropped: droppedCount,
                          lastError: lastErrorDescription)
    }
}

extension MicrophoneTrack: AVCaptureAudioDataOutputSampleBufferDelegate {
    func captureOutput(_ output: AVCaptureOutput,
                       didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        let host = CACurrentMediaTime()
        let presentationTime = CMSampleBufferGetPresentationTimeStamp(sampleBuffer).seconds

        let frame: AudioFrame
        do {
            let pcm = try normalizer.pcm(from: sampleBuffer)
            frame = AudioFrame(track: track, hostTime: host, pcm: pcm)
        } catch {
            // A dropped buffer leaves a hole in the transcript. Count it and
            // keep going rather than tear down the meeting.
            lock.lock()
            droppedCount += 1
            lastErrorDescription = error.localizedDescription
            lock.unlock()
            onError?(error)
            return
        }

        lock.lock()
        if firstHost == nil {
            firstHost = host
            firstPresentationTime = presentationTime
        }
        frameCount += 1
        deliveredSeconds += frame.seconds
        // Host clock moved this far; the device's own clock moved that far. The
        // difference is drift, and it is why the two tracks need one shared clock.
        let hostElapsed = host - (firstHost ?? host)
        let deviceElapsed = presentationTime - (firstPresentationTime ?? presentationTime)
        driftSeconds = hostElapsed - deviceElapsed
        lock.unlock()

        onFrame?(frame)
    }
}
