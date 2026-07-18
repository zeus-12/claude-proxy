import Foundation

/// One live transcription session against Claude's speech-to-text WebSocket
/// (Deepgram nova-3 behind the Claude Code subscription OAuth token). Audio is
/// forwarded in capture order through an `AsyncStream`, with `KeepAlive` sent
/// before any audio so Claude never sees frames out of order.
///
/// This is the single owner of the reverse-engineered Claude voice protocol and
/// the Keychain token — the TypeWhisper plugin no longer talks to Claude
/// directly; it streams to the proxy's local WebSocket, which drives this bridge.
final class ClaudeVoiceBridge {
    private let ws: URLSessionWebSocketTask
    private let audio: AsyncStream<Data>
    private let audioIn: AsyncStream<Data>.Continuation
    private var sendTask: Task<Void, Never>?
    private var receiveTask: Task<Void, Never>?

    // Touched only by `receiveLoop` (a single task); `finish()` reads the final
    // transcript after awaiting that task, so no locking is needed.
    private var accumulator = TranscriptAccumulator()

    /// Called with the progressive transcript as it grows (background thread).
    var onInterim: ((String) -> Void)?

    /// Reads the Keychain token and prepares the Claude WebSocket. Throws if the
    /// token can't be read (surfaced to the plugin as a protocol error).
    init() throws {
        let token = try ClaudeCredentials.accessToken()

        var comps = URLComponents(string: "wss://api.anthropic.com/api/ws/speech_to_text/voice_stream")!
        comps.queryItems = [
            .init(name: "encoding", value: "linear16"),
            .init(name: "sample_rate", value: "16000"),
            .init(name: "channels", value: "1"),
            .init(name: "endpointing_ms", value: "300"),
            .init(name: "utterance_end_ms", value: "1000"),
            .init(name: "language", value: "en"),
            .init(name: "use_conversation_engine", value: "true"),
            .init(name: "stt_provider", value: "deepgram-nova3"),
        ]
        var req = URLRequest(url: comps.url!)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("claude-cli/2.1.187 (external, cli)", forHTTPHeaderField: "User-Agent")
        req.setValue("claude_code_cli", forHTTPHeaderField: "anthropic-client-platform")
        req.setValue("cli", forHTTPHeaderField: "x-app")
        ws = URLSession(configuration: .default).webSocketTask(with: req)

        (audio, audioIn) = AsyncStream.makeStream(of: Data.self)
    }

    /// Open the socket and start pumping. Must be called once before `sendAudio`.
    func start() async {
        ws.resume()
        try? await ws.send(.string(#"{"type":"KeepAlive"}"#))
        sendTask = Task { [ws, audio] in
            for await chunk in audio { try? await ws.send(.data(chunk)) }
        }
        receiveTask = Task { [weak self] in await self?.receiveLoop() }
    }

    /// Feed a chunk of 16 kHz mono linear16 PCM.
    func sendAudio(_ pcm: Data) {
        audioIn.yield(pcm)
    }

    /// Stop sending audio, flush to Claude, and return the final transcript.
    func finish() async -> String {
        audioIn.finish()
        await sendTask?.value                 // all audio actually sent
        try? await ws.send(.string(#"{"type":"CloseStream"}"#))
        await receiveTask?.value              // server finished + closed
        return accumulator.final
    }

    func cancel() {
        audioIn.finish()
        receiveTask?.cancel()
        ws.cancel(with: .goingAway, reason: nil)
    }

    private func receiveLoop() async {
        while true {
            let message: URLSessionWebSocketTask.Message
            do { message = try await ws.receive() } catch { break }
            guard case .string(let text) = message,
                  let data = text.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                continue
            }
            if let interim = accumulator.handle(obj) {
                onInterim?(interim)
            }
        }
    }
}
