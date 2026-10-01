import AVFoundation
import Foundation
import WallFlyCapture

/// Replays a recording as one track, in the same format capture produces.
///
/// This is a check tool, not a meeting path. It reads a whole file into memory,
/// which is fine for a clip and wrong for an hour of audio.
///
/// Handy for proving the provider path without a meeting: run `say` to make a
/// clip, then send it through. See the README.
public enum AudioFileSource {
    /// Seconds per frame. Matches what capture hands over, about 20 ms.
    public static let chunkSeconds = 0.02

    /// Reads any format the system can decode and returns 16 kHz mono 16-bit
    /// frames, ready for the same pipe capture uses.
    public static func frames(from url: URL, track: AudioTrack = .microphone) throws -> [AudioFrame] {
        let file = try AVAudioFile(forReading: url)
        let source = file.processingFormat
        let capacity = AVAudioFrameCount(max(file.length, 1))
        guard let input = AVAudioPCMBuffer(pcmFormat: source, frameCapacity: capacity) else {
            throw AudioFileError.couldNotAllocateBuffer
        }
        try file.read(into: input)
        guard input.frameLength > 0 else { return [] }

        guard let target = AVAudioFormat(commonFormat: .pcmFormatInt16,
                                        sampleRate: CaptureFormat.sampleRate,
                                        channels: 1,
                                        interleaved: true),
              let converter = AVAudioConverter(from: source, to: target) else {
            throw AudioFileError.couldNotConvert
        }

        let expected = Double(input.frameLength) * CaptureFormat.sampleRate / source.sampleRate
        let output = try makeBuffer(target, capacity: AVAudioFrameCount(expected) + 4096)

        var supplied = false
        var conversionError: NSError?
        let status = converter.convert(to: output, error: &conversionError) { _, outStatus in
            if supplied {
                outStatus.pointee = .endOfStream
                return nil
            }
            supplied = true
            outStatus.pointee = .haveData
            return input
        }
        guard status != .error else {
            throw AudioFileError.conversionFailed(conversionError?.localizedDescription ?? "no reason given")
        }

        guard let samples = output.int16ChannelData?[0] else {
            throw AudioFileError.couldNotConvert
        }
        let bytes = UnsafeRawBufferPointer(start: samples, count: Int(output.frameLength) * 2)
        return chunk(Data(bytes), track: track)
    }

    /// Cuts raw PCM into the frame size capture would have produced.
    static func chunk(_ pcm: Data, track: AudioTrack) -> [AudioFrame] {
        let chunkBytes = Int(chunkSeconds * Double(CaptureFormat.bytesPerSecond))
        guard chunkBytes > 0 else { return [] }
        var frames: [AudioFrame] = []
        var offset = 0
        while offset < pcm.count {
            let end = min(offset + chunkBytes, pcm.count)
            frames.append(AudioFrame(track: track,
                                     hostTime: Double(offset) / Double(CaptureFormat.bytesPerSecond),
                                     pcm: pcm.subdata(in: offset..<end)))
            offset = end
        }
        return frames
    }

    /// The start information the pipe expects, for a single track at zero.
    public static func captureStart(track: AudioTrack = .microphone) -> CaptureStart {
        CaptureStart(base: 0, starts: [TrackStart(track: track, hostTime: 0, offset: 0)])
    }

    private static func makeBuffer(_ format: AVAudioFormat, capacity: AVAudioFrameCount) throws -> AVAudioPCMBuffer {
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else {
            throw AudioFileError.couldNotAllocateBuffer
        }
        return buffer
    }
}

public enum AudioFileError: Error, CustomStringConvertible {
    case couldNotAllocateBuffer
    case couldNotConvert
    case conversionFailed(String)

    public var description: String {
        switch self {
        case .couldNotAllocateBuffer: return "could not make room for the audio"
        case .couldNotConvert: return "could not convert the file to 16 kHz mono"
        case .conversionFailed(let reason): return "could not convert the file: \(reason)"
        }
    }
}
