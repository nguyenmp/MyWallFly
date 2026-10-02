import Foundation
import Network
import WallFlyCapture

/// One settled transcript line, in the shape the page reads.
public struct LiveTurn: Codable, Sendable, Equatable {
    /// `mic` or `system`. The page labels the two tracks apart.
    public let track: String
    /// The provider's speaker label, like `S1`.
    public let label: String
    /// Milliseconds from the start of the meeting.
    public let t0: Int
    public let t1: Int
    public let text: String

    public init(track: String, label: String, t0: Int, t1: Int, text: String) {
        self.track = track
        self.label = label
        self.t0 = t0
        self.t1 = t1
        self.text = text
    }
}

/// The line still being spoken on one track. Its words can still change.
public struct LiveOpenLine: Codable, Sendable, Equatable {
    public let track: String
    public let label: String
    public let text: String

    public init(track: String, label: String, text: String) {
        self.track = track
        self.label = label
        self.text = text
    }
}

public enum LivePageError: Error, CustomStringConvertible {
    case pageMissing
    case couldNotStart(String)

    public var description: String {
        switch self {
        case .pageMissing:
            return "The transcript page is missing from the app bundle."
        case .couldNotStart(let reason):
            return "The transcript page did not start: \(reason)"
        }
    }
}

/// Reads the transcript page out of the app bundle.
///
/// The page ships inside the program, so starting a run has no separate file to
/// install, and there is only ever one copy of it to keep up.
public enum TranscriptPage {
    public static func html() throws -> Data {
        guard let url = Bundle.module.url(forResource: "transcript", withExtension: "html") else {
            throw LivePageError.pageMissing
        }
        return try Data(contentsOf: url)
    }
}

/// Serves the transcript page on the loopback address and pushes new lines to it
/// as they arrive.
///
/// Only text crosses the wire. The audio never does, which is decision 5 in the
/// README. The page is a normal browser tab, so there is no window to build and
/// nothing to install.
public final class LivePageServer: @unchecked Sendable {
    /// The name of a Server-Sent Event. The page listens for each one by name.
    private enum Event: String {
        /// The whole transcript so far. Sent once, when a page opens.
        case reset
        /// One settled line.
        case turn
        /// The line still being spoken on a track.
        case open
        /// Something about the run: a warning, or the end.
        case note
        /// The run is over.
        case end
    }

    private struct PageState: Codable {
        var turns: [LiveTurn]
        var open: [LiveOpenLine]
        var ended: Bool
        /// The page's list of changes, kept exactly as the page wrote it. The page
        /// rebuilds the transcript from this, so it is the whole edit state.
        var edits: String? = nil
    }

    private struct OpenPayload: Codable {
        var track: String
        var label: String?
        var text: String?
    }

    private struct NotePayload: Codable {
        var text: String
        var level: String
    }

    private final class Box: @unchecked Sendable {
        private let lock = NSLock()
        private var value: String?

        var text: String? {
            get { lock.lock(); defer { lock.unlock() }; return value }
            set { lock.lock(); defer { lock.unlock() }; value = newValue }
        }
    }

    private let queue = DispatchQueue(label: "org.mywallfly.transcript-page")
    private let pageHTML: Data
    private let banner: String?
    private let requestedPort: UInt16
    /// Where the page's changes are kept between page loads. Nil when the run has
    /// no folder, and the changes then last only as long as the run itself.
    private let editsURL: URL?
    /// Made on first use, so it lands on the same queue as everything else.
    private lazy var keepAlive = DispatchSource.makeTimerSource(queue: queue)
    private let encoder = JSONEncoder()

    private var listener: NWListener?
    private var clients: [UUID: NWConnection] = [:]
    private var state = PageState(turns: [], open: [], ended: false)

    public init(banner: String? = nil, port: UInt16 = 0, editsURL: URL? = nil) throws {
        self.pageHTML = try TranscriptPage.html()
        self.banner = banner
        self.requestedPort = port
        self.editsURL = editsURL
        // A run in this folder has been here before. Pick up the changes it left.
        if let editsURL, let saved = try? Data(contentsOf: editsURL) {
            self.state.edits = String(decoding: saved, as: UTF8.self)
        }
    }

    /// Starts listening on 127.0.0.1 and returns the address of the page.
    @discardableResult
    public func start(timeout: TimeInterval = 5) throws -> URL {
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback),
                                                     port: NWEndpoint.Port(rawValue: requestedPort) ?? .any)

        let listener = try NWListener(using: parameters)
        let ready = DispatchSemaphore(value: 0)
        let problem = Box()
        listener.stateUpdateHandler = { state in
            switch state {
            case .ready:
                ready.signal()
            case .failed(let error):
                problem.text = error.localizedDescription
                ready.signal()
            default:
                break
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            self?.accept(connection)
        }
        self.listener = listener
        listener.start(queue: queue)

        if ready.wait(timeout: .now() + timeout) == .timedOut {
            listener.cancel()
            throw LivePageError.couldNotStart("no answer after \(Int(timeout)) s")
        }
        if let reason = problem.text {
            listener.cancel()
            throw LivePageError.couldNotStart(reason)
        }
        guard let bound = listener.port else {
            throw LivePageError.couldNotStart("it reported no port")
        }
        startKeepAlive()
        return URL(string: "http://127.0.0.1:\(bound.rawValue)/")!
    }

    /// Stops the server and closes every open page.
    public func stop() {
        queue.sync {
            keepAlive.cancel()
            listener?.cancel()
            listener = nil
            for connection in clients.values { connection.cancel() }
            clients.removeAll()
        }
    }

    // MARK: - What the page shows

    /// Adds a settled line. Safe to call from any thread.
    public func add(_ turn: LiveTurn) {
        queue.async { [self] in
            state.turns.append(turn)
            state.open.removeAll { $0.track == turn.track }
            broadcast(.turn, turn)
        }
    }

    /// Shows the line still being spoken on a track. A nil text clears it.
    public func setOpen(track: String, label: String?, text: String?) {
        queue.async { [self] in
            state.open.removeAll { $0.track == track }
            if let text, !text.isEmpty {
                state.open.append(LiveOpenLine(track: track, label: label ?? "??", text: text))
            }
            broadcast(.open, OpenPayload(track: track, label: label, text: text))
        }
    }

    /// Sends a note about the run: a warning, or how far along it is.
    public func note(_ text: String, level: String = "note") {
        queue.async { [self] in
            broadcast(.note, NotePayload(text: text, level: level))
        }
    }

    /// Marks the run as over. The page stops drawing a live line.
    public func finish() {
        queue.async { [self] in
            state.ended = true
            state.open.removeAll()
            broadcast(.end, NotePayload(text: "The run has ended.", level: "note"))
        }
    }

    /// Keeps the page's list of changes. The page sends the whole list after every
    /// edit, so the last one wins and nothing needs merging.
    ///
    /// With a folder the list goes in a file beside the transcript: it survives a
    /// reload and a crash, and the end-of-meeting pass can read it. Without a
    /// folder it stays in memory, so a reload still finds it while the run lasts.
    public func saveEdits(_ json: String) {
        queue.async { [self] in
            state.edits = json
            guard let editsURL else { return }
            // Write the whole file at once, so a crash cannot leave half of it.
            try? Data(json.utf8).write(to: editsURL, options: .atomic)
        }
    }

    // MARK: - The socket

    private func accept(_ connection: NWConnection) {
        let id = UUID()
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed, .cancelled:
                self?.queue.async { self?.clients[id] = nil }
            default:
                break
            }
        }
        connection.start(queue: queue)
        readRequest(connection, id: id, buffer: Data())
    }

    /// Reads until the blank line that ends the request headers, then routes it.
    /// Whatever arrived after the headers is the start of the body.
    private func readRequest(_ connection: NWConnection, id: UUID, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else { connection.cancel(); return }
            var buffer = buffer
            if let data { buffer.append(data) }
            if let end = buffer.range(of: Data("\r\n\r\n".utf8)) {
                let head = String(decoding: buffer[..<end.lowerBound], as: UTF8.self)
                route(connection, head: head, body: Data(buffer[end.upperBound...]))
                return
            }
            if isComplete || error != nil || buffer.count > 64 * 1024 {
                connection.cancel()
                return
            }
            readRequest(connection, id: id, buffer: buffer)
        }
    }

    private func route(_ connection: NWConnection, head: String, body: Data) {
        let lines = head.split(separator: "\r\n", omittingEmptySubsequences: false).map(String.init)
        let requestLine = lines.first ?? ""
        let parts = requestLine.split(separator: " ")
        let method = parts.first.map(String.init) ?? ""
        let target = parts.count > 1 ? String(parts[1]) : "/"
        let path = target.split(separator: "?", maxSplits: 1).first.map(String.init) ?? "/"
        let contentLength = lines.dropFirst()
            .first { $0.lowercased().hasPrefix("content-length:") }
            .flatMap { Int($0.split(separator: ":", maxSplits: 1).last?
                          .trimmingCharacters(in: .whitespaces) ?? "") } ?? 0

        switch (method, path) {
        case ("GET", "/"), ("GET", "/index.html"), ("HEAD", "/"), ("HEAD", "/index.html"):
            respond(connection, status: "200 OK", type: "text/html; charset=utf-8", body: page())
        case ("GET", "/events"):
            openStream(connection)
        case ("GET", "/favicon.ico"), ("HEAD", "/favicon.ico"):
            respond(connection, status: "204 No Content", type: "text/plain", body: Data())
        case ("POST", "/edits"):
            // The page sends the whole list of changes after every edit.
            readBody(connection, have: body, need: contentLength) { [weak self] full in
                self?.saveEdits(String(decoding: full, as: UTF8.self))
                self?.respond(connection, status: "204 No Content",
                              type: "text/plain; charset=utf-8", body: Data())
            }
        default:
            if method == "GET" || method == "HEAD" || method == "POST" {
                respond(connection, status: "404 Not Found", type: "text/plain; charset=utf-8",
                        body: Data("No page at \(path).\n".utf8))
            } else {
                respond(connection, status: "405 Method Not Allowed", type: "text/plain; charset=utf-8",
                        body: Data("Only GET, HEAD, and POST /edits are served.\n".utf8))
            }
        }
    }

    /// Reads the rest of a request body when the first read did not carry all of it.
    private func readBody(_ connection: NWConnection, have: Data, need: Int,
                          then done: @escaping (Data) -> Void) {
        var have = have
        guard have.count < need else { done(Data(have.prefix(need))); return }
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else { connection.cancel(); return }
            if let data { have.append(data) }
            if have.count >= need {
                done(Data(have.prefix(need)))
                return
            }
            if isComplete || error != nil { connection.cancel(); return }
            self.readBody(connection, have: have, need: need, then: done)
        }
    }

    /// The page, with the run's name added so the tab says which run this is.
    /// The file on disk is never changed.
    private func page() -> Data {
        guard let banner, let marker = pageHTML.range(of: Data("</head>".utf8)) else { return pageHTML }
        let script = "<script>window.WALLFLY_LIVE = {\"label\": \(jsonString(banner))};</script>\n"
        var out = Data()
        out.append(pageHTML[..<marker.lowerBound])
        out.append(Data(script.utf8))
        out.append(pageHTML[marker.lowerBound...])
        return out
    }

    private func jsonString(_ value: String) -> String {
        let data = (try? encoder.encode(value)) ?? Data("\"\"".utf8)
        return String(decoding: data, as: UTF8.self)
    }

    private func respond(_ connection: NWConnection, status: String, type: String, body: Data) {
        var head = "HTTP/1.1 \(status)\r\n"
        head += "Content-Type: \(type)\r\n"
        head += "Content-Length: \(body.count)\r\n"
        head += "Cache-Control: no-store\r\n"
        head += "Connection: close\r\n\r\n"
        var out = Data(head.utf8)
        out.append(body)
        connection.send(content: out, completion: .contentProcessed { _ in connection.cancel() })
    }

    private func openStream(_ connection: NWConnection) {
        let id = UUID()
        clients[id] = connection
        // The stream is chunked, so a reader shows each event as it is made
        // instead of waiting for a connection that never closes.
        let head = "HTTP/1.1 200 OK\r\n"
            + "Content-Type: text/event-stream; charset=utf-8\r\n"
            + "Cache-Control: no-store\r\n"
            + "Connection: keep-alive\r\n"
            + "Transfer-Encoding: chunked\r\n"
            + "X-Accel-Buffering: no\r\n\r\n"
        connection.send(content: Data(head.utf8), completion: .contentProcessed { _ in })
        write(to: id, .reset, state)
        watchForClose(connection, id: id)
    }

    /// Keeps reading only to notice the page going away. A page sends nothing.
    private func watchForClose(_ connection: NWConnection, id: UUID) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1024) { [weak self] _, _, isComplete, error in
            guard let self else { return }
            if isComplete || error != nil {
                connection.cancel()
                self.clients[id] = nil
                return
            }
            self.watchForClose(connection, id: id)
        }
    }

    private func broadcast<T: Encodable>(_ event: Event, _ payload: T) {
        for id in clients.keys { write(to: id, event, payload) }
    }

    private func write<T: Encodable>(to id: UUID, _ event: Event, _ payload: T) {
        guard let connection = clients[id] else { return }
        let body = (try? encoder.encode(payload)).map { String(decoding: $0, as: UTF8.self) } ?? "{}"
        var frame = "event: \(event.rawValue)\n"
        for line in body.split(separator: "\n", omittingEmptySubsequences: false) {
            frame += "data: \(line)\n"
        }
        frame += "\n"
        connection.send(content: chunk(frame), completion: .contentProcessed { _ in })
    }

    /// Wraps text as one HTTP chunk. The event stream is sent this way, so a
    /// reader gets each event as it is made instead of waiting for the end.
    private func chunk(_ text: String) -> Data {
        let body = Data(text.utf8)
        var out = Data("\(String(body.count, radix: 16))\r\n".utf8)
        out.append(body)
        out.append(Data("\r\n".utf8))
        return out
    }

    /// A comment every so often, so a browser or a proxy does not decide a quiet
    /// stream has died.
    private func startKeepAlive() {
        keepAlive.schedule(deadline: .now() + 15, repeating: 15)
        keepAlive.setEventHandler { [weak self] in
            guard let self else { return }
            for connection in self.clients.values {
                connection.send(content: self.chunk(": keep-alive\n\n"), completion: .contentProcessed { _ in })
            }
        }
        keepAlive.resume()
    }
}

/// What the rest of the app talks to. It turns transcript events into page
/// updates, so the terminal and the page always show the same thing.
public final class LivePage: @unchecked Sendable {
    private let server: LivePageServer

    private init(server: LivePageServer) {
        self.server = server
    }

    /// Loads the page and starts the server. Returns the address to open.
    public static func start(banner: String? = nil, port: UInt16 = 0,
                             editsURL: URL? = nil) throws -> (page: LivePage, url: URL) {
        let server = try LivePageServer(banner: banner, port: port, editsURL: editsURL)
        let url = try server.start()
        return (LivePage(server: server), url)
    }

    /// Shows one transcript event.
    public func show(_ event: TranscriptionEvent) {
        let track = event.track == .microphone ? "mic" : "system"
        let segment = event.segment
        if segment.isFinal {
            server.add(LiveTurn(track: track,
                                label: segment.speaker ?? "??",
                                t0: millis(segment.start),
                                t1: settleEnd(segment),
                                text: segment.text))
        } else {
            server.setOpen(track: track, label: segment.speaker, text: segment.text)
        }
    }

    public func note(_ text: String, level: String = "note") {
        server.note(text, level: level)
    }

    /// The run is over: clear the live line and say so.
    public func finish() {
        server.finish()
    }

    public func stop() {
        server.stop()
    }

    private func millis(_ seconds: Double) -> Int {
        Int((seconds * 1000).rounded())
    }

    /// A line has to cover some time. The page spreads each word across the line
    /// to place it on the clock, and a line of no length would leave them nowhere
    /// to go.
    private func settleEnd(_ segment: TranscriptSegment) -> Int {
        max(millis(segment.end), millis(segment.start) + 300)
    }
}
