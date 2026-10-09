import Foundation
import WallFlyCapture

/// Sends a whole recording to Speechmatics and gets the result back in one piece.
///
/// This is the non-realtime path. The real-time client pushes audio as it
/// happens, so an hour of audio takes an hour. This one uploads the file, waits
/// for the job, and reads the transcript. The provider works at its own speed,
/// so a long meeting comes back in minutes.
///
/// Use it for the end-of-meeting pass: the batch result is the tighter one, so
/// its speaker labels replace the live ones.
///
/// Run against the service on a short clip. The upload, the job status, and the
/// transcript all work as written. Two things the service taught us: the batch
/// settings have no `max_speakers`, and the transcript format must be asked for
/// as `json-v2`. Both are in the code below.
public struct SpeechmaticsBatchClient: Sendable {
    public let config: SpeechmaticsBatchConfig
    private let session: URLSession

    public init(config: SpeechmaticsBatchConfig) {
        self.config = config
        self.session = URLSession(configuration: .ephemeral)
    }

    /// Uploads the file at `url`, waits for the job, and returns transcript lines.
    ///
    /// `onProgress` reports each step, so a caller can say what is happening.
    public func transcribe(fileAt url: URL,
                          onProgress: (@Sendable (String) -> Void)? = nil) async throws -> [TranscriptSegment] {
        let id = try await submit(fileAt: url)
        onProgress?("job \(id) accepted")
        try await waitForJob(id, onProgress: onProgress)
        let words = try await words(forJob: id)
        return Self.segments(from: words, gap: config.turnGapSeconds)
    }

    // MARK: - Sending the file

    /// Uploads the audio and returns the id of the job the service made.
    private func submit(fileAt url: URL) async throws -> String {
        let boundary = "wallfly-\(UUID().uuidString)"
        let body = try Self.multipartBody(fileAt: url, boundary: boundary, config: config.configJSON())
        defer { try? FileManager.default.removeItem(at: body) }

        var request = URLRequest(url: config.jobsURL)
        request.httpMethod = "POST"
        request.setValue("Bearer \(config.apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

        let (data, response) = try await session.upload(for: request, fromFile: body)
        try Self.check(response, data: data)
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let id = root["id"] as? String else {
            throw SpeechmaticsBatchError.unreadable("the job reply held no id")
        }
        return id
    }

    /// Writes the multipart body to a temporary file and returns its path.
    ///
    /// The audio is copied a chunk at a time, so an hour-long recording never
    /// sits in memory, and `upload(for:fromFile:)` reads the file itself. The
    /// caller deletes the file when the upload is done.
    static func multipartBody(fileAt url: URL, boundary: String, config: String) throws -> URL {
        let temp = FileManager.default.temporaryDirectory
            .appendingPathComponent("wallfly-batch-\(UUID().uuidString).body")
        guard FileManager.default.createFile(atPath: temp.path, contents: nil) else {
            throw SpeechmaticsBatchError.unreadable("could not make room for the upload")
        }
        let out: FileHandle
        do {
            out = try FileHandle(forWritingTo: temp)
        } catch {
            throw SpeechmaticsBatchError.unreadable("could not open the upload file: \(error)")
        }
        defer { try? out.close() }

        var head = "--\(boundary)\r\n"
        head += "Content-Disposition: form-data; name=\"config\"\r\n"
        head += "Content-Type: application/json\r\n\r\n"
        head += config + "\r\n"
        head += "--\(boundary)\r\n"
        head += "Content-Disposition: form-data; name=\"data_file\"; filename=\"\(url.lastPathComponent)\"\r\n"
        head += "Content-Type: application/octet-stream\r\n\r\n"
        try out.write(contentsOf: Data(head.utf8))

        let source: FileHandle
        do {
            source = try FileHandle(forReadingFrom: url)
        } catch {
            throw SpeechmaticsBatchError.unreadable("could not read \(url.lastPathComponent): \(error)")
        }
        defer { try? source.close() }
        while let chunk = try source.read(upToCount: 1 << 20), !chunk.isEmpty {
            try out.write(contentsOf: chunk)
        }

        try out.write(contentsOf: Data("\r\n--\(boundary)--\r\n".utf8))
        return temp
    }

    // MARK: - Waiting for the job

    /// Asks the service whether the job is done, and keeps asking until it says so.
    ///
    /// A whole meeting takes a while, so one request is not enough. Each one
    /// carries `wait`, which asks the service to hold the request open for a few
    /// seconds rather than answering "still running" straight away. That is far
    /// fewer requests for the same answer.
    private func waitForJob(_ id: String, onProgress: (@Sendable (String) -> Void)?) async throws {
        let deadline = Date().addingTimeInterval(config.jobTimeoutSeconds)
        var reported = ""
        while true {
            let status = try await status(ofJob: id)
            switch status {
            case "done":
                onProgress?("job \(id) finished")
                return
            case "rejected", "expired", "deleted":
                throw SpeechmaticsBatchError.jobFailed(status)
            default:
                // Say this once, not on every request, or the log fills up.
                if status != reported {
                    onProgress?("job \(id) \(status)")
                    reported = status
                }
            }
            guard Date() < deadline else { throw SpeechmaticsBatchError.jobTimedOut }
            try await Task.sleep(nanoseconds: UInt64(config.waitFloorSeconds * 1_000_000_000))
        }
    }

    private func status(ofJob id: String) async throws -> String {
        let url = Self.addingWait(to: config.jobURL(id), seconds: config.pollSeconds)
        let (data, response) = try await session.data(for: request(for: url))
        try Self.check(response, data: data)
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let job = root["job"] as? [String: Any],
              let status = job["status"] as? String else {
            throw SpeechmaticsBatchError.unreadable("the job reply held no status")
        }
        return status
    }

    // MARK: - Reading the result

    /// Reads the finished transcript, with a few tries in case it has not landed.
    ///
    /// The job can say `done` a moment before the transcript is readable. Each
    /// try waits inside the request first, so three tries cover a good while.
    private func words(forJob id: String) async throws -> [TranscriptWord] {
        var lastFailure: Error = SpeechmaticsBatchError.unreadable("the transcript never arrived")
        for attempt in 1...config.transcriptAttempts {
            do {
                return try await fetchWords(forJob: id)
            } catch {
                lastFailure = error
                if attempt < config.transcriptAttempts {
                    try await Task.sleep(nanoseconds: 1_000_000_000)
                }
            }
        }
        throw lastFailure
    }

    private func fetchWords(forJob id: String) async throws -> [TranscriptWord] {
        // `json-v2` is the name the service wants. Plain `json` comes back as
        // "format in query should be one of [json-v2 txt srt]".
        let url = Self.addingQuery(to: config.transcriptURL(id),
                                   items: [URLQueryItem(name: "format", value: "json-v2"),
                                           URLQueryItem(name: "wait",
                                                        value: String(Int(config.pollSeconds)))])
        let (data, response) = try await session.data(for: request(for: url))
        try Self.check(response, data: data)
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw SpeechmaticsBatchError.unreadable("the transcript was not JSON")
        }
        // The result has the same shape as a real-time final, so one parser
        // reads both.
        return TranscriptParser.words(from: root["results"])
    }

    /// Adds `wait`, which asks the service to hold the request open until the
    /// job reaches a final state or the wait runs out.
    static func addingWait(to url: URL, seconds: Double) -> URL {
        addingQuery(to: url, items: [URLQueryItem(name: "wait", value: String(Int(seconds)))])
    }

    /// Adds query items to a url. An address that cannot be rebuilt comes back
    /// unchanged rather than lost.
    static func addingQuery(to url: URL, items: [URLQueryItem]) -> URL {
        guard var parts = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return url }
        parts.queryItems = (parts.queryItems ?? []) + items
        return parts.url ?? url
    }

    private func request(for url: URL) -> URLRequest {
        var request = URLRequest(url: url)
        request.setValue("Bearer \(config.apiKey)", forHTTPHeaderField: "Authorization")
        return request
    }

    /// Throws when the service answered with a problem, and repeats its reason.
    static func check(_ response: URLResponse, data: Data) throws {
        guard let http = response as? HTTPURLResponse,
              !(200..<300).contains(http.statusCode) else { return }
        let reason = Self.reason(in: data)
        throw SpeechmaticsBatchError.rejected(status: http.statusCode, reason: reason)
    }

    /// The service explains a refusal in `detail` or `reason`. Fall back to the
    /// raw text, so the message is never empty.
    static func reason(in data: Data) -> String {
        if let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let detail = root["detail"] as? String { return detail }
            if let reason = root["reason"] as? String { return reason }
        }
        let text = String(data: data, encoding: .utf8) ?? ""
        return text.isEmpty ? "no reason given" : text
    }

    /// Splits words into lines, one per run of one speaker.
    ///
    /// A batch transcript carries no utterance marks, so one person talking for
    /// five minutes would come back as one line. A pause longer than `gap` starts
    /// a new line instead, which keeps a speaker's turns readable.
    public static func segments(from words: [TranscriptWord], gap: Double) -> [TranscriptSegment] {
        var segments: [TranscriptSegment] = []
        var speaker: String?
        var start: Double = 0
        var end: Double = 0
        var text = ""

        func flush() {
            guard !text.isEmpty else { return }
            segments.append(TranscriptSegment(speaker: speaker,
                                              start: start,
                                              end: end,
                                              text: text,
                                              isFinal: true))
            text = ""
            end = 0
        }

        for word in words {
            if word.isPunctuation {
                // Punctuation belongs to the words before it and has no speaker.
                if !text.isEmpty {
                    text += word.content
                    end = max(end, word.end)
                }
                continue
            }
            let paused = !text.isEmpty && word.start - end > gap
            if text.isEmpty {
                speaker = word.speaker
                start = word.start
            } else if word.speaker != speaker || paused {
                flush()
                speaker = word.speaker
                start = word.start
            }
            text += text.isEmpty ? word.content : " " + word.content
            end = max(end, word.end)
        }
        flush()
        return segments
    }
}

/// Everything one batch job needs.
public struct SpeechmaticsBatchConfig: Sendable {
    public var apiKey: String
    public var region: SpeechmaticsRegion
    public var language: String
    /// How long to hint each status request should wait for the job. Bigger
    /// means fewer requests; smaller means a fresher answer.
    public var pollSeconds: Double
    /// The shortest gap between two status requests, after one comes back.
    public var waitFloorSeconds: Double
    /// How long to wait for the job before giving up.
    public var jobTimeoutSeconds: Double
    /// How many times to ask for the transcript before giving up.
    public var transcriptAttempts: Int
    /// A pause longer than this starts a new line.
    public var turnGapSeconds: Double

    /// Note: there is no speaker cap here. The batch settings refuse
    /// `max_speakers` ("Additional property max_speakers is not allowed"), unlike
    /// the real-time settings, which accept it.
    public init(apiKey: String,
                region: SpeechmaticsRegion = .eu,
                language: String = "en",
                pollSeconds: Double = 5,
                waitFloorSeconds: Double = 1,
                jobTimeoutSeconds: Double = 3600,
                transcriptAttempts: Int = 3,
                turnGapSeconds: Double = 2) {
        self.apiKey = apiKey
        self.region = region
        self.language = language
        self.pollSeconds = pollSeconds
        self.waitFloorSeconds = waitFloorSeconds
        self.jobTimeoutSeconds = jobTimeoutSeconds
        self.transcriptAttempts = transcriptAttempts
        self.turnGapSeconds = turnGapSeconds
    }

    /// A batch job runs on a different host from a real-time stream.
    public var baseURL: URL { URL(string: "https://\(region.batchHost)/v2")! }
    public var jobsURL: URL { baseURL.appendingPathComponent("jobs") }
    public func jobURL(_ id: String) -> URL { jobsURL.appendingPathComponent(id) }
    public func transcriptURL(_ id: String) -> URL {
        jobURL(id).appendingPathComponent("transcript")
    }

    /// The `config` part of the upload: what the file is and how to transcribe it.
    public func configJSON() -> String {
        let config: [String: Any] = [
            "type": "transcription",
            "transcription_config": [
                "language": language,
                "diarization": "speaker",
                "speaker_diarization_config": [
                    "prefer_current_speaker": true,
                ],
            ],
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: config, options: [.sortedKeys]) else {
            return "{}"
        }
        return String(decoding: data, as: UTF8.self)
    }
}

extension SpeechmaticsRegion {
    /// The host for the batch API.
    ///
    /// It differs from the real-time host, which only serves live streams.
    ///
    /// Europe is proven: a job was submitted and its transcript read from
    /// `asr.api.speechmatics.com`. The United States address answers, but this
    /// key was refused there with a 401, because a key belongs to one region.
    /// So check it with a United States key before you rely on it.
    public var batchHost: String {
        switch self {
        case .eu: return "asr.api.speechmatics.com"
        case .us: return "us2.asr.api.speechmatics.com"
        }
    }
}

public enum SpeechmaticsBatchError: Error, CustomStringConvertible {
    case rejected(status: Int, reason: String)
    case jobFailed(String)
    case jobTimedOut
    case unreadable(String)

    public var description: String {
        switch self {
        case .rejected(let status, let reason):
            return "Speechmatics refused the job (\(status)): \(reason)"
        case .jobFailed(let status):
            return "the job ended as \(status)"
        case .jobTimedOut:
            return "the job did not finish in time"
        case .unreadable(let reason):
            return reason
        }
    }
}
