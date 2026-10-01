import Foundation
import Testing
@testable import WallFlyCapture

@Suite("Writing a WAV file as audio arrives")
struct WavWriterTests {
    /// A folder of its own for one test, so two tests never share a file.
    private func temporaryFolder() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("wallfly-wav-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func path(in folder: URL) -> String {
        folder.appendingPathComponent("track.wav").path
    }

    /// Reads a little-endian number out of the header.
    private func number(_ bytes: [UInt8], at offset: Int, width: Int) -> UInt32 {
        var value: UInt32 = 0
        for index in 0..<width {
            value |= UInt32(bytes[offset + index]) << (8 * index)
        }
        return value
    }

    @Test("fills in the two sizes when it closes")
    func fillsInSizes() throws {
        let file = path(in: temporaryFolder())
        let writer = try WavWriter(path: file)
        writer.append(Data(count: 3_200))            // a tenth of a second
        #expect(writer.close() == nil)

        let bytes = [UInt8](try Data(contentsOf: URL(fileURLWithPath: file)))
        #expect(bytes.count == WavWriter.headerByteCount + 3_200)
        #expect(String(decoding: bytes[0..<4], as: UTF8.self) == "RIFF")
        #expect(String(decoding: bytes[8..<12], as: UTF8.self) == "WAVE")
        #expect(String(decoding: bytes[36..<40], as: UTF8.self) == "data")
        // The RIFF size counts everything after its own field: 36 + the audio.
        #expect(number(bytes, at: 4, width: 4) == UInt32(36 + 3_200))
        #expect(number(bytes, at: 40, width: 4) == 3_200)
    }

    @Test("describes the format the capture helper produces")
    func describesTheFormat() throws {
        let file = path(in: temporaryFolder())
        let writer = try WavWriter(path: file)
        writer.close()

        let bytes = [UInt8](try Data(contentsOf: URL(fileURLWithPath: file)))
        #expect(number(bytes, at: 20, width: 2) == 1)              // plain PCM
        #expect(number(bytes, at: 22, width: 2) == 1)              // mono
        #expect(number(bytes, at: 24, width: 4) == 16_000)         // sample rate
        #expect(number(bytes, at: 34, width: 2) == 16)             // bits per sample
    }

    @Test("makes a file that opens when no audio ever arrives")
    func emptyFileIsStillAFile() throws {
        let file = path(in: temporaryFolder())
        let writer = try WavWriter(path: file)
        writer.close()

        let bytes = [UInt8](try Data(contentsOf: URL(fileURLWithPath: file)))
        #expect(bytes.count == WavWriter.headerByteCount)
        #expect(number(bytes, at: 40, width: 4) == 0)
    }

    @Test("ignores audio that arrives after it closes")
    func ignoresLateAudio() throws {
        let file = path(in: temporaryFolder())
        let writer = try WavWriter(path: file)
        writer.append(Data(count: 100))
        writer.close()
        writer.append(Data(count: 100))              // too late to matter
        writer.close()                               // and safe to call twice

        let bytes = [UInt8](try Data(contentsOf: URL(fileURLWithPath: file)))
        #expect(bytes.count == WavWriter.headerByteCount + 100)
        #expect(number(bytes, at: 40, width: 4) == 100)
    }

    @Test("counts the seconds it has written so far")
    func countsSeconds() throws {
        let writer = try WavWriter(path: path(in: temporaryFolder()))
        writer.append(Data(count: 3_200))
        #expect(writer.seconds == 0.1)
        #expect(writer.audioByteCount == 3_200)
        writer.close()
    }

    @Test("takes empty audio without complaint")
    func takesEmptyAudio() throws {
        let writer = try WavWriter(path: path(in: temporaryFolder()))
        writer.append(Data())
        #expect(writer.audioByteCount == 0)
        writer.close()
    }
}

@Suite("Naming a run")
struct RunStampTests {
    @Test("reads as a time a file name can hold")
    func readsAsATime() {
        let stamp = RunStamp.now(Date(timeIntervalSince1970: 0))
        #expect(stamp == "1970-01-01T00-00-00Z")
    }

    @Test("keeps colons out, because Finder shows them as slashes")
    func hasNoColons() {
        let stamp = RunStamp.now()
        #expect(!stamp.contains(":"))
        #expect(stamp.hasSuffix("Z"))
    }
}
