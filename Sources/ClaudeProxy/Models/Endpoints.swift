import Foundation

/// The Claude models the Chat endpoint accepts. This is the single source of
/// truth for the allowlist: `/v1/models` advertises these, and every chat
/// request's `model` field is validated against them. To allow another model,
/// add a case here — nothing else needs to change.
enum ChatModel: String, CaseIterable, Identifiable, Sendable {
    case sonnet
    case opus
    case haiku

    var id: String { rawValue }

    /// The `--model` alias passed straight to the `claude` CLI.
    var cliAlias: String { rawValue }

    var displayName: String {
        switch self {
        case .sonnet: return "Sonnet"
        case .opus: return "Opus"
        case .haiku: return "Haiku"
        }
    }

    /// All allowed model ids, e.g. `["sonnet", "opus", "haiku"]`.
    static let allowedIDs: [String] = allCases.map(\.rawValue)

    static func isAllowed(_ id: String) -> Bool { ChatModel(rawValue: id) != nil }
}

/// The Chat endpoint: a single local OpenAI-compatible HTTP server. Unlike the
/// old per-model "instances", there is exactly one Chat endpoint; the model is
/// chosen per-request (validated against `ChatModel`), not pinned here.
struct ChatEndpoint: Codable, Equatable {
    var port: Int
    /// Start automatically when the app launches.
    var autoStart: Bool

    init(port: Int = 8787, autoStart: Bool = true) {
        self.port = port
        self.autoStart = autoStart
    }

    var baseURL: String { "http://127.0.0.1:\(port)/v1" }
}

/// The Voice endpoint: a local transcription WebSocket that streams speech
/// through the Claude subscription. Any client can connect (the TypeWhisper
/// plugin is one such client).
struct VoiceEndpoint: Codable, Equatable {
    var port: Int
    /// Start automatically when the app launches.
    var autoStart: Bool

    init(port: Int = 8765, autoStart: Bool = true) {
        self.port = port
        self.autoStart = autoStart
    }

    var endpointURL: String { "ws://127.0.0.1:\(port)" }
}

/// Transient runtime status for an endpoint. Never persisted — it must reflect
/// the *real* listener state, so we only ever derive it from live server events.
enum InstanceStatus: Equatable {
    case stopped
    case starting
    case running
    case failed(String)

    var isActive: Bool {
        switch self {
        case .running, .starting: return true
        case .stopped, .failed: return false
        }
    }
}
