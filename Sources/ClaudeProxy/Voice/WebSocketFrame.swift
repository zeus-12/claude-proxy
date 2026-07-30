import Foundation

/// RFC 6455 frame encoding and decoding.
///
/// We hand-roll this instead of using `NWProtocolWebSocket` because that API
/// hides the HTTP upgrade request from the server: its client-request handler is
/// handed only `(subprotocols, headers)`, with no request line. Deepgram clients
/// carry everything that matters — the route, plus `encoding`, `sample_rate` and
/// `channels` — in the path and query string, so a server that cannot read them
/// would have to guess the audio format. Guessing 16 kHz when a client is
/// actually sending 48 kHz produces a plausible-looking but wrong transcript, so
/// framing it ourselves is the only correct option.
///
/// This type is pure: it moves bytes to and from values and performs no I/O, so
/// `VoiceSelfTest` can exercise it without a socket.
enum WebSocketOpcode: UInt8 {
    case continuation = 0x0
    case text = 0x1
    case binary = 0x2
    case close = 0x8
    case ping = 0x9
    case pong = 0xA

    /// Control frames may not be fragmented and carry at most 125 bytes.
    var isControl: Bool { rawValue & 0x8 != 0 }
}

struct WebSocketFrame: Equatable {
    let isFinal: Bool
    let opcode: WebSocketOpcode
    let payload: Data
}

enum WebSocketFrameError: LocalizedError, Equatable {
    case reservedBitsSet
    case unknownOpcode(UInt8)
    case unmaskedClientFrame
    case fragmentedControlFrame
    case oversizedControlFrame(Int)
    case payloadTooLarge(UInt64)

    var errorDescription: String? {
        switch self {
        case .reservedBitsSet:            return "WebSocket frame set reserved bits"
        case .unknownOpcode(let code):    return "Unknown WebSocket opcode 0x\(String(code, radix: 16))"
        case .unmaskedClientFrame:        return "Client frame was not masked"
        case .fragmentedControlFrame:     return "Control frame was fragmented"
        case .oversizedControlFrame(let n): return "Control frame carried \(n) bytes (max 125)"
        case .payloadTooLarge(let n):     return "Frame payload of \(n) bytes exceeds the limit"
        }
    }
}

enum WebSocketFraming {
    /// Frames larger than this are refused rather than allocated. Generous for
    /// audio chunks (a client sending 100 ms of 48 kHz stereo needs ~19 KB)
    /// while still bounding what a single frame header can make us reserve.
    static let maximumPayload = 16 * 1024 * 1024

    /// Decodes one frame from the front of `buffer`, removing the bytes it
    /// consumed. Returns nil when the buffer holds only part of a frame, in
    /// which case `buffer` is left untouched and the caller should read more.
    static func decode(from buffer: inout Data) throws -> WebSocketFrame? {
        let base = buffer.startIndex
        guard buffer.count >= 2 else { return nil }

        let byte0 = buffer[base]
        let byte1 = buffer[base + 1]

        guard byte0 & 0x70 == 0 else { throw WebSocketFrameError.reservedBitsSet }
        let rawOpcode = byte0 & 0x0F
        guard let opcode = WebSocketOpcode(rawValue: rawOpcode) else {
            throw WebSocketFrameError.unknownOpcode(rawOpcode)
        }
        let isFinal = byte0 & 0x80 != 0
        let isMasked = byte1 & 0x80 != 0

        var offset = 2
        var length = Int(byte1 & 0x7F)

        if length == 126 {
            guard buffer.count >= offset + 2 else { return nil }
            length = Int(buffer[base + offset]) << 8 | Int(buffer[base + offset + 1])
            offset += 2
        } else if length == 127 {
            guard buffer.count >= offset + 8 else { return nil }
            var wide: UInt64 = 0
            for i in 0..<8 { wide = wide << 8 | UInt64(buffer[base + offset + i]) }
            guard wide <= UInt64(maximumPayload) else {
                throw WebSocketFrameError.payloadTooLarge(wide)
            }
            length = Int(wide)
            offset += 8
        }

        if opcode.isControl {
            guard isFinal else { throw WebSocketFrameError.fragmentedControlFrame }
            guard length <= 125 else { throw WebSocketFrameError.oversizedControlFrame(length) }
        }
        // RFC 6455 §5.1: every frame from client to server must be masked.
        guard isMasked else { throw WebSocketFrameError.unmaskedClientFrame }

        guard buffer.count >= offset + 4 else { return nil }
        let mask = [buffer[base + offset], buffer[base + offset + 1],
                    buffer[base + offset + 2], buffer[base + offset + 3]]
        offset += 4

        guard buffer.count >= offset + length else { return nil }
        var payload = buffer.subdata(in: (base + offset)..<(base + offset + length))
        for i in payload.indices {
            payload[i] ^= mask[(i - payload.startIndex) % 4]
        }

        buffer.removeSubrange(base..<(base + offset + length))
        return WebSocketFrame(isFinal: isFinal, opcode: opcode, payload: payload)
    }

    /// Encodes a server-to-client frame. Server frames are never masked.
    static func encode(opcode: WebSocketOpcode, payload: Data) -> Data {
        var out = Data()
        out.append(0x80 | opcode.rawValue)   // FIN set: we never fragment outbound

        let count = payload.count
        if count < 126 {
            out.append(UInt8(count))
        } else if count <= 0xFFFF {
            out.append(126)
            out.append(UInt8(count >> 8 & 0xFF))
            out.append(UInt8(count & 0xFF))
        } else {
            out.append(127)
            for shift in stride(from: 56, through: 0, by: -8) {
                out.append(UInt8(UInt64(count) >> UInt64(shift) & 0xFF))
            }
        }
        out.append(payload)
        return out
    }

    static func text(_ string: String) -> Data {
        encode(opcode: .text, payload: Data(string.utf8))
    }

    /// A close frame carrying a status code and optional reason.
    static func close(code: UInt16 = 1000, reason: String = "") -> Data {
        var payload = Data([UInt8(code >> 8 & 0xFF), UInt8(code & 0xFF)])
        payload.append(Data(reason.utf8))
        return encode(opcode: .close, payload: payload)
    }
}
