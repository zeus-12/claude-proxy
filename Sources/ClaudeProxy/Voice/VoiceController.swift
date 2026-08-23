import Foundation
import Combine

/// Owns the loopback voice WebSocket server: its persisted config and its live
/// status. Any client can connect to `config.endpointURL` (the TypeWhisper
/// "Claude (subscription)" plugin is one such client).
///
/// Like the Chat endpoint, it can be toggled on/off from the UI and started
/// automatically on launch, but it is a fixed, built-in endpoint — it can't be
/// removed. Status reflects the real listener state, never an optimistic guess.
@MainActor
final class VoiceController: ObservableObject {
    @Published var config: VoiceEndpoint { didSet { if config != oldValue { save() } } }
    /// True only while the listener is actually up (from the server's real
    /// ready/failed callback).
    @Published private(set) var running = false
    @Published private(set) var error: String?

    private var server: VoiceServer?
    private static let store = "voiceEndpoint"

    /// Whether the endpoint is *meant* to be up. Distinct from `running`, which
    /// is the real listener state: a failed bind leaves the endpoint wanted but
    /// not running, and a later port change has to retry rather than conclude
    /// the user had deliberately stopped it.
    private var wantsRunning = false

    /// Invalidates callbacks from a server we've discarded. A cancelled listener
    /// reports `.cancelled` asynchronously, which would otherwise land after a
    /// replacement has already reported ready and wipe its status.
    private var generation = 0

    init() {
        config = EndpointOptInMigration.voice(Self.load())
        save()
        if config.autoStart { start() }
    }

    var isActive: Bool { running }

    /// Real status for the shared endpoint UI, derived from live server events.
    var status: InstanceStatus {
        if let error { return .failed(error) }
        return running ? .running : .stopped
    }

    // MARK: - Lifecycle

    func toggle() {
        if running { stop() } else { start() }
    }

    func start() {
        wantsRunning = true
        // Not `guard server == nil`: a server that failed to bind is still a
        // live object, and refusing to replace it made every retry a no-op
        // until the app was relaunched.
        teardown()
        let token = generation
        let server = VoiceServer(port: UInt16(config.port)) { [weak self] running, error in
            guard let self, self.generation == token else { return }
            self.running = running
            self.error = error
        }
        self.server = server
        server.start()
    }

    func stop() {
        wantsRunning = false
        teardown()
    }

    /// Releases the current server without changing intent, clearing any error
    /// so a stale failure can't outlive the configuration that caused it.
    private func teardown() {
        generation &+= 1
        server?.stop()
        server = nil
        running = false
        error = nil
    }

    /// Apply an edited config, restarting the server if the endpoint is meant to
    /// be up so the new port takes effect. Keyed on intent rather than on
    /// `running`, so changing the port also retries an endpoint whose previous
    /// port was already taken.
    func apply(_ newConfig: VoiceEndpoint) {
        let shouldRun = wantsRunning
        teardown()
        config = newConfig
        if shouldRun { start() }
    }

    // MARK: - Persistence

    private func save() {
        guard let data = try? JSONEncoder().encode(config) else { return }
        UserDefaults.standard.set(data, forKey: Self.store)
    }

    private static func load() -> VoiceEndpoint {
        if let data = UserDefaults.standard.data(forKey: store),
           let decoded = try? JSONDecoder().decode(VoiceEndpoint.self, from: data) {
            return decoded
        }
        return VoiceEndpoint()
    }
}
