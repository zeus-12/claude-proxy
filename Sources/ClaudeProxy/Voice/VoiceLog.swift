import Foundation

/// A trace log for the voice path, written to
/// `~/Library/Logs/ClaudeProxy/voice-trace.log`.
///
/// Exists because the interesting failures here are timing- and
/// interleaving-shaped — how many connections a client opens, what audio format
/// it declares, and how the upstream segments a long utterance — none of which
/// can be seen from the outside.
///
/// It records transcript text, so it contains whatever was said. The file is
/// truncated on every app launch and never leaves the machine, but delete it
/// when you are done debugging if that matters:
///     rm ~/Library/Logs/ClaudeProxy/voice-trace.log
enum VoiceLog {
    private static let lock = NSLock()
    private static let started = Date()

    static let url: URL = {
        let directory = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/ClaudeProxy", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("voice-trace.log")
    }()

    /// Truncates the log. Called once at launch so each run starts clean.
    static func reset() {
        lock.lock()
        defer { lock.unlock() }
        try? Data().write(to: url)
        appendLocked("=== voice trace started \(ISO8601DateFormatter().string(from: Date())) ===")
    }

    /// `tag` identifies the connection, so concurrent sessions can be told apart.
    static func write(_ tag: String, _ message: String) {
        lock.lock()
        defer { lock.unlock() }
        let elapsed = String(format: "%7.3f", Date().timeIntervalSince(started))
        appendLocked("[\(elapsed)] [\(tag)] \(message)")
    }

    private static func appendLocked(_ line: String) {
        guard let data = (line + "\n").data(using: .utf8) else { return }
        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        } else {
            try? data.write(to: url)
        }
    }
}
