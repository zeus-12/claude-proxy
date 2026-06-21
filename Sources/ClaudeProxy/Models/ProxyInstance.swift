import Foundation

/// One proxy endpoint: a single local OpenAI-compatible server bound to `port`,
/// backed by `claude -p` running the chosen `model`.
struct ProxyInstance: Identifiable, Codable, Equatable {
    var id: UUID
    var name: String
    /// A Claude model alias or full id passed straight to `claude --model`
    /// (e.g. "sonnet", "opus", "haiku", or "claude-sonnet-4-6").
    var model: String
    /// Loopback TCP port this instance listens on.
    var port: Int
    /// Start this instance automatically when the app launches.
    var autoStart: Bool

    init(id: UUID = UUID(),
         name: String,
         model: String = "sonnet",
         port: Int,
         autoStart: Bool = false) {
        self.id = id
        self.name = name
        self.model = model
        self.port = port
        self.autoStart = autoStart
    }

    /// The model id advertised to clients via `/v1/models` and echoed back in
    /// responses. We expose the configured Claude model verbatim so clients see
    /// exactly what they're getting.
    var advertisedModelID: String { model }

    var baseURL: String { "http://127.0.0.1:\(port)/v1" }
}

/// Transient runtime status. Never persisted — it must reflect the *real*
/// listener state, so we only ever derive it from live NWListener events.
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

let suggestedModels = ["sonnet", "opus", "haiku"]
