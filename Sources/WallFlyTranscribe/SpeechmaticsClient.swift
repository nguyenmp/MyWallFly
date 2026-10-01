import Foundation

/// One real-time stream to Speechmatics.
///
/// Open it, `start()`, push PCM with `send(_:)`, then `finish()`. Events arrive
/// on `events` in the order the service sent them.
///
/// The service wants a steady flow of audio. Push a buffer as soon as capture
/// hands you one, and never hold a whole meeting in memory.
public actor SpeechmaticsClient {
    /// Events from the socket. Read it before calling `start()`.
    public nonisolated let events: AsyncStream<SpeechmaticsEvent>

    public nonisolated let config: SpeechmaticsConfig

    private let session: URLSession
    private let socket: URLSessionWebSocketTask
    private let continuation: AsyncStream<SpeechmaticsEvent>.Continuation

    private var reader: Task<Void, Never>?
    private var startWaiters: [CheckedContinuation<Void, Error>] = []
    private var startResult: Result<Void, Error>?
    private var closed = false

    public init(config: SpeechmaticsConfig) {
        self.config = config
        var captured: AsyncStream<SpeechmaticsEvent>.Continuation!
        self.events = AsyncStream { captured = $0 }
        self.continuation = captured

        let session = URLSession(configuration: .ephemeral)
        var request = URLRequest(url: config.url)
        request.setValue("Bearer \(config.apiKey)", forHTTPHeaderField: "Authorization")
        self.session = session
        self.socket = session.webSocketTask(with: request)
    }

    /// Opens the socket and waits until the service accepts the start message.
    /// Throws if the key is bad, the network is down, or the service stays quiet.
    public func start(timeout: Double = 20) async throws {
        socket.resume()
        reader = Task { [weak self] in await self?.readLoop() }

        try await socket.send(.data(config.startMessage()))

        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { try await self.awaitStart() }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                throw SpeechmaticsError.startTimedOut
            }
            defer { group.cancelAll() }
            _ = try await group.next()
        }
    }

    /// Hands raw 16 kHz mono 16-bit little-endian PCM to the service.
    public func send(_ pcm: Data) async throws {
        guard !closed else { return }
        try await socket.send(.data(pcm))
    }

    /// Says there is no more audio and asks the service to wrap up.
    public func finish() async {
        guard !closed else { return }
        try? await socket.send(.string(#"{"message":"EndOfStream"}"#))
    }

    /// Closes the socket and ends the event stream. Safe to call twice.
    public func close() {
        guard !closed else { return }
        closed = true
        reader?.cancel()
        reader = nil
        socket.cancel(with: .normalClosure, reason: nil)
        session.invalidateAndCancel()
        resolveStart(.failure(SpeechmaticsError.rejected("stream closed")))
        continuation.finish()
    }

    // MARK: - Reading

    private func readLoop() async {
        while !Task.isCancelled && !closed {
            do {
                let message = try await socket.receive()
                handle(message)
            } catch {
                if !closed {
                    deliver(.failure(error.localizedDescription))
                }
                break
            }
        }
        if !closed {
            continuation.finish()
        }
    }

    private func handle(_ message: URLSessionWebSocketTask.Message) {
        let data: Data
        switch message {
        case .string(let text):
            data = Data(text.utf8)
        case .data(let raw):
            data = raw
        @unknown default:
            return
        }

        guard let event = try? TranscriptParser.event(fromJSON: data) else {
            deliver(.warning("could not read a message from the service"))
            return
        }
        deliver(event)
    }

    private func deliver(_ event: SpeechmaticsEvent) {
        switch event {
        case .recognising:
            resolveStart(.success(()))
            continuation.yield(event)
        case .failure(let reason):
            resolveStart(.failure(SpeechmaticsError.rejected(reason)))
            continuation.yield(event)
        default:
            continuation.yield(event)
        }
    }

    // MARK: - The start handshake

    private func awaitStart() async throws {
        if let result = startResult {
            try result.get()
            return
        }
        try await withCheckedThrowingContinuation { continuation in
            startWaiters.append(continuation)
        }
    }

    private func resolveStart(_ result: Result<Void, Error>) {
        // Keep the first answer. A later event must not undo it.
        guard startResult == nil else { return }
        startResult = result
        let waiters = startWaiters
        startWaiters = []
        for waiter in waiters {
            switch result {
            case .success: waiter.resume()
            case .failure(let error): waiter.resume(throwing: error)
            }
        }
    }
}
