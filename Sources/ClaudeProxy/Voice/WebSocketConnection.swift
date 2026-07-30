import CryptoKit
import Foundation
import Network

/// The WebSocket half of the upgrade handshake.
enum WebSocketHandshake {
    /// RFC 6455 §1.3 — the fixed, public GUID every implementation concatenates
    /// with the client's key before hashing. Not a secret.
    private static let magicGUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"

    /// True when the request is a well-formed WebSocket upgrade.
    static func isUpgrade(_ request: HTTPRequest) -> Bool {
        let connection = request.headers["connection"]?.lowercased() ?? ""
        let upgrade = request.headers["upgrade"]?.lowercased() ?? ""
        return connection.contains("upgrade")
            && upgrade == "websocket"
            && request.headers["sec-websocket-key"] != nil
    }

    /// `base64(SHA1(clientKey + GUID))`, the value the client verifies.
    static func acceptKey(for clientKey: String) -> String {
        let digest = Insecure.SHA1.hash(data: Data((clientKey + magicGUID).utf8))
        return Data(digest).base64EncodedString()
    }

    /// The 101 response completing the handshake.
    static func response(for clientKey: String) -> Data {
        let lines = [
            "HTTP/1.1 101 Switching Protocols",
            "Upgrade: websocket",
            "Connection: Upgrade",
            "Sec-WebSocket-Accept: \(acceptKey(for: clientKey))",
            "", "",
        ]
        return Data(lines.joined(separator: "\r\n").utf8)
    }
}

/// A live WebSocket connection after a successful upgrade: reassembles inbound
/// frames into messages, answers pings, and writes outbound frames.
///
/// Callbacks fire on the connection's queue. `onClose` is called exactly once.
final class WebSocketConnection {
    private let conn: NWConnection
    private let queue: DispatchQueue
    private var buffer: Data
    private var closed = false

    /// Accumulates a fragmented message across continuation frames.
    private var fragmentOpcode: WebSocketOpcode?
    private var fragmentPayload = Data()

    var onText: ((String) -> Void)?
    var onBinary: ((Data) -> Void)?
    var onClose: (() -> Void)?

    /// `leftover` carries any bytes that arrived in the same read as the upgrade
    /// request — clients that start streaming immediately after the handshake
    /// would otherwise lose their first frames.
    init(conn: NWConnection, queue: DispatchQueue, leftover: Data = Data()) {
        self.conn = conn
        self.queue = queue
        self.buffer = leftover
    }

    func start() {
        // The leftover bytes may already contain complete frames.
        if drainBuffer() { receive() }
    }

    func sendText(_ string: String) {
        send(WebSocketFraming.text(string))
    }

    func close(code: UInt16 = 1000, reason: String = "") {
        guard !closed else { return }
        send(WebSocketFraming.close(code: code, reason: reason))
        // Let the close frame flush before tearing the socket down.
        conn.send(content: nil, contentContext: .finalMessage, isComplete: true,
                  completion: .contentProcessed { [weak self] _ in self?.finish() })
    }

    // MARK: - Reading

    private func receive() {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 1 << 16) { [weak self] data, _, isComplete, error in
            guard let self, !self.closed else { return }
            if let data, !data.isEmpty { self.buffer.append(data) }

            guard self.drainBuffer() else { return }

            if error != nil || isComplete {
                self.finish()
                return
            }
            self.receive()
        }
    }

    /// Decodes as many complete frames as the buffer holds. Returns false when
    /// the connection has been torn down and reading should stop.
    private func drainBuffer() -> Bool {
        while !closed {
            let frame: WebSocketFrame?
            do {
                frame = try WebSocketFraming.decode(from: &buffer)
            } catch {
                // A malformed frame is unrecoverable — the stream is desynced.
                close(code: 1002, reason: "\(error.localizedDescription)")
                return false
            }
            guard let frame else { return !closed }
            if !handle(frame) { return false }
        }
        return false
    }

    /// Returns false when the connection was closed while handling the frame.
    private func handle(_ frame: WebSocketFrame) -> Bool {
        switch frame.opcode {
        case .ping:
            send(WebSocketFraming.encode(opcode: .pong, payload: frame.payload))
        case .pong:
            break
        case .close:
            close()
            return false
        case .text, .binary:
            if frame.isFinal {
                deliver(opcode: frame.opcode, payload: frame.payload)
            } else {
                fragmentOpcode = frame.opcode
                fragmentPayload = frame.payload
            }
        case .continuation:
            guard let opcode = fragmentOpcode else {
                close(code: 1002, reason: "Continuation without an opening frame")
                return false
            }
            fragmentPayload.append(frame.payload)
            if frame.isFinal {
                deliver(opcode: opcode, payload: fragmentPayload)
                fragmentOpcode = nil
                fragmentPayload = Data()
            }
        }
        return true
    }

    private func deliver(opcode: WebSocketOpcode, payload: Data) {
        switch opcode {
        case .text:
            if let string = String(data: payload, encoding: .utf8) { onText?(string) }
        case .binary:
            onBinary?(payload)
        default:
            break
        }
    }

    // MARK: - Writing

    private func send(_ data: Data) {
        guard !closed else { return }
        conn.send(content: data, completion: .contentProcessed { _ in })
    }

    private func finish() {
        guard !closed else { return }
        closed = true
        conn.cancel()
        onClose?()
    }
}
