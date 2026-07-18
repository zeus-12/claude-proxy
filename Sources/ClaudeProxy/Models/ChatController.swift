import Foundation
import Combine

/// Owns the single Chat endpoint: its persisted config and its live server.
/// Status is kept separate from config because it must reflect real listener
/// events, never optimistic guesses.
@MainActor
final class ChatController: ObservableObject {
    @Published var config: ChatEndpoint { didSet { if config != oldValue { save() } } }
    @Published private(set) var status: InstanceStatus = .stopped

    private var server: ProxyServer?
    private let storeURL: URL

    init() {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = support.appendingPathComponent("ClaudeProxy", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        storeURL = dir.appendingPathComponent("chat-endpoint.json")
        config = Self.loadOrMigrate(from: dir)
        save()
        if config.autoStart { start() }
    }

    var claudeAvailable: Bool { ToolLocator.resolve() != nil }
    var isActive: Bool { status.isActive }

    // MARK: - Lifecycle

    func toggle() {
        if status.isActive { stop() } else { start() }
    }

    func start() {
        guard server == nil else { return }
        let server = ProxyServer(endpoint: config) { [weak self] status in
            self?.status = status
        }
        self.server = server
        status = .starting
        server.start()
    }

    func stop() {
        server?.stop()
        server = nil
        status = .stopped
    }

    /// Apply an edited config. Restarts the server if it was running so the new
    /// port takes effect.
    func apply(_ newConfig: ChatEndpoint) {
        let wasRunning = status.isActive
        if wasRunning { stop() }
        config = newConfig
        if wasRunning { start() }
    }

    // MARK: - Persistence

    private func save() {
        guard let data = try? JSONEncoder().encode(config) else { return }
        try? data.write(to: storeURL, options: .atomic)
    }

    /// Load the Chat endpoint config. If it doesn't exist yet, migrate from the
    /// legacy multi-instance `instances.json` (take the first instance's port /
    /// auto-start), else fall back to defaults.
    private static func loadOrMigrate(from dir: URL) -> ChatEndpoint {
        let store = dir.appendingPathComponent("chat-endpoint.json")
        if let data = try? Data(contentsOf: store),
           let decoded = try? JSONDecoder().decode(ChatEndpoint.self, from: data) {
            return decoded
        }
        // Legacy migration: old builds stored `[{port,autoStart,model,name}]`.
        let legacy = dir.appendingPathComponent("instances.json")
        if let data = try? Data(contentsOf: legacy),
           let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]],
           let first = arr.first,
           let port = first["port"] as? Int {
            let autoStart = first["autoStart"] as? Bool ?? true
            return ChatEndpoint(port: port, autoStart: autoStart)
        }
        return ChatEndpoint()
    }
}
