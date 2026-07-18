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

    init() {
        config = Self.load()
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
        guard server == nil else { return }
        let server = VoiceServer(port: UInt16(config.port)) { [weak self] running, error in
            self?.running = running
            self?.error = error
        }
        self.server = server
        server.start()
    }

    func stop() {
        server?.stop()
        server = nil
        running = false
        error = nil
    }

    /// Apply an edited config, restarting the server if it was running so the new
    /// port takes effect.
    func apply(_ newConfig: VoiceEndpoint) {
        let wasRunning = running
        if wasRunning { stop() }
        config = newConfig
        if wasRunning { start() }
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
