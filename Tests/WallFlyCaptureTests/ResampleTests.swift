import Foundation
import Testing
@testable import WallFlyCapture

/// Guards the step that drops system audio from 48 kHz to 16 kHz.
///
/// The bug this covers: a converter built fresh for every buffer has no memory
/// of the audio before it, so it drops the tail of each one. ScreenCaptureKit
/// sends 960-frame buffers at 48 kHz, and a fresh converter turned each into 314
/// samples instead of 320. The track came out 1.9% short, every timestamp slid
/// earlier by the same 1.9%, and two people who took turns looked like they
/// talked over each other.
@Suite("Dropping audio to 16 kHz")
struct ResampleTests {
    /// The rate system audio arrives at.
    private let inputRate: Double = 48_000
    /// Frames in one buffer, which is 20 ms and what ScreenCaptureKit sends.
    private let bufferFrames = 960

    /// A tone at half of full scale, the shape a speaking voice roughly makes.
    /// `rate` is the rate it is recorded at, which is 48 kHz for system audio.
    private func tone(seconds: Double, hertz: Double = 1_000, rate: Double? = nil) -> [Float] {
        let rate = rate ?? inputRate
        let count = Int(rate * seconds)
        return (0..<count).map { index in
            0.5 * Float(sin(2 * Double.pi * hertz * Double(index) / rate))
        }
    }

    /// Runs a tone through the normalizer in the buffer size capture really
    /// sends, and returns the 16 kHz PCM that comes out.
    private func throughTheNormalizer(_ source: [Float]) throws -> Data {
        let normalizer = try PCMNormalizer()
        var pcm = Data()
        var offset = 0
        while offset + bufferFrames <= source.count {
            pcm += try normalizer.resample(Array(source[offset..<(offset + bufferFrames)]),
                                           from: inputRate)
            offset += bufferFrames
        }
        return pcm
    }

    /// The 16-bit samples in `pcm`, scaled to the range -1 to 1.
    private func samples(_ pcm: Data) -> [Double] {
        pcm.withUnsafeBytes { raw in
            raw.bindMemory(to: Int16.self).map { Double(Int16(littleEndian: $0)) / 32_768 }
        }
    }

    /// The loudest frequency in `samples` near `target`, to the nearest half
    /// hertz. A plain scan, because one steady tone needs nothing cleverer.
    private func loudestFrequency(_ samples: [Double], near target: Double) -> Double {
        // A second of audio is enough to tell 1000 Hz from 1019 Hz.
        let window = Array(samples.prefix(Int(CaptureFormat.sampleRate)))
        var best = (hertz: 0.0, power: -1.0)
        for step in 0..<121 {
            let hertz = target - 20 + Double(step) / 2
            var real = 0.0
            var imaginary = 0.0
            for (index, sample) in window.enumerated() {
                let angle = 2 * Double.pi * hertz * Double(index) / CaptureFormat.sampleRate
                real += sample * cos(angle)
                imaginary += sample * sin(angle)
            }
            let power = real * real + imaginary * imaginary
            if power > best.power { best = (hertz, power) }
        }
        return best.hertz
    }

    @Test("keeps every sample when the buffers are the size capture sends")
    func keepsEverySample() throws {
        let constant: Float = 0.25
        let source = [Float](repeating: constant, count: Int(inputRate) * 10)
        let pcm = try throughTheNormalizer(source)

        // Ten seconds at 48 kHz is ten seconds at 16 kHz, which is 160,000
        // samples. The converter holds back a handful of frames for its filter,
        // so allow a few. The old code lost 3,040 of them.
        let expected = 160_000
        let got = pcm.count / CaptureFormat.bytesPerSample
        #expect(abs(got - expected) <= 16,
                "got \(got) samples, expected about \(expected)")
    }

    @Test("keeps the pitch")
    func keepsPitch() throws {
        let pcm = try throughTheNormalizer(tone(seconds: 2, hertz: 1_000))
        let hertz = loudestFrequency(samples(pcm), near: 1_000)

        // Losing samples makes the tone play fast, which raises the pitch. The
        // old code turned 1,000 Hz into 1,019 Hz.
        #expect(abs(hertz - 1_000) <= 1,
                "a 1000 Hz tone came out at \(hertz) Hz")
    }

    @Test("a rate the audio already has passes straight through")
    func alreadyAtSixteenKilohertz() throws {
        let normalizer = try PCMNormalizer()
        let source = tone(seconds: 1, hertz: 440, rate: CaptureFormat.sampleRate)
        let pcm = try normalizer.resample(source, from: CaptureFormat.sampleRate)

        // The fast path copies the samples, so nothing is dropped and nothing
        // is converted.
        #expect(pcm.count == source.count * CaptureFormat.bytesPerSample)
        #expect(abs(loudestFrequency(samples(pcm), near: 440) - 440) <= 1)
    }
}
