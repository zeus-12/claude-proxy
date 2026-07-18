import Foundation
import Network

/// A loopback WebSocket server that bridges the TypeWhisper "Claude
/// (subscription)" plugin to Claude's speech-to-text — so all the Keychain +
/// Claude-protocol logic lives here in the proxy, and the plugin stays thin.
///
/// Wire protocol (we own both ends, so it's minimal):
///  - plugin → proxy: binary frames of 16 kHz mono linear16 PCM; a text frame
///    `{"type":"end"}` signals end-of-audio.
///  - proxy → plugin: `{"type":"transcript","text":"…"}` for interim results,
///    `{"type":"final","text":"…"}` when done (then the socket closes), and
///    `{"type":"error","message":"…"}` if the Claude bridge can't start.
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
        // Loopback-only, same policy as the HTTP proxy servers.
        let params = NWParameters.tcp
        params.requiredLocalEndpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: nwPort)
        let ws = NWProtocolWebSocket.Options()
        ws.autoReplyPing = true
        params.defaultProtocolStack.applicationProtocols.insert(ws, at: 0)

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
                VoiceSession(conn: conn, queue: self.queue).start()
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

/// One accepted plugin connection, wired to a `ClaudeVoiceBridge`.
private final class VoiceSession {
    private let conn: NWConnection
    private let queue: DispatchQueue
    private var bridge: ClaudeVoiceBridge?
    private var selfRetain: VoiceSession?

    init(conn: NWConnection, queue: DispatchQueue) {
        self.conn = conn
        self.queue = queue
    }

    func start() {
        selfRetain = self
        conn.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:            self?.openBridge()
            case .failed, .cancelled: self?.close()
            default:                break
            }
        }
        conn.start(queue: queue)
    }

    private func openBridge() {
        let bridge: ClaudeVoiceBridge
        do {
            bridge = try ClaudeVoiceBridge()
        } catch {
            sendJSON(["type": "error", "message": error.localizedDescription])
            close()
            return
        }
        self.bridge = bridge
        bridge.onInterim = { [weak self] text in
            self?.sendJSON(["type": "transcript", "text": text])
        }
        Task { await bridge.start() }
        receive()
    }

    private func receive() {
        conn.receiveMessage { [weak self] data, context, _, error in
            guard let self else { return }
            if let data, let meta = context?.protocolMetadata(definition: NWProtocolWebSocket.definition)
                as? NWProtocolWebSocket.Metadata {
                switch meta.opcode {
                case .binary:
                    self.bridge?.sendAudio(data)
                case .text:
                    if let s = String(data: data, encoding: .utf8), s.contains("\"end\"") {
                        self.finishAndReply()
                        return
                    }
                case .close:
                    self.close()
                    return
                default:
                    break
                }
            }
            if error != nil { self.close(); return }
            self.receive()
        }
    }

    private func finishAndReply() {
        guard let bridge else { close(); return }
        Task {
            let final = await bridge.finish()
            self.sendJSON(["type": "final", "text": final])
            // Give the final frame a moment to flush, then close.
            self.conn.send(content: nil, contentContext: .finalMessage, isComplete: true,
                           completion: .contentProcessed { [weak self] _ in self?.close() })
        }
    }

    private func sendJSON(_ object: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: object) else { return }
        let meta = NWProtocolWebSocket.Metadata(opcode: .text)
        let context = NWConnection.ContentContext(identifier: "send", metadata: [meta])
        conn.send(content: data, contentContext: context, completion: .contentProcessed { _ in })
    }

    private func close() {
        bridge?.cancel()
        bridge = nil
        conn.cancel()
        selfRetain = nil
    }
}
