import Foundation

/// Accumulates Claude voice-stream messages into a transcript.
///
/// Claude's speech-to-text WebSocket emits two message types:
///  - `TranscriptText`  — the running hypothesis for the current segment (its
///    `data` field is cumulative within the segment, replacing the previous one).
///  - `TranscriptEndpoint` — the current segment is finalized; start a new one.
///
/// This is intentionally a pure value type with no I/O so the parsing/joining
/// logic can be unit-tested without a live WebSocket or Keychain token.
struct TranscriptAccumulator {
    private var segments: [String] = []
    private var current = ""

    /// Feed one decoded message. Returns the new cumulative interim transcript
    /// when it changed (for progress callbacks), or `nil` when nothing to emit.
    mutating func handle(_ message: [String: Any]) -> String? {
        switch message["type"] as? String {
        case "TranscriptText":
            current = (message["data"] as? String) ?? current
            return interim
        case "TranscriptEndpoint":
            if !current.isEmpty {
                segments.append(current)
                current = ""
            }
            return nil
        default:
            return nil
        }
    }

    /// Cumulative transcript so far, including the in-progress segment.
    var interim: String {
        (segments + (current.isEmpty ? [] : [current])).joined(separator: " ")
    }

    /// The final transcript once the stream has closed.
    var final: String {
        interim.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
