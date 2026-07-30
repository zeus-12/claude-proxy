import Foundation

/// Something observable happening to the transcript, reported per segment.
///
/// The legacy protocol only needs a running total and can ignore the boundaries,
/// but the Deepgram protocol has to distinguish an interim hypothesis from a
/// finalized segment, so the boundary is part of the event rather than something
/// callers have to infer by diffing strings.
enum TranscriptEvent: Equatable {
    /// The in-progress segment's text changed. Cumulative within the segment:
    /// each value replaces the previous one rather than appending to it.
    case segmentUpdated(String)
    /// The segment finished, carrying its settled text. Empty segments are not
    /// reported.
    case segmentEnded(String)
}

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

    /// Feed one decoded message. Returns the event it produced, or `nil` when
    /// the message changed nothing worth reporting.
    mutating func handle(_ message: [String: Any]) -> TranscriptEvent? {
        switch message["type"] as? String {
        case "TranscriptText":
            current = (message["data"] as? String) ?? current
            return .segmentUpdated(current)
        case "TranscriptEndpoint":
            guard !current.isEmpty else { return nil }
            let ended = current
            segments.append(ended)
            current = ""
            return .segmentEnded(ended)
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
