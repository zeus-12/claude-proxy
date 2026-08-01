import Foundation

/// A GUI app launched from Finder/`swift run` inherits a minimal PATH, so it
/// can't find `claude` (in ~/.local/bin) or the `node` runtime it shells out
/// to (under nvm). We resolve the real login-shell PATH and the absolute
/// `claude` path once, by asking the user's login shell directly. This avoids
/// hardcoding version-specific paths that would break on the next nvm upgrade.
enum ToolLocator {
    struct Resolved {
        let claudePath: String
        /// Full PATH from the login shell, handed to the subprocess so `claude`
        /// can find `node`.
        let path: String
    }

    /// Cached result of the login-shell probe.
    private static var cached: Resolved?

    /// Runs `<login shell> -lc 'command -v claude; echo $PATH'` once and caches
    /// the result. Returns nil if `claude` is not on the login PATH.
    static func resolve() -> Resolved? {
        if let cached { return cached }

        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: shell)
        process.arguments = ["-lc", "command -v claude; echo \"$PATH\""]
        let out = Pipe()
        process.standardOutput = out
        // Never read, so it must not be a pipe: a login shell that prints more
        // than the 64 KB buffer to stderr — nvm warnings, a chatty profile —
        // would block forever with nothing draining it.
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            return nil
        }

        // Read to EOF before waiting, never after. Waiting first deadlocks the
        // same way once the shell fills the stdout buffer, and this runs on the
        // main thread, so that freezes the app rather than one request. EOF means
        // the shell is done; its exit status is not used.
        let data = out.fileHandleForReading.readDataToEndOfFile()
        let lines = (String(data: data, encoding: .utf8) ?? "")
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map { $0.trimmingCharacters(in: .whitespaces) }

        guard lines.count >= 2,
              !lines[0].isEmpty,
              FileManager.default.isExecutableFile(atPath: lines[0]) else {
            return nil
        }

        let resolved = Resolved(claudePath: lines[0], path: lines[1])
        cached = resolved
        return resolved
    }

    /// Clear the cache and probe again (used by the "Re-check" button in
    /// Settings, e.g. after the user installs or logs into Claude Code).
    static func refresh() -> Resolved? {
        cached = nil
        return resolve()
    }
}
