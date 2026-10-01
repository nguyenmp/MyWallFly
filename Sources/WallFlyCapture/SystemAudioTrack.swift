import AVFoundation
import CoreMedia
import Foundation
import QuartzCore
import ScreenCaptureKit

/// Captures system audio, the sound every other app makes, as its own track.
///
/// ScreenCaptureKit is the only way to get system audio, and it refuses to give
/// us audio alone: a small video stream always runs alongside. We ask for the
/// smallest picture at the slowest rate and throw every frame away.
final class SystemAudioTrack: NSObject {
    let track: AudioTrack = .system

    private let normalizer: PCMNormalizer
    private let queue = DispatchQueue(label: "wallfly.capture.system")
    private let lock = NSLock()
    private var stream: SCStream?

    private var firstHost: Double?
    private var firstPresentationTime: Double?
    private var driftSeconds: Double = 0
    private var frameCount = 0
    private var deliveredSeconds: Double = 0
    private var droppedCount = 0
    private var discardedVideoFrames = 0
    private var streamError: Error?
    private var lastErrorDescription: String?

    var onFrame: ((AudioFrame) -> Void)?
    /// Called when a buffer could not be read, so the reason does not vanish.
    var onError: ((Error) -> Void)?

    init(normalizer: PCMNormalizer) {
        self.normalizer = normalizer
        super.init()
    }

    /// Finds a screen to hang the capture on and opens the stream. This needs
    /// Screen Recording approval, and it is the call that fails without it.
    func open() async throws {
        let content: SCShareableContent
        do {
            content = try await SCShareableContent.current
        } catch {
            throw CaptureError.systemAudioFailed("could not list capture sources: \(error.localizedDescription)")
        }
        guard let display = content.displays.first else {
            throw CaptureError.noDisplay
        }

        let configuration = SCStreamConfiguration()
        configuration.capturesAudio = true
        configuration.sampleRate = 48_000
        configuration.channelCount = 2
        // Leave our own sound out, so we never record ourselves.
        configuration.excludesCurrentProcessAudio = true
        configuration.width = 2
        configuration.height = 2
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: 1)
        configuration.queueDepth = 5
        configuration.showsCursor = false

        let ourBundle = Bundle.main.bundleIdentifier
        let excluding = content.applications.filter { app in
            guard let ourBundle else { return false }
            return app.bundleIdentifier == ourBundle
        }
        let filter = SCContentFilter(display: display,
                                     excludingApplications: excluding,
                                     exceptingWindows: [])

        let newStream = SCStream(filter: filter, configuration: configuration, delegate: self)
        do {
            try newStream.addStreamOutput(self, type: .audio, sampleHandlerQueue: queue)
            try newStream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        } catch {
            throw CaptureError.systemAudioFailed("could not attach a stream output: \(error.localizedDescription)")
        }
        stream = newStream
    }

    func start() async throws {
        guard let stream else {
            throw CaptureError.systemAudioFailed("the stream was never opened")
        }
        do {
            try await withCheckedThrowingContinuation { (done: CheckedContinuation<Void, Error>) in
                stream.startCapture { error in
                    if let error {
                        done.resume(throwing: error)
                    } else {
                        done.resume()
                    }
                }
            }
        } catch {
            throw CaptureError.systemAudioFailed("could not start capture: \(error.localizedDescription)")
        }
    }

    func stop() async {
        guard let stream else { return }
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            stream.stopCapture { _ in done.resume() }
        }
        self.stream = nil
    }

    func firstHostTime() -> Double? {
        lock.lock(); defer { lock.unlock() }
        return firstHost
    }

    func discardedVideoFrameCount() -> Int {
        lock.lock(); defer { lock.unlock() }
        return discardedVideoFrames
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

extension SystemAudioTrack: SCStreamOutput {
    func stream(_ stream: SCStream,
                didOutputSampleBuffer buffer: CMSampleBuffer,
                of type: SCStreamOutputType) {
        guard type == .audio else {
            // ScreenCaptureKit sends video whether we want it or not. Count it
            // and drop it, so the cost of the wasted frames stays visible.
            lock.lock(); discardedVideoFrames += 1; lock.unlock()
            return
        }

        let host = CACurrentMediaTime()
        let presentationTime = CMSampleBufferGetPresentationTimeStamp(buffer).seconds

        let frame: AudioFrame
        do {
            let pcm = try normalizer.pcm(from: buffer)
            frame = AudioFrame(track: track, hostTime: host, pcm: pcm)
        } catch {
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
        let hostElapsed = host - (firstHost ?? host)
        let deviceElapsed = presentationTime - (firstPresentationTime ?? presentationTime)
        driftSeconds = hostElapsed - deviceElapsed
        lock.unlock()

        onFrame?(frame)
    }
}

extension SystemAudioTrack: SCStreamDelegate {
    func stream(_ stream: SCStream, didStopWithError error: Error) {
        // The provider sockets are not the only thing that drops. Say what
        // happened so the app can decide whether to buffer or give up.
        lock.lock(); streamError = error; lock.unlock()
    }
}
