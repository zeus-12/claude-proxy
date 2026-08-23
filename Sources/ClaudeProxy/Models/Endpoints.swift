import Foundation

/// Which locally authenticated coding client serves a Chat model.
enum ChatBackend: String, CaseIterable, Codable, Identifiable, Sendable {
    case claude
    case codex

    var id: String { rawValue }
    var title: String { self == .claude ? "Claude" : "Codex" }
    var subtitle: String { self == .claude ? "Claude Code subscription" : "Codex subscription" }
    var icon: String { self == .claude ? "sparkles" : "chevron.left.forwardslash.chevron.right" }
    var defaultPort: Int { self == .claude ? 8787 : 8788 }
    var keyScope: APIKeyScope { self == .claude ? .claude : .codex }
    var models: [ChatModel] { ChatModel.allCases.filter { $0.backend == self } }
    var allowedIDs: [String] { models.map(\.rawValue) }
}

/// The models the Chat endpoint accepts. This is the single source of truth for
/// the allowlist: `/v1/models` advertises these, every request validates against
/// them, and `backend` routes the turn to the matching local CLI.
enum ChatModel: String, CaseIterable, Identifiable, Sendable {
    case sonnet
    case opus
    case haiku
    case gpt56 = "gpt-5.6"
    case gpt56Sol = "gpt-5.6-sol"
    case gpt56Terra = "gpt-5.6-terra"
    case gpt56Luna = "gpt-5.6-luna"

    var id: String { rawValue }

    /// The model id passed straight to the selected local client.
    var cliAlias: String { rawValue }

    var backend: ChatBackend {
        switch self {
        case .sonnet, .opus, .haiku: return .claude
        case .gpt56, .gpt56Sol, .gpt56Terra, .gpt56Luna: return .codex
        }
    }

    var owner: String { backend == .claude ? "anthropic" : "openai" }

    var displayName: String {
        switch self {
        case .sonnet: return "Sonnet"
        case .opus: return "Opus"
        case .haiku: return "Haiku"
        case .gpt56: return "GPT-5.6 (Sol alias)"
        case .gpt56Sol: return "GPT-5.6 Sol"
        case .gpt56Terra: return "GPT-5.6 Terra"
        case .gpt56Luna: return "GPT-5.6 Luna"
        }
    }

    /// All allowed model ids, e.g. `["sonnet", "opus", "haiku"]`.
    static let allowedIDs: [String] = allCases.map(\.rawValue)

    static func isAllowed(_ id: String) -> Bool { ChatModel(rawValue: id) != nil }
}

/// Configuration for one provider-specific local OpenAI-compatible HTTP server.
/// Claude and Codex each persist their own instance of this value.
struct ChatEndpoint: Codable, Equatable {
    var port: Int
    /// Start automatically when the app launches.
    var autoStart: Bool

    init(port: Int = 8787, autoStart: Bool = false) {
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

    init(port: Int = 8765, autoStart: Bool = false) {
        self.port = port
        self.autoStart = autoStart
    }

    var endpointURL: String { "ws://127.0.0.1:\(port)" }
}

/// One-time migration for builds that previously started every endpoint by
/// default. Each endpoint gets its own marker so the first launch after this
/// change stops all three, while later user choices remain untouched.
enum EndpointOptInMigration {
    static func chat(_ endpoint: ChatEndpoint, backend: ChatBackend) -> ChatEndpoint {
        let key = "endpointOptInMigrated.chat.\(backend.rawValue)"
        guard !UserDefaults.standard.bool(forKey: key) else { return endpoint }
        UserDefaults.standard.set(true, forKey: key)
        return ChatEndpoint(port: endpoint.port, autoStart: false)
    }

    static func voice(_ endpoint: VoiceEndpoint) -> VoiceEndpoint {
        let key = "endpointOptInMigrated.voice"
        guard !UserDefaults.standard.bool(forKey: key) else { return endpoint }
        UserDefaults.standard.set(true, forKey: key)
        return VoiceEndpoint(port: endpoint.port, autoStart: false)
    }
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
