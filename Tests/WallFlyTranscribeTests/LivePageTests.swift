import Darwin
import Foundation
import Testing
@testable import WallFlyTranscribe

@Suite("The live transcript page")
struct LivePageTests {
    @Test("the page ships inside the program")
    func pageIsBundled() throws {
        let html = String(decoding: try TranscriptPage.html(), as: UTF8.self)
        #expect(html.contains("window.WALLFLY_DATA"))
        #expect(html.contains("</head>"))
    }

    @Test("a browser gets the page, with the name of the run")
    func servesThePage() async throws {
        let (page, url) = try LivePage.start(banner: "test run")
        defer { page.stop() }

        let (data, response) = try await URLSession.shared.data(from: url)
        #expect((response as? HTTPURLResponse)?.statusCode == 200)
        let html = String(decoding: data, as: UTF8.self)
        #expect(html.contains("window.WALLFLY_LIVE"))
        #expect(html.contains("test run"))
        // The page has to listen to the run, or it would show the sample data.
        #expect(html.contains("new EventSource('/events')"))
    }

    @Test("a page gets the transcript so far, then each new line as it lands", .timeLimit(.minutes(1)))
    func streamsLinesAsTheyArrive() async throws {
        let (page, url) = try LivePage.start(banner: "test run")
        defer { page.stop() }

        let socket = try Socket(port: UInt16(url.port ?? 0))
        defer { socket.shut() }

        // A page that opens part way through a run gets everything so far.
        let opening = await socket.readForAWhile()
        #expect(opening.contains("Transfer-Encoding: chunked"))
        #expect(opening.contains("event: reset"))

        // A settled line reaches a page that is already open.
        page.show(TranscriptionEvent(track: .microphone,
                                     segment: TranscriptSegment(speaker: "S1", start: 1,
                                                                end: 3, text: "Hello there",
                                                                isFinal: true)))
        let settled = await socket.readForAWhile()
        #expect(settled.contains("event: turn"))
        #expect(settled.contains("Hello there"))

        // So does the line still being spoken.
        page.show(TranscriptionEvent(track: .system,
                                     segment: TranscriptSegment(speaker: "S2", start: 4,
                                                                end: 5, text: "Still talking",
                                                                isFinal: false)))
        let open = await socket.readForAWhile()
        #expect(open.contains("event: open"))
        #expect(open.contains("Still talking"))
    }
}

/// A plain TCP client. Reading the raw bytes shows exactly what the server sends
/// and when, which a URL session decides for itself.
private final class Socket: @unchecked Sendable {
    private let handle: Int32

    init(port: UInt16) throws {
        handle = socket(AF_INET, SOCK_STREAM, 0)
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        address.sin_addr.s_addr = inet_addr("127.0.0.1")

        let joined = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(handle, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard joined == 0 else {
            Darwin.close(handle)
            throw LivePageError.couldNotStart("the test could not reach the page")
        }

        // Stop reading after a moment of quiet, so a test cannot hang.
        var timeout = timeval(tv_sec: 2, tv_usec: 0)
        setsockopt(handle, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))

        let request = "GET /events HTTP/1.1\r\nHost: 127.0.0.1\r\nAccept: text/event-stream\r\n\r\n"
        _ = request.withCString { send(handle, $0, strlen($0), 0) }
    }

    func shut() {
        Darwin.close(handle)
    }

    /// Everything that arrives before the socket goes quiet.
    func readForAWhile() async -> String {
        await Task.detached { [handle] in
            var out = Data()
            var chunk = [UInt8](repeating: 0, count: 4096)
            while true {
                let count = recv(handle, &chunk, chunk.count, 0)
                if count <= 0 { break }
                out.append(contentsOf: chunk[0..<count])
            }
            return String(decoding: out, as: UTF8.self)
        }.value
    }
}
