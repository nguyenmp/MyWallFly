import Foundation

/// A meeting read back from a run's folder.
///
/// A run keeps two records of the same meeting: `transcript.txt` for a person to
/// read, and `turns.jsonl` for the app to read. This prefers the record, because
/// it is exact, and falls back to the transcript for folders written before the
/// record existed. The fallback has to guess when each line ended.
public struct SavedMeeting: Sendable {
    /// Which record the turns came from.
    public enum Source: String, Sendable {
        /// `turns.jsonl`: exactly what the provider settled.
        case record
        /// `transcript.txt`: the human-readable transcript, with ends guessed.
        case transcript

        public var description: String {
            switch self {
            case .record: return "turns.jsonl (exact)"
            case .transcript: return "transcript.txt (ends guessed)"
            }
        }
    }

    public enum LoadError: Error, CustomStringConvertible {
        case nothingToShow(URL)

        public var description: String {
            switch self {
            case .nothingToShow(let folder):
                return "\(folder.lastPathComponent) holds no turns: looked for turns.jsonl and transcript.txt"
            }
        }
    }

    public let folder: URL
    /// The folder's name. The page shows it as the title.
    public let label: String
    public let turns: [LiveTurn]
    public let source: Source
    /// How many changes the page had made when the run ended.
    public let changes: Int

    /// Where the page's changes live, and where its new ones go.
    public var editsURL: URL { folder.appendingPathComponent("edits.json") }

    /// Reads a run's folder.
    public static func load(from folder: URL) throws -> SavedMeeting {
        let edits = countEdits(at: folder.appendingPathComponent("edits.json"))
        if let exact = readRecord(at: folder.appendingPathComponent("turns.jsonl")) {
            return SavedMeeting(folder: folder, label: folder.lastPathComponent,
                                turns: exact, source: .record, changes: edits)
        }
        let guessed = readTranscript(at: folder.appendingPathComponent("transcript.txt"))
        guard !guessed.isEmpty else { throw LoadError.nothingToShow(folder) }
        return SavedMeeting(folder: folder, label: folder.lastPathComponent,
                            turns: guessed, source: .transcript, changes: edits)
    }

    // MARK: - The record

    /// One `LiveTurn` per line, in the order they settled.
    private static func readRecord(at url: URL) -> [LiveTurn]? {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        let decoder = JSONDecoder()
        var turns: [LiveTurn] = []
        for line in text.split(separator: "\n") where !line.isEmpty {
            if let turn = try? decoder.decode(LiveTurn.self, from: Data(line.utf8)) {
                turns.append(turn)
            }
        }
        return turns.isEmpty ? nil : turns
    }

    // MARK: - The transcript

    /// The transcript is one line per settled piece:
    ///
    ///     [   4.68s] mic S2: this is Daniel.
    ///
    /// It holds each line's start, not its end, so a line's end is the next line
    /// on the same track. The last line on a track has nothing after it, so its
    /// end is guessed from how long the words take to say.
    private static func readTranscript(at url: URL) -> [LiveTurn] {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        var turns = text.split(separator: "\n").compactMap { parseLine(String($0)) }
        guard !turns.isEmpty else { return [] }
        turns = fillEnds(turns)
        turns.sort { $0.t0 < $1.t0 || ($0.t0 == $1.t0 && $0.track < $1.track) }
        return turns
    }

    /// Reads one `[   4.68s] mic S2: the words` line. Anything else, like the
    /// `…` line for words still being spoken, is not a settled turn.
    static func parseLine(_ raw: String) -> LiveTurn? {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("["), let close = trimmed.firstIndex(of: "]") else { return nil }
        let stamp = trimmed[trimmed.index(after: trimmed.startIndex)..<close]
            .replacingOccurrences(of: "s", with: "")
            .trimmingCharacters(in: .whitespaces)
        guard let seconds = Double(stamp) else { return nil }

        let rest = trimmed[trimmed.index(after: close)...].trimmingCharacters(in: .whitespaces)
        guard let colon = rest.firstIndex(of: ":") else { return nil }
        let head = rest[..<colon].trimmingCharacters(in: .whitespaces)
        let words = rest[rest.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        let parts = head.split(separator: " ")
        guard parts.count >= 2, !words.isEmpty else { return nil }
        let track = parts[0] == "sys" ? "system" : String(parts[0])
        return LiveTurn(track: track, label: parts[1...].joined(separator: " "),
                        t0: Int((seconds * 1000).rounded()), t1: 0, text: words)
    }

    /// Gives every line an end, using the next line on its track.
    private static func fillEnds(_ turns: [LiveTurn]) -> [LiveTurn] {
        var byTrack: [String: [Int]] = [:]
        for (index, turn) in turns.enumerated() { byTrack[turn.track, default: []].append(index) }

        var out = turns
        for indexes in byTrack.values {
            let ordered = indexes.sorted { turns[$0].t0 < turns[$1].t0 }
            for (position, index) in ordered.enumerated() {
                let start = turns[index].t0
                let next = position + 1 < ordered.count ? turns[ordered[position + 1]].t0 : nil
                let end: Int
                if let next, next > start {
                    end = next
                } else {
                    // About 2.7 words a second, and never less than a second.
                    let words = turns[index].text.split(separator: " ").count
                    end = start + max(1000, words * 370)
                }
                out[index] = LiveTurn(track: turns[index].track, label: turns[index].label,
                                      t0: start, t1: end, text: turns[index].text)
            }
        }
        return out
    }

    // MARK: - The changes

    private static func countEdits(at url: URL) -> Int {
        guard let data = try? Data(contentsOf: url),
              let list = try? JSONSerialization.jsonObject(with: data) as? [Any] else { return 0 }
        return list.count
    }
}
