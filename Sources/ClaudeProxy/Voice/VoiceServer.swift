import Foundation
import Network

/// A loopback WebSocket server exposing Claude's speech-to-text over two
/// protocols on one port, chosen by request path:
///
///  - `/v1/listen`, `/listen` — Deepgram's streaming protocol, which is what
///    third-party transcription clients speak. Binary linear16 PCM in;
///    `Results` / `UtteranceEnd` / `Metadata` JSON out.
///  - `/` — the original minimal protocol the TypeWhisper plugin uses. Binary
///    16 kHz PCM in, `{"type":"end"}` to finish; `transcript` / `final` /
///    `error` out.
///
/// The HTTP upgrade is handled by hand rather than with `NWProtocolWebSocket`
/// because that API never shows the server the request line — only the headers —
/// and both the route and the client's audio format live in the path and query.
final class VoiceServer {
    let port: UInt16
    private var listener: NWListener?
    private let queue = DispatchQueue(label: "proxy.voice.server")
    private let onStatus: (Bool, String?) -> Void   // (running, error)

    init(port: UInt16 = 8765, onStatus: @escaping (Bool, String?) -> Void) {
        self.port = port
        self.onStatus = onStatus
    }

    func start() {
        guard let nwPort = NWEndpoint.Port(rawValue: port) else {
            report(false, "Invalid voice port \(port)")
            return
        }
        // Loopback-only, same policy as the HTTP proxy servers. Plain TCP: the
        // WebSocket handshake and framing are ours.
        let params = NWParameters.tcp
        params.requiredLocalEndpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: nwPort)

        VoiceLog.reset()

        do {
            let listener = try NWListener(using: params)
            self.listener = listener
            listener.stateUpdateHandler = { [weak self] state in
                switch state {
                case .ready:         self?.report(true, nil)
                case .failed(let e): self?.report(false, Self.describe(e))
                case .cancelled:     self?.report(false, nil)
                default:             break
                }
            }
            listener.newConnectionHandler = { [weak self] conn in
                guard let self else { return }
                VoiceUpgrade(conn: conn, queue: self.queue).start()
            }
            listener.start(queue: queue)
        } catch {
            report(false, Self.describe(error))
        }
    }

    func stop() {
        listener?.cancel()
        listener = nil
    }

    private func report(_ running: Bool, _ error: String?) {
        DispatchQueue.main.async { self.onStatus(running, error) }
    }

    private static func describe(_ error: Error) -> String {
        if let nw = error as? NWError, case .posix(let code) = nw, code == .EADDRINUSE {
            return "Voice port already in use"
        }
        return error.localizedDescription
    }
}

// MARK: - Upgrade

/// Reads the HTTP upgrade request off a fresh connection, completes the
/// handshake, and hands the socket to the session matching the request path.
private final class VoiceUpgrade {
    private let conn: NWConnection
    private let queue: DispatchQueue
    private var buffer = Data()
    private var selfRetain: VoiceUpgrade?

    init(conn: NWConnection, queue: DispatchQueue) {
        self.conn = conn
        self.queue = queue
    }

    func start() {
        selfRetain = self
        conn.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed, .cancelled: self?.abandon()
            default: break
            }
        }
        conn.start(queue: queue)
        receive()
    }

    private func receive() {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 1 << 16) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let data, !data.isEmpty { self.buffer.append(data) }

            if let request = HTTPRequest.parse(self.buffer) {
                self.handle(request)
                return
            }
            if error != nil || isComplete {
                self.abandon()
                return
            }
            self.receive()
        }
    }

    private func handle(_ request: HTTPRequest) {
        // Short per-connection tag so concurrent sessions can be told apart in
        // the trace — a client opening two sockets looks identical to one
        // opening a single socket unless the log distinguishes them.
        let tag = String(UUID().uuidString.prefix(4))

        guard WebSocketHandshake.isUpgrade(request),
              let key = request.headers["sec-websocket-key"] else {
            VoiceLog.write(tag, "rejected non-upgrade \(request.method) \(request.path)")
            writeHTTPError("This endpoint expects a WebSocket upgrade request.")
            return
        }

        let (rawPath, query) = DeepgramListenParams.split(path: request.path)
        VoiceLog.write(tag, "connect \(request.method) \(rawPath)")

        // CORS never applies to WebSockets, so the key is the only thing standing
        // between this endpoint and any page the user happens to visit. Refused
        // before the upgrade, so the client sees a plain 401 rather than a socket
        // that opens and then dies.
        guard APIKey.accepts(APIKey.presented(headers: request.headers, query: query), for: .voice) else {
            VoiceLog.write(tag, "rejected: missing or invalid access key")
            writeHTTPError("Invalid access key. Send it as `Authorization: Token <access-key>`, "
                           + "as the `token` query parameter, or as the "
                           + "`token, <access-key>` WebSocket subprotocol.", status: 401)
            return
        }
        VoiceLog.write(tag, "  query: \(query.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: " "))")

        conn.send(content: WebSocketHandshake.response(for: key),
                  completion: .contentProcessed { _ in })

        // From here the session owns the connection.
        conn.stateUpdateHandler = nil
        let socket = WebSocketConnection(conn: conn, queue: queue, leftover: request.body ?? Data())

        switch Self.normalize(rawPath) {
        case "/listen", "/v1/listen":
            DeepgramVoiceSession(socket: socket, queue: queue, query: query, tag: tag).start()
        case "":
            VoiceLog.write(tag, "legacy protocol")
            LegacyVoiceSession(socket: socket, queue: queue).start()
        default:
            socket.sendText(DeepgramProtocol.error(
                "Unknown path \(rawPath). Use /v1/listen for the Deepgram protocol, "
                + "or / for the legacy protocol."))
            socket.close(code: 1008, reason: "Unknown path")
        }
        selfRetain = nil
    }

    /// Trailing slashes are insignificant, and clients build this path by
    /// appending to a configured base URL, so `/v1/listen/` must match too.
    private static func normalize(_ path: String) -> String {
        var trimmed = path
        while trimmed.count > 1, trimmed.hasSuffix("/") { trimmed.removeLast() }
        return trimmed == "/" ? "" : trimmed
    }

    private func writeHTTPError(_ message: String, status: Int = 400) {
        let body = Data(message.utf8)
        let reason = status == 401 ? "Unauthorized" : "Bad Request"
        let head = """
        HTTP/1.1 \(status) \(reason)\r
        Content-Type: text/plain; charset=utf-8\r
        Content-Length: \(body.count)\r
        Connection: close\r
        \r

        """
        var response = Data(head.utf8)
        response.append(body)
        conn.send(content: response, completion: .contentProcessed { [weak self] _ in
            self?.abandon()
        })
    }

    private func abandon() {
        conn.cancel()
        selfRetain = nil
    }
}

// MARK: - Legacy protocol (TypeWhisper)

/// The original minimal protocol: binary 16 kHz mono PCM in, `{"type":"end"}` to
/// finish, `transcript` / `final` / `error` out. Unchanged in behaviour — only
/// the transport underneath it moved from `NWProtocolWebSocket` to our own.
private final class LegacyVoiceSession {
    private let socket: WebSocketConnection
    private let queue: DispatchQueue
    private var bridge: ClaudeVoiceBridge?
    private var selfRetain: LegacyVoiceSession?

    init(socket: WebSocketConnection, queue: DispatchQueue) {
        self.socket = socket
        self.queue = queue
    }

    func start() {
        selfRetain = self

        let bridge: ClaudeVoiceBridge
        do {
            bridge = try ClaudeVoiceBridge()
        } catch {
            socket.sendText(Self.json(["type": "error", "message": error.localizedDescription]))
            socket.close()
            selfRetain = nil
            return
        }
        self.bridge = bridge

        bridge.onInterim = { [weak self] text in
            guard let self else { return }
            self.queue.async {
                self.socket.sendText(Self.json(["type": "transcript", "text": text]))
            }
        }
        socket.onBinary = { [weak self] pcm in
            self?.bridge?.sendAudio(pcm)
        }
        socket.onText = { [weak self] text in
            guard let self, text.contains("\"end\"") else { return }
            self.finish()
        }
        socket.onClose = { [weak self] in
            self?.bridge?.cancel()
            self?.bridge = nil
            self?.selfRetain = nil
        }

        Task { await bridge.start() }
        socket.start()
    }

    private func finish() {
        guard let bridge else { socket.close(); return }
        Task { [weak self] in
            let final = await bridge.finish()
            guard let self else { return }
            self.queue.async {
                self.socket.sendText(Self.json(["type": "final", "text": final]))
                self.socket.close()
            }
        }
    }

    private static func json(_ object: [String: Any]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: object),
              let text = String(data: data, encoding: .utf8) else { return "{}" }
        return text
    }
}

// MARK: - Deepgram protocol

/// Deepgram's streaming protocol, backed by Claude.
///
/// All mutable state is touched only on `queue`: audio arrives on the socket's
/// queue while transcripts arrive on the bridge's task, so bridge callbacks are
/// hopped onto the same queue rather than guarded with a lock.
private final class DeepgramVoiceSession {
    private let socket: WebSocketConnection
    private let queue: DispatchQueue
    private let query: [String: String]
    private let tag: String

    private var bridge: ClaudeVoiceBridge?
    private var converter: PCMConverter?
    private var clock = AudioClock()

    /// Audio is logged in aggregate — one line per chunk would bury everything
    /// else at ten chunks a second.
    private var chunksIn = 0
    private var bytesIn = 0

    /// Text of the segment currently in progress, so a forced finalize or a
    /// close can report what we have instead of dropping it.
    private var currentSegment = ""
    private var finished = false
    private var selfRetain: DeepgramVoiceSession?

    private let requestID = UUID().uuidString
    private let modelUUID = UUID().uuidString

    /// We downmix to mono for Claude, so exactly one channel comes back out
    /// regardless of how many the client sent.
    private let outputChannels = 1

    init(socket: WebSocketConnection, queue: DispatchQueue, query: [String: String], tag: String) {
        self.socket = socket
        self.queue = queue
        self.query = query
        self.tag = tag
    }

    func start() {
        selfRetain = self

        let bridge: ClaudeVoiceBridge
        do {
            let params = try DeepgramListenParams.parse(query: query)
            VoiceLog.write(tag, "params: \(params.sampleRate) Hz, \(params.channels) ch, "
                              + "model=\(params.model ?? "-") language=\(params.language ?? "-")")
            guard let converter = PCMConverter(sourceRate: params.sampleRate,
                                               channels: params.channels) else {
                throw DeepgramListenParams.ParseError.invalidSampleRate("\(params.sampleRate)")
            }
            self.converter = converter
            bridge = try ClaudeVoiceBridge(tag: tag)
        } catch {
            VoiceLog.write(tag, "start failed: \(error.localizedDescription)")
            socket.sendText(DeepgramProtocol.error(error.localizedDescription))
            socket.close(code: 1008, reason: "Invalid listen parameters")
            selfRetain = nil
            return
        }
        self.bridge = bridge

        bridge.onEvent = { [weak self] event in
            guard let self else { return }
            self.queue.async { self.handle(event) }
        }
        socket.onBinary = { [weak self] pcm in
            self?.forward(pcm)
        }
        socket.onText = { [weak self] text in
            self?.handleControl(text)
        }
        socket.onClose = { [weak self] in
            self?.bridge?.cancel()
            self?.bridge = nil
            self?.selfRetain = nil
        }

        Task { await bridge.start() }
        socket.start()
    }

    // MARK: Audio in

    private func forward(_ pcm: Data) {
        guard let converter, let bridge else { return }
        guard let converted = converter.convert(pcm) else {
            socket.sendText(DeepgramProtocol.error("Failed to convert audio to 16 kHz mono."))
            socket.close(code: 1011, reason: "Audio conversion failed")
            return
        }
        guard !converted.isEmpty else { return }
        clock.advance(bytes: converted.count)
        bridge.sendAudio(converted)

        chunksIn += 1
        bytesIn += pcm.count
        if chunksIn % 50 == 0 {
            VoiceLog.write(tag, "audio: \(chunksIn) chunks, \(bytesIn) bytes in, "
                              + String(format: "%.1fs", clock.position) + " forwarded")
        }
    }

    // MARK: Control messages

    private func handleControl(_ text: String) {
        guard let data = text.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = object["type"] as? String else { return }

        if type != "KeepAlive" { VoiceLog.write(tag, "control: \(type)") }

        switch type {
        case "KeepAlive":
            break   // the socket is already alive; nothing upstream needs poking
        case "Finalize":
            queue.async { self.flushSegment(fromFinalize: true) }
        case "CloseStream":
            queue.async { self.finish() }
        default:
            break
        }
    }

    // MARK: Transcripts out

    private func handle(_ event: TranscriptEvent) {
        switch event {
        case .segmentUpdated(let text):
            currentSegment = text
            emitResults(text: text, start: clock.segmentStart, end: clock.position,
                        isFinal: false, fromFinalize: false)
        case .segmentEnded(let text):
            currentSegment = ""
            let span = clock.closeSegment()
            emitResults(text: text, start: span.start, end: span.end,
                        isFinal: true, fromFinalize: false)
            socket.sendText(DeepgramProtocol.utteranceEnd(lastWordEnd: span.end,
                                                          channels: outputChannels))
        }
    }

    /// Reports the in-progress segment as final. Claude has no mid-stream flush,
    /// so this states what we have rather than forcing the upstream to settle —
    /// a client that asked to finalize gets an answer instead of stalling.
    private func flushSegment(fromFinalize: Bool) {
        guard !currentSegment.isEmpty else { return }
        let text = currentSegment
        currentSegment = ""
        let span = clock.closeSegment()
        emitResults(text: text, start: span.start, end: span.end,
                    isFinal: true, fromFinalize: fromFinalize)
        socket.sendText(DeepgramProtocol.utteranceEnd(lastWordEnd: span.end,
                                                      channels: outputChannels))
    }

    private func emitResults(text: String, start: Double, end: Double,
                             isFinal: Bool, fromFinalize: Bool) {
        VoiceLog.write(tag, "emit \(isFinal ? "FINAL  " : "interim") "
                          + String(format: "[%.2f→%.2f] ", start, end) + "\"\(text)\"")
        socket.sendText(DeepgramProtocol.results(
            transcript: text,
            start: start,
            end: end,
            isFinal: isFinal,
            // Claude's endpointing is what produced the boundary, so a final
            // result here does mean speech settled rather than a timer firing.
            speechFinal: isFinal,
            fromFinalize: fromFinalize,
            channels: outputChannels,
            requestID: requestID,
            modelUUID: modelUUID))
    }

    private func finish() {
        guard !finished, let bridge else { return }
        finished = true
        Task { [weak self] in
            _ = await bridge.finish()
            guard let self else { return }
            self.queue.async {
                self.flushSegment(fromFinalize: false)
                self.socket.sendText(DeepgramProtocol.terminal(
                    requestID: self.requestID,
                    duration: self.clock.position,
                    channels: self.outputChannels,
                    created: ISO8601DateFormatter().string(from: Date())))
                self.socket.close()
            }
        }
    }
}
