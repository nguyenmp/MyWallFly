// Spike: can we capture the microphone and system audio as two tracks, and can
// we record where each track starts on one shared clock?
//
// Throwaway code. Not wired into the app. Run it, read the numbers, delete it.

import AVFoundation
import CoreGraphics
import CoreMedia
import Foundation
import QuartzCore
import ScreenCaptureKit

let runSecondsArgs = CommandLine.arguments.dropFirst()
let runSecondsArg = runSecondsArgs.first { Double($0) != nil }
let runSeconds = runSecondsArg.flatMap(Double.init) ?? 20.0
// "mic-only" skips system audio, so the spike can run without Screen Recording.
let micOnly = CommandLine.arguments.contains("mic-only")

func secs(_ value: Double?) -> String {
    guard let value else { return "never" }
    return String(format: "%.3f", value)
}

func signed(_ value: Double) -> String {
    String(format: "%+.3f", value)
}

func describe(_ buffer: CMSampleBuffer) -> String {
    guard let format = CMSampleBufferGetFormatDescription(buffer),
          let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(format) else {
        return "unknown format"
    }
    let rate = Int(asbd.pointee.mSampleRate)
    let channels = asbd.pointee.mChannelsPerFrame
    let bits = asbd.pointee.mBitsPerChannel
    let isFloat = (asbd.pointee.mFormatFlags & kAudioFormatFlagIsFloat) != 0
    let frames = CMSampleBufferGetNumSamples(buffer)
    return "\(rate) Hz, \(channels) ch, \(bits)-bit \(isFloat ? "float" : "int"), \(frames) frames"
}

// One track's timing. Both tracks stamp each buffer with the host clock
// (CACurrentMediaTime), so the gap between their first buffers is the offset.
final class Track {
    let name: String
    private let lock = NSLock()
    private var firstPTS: Double?
    private var firstHost: Double?
    private var buffers = 0
    private var lastPrinted = 0.0
    private var latestDrift = 0.0

    init(_ name: String) { self.name = name }

    func startHost() -> Double? {
        lock.lock(); defer { lock.unlock() }
        return firstHost
    }

    func drift() -> Double {
        lock.lock(); defer { lock.unlock() }
        return latestDrift
    }

    func count() -> Int {
        lock.lock(); defer { lock.unlock() }
        return buffers
    }

    func note(_ buffer: CMSampleBuffer) {
        let host = CACurrentMediaTime()
        let pts = CMSampleBufferGetPresentationTimeStamp(buffer).seconds

        lock.lock(); defer { lock.unlock() }

        if firstPTS == nil {
            firstPTS = pts
            firstHost = host
            print("[\(name)] first buffer: host \(secs(host)) s, pts \(secs(pts)) s")
            print("[\(name)] format: \(describe(buffer))")
        }

        buffers += 1
        let hostElapsed = host - (firstHost ?? host)
        let ptsElapsed = pts - (firstPTS ?? pts)
        latestDrift = hostElapsed - ptsElapsed

        if hostElapsed - lastPrinted >= 2.0 {
            lastPrinted = hostElapsed
            print("[\(name)] \(secs(hostElapsed)) s in: \(buffers) buffers, clock drift \(signed(latestDrift)) s")
        }
    }
}

final class MicrophoneOutput: NSObject, AVCaptureAudioDataOutputSampleBufferDelegate {
    let track: Track
    init(_ track: Track) { self.track = track }

    func captureOutput(_ output: AVCaptureOutput,
                       didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        track.note(sampleBuffer)
    }
}

final class SystemOutput: NSObject, SCStreamOutput {
    let track: Track
    private(set) var videoFrames = 0

    init(_ track: Track) { self.track = track }

    func stream(_ stream: SCStream,
                didOutputSampleBuffer buffer: CMSampleBuffer,
                of type: SCStreamOutputType) {
        switch type {
        case .audio:
            track.note(buffer)
        case .screen:
            // ScreenCaptureKit always sends video next to the audio. We asked
            // for 2x2 at one frame a second, and we throw every frame away.
            videoFrames += 1
        default:
            break
        }
    }
}

// The SDK hands us completion-handler versions, so wrap them to get errors back.

func startCapture(_ stream: SCStream) async throws {
    try await withCheckedThrowingContinuation { (done: CheckedContinuation<Void, Error>) in
        stream.startCapture { error in
            if let error {
                done.resume(throwing: error)
            } else {
                done.resume()
            }
        }
    }
}

func stopCapture(_ stream: SCStream) async {
    await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
        stream.stopCapture { _ in done.resume() }
    }
}

func requestMicrophone() async -> Bool {
    switch AVCaptureDevice.authorizationStatus(for: .audio) {
    case .authorized:
        return true
    case .notDetermined:
        return await AVCaptureDevice.requestAccess(for: .audio)
    default:
        return false
    }
}

print("MyWallFly capture spike — running for \(secs(runSeconds)) s")

// Check Screen Recording live. A saved flag goes stale the moment a user
// revokes it in System Settings.
if !micOnly, !CGPreflightScreenCaptureAccess() {
    print("Screen Recording is not granted yet. Asking now.")
    CGRequestScreenCaptureAccess()
    print("Grant it in System Settings, then run this again.")
}

guard await requestMicrophone() else {
    print("Microphone access was refused. Grant it in System Settings, then run this again.")
    exit(1)
}

var content: SCShareableContent?
if !micOnly {
    do {
        content = try await SCShareableContent.current
    } catch {
        print("Could not list capture sources: \(error)")
        print("This usually means Screen Recording is not granted.")
        exit(1)
    }
}

// Mic-only runs have no display at all, so keep this optional.
let display: SCDisplay? = content?.displays.first

if micOnly {
    print("Mic-only run: skipping system audio.")
} else if display == nil {
    print("No display found to capture system audio from.")
    exit(1)
}

let micTrack = Track("mic")
let systemTrack = Track("system")

// --- Microphone: ask for the format we plan to send, 16 kHz mono int16. ---

let micQueue = DispatchQueue(label: "spike.mic")
let session = AVCaptureSession()
guard let micDevice = AVCaptureDevice.default(for: .audio) else {
    print("No microphone found.")
    exit(1)
}

// The output holds its delegate weakly, so keep the delegate alive up here.
// A local one dies at the end of the scope below and no buffers ever arrive.
let micDelegate = MicrophoneOutput(micTrack)

do {
    let input = try AVCaptureDeviceInput(device: micDevice)
    let output = AVCaptureAudioDataOutput()
    output.audioSettings = [
        AVFormatIDKey: kAudioFormatLinearPCM,
        AVSampleRateKey: 16000.0,
        AVNumberOfChannelsKey: 1,
        AVLinearPCMBitDepthKey: 16,
        AVLinearPCMIsFloatKey: false,
        AVLinearPCMIsBigEndianKey: false,
        AVLinearPCMIsNonInterleaved: false,
    ]
    output.setSampleBufferDelegate(micDelegate, queue: micQueue)

    session.beginConfiguration()
    session.addInput(input)
    session.addOutput(output)
    session.commitConfiguration()
} catch {
    print("Could not open the microphone: \(error)")
    exit(1)
}

// --- System audio: one display mix, 48 kHz stereo, small video thrown away. ---

let systemQueue = DispatchQueue(label: "spike.system")
let systemOutput = SystemOutput(systemTrack)
var stream: SCStream?

if let display, let content {
    let config = SCStreamConfiguration()
    config.capturesAudio = true
    config.sampleRate = 48000
    config.channelCount = 2
    config.excludesCurrentProcessAudio = true
    config.width = 2
    config.height = 2
    config.minimumFrameInterval = CMTime(value: 1, timescale: 1)
    config.queueDepth = 5
    config.showsCursor = false

    // Leave our own app out of the mix, so we never record our own output.
    let us = content.applications.filter { $0.bundleIdentifier == Bundle.main.bundleIdentifier }
    let filter = SCContentFilter(display: display, excludingApplications: us, exceptingWindows: [])
    let newStream = SCStream(filter: filter, configuration: config, delegate: nil)

    do {
        try newStream.addStreamOutput(systemOutput, type: .audio, sampleHandlerQueue: systemQueue)
        try newStream.addStreamOutput(systemOutput, type: .screen, sampleHandlerQueue: systemQueue)
    } catch {
        print("Could not attach a stream output: \(error)")
        exit(1)
    }
    stream = newStream
}

session.startRunning()

if let stream {
    do {
        try await startCapture(stream)
    } catch {
        print("Could not start system audio capture: \(error)")
        print("This usually means Screen Recording is not granted.")
        session.stopRunning()
        exit(1)
    }
    print("Both tracks are open. Talk, and play something out loud, so both tracks see audio.")
} else {
    print("Mic track is open. Talk, so the microphone sees audio.")
}

try? await Task.sleep(nanoseconds: UInt64(runSeconds * 1_000_000_000))

if let stream {
    await stopCapture(stream)
}
session.stopRunning()

// --- The two numbers this spike exists to produce. ---

let micStart = micTrack.startHost()
let systemStart = systemTrack.startHost()
let starts = [micStart, systemStart].compactMap { $0 }
let base = starts.min()

print("")
print("--- result ---")
print("mic:    \(micTrack.count()) buffers, started at \(secs(micStart)) s")
print("system: \(systemTrack.count()) buffers, started at \(secs(systemStart)) s")

if micOnly {
    print("Mic-only run, so there is no offset to report.")
} else if let base, let micStart, let systemStart {
    print("offset from the earlier track — mic \(signed(micStart - base)) s, system \(signed(systemStart - base)) s")
    print("Use that offset to line the two tracks up on one clock.")
} else {
    print("One track never delivered audio. Check the permission it needs.")
}

print("clock drift at the end — mic \(signed(micTrack.drift())) s, system \(signed(systemTrack.drift())) s")
print("video frames captured and thrown away: \(systemOutput.videoFrames)")
