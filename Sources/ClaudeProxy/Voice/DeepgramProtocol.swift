import Foundation

/// The listen parameters a Deepgram client declares in its query string.
///
/// Only the fields that change how we handle audio are honoured. Everything else
/// Deepgram accepts (`diarize`, `punctuate`, `smart_format`, `numerals`, …) is
/// parsed off and ignored, because Claude's speech-to-text socket exposes no
/// controls for them — see `APIDocs` for the list we tell callers about.
struct DeepgramListenParams: Equatable {
    var sampleRate: Double
    var channels: Int
    var model: String?
    var language: String?

    enum ParseError: LocalizedError, Equatable {
        case missingEncoding
        case unsupportedEncoding(String)
        case missingSampleRate
        case invalidSampleRate(String)
        case invalidChannels(String)

        var errorDescription: String? {
            switch self {
            case .missingEncoding:
                return "Missing `encoding`. This endpoint accepts raw PCM only, so it cannot "
                     + "auto-detect a container. Pass `encoding=linear16`."
            case .unsupportedEncoding(let value):
                return "Unsupported `encoding=\(value)`. Only `linear16` is supported."
            case .missingSampleRate:
                return "Missing `sample_rate`, which is required with `encoding=linear16`."
            case .invalidSampleRate(let value):
                return "Invalid `sample_rate=\(value)`."
            case .invalidChannels(let value):
                return "Invalid `channels=\(value)`."
            }
        }
    }

    /// Parses the query component of a request path such as
    /// `/v1/listen?encoding=linear16&sample_rate=48000&channels=2`.
    static func parse(query: [String: String]) throws -> DeepgramListenParams {
        guard let encoding = query["encoding"] else { throw ParseError.missingEncoding }
        guard encoding == "linear16" else { throw ParseError.unsupportedEncoding(encoding) }

        guard let rateText = query["sample_rate"] else { throw ParseError.missingSampleRate }
        guard let rate = Double(rateText), rate > 0 else {
            throw ParseError.invalidSampleRate(rateText)
        }

        var channels = 1
        if let channelsText = query["channels"] {
            guard let parsed = Int(channelsText), parsed >= 1, parsed <= 8 else {
                throw ParseError.invalidChannels(channelsText)
            }
            channels = parsed
        }

        return DeepgramListenParams(sampleRate: rate,
                                    channels: channels,
                                    model: query["model"],
                                    language: query["language"])
    }

    /// Splits `"/v1/listen?a=1&b=2"` into its path and decoded query pairs.
    static func split(path rawPath: String) -> (path: String, query: [String: String]) {
        guard let separator = rawPath.firstIndex(of: "?") else { return (rawPath, [:]) }
        let path = String(rawPath[rawPath.startIndex..<separator])
        let queryText = String(rawPath[rawPath.index(after: separator)...])

        var query: [String: String] = [:]
        for pair in queryText.split(separator: "&") {
            let parts = pair.split(separator: "=", maxSplits: 1)
            guard let rawKey = parts.first else { continue }
            let key = String(rawKey).removingPercentEncoding ?? String(rawKey)
            let value = parts.count > 1
                ? (String(parts[1]).removingPercentEncoding ?? String(parts[1]))
                : ""
            query[key] = value
        }
        return (path, query)
    }
}

/// Builds the JSON messages a Deepgram streaming client expects.
///
/// Shapes mirror `owhisper_interface::stream::StreamResponse`, which clients
/// deserialize strictly: a field that is absent where the schema has no default
/// makes the whole message fail to decode, and it is dropped in silence rather
/// than reported. So every required field is written explicitly, and optional
/// leaf values are written as an explicit `null` rather than omitted.
///
/// Built as dictionaries rather than `Codable` structs on purpose: `JSONEncoder`
/// omits nil optionals, and here the difference between "absent" and "null"
/// matters.
enum DeepgramProtocol {

    /// Claude returns no confidence score of any kind. The schema requires the
    /// field, so we emit this placeholder — it is not a measurement, and the
    /// API reference says so. 1.0 rather than 0.0 because clients that filter on
    /// a confidence threshold would otherwise discard every word.
    static let placeholderConfidence = 1.0

    /// A `Results` message carrying one segment.
    ///
    /// `words` holds a single entry spanning the whole segment: Claude gives us
    /// segment text with no word-level timing, and splitting the text across
    /// invented per-word offsets would put fabricated positions on a timeline
    /// people scrub through. One honest coarse span beats many precise lies.
    static func results(transcript: String,
                        start: Double,
                        end: Double,
                        isFinal: Bool,
                        speechFinal: Bool,
                        fromFinalize: Bool,
                        channels: Int,
                        requestID: String,
                        modelUUID: String) -> String {
        let duration = max(end - start, 0)
        let word: [String: Any] = [
            "word": transcript,
            "start": start,
            "end": end,
            "confidence": placeholderConfidence,
            "speaker": NSNull(),
            "punctuated_word": NSNull(),
            "language": NSNull(),
        ]
        let alternative: [String: Any] = [
            "transcript": transcript,
            "words": transcript.isEmpty ? [] : [word],
            "confidence": placeholderConfidence,
            "languages": [],
        ]
        let message: [String: Any] = [
            "type": "Results",
            "start": start,
            "duration": duration,
            "is_final": isFinal,
            "speech_final": speechFinal,
            "from_finalize": fromFinalize,
            "channel_index": [0, channels],
            "channel": ["alternatives": [alternative]],
            "metadata": metadataBlock(requestID: requestID, modelUUID: modelUUID),
        ]
        return encode(message)
    }

    /// The terminal `Metadata` message sent once the stream is finished.
    static func terminal(requestID: String, duration: Double, channels: Int, created: String) -> String {
        encode([
            "type": "Metadata",
            "request_id": requestID,
            "created": created,
            "duration": duration,
            "channels": channels,
        ])
    }

    static func utteranceEnd(lastWordEnd: Double, channels: Int) -> String {
        encode([
            "type": "UtteranceEnd",
            "channel": [0, channels],
            "last_word_end": lastWordEnd,
        ])
    }

    static func error(_ message: String, code: Int? = nil) -> String {
        encode([
            "type": "Error",
            "error_code": code.map { $0 as Any } ?? NSNull(),
            "error_message": message,
            "provider": "claude-proxy",
        ])
    }

    /// `model_info` reports what we actually asked Claude for. The version is
    /// blank because the upstream never tells us one, and inventing a plausible
    /// version string would be worse than an empty field.
    private static func metadataBlock(requestID: String, modelUUID: String) -> [String: Any] {
        [
            "request_id": requestID,
            "model_uuid": modelUUID,
            "model_info": ["name": "deepgram-nova3", "version": "", "arch": "nova-3"],
        ]
    }

    private static func encode(_ object: [String: Any]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: object),
              let text = String(data: data, encoding: .utf8) else {
            return #"{"type":"Error","error_code":null,"error_message":"Failed to encode response","provider":"claude-proxy"}"#
        }
        return text
    }
}

/// Tracks where we are in the audio stream, in seconds, from the bytes actually
/// forwarded to Claude.
///
/// This is the only timing source available: Claude's messages carry no
/// timestamps. The position is exact with respect to audio *submitted*, but a
/// transcript arrives after the speech it describes has been processed, so a
/// segment closed on arrival is biased late by roughly the recognition latency
/// — around a second in practice. Segment ordering and duration are sound;
/// absolute alignment against the recording is approximate.
struct AudioClock: Equatable {
    /// 16 kHz mono linear16 — two bytes per sample.
    static let bytesPerSecond = 32000.0

    private var bytesForwarded = 0
    private(set) var segmentStart = 0.0

    /// Seconds of audio handed to Claude so far.
    var position: Double { Double(bytesForwarded) / Self.bytesPerSecond }

    mutating func advance(bytes: Int) {
        bytesForwarded += bytes
    }

    /// Closes the current segment at the present position and starts the next
    /// one there. Returns the span just closed.
    mutating func closeSegment() -> (start: Double, end: Double) {
        let span = (start: segmentStart, end: position)
        segmentStart = position
        return span
    }
}
