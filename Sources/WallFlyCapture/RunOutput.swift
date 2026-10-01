import Foundation
import os

/// The name of a run, taken from the moment it began.
///
/// Every file a run writes carries the same stamp, so two runs never overwrite
/// each other and everything from one run sorts together.
public enum RunStamp {
    /// ISO 8601 in UTC, with dashes in place of the colons. Finder shows a colon
    /// in a file name as a slash, so keep it out.
    public static func now(_ date: Date = Date()) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: date).replacingOccurrences(of: ":", with: "-")
    }
}

/// A problem opening a file a run writes.
public enum RunOutputError: Error, CustomStringConvertible {
    case couldNotOpen(path: String)

    public var description: String {
        switch self {
        case .couldNotOpen(let path): return "could not open \(path) for writing"
        }
    }
}

/// Writes 16-bit PCM into a WAV file as the audio arrives, so a long meeting
/// never sits in memory.
///
/// The header goes down first with sizes of zero, because nobody knows how long
/// a meeting will run. `close()` seeks back and fills the real sizes in, so the
/// file stays open for the whole run.
///
/// A write failure does not throw: there is no good moment to stop a meeting
/// over one. The first failure is kept, and `close()` returns it.
public final class WavWriter: @unchecked Sendable {
    /// Bytes of header in a WAV file that carries no extra chunks.
    public static let headerByteCount = 44

    public let path: String

    private let sampleRate: Int
    private let channels: Int
    private let bytesPerSample: Int

    /// `FileHandle` is not safe to share, but every use of it goes through this
    /// lock, so the unchecked conformance holds.
    private struct State: @unchecked Sendable {
        var handle: FileHandle?
        var audioBytes = 0
        var lastError: String?
    }

    /// The scoped lock is safe to call from `async` code, where a plain `NSLock`
    /// warns now and fails under Swift 6.
    private let state: OSAllocatedUnfairLock<State>

    public init(path: String,
                sampleRate: Double = CaptureFormat.sampleRate,
                channels: Int = CaptureFormat.channels,
                bytesPerSample: Int = CaptureFormat.bytesPerSample) throws {
        self.path = path
        self.sampleRate = Int(sampleRate)
        self.channels = channels
        self.bytesPerSample = bytesPerSample

        // Start the file at full header size, so audio always lands after the
        // header and the sizes can be patched in place at the end.
        FileManager.default.createFile(atPath: path, contents: Data(count: Self.headerByteCount))
        guard let handle = FileHandle(forUpdatingAtPath: path) else {
            throw RunOutputError.couldNotOpen(path: path)
        }
        try? handle.seek(toOffset: UInt64(Self.headerByteCount))
        self.state = OSAllocatedUnfairLock(initialState: State(handle: handle))
    }

    /// Adds audio. Empty data, and a closed file, are both fine.
    public func append(_ pcm: Data) {
        guard !pcm.isEmpty else { return }
        state.withLock { state in
            guard let handle = state.handle else { return }
            do {
                try handle.write(contentsOf: pcm)
                state.audioBytes += pcm.count
            } catch {
                if state.lastError == nil { state.lastError = "\(error)" }
            }
        }
    }

    /// Fills in the header sizes and closes the file. Safe to call twice.
    /// Returns the first failure, if any.
    @discardableResult
    public func close() -> String? {
        state.withLock { state in
            guard let handle = state.handle else { return state.lastError }
            state.handle = nil
            do {
                try handle.seek(toOffset: 0)
                try handle.write(contentsOf: header(audioByteCount: state.audioBytes))
                try handle.close()
            } catch {
                if state.lastError == nil { state.lastError = "\(error)" }
            }
            return state.lastError
        }
    }

    /// Seconds of audio written so far. Readable before `close()` too, which is
    /// what a live progress line wants.
    public var seconds: Double {
        let bytes = state.withLock { $0.audioBytes }
        return Double(bytes) / Double(sampleRate * channels * bytesPerSample)
    }

    /// Audio bytes written, not counting the header.
    public var audioByteCount: Int { state.withLock { $0.audioBytes } }

    /// The first failure, if any.
    public var lastError: String? { state.withLock { $0.lastError } }

    /// The 44 bytes in front of the audio: format, then the two sizes.
    private func header(audioByteCount: Int) -> Data {
        var file = Data()
        let blockAlign = channels * bytesPerSample
        let byteRate = sampleRate * blockAlign

        func append(_ text: String) { file.append(contentsOf: Array(text.utf8)) }
        func append32(_ number: Int) { withUnsafeBytes(of: UInt32(number).littleEndian) { file.append(contentsOf: $0) } }
        func append16(_ number: Int) { withUnsafeBytes(of: UInt16(number).littleEndian) { file.append(contentsOf: $0) } }

        append("RIFF")
        append32(36 + audioByteCount)
        append("WAVE")
        append("fmt ")
        append32(16)                                  // size of the format block
        append16(1)                                   // 1 means plain PCM
        append16(channels)
        append32(sampleRate)
        append32(byteRate)
        append16(blockAlign)
        append16(bytesPerSample * 8)
        append("data")
        append32(audioByteCount)
        return file
    }
}
