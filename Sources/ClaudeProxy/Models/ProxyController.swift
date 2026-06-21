import Foundation
import Combine

/// Owns the list of instances, their persisted config, and their live servers.
/// Single source of truth for the UI. Status is kept separate from config
/// because it must reflect real listener events, never optimistic guesses.
@MainActor
final class ProxyController: ObservableObject {
    @Published private(set) var instances: [ProxyInstance] = []
    @Published private(set) var statuses: [UUID: InstanceStatus] = [:]

    private var servers: [UUID: ProxyServer] = [:]
    private let storeURL: URL

    init() {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = support.appendingPathComponent("ClaudeProxy", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        storeURL = dir.appendingPathComponent("instances.json")
        load()
        startAutoStartInstances()
    }

    func status(for id: UUID) -> InstanceStatus { statuses[id] ?? .stopped }

    var claudeAvailable: Bool { ToolLocator.resolve() != nil }

    // MARK: - CRUD

    func addInstance() {
        let port = nextFreePort()
        let instance = ProxyInstance(name: "Instance \(instances.count + 1)", model: "sonnet", port: port)
        instances.append(instance)
        save()
    }

    func update(_ instance: ProxyInstance) {
        guard let idx = instances.firstIndex(where: { $0.id == instance.id }) else { return }
        let wasRunning = status(for: instance.id).isActive
        if wasRunning { stop(instance.id) }
        instances[idx] = instance
        save()
        if wasRunning { start(instance.id) }
    }

    func remove(_ id: UUID) {
        stop(id)
        instances.removeAll { $0.id == id }
        statuses[id] = nil
        save()
    }

    // MARK: - Lifecycle

    func toggle(_ id: UUID) {
        if status(for: id).isActive {
            stop(id)
        } else {
            start(id)
        }
    }

    func start(_ id: UUID) {
        guard let instance = instances.first(where: { $0.id == id }) else { return }
        guard servers[id] == nil else { return }
        let server = ProxyServer(instance: instance) { [weak self] status in
            self?.statuses[id] = status
        }
        servers[id] = server
        statuses[id] = .starting
        server.start()
    }

    func stop(_ id: UUID) {
        servers[id]?.stop()
        servers[id] = nil
        statuses[id] = .stopped
    }

    func stopAll() {
        for id in servers.keys { servers[id]?.stop() }
        servers.removeAll()
    }

    // MARK: - Persistence

    private func load() {
        guard let data = try? Data(contentsOf: storeURL),
              let decoded = try? JSONDecoder().decode([ProxyInstance].self, from: data) else {
            return
        }
        instances = decoded
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(instances) else { return }
        try? data.write(to: storeURL, options: .atomic)
    }

    private func startAutoStartInstances() {
        for instance in instances where instance.autoStart {
            start(instance.id)
        }
    }

    private func nextFreePort() -> Int {
        let used = Set(instances.map(\.port))
        var port = 8787
        while used.contains(port) { port += 1 }
        return port
    }
}
