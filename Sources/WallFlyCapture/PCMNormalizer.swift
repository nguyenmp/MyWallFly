import AVFoundation
import CoreMedia
import Foundation

/// Turns a captured audio buffer into the one format the rest of the app wants:
/// mono 16 kHz 16-bit PCM.
///
/// The microphone already arrives in that shape, so it takes the fast path.
/// System audio arrives at 48 kHz stereo, so it gets mixed down and resampled.
final class PCMNormalizer {
    private let outputFormat: AVAudioFormat
    private let reportLock = NSLock()
    private var reportedFormats: Set<String> = []

    /// Set this to see what each track really sends. Leave it nil in the app.
    var debugSink: ((String) -> Void)?

    init() throws {
        guard let format = AVAudioFormat(commonFormat: .pcmFormatInt16,
                                         sampleRate: CaptureFormat.sampleRate,
                                         channels: AVAudioChannelCount(CaptureFormat.channels),
                                         interleaved: true) else {
            throw CaptureError.unsupportedAudioFormat("could not build the 16 kHz mono output format")
        }
        outputFormat = format
    }

    /// Pulls the audio out of a sample buffer as mono 16 kHz 16-bit PCM.
    func pcm(from sampleBuffer: CMSampleBuffer) throws -> Data {
        let shape = try shape(of: sampleBuffer)
        guard shape.frameCount > 0 else { return Data() }

        let audio = try readAudio(from: sampleBuffer, shape: shape)
        report(shape, peak: audio.peak, raw: rawPeak(of: sampleBuffer))

        if let direct = audio.direct {
            return direct
        }
        return try resample(audio.mono, from: shape.sampleRate)
    }

    // MARK: - What the buffer says it is

    private struct Shape {
        let sampleRate: Double
        let channels: Int
        let bits: Int
        let isFloat: Bool
        let isNonInterleaved: Bool
        let frameCount: Int

        /// True when the buffer is already mono 16 kHz 16-bit PCM.
        var isTargetFormat: Bool {
            sampleRate == CaptureFormat.sampleRate && channels == 1 && bits == 16 && !isFloat
        }

        var description: String {
            let kind = isFloat ? "float" : "int"
            let layout = isNonInterleaved ? "non-interleaved" : "interleaved"
            return "\(Int(sampleRate)) Hz, \(channels) ch, \(bits)-bit \(kind), \(layout), \(frameCount) frames"
        }
    }

    private func shape(of sampleBuffer: CMSampleBuffer) throws -> Shape {
        guard let description = CMSampleBufferGetFormatDescription(sampleBuffer),
              let pointer = CMAudioFormatDescriptionGetStreamBasicDescription(description) else {
            throw CaptureError.unsupportedAudioFormat("the buffer carried no format description")
        }
        let asbd = pointer.pointee
        return Shape(sampleRate: asbd.mSampleRate,
                     channels: Int(asbd.mChannelsPerFrame),
                     bits: Int(asbd.mBitsPerChannel),
                     isFloat: (asbd.mFormatFlags & kAudioFormatFlagIsFloat) != 0,
                     isNonInterleaved: (asbd.mFormatFlags & kAudioFormatFlagIsNonInterleaved) != 0,
                     frameCount: CMSampleBufferGetNumSamples(sampleBuffer))
    }

    // MARK: - Reading the samples

    /// Returns the audio as mono floats, plus the raw bytes when the buffer is
    /// already in the format we want.
    private func readAudio(from sampleBuffer: CMSampleBuffer,
                           shape: Shape) throws -> (mono: [Float], peak: Float, direct: Data?) {
        guard let description = CMSampleBufferGetFormatDescription(sampleBuffer),
              let pointer = CMAudioFormatDescriptionGetStreamBasicDescription(description),
              let format = AVAudioFormat(streamDescription: pointer) else {
            throw CaptureError.unsupportedAudioFormat("could not read the captured format")
        }
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format,
                                            frameCapacity: AVAudioFrameCount(shape.frameCount)) else {
            throw CaptureError.unsupportedAudioFormat("could not hold \(shape.frameCount) frames of \(format)")
        }
        buffer.frameLength = AVAudioFrameCount(shape.frameCount)

        let status = CMSampleBufferCopyPCMDataIntoAudioBufferList(sampleBuffer,
                                                                  at: 0,
                                                                  frameCount: Int32(shape.frameCount),
                                                                  into: buffer.mutableAudioBufferList)
        guard status == noErr else {
            throw CaptureError.unsupportedAudioFormat("could not copy the audio out of the sample buffer (\(status))")
        }

        if shape.isTargetFormat, let channel = buffer.int16ChannelData?[0] {
            let bytes = Int(buffer.frameLength) * CaptureFormat.bytesPerSample
            return ([], peak(ofInt16: channel, count: bytes / 2), Data(bytes: channel, count: bytes))
        }

        let mono = try monoSamples(from: buffer)
        let loudest = mono.reduce(Float(0)) { max($0, abs($1)) }
        return (mono, loudest, nil)
    }

    private func peak(ofInt16 samples: UnsafeMutablePointer<Int16>, count: Int) -> Float {
        var loudest: Int16 = 0
        for index in 0..<count {
            let value = samples[index]
            loudest = max(loudest, value == Int16.min ? Int16.max : abs(value))
        }
        return Float(loudest) / 32_768
    }

    private func report(_ shape: Shape, peak: Float, raw: (bytes: Int, peak: Float)?) {
        guard let debugSink else { return }
        let key = shape.description
        reportLock.lock()
        let isNew = reportedFormats.insert(key).inserted
        reportLock.unlock()
        guard isNew else { return }
        var line = "\(key) — loudest sample \(String(format: "%.4f", peak)) of full scale"
        if let raw {
            // Read the bytes straight off the sample buffer. This says whether a
            // silent track is really silent, or whether our copy lost the audio.
            line += ", straight off the buffer \(raw.bytes) bytes peaking at \(String(format: "%.4f", raw.peak))"
        }
        debugSink(line)
    }

    /// The loudest sample in the raw sample buffer, read without any conversion.
    private func rawPeak(of sampleBuffer: CMSampleBuffer) -> (bytes: Int, peak: Float)? {
        guard let block = CMSampleBufferGetDataBuffer(sampleBuffer) else { return nil }
        var lengthAtOffset = 0
        var totalLength = 0
        var pointer: UnsafeMutablePointer<Int8>?
        let status = CMBlockBufferGetDataPointer(block,
                                                 atOffset: 0,
                                                 lengthAtOffsetOut: &lengthAtOffset,
                                                 totalLengthOut: &totalLength,
                                                 dataPointerOut: &pointer)
        guard status == kCMBlockBufferNoErr, let pointer, lengthAtOffset == totalLength else { return nil }
        let count = totalLength / MemoryLayout<Float>.size
        guard count > 0 else { return (totalLength, 0) }
        let samples = UnsafeRawPointer(pointer).assumingMemoryBound(to: Float.self)
        var loudest: Float = 0
        for index in 0..<count { loudest = max(loudest, abs(samples[index])) }
        return (totalLength, loudest)
    }

    // MARK: - Mixing down to mono

    /// Averages every channel into one, keeping the sample rate and using floats
    /// so the arithmetic does not clip.
    private func monoSamples(from buffer: AVAudioPCMBuffer) throws -> [Float] {
        let frames = Int(buffer.frameLength)
        let channels = Int(buffer.format.channelCount)
        guard frames > 0, channels > 0 else { return [] }
        var mono = [Float](repeating: 0, count: frames)

        // Read every input shape the audio core can hand us: float or integer,
        // packed together or one array per channel.
        func read(_ value: (Int, Int) -> Float) {
            for channel in 0..<channels {
                for frame in 0..<frames {
                    mono[frame] += value(channel, frame)
                }
            }
            let scale = 1 / Float(channels)
            for frame in 0..<frames { mono[frame] *= scale }
        }

        switch (buffer.format.commonFormat, buffer.format.isInterleaved) {
        case (.pcmFormatFloat32, true):
            guard let base = buffer.floatChannelData?[0] else { throw unsupported(buffer) }
            read { channel, frame in base[frame * channels + channel] }
        case (.pcmFormatFloat32, false):
            guard let data = buffer.floatChannelData else { throw unsupported(buffer) }
            read { channel, frame in data[channel][frame] }
        case (.pcmFormatInt16, true):
            guard let base = buffer.int16ChannelData?[0] else { throw unsupported(buffer) }
            read { channel, frame in Float(base[frame * channels + channel]) / 32_768 }
        case (.pcmFormatInt16, false):
            guard let data = buffer.int16ChannelData else { throw unsupported(buffer) }
            read { channel, frame in Float(data[channel][frame]) / 32_768 }
        case (.pcmFormatInt32, true):
            guard let base = buffer.int32ChannelData?[0] else { throw unsupported(buffer) }
            read { channel, frame in Float(base[frame * channels + channel]) / 2_147_483_648 }
        case (.pcmFormatInt32, false):
            guard let data = buffer.int32ChannelData else { throw unsupported(buffer) }
            read { channel, frame in Float(data[channel][frame]) / 2_147_483_648 }
        default:
            throw unsupported(buffer)
        }
        return mono
    }

    private func unsupported(_ buffer: AVAudioPCMBuffer) -> CaptureError {
        .unsupportedAudioFormat("unhandled sample shape: \(buffer.format.commonFormat), interleaved \(buffer.format.isInterleaved)")
    }

    // MARK: - Dropping to 16 kHz

    /// Resamples mono floats down to 16 kHz and packs them as 16-bit PCM.
    /// Only the rate changes here. Mixing to mono happened before this.
    private func resample(_ samples: [Float], from inputRate: Double) throws -> Data {
        guard !samples.isEmpty else { return Data() }
        guard inputRate != CaptureFormat.sampleRate else {
            return pack(samples)
        }
        guard let inputFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                              sampleRate: inputRate,
                                              channels: 1,
                                              interleaved: false),
              let input = AVAudioPCMBuffer(pcmFormat: inputFormat,
                                           frameCapacity: AVAudioFrameCount(samples.count)) else {
            throw CaptureError.unsupportedAudioFormat("could not build a mono buffer at \(inputRate) Hz")
        }
        input.frameLength = AVAudioFrameCount(samples.count)
        if let channel = input.floatChannelData?[0] {
            samples.withUnsafeBufferPointer { source in
                channel.update(from: source.baseAddress!, count: samples.count)
            }
        }

        guard let converter = AVAudioConverter(from: inputFormat, to: outputFormat) else {
            throw CaptureError.unsupportedAudioFormat("could not convert \(inputRate) Hz to \(CaptureFormat.sampleRate) Hz")
        }
        let ratio = CaptureFormat.sampleRate / inputRate
        let capacity = AVAudioFrameCount(Double(samples.count) * ratio) + 64
        guard let output = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity) else {
            throw CaptureError.unsupportedAudioFormat("could not hold the converted audio")
        }

        var handedOver = false
        var conversionError: NSError?
        converter.convert(to: output, error: &conversionError) { _, status in
            if handedOver {
                status.pointee = .noDataNow
                return nil
            }
            handedOver = true
            status.pointee = .haveData
            return input
        }
        if let conversionError {
            throw CaptureError.unsupportedAudioFormat("conversion failed: \(conversionError.localizedDescription)")
        }
        guard let channel = output.int16ChannelData?[0] else {
            throw CaptureError.unsupportedAudioFormat("conversion produced no audio")
        }
        return Data(bytes: channel, count: Int(output.frameLength) * CaptureFormat.bytesPerSample)
    }

    /// Packs mono floats as 16-bit PCM when the rate already matches.
    private func pack(_ samples: [Float]) -> Data {
        var bytes = Data(capacity: samples.count * CaptureFormat.bytesPerSample)
        for value in samples {
            let clipped = max(-1, min(1, value))
            let scaled = Int16(clipped * 32_767)
            withUnsafeBytes(of: scaled.littleEndian) { bytes.append(contentsOf: $0) }
        }
        return bytes
    }
}
