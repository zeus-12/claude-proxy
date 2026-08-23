import Foundation
import Combine

/// Owns one provider-specific Chat endpoint. Claude and Codex deliberately get
/// separate listeners, persisted settings, keys and lifecycle controls.
/// Status is kept separate from config because it must reflect real listener
/// events, never optimistic guesses.
@MainActor
final class ChatController: ObservableObject {
    @Published var config: ChatEndpoint { didSet { if config != oldValue { save() } } }
    @Published private(set) var status: InstanceStatus = .stopped

    private var server: ProxyServer?
    private let storeURL: URL
    let backend: ChatBackend

    /// Whether the endpoint is *meant* to be up. Distinct from `status`, which
    /// is the real listener state: a failed bind reports `.failed` (and so
    /// `isActive == false`), and a later port change has to retry rather than
    /// conclude the user had deliberately stopped it.
    private var wantsRunning = false

    /// Invalidates callbacks from a server we've discarded. A cancelled listener
    /// reports asynchronously, which would otherwise land after a replacement
    /// has already reported ready and wipe its status.
    private var generation = 0

    init(backend: ChatBackend) {
        self.backend = backend
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = support.appendingPathComponent("ClaudeProxy", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        storeURL = dir.appendingPathComponent("\(backend.rawValue)-chat-endpoint.json")
        config = EndpointOptInMigration.chat(
            Self.loadOrMigrate(backend: backend, from: dir), backend: backend
        )
        save()
        if config.autoStart { start() }
    }

    var isAvailable: Bool {
        backend == .claude ? ToolLocator.resolve() != nil : ToolLocator.resolveCodex() != nil
    }
    var isActive: Bool { status.isActive }

    // MARK: - Lifecycle

    func toggle() {
        if status.isActive { stop() } else { start() }
    }

    func start() {
        wantsRunning = true
        // Not `guard server == nil`: a server that failed to bind is still a
        // live object, and refusing to replace it made every retry a no-op
        // until the app was relaunched.
        teardown()
        let token = generation
        let server = ProxyServer(endpoint: config, backend: backend) { [weak self] status in
            guard let self, self.generation == token else { return }
            self.status = status
        }
        self.server = server
        status = .starting
        server.start()
        if backend == .codex {
            DispatchQueue.global(qos: .userInitiated).async { try? CodexBackend.prepare() }
        }
    }

    func stop() {
        wantsRunning = false
        teardown()
        if backend == .codex { CodexBackend.shutdown() }
    }

    /// Releases the current server without changing intent, clearing any failure
    /// so a stale error can't outlive the configuration that caused it.
    private func teardown() {
        generation &+= 1
        server?.stop()
        server = nil
        status = .stopped
    }

    /// Apply an edited config, restarting the server if the endpoint is meant to
    /// be up so the new port takes effect. Keyed on intent rather than on
    /// `status.isActive`, so changing the port also retries an endpoint whose
    /// previous port was already taken.
    func apply(_ newConfig: ChatEndpoint) {
        let shouldRun = wantsRunning
        teardown()
        config = newConfig
        if shouldRun { start() }
    }

    // MARK: - Persistence

    private func save() {
        guard let data = try? JSONEncoder().encode(config) else { return }
        try? data.write(to: storeURL, options: .atomic)
    }

    /// Load the Chat endpoint config. If it doesn't exist yet, migrate from the
    /// legacy multi-instance `instances.json` (take the first instance's port /
    /// auto-start), else fall back to defaults.
    private static func loadOrMigrate(backend: ChatBackend, from dir: URL) -> ChatEndpoint {
        let store = dir.appendingPathComponent("\(backend.rawValue)-chat-endpoint.json")
        if let data = try? Data(contentsOf: store),
           let decoded = try? JSONDecoder().decode(ChatEndpoint.self, from: data) {
            return decoded
        }
        // The old combined Chat endpoint becomes the Claude endpoint. Codex is
        // new and starts independently on 8788, avoiding a silent behavior swap.
        if backend == .claude {
            let combined = dir.appendingPathComponent("chat-endpoint.json")
            if let data = try? Data(contentsOf: combined),
               let decoded = try? JSONDecoder().decode(ChatEndpoint.self, from: data) {
                return decoded
            }
        }
        // Legacy migration: old builds stored `[{port,autoStart,model,name}]`.
        let legacy = dir.appendingPathComponent("instances.json")
        if backend == .claude, let data = try? Data(contentsOf: legacy),
           let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]],
           let first = arr.first,
           let port = first["port"] as? Int {
            let autoStart = first["autoStart"] as? Bool ?? true
            return ChatEndpoint(port: port, autoStart: autoStart)
        }
        return ChatEndpoint(port: backend.defaultPort)
    }
}
