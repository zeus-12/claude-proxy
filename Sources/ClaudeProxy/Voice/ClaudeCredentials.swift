import Foundation
import Security

enum ClaudeCredentialsError: LocalizedError {
    case noCredentials(OSStatus)
    case tokenNotFound
    case tokenExpired(Date)

    var errorDescription: String? {
        switch self {
        case .noCredentials(let s):
            return "Could not read the Claude Code OAuth token from the Keychain (status \(s)). "
                 + "Open Claude Code once and approve Keychain access for this app."
        case .tokenNotFound:
            return "Claude Code Keychain entry did not contain claudeAiOauth.accessToken."
        case .tokenExpired(let date):
            return "The Claude Code OAuth token expired at \(date). "
                 + "Run Claude Code once to refresh it, then try again."
        }
    }
}

/// Reads the Claude Code subscription OAuth token from the macOS Keychain. The
/// token is created by Claude Code; the first read from this app triggers a
/// macOS approval prompt (the user clicks "Always Allow").
enum ClaudeCredentials {
    private static let lock = NSLock()
    private static var cached: (token: String, expiresAt: Date?)?

    /// Re-read the Keychain once the cached token is within this long of expiry.
    /// Claude Code refreshes the stored token in the background, so a fresh read
    /// usually picks up a new one without us touching the refresh token.
    private static let expiryMargin: TimeInterval = 120

    /// Returns the OAuth token, reading from the Keychain on the first call, when
    /// the cached token is at/near expiry, or when `forceRefresh` is set. The
    /// Keychain read triggers the macOS approval prompt, so caching means the
    /// user sees it at most once per app launch — not on every dictation press.
    static func accessToken(forceRefresh: Bool = false) throws -> String {
        lock.lock()
        defer { lock.unlock() }

        if !forceRefresh, let cached, !isStale(cached.expiresAt) {
            return cached.token
        }

        let fresh = try readFromKeychain()
        if let expiresAt = fresh.expiresAt, expiresAt <= Date() {
            // Re-reading gained us nothing: Claude Code hasn't refreshed it. Fail
            // here with something actionable rather than letting the server
            // reject us with an opaque "Invalid authorization".
            cached = nil
            throw ClaudeCredentialsError.tokenExpired(expiresAt)
        }
        cached = fresh
        return fresh.token
    }

    private static func isStale(_ expiresAt: Date?) -> Bool {
        guard let expiresAt else { return false }
        return expiresAt.timeIntervalSinceNow <= expiryMargin
    }

    /// Reads `claudeAiOauth.accessToken` by its exact path.
    ///
    /// Deliberately *not* a recursive search for any `accessToken` key: the same
    /// Keychain blob also holds `mcpOAuth.<server>.accessToken` entries for
    /// unrelated MCP servers. Swift dictionary iteration is unordered, so a blind
    /// search returns an arbitrary one of them — which the Anthropic API rejects
    /// as `account_session_invalid`, intermittently and per app launch.
    private static func readFromKeychain() throws -> (token: String, expiresAt: Date?) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "Claude Code-credentials",
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data else {
            throw ClaudeCredentialsError.noCredentials(status)
        }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let oauth = json["claudeAiOauth"] as? [String: Any],
              let token = oauth["accessToken"] as? String, !token.isEmpty else {
            throw ClaudeCredentialsError.tokenNotFound
        }
        // `expiresAt` is milliseconds since the epoch. Absent means "no expiry
        // information", which we treat as never-stale rather than always-stale.
        let expiresAt = (oauth["expiresAt"] as? Double).map {
            Date(timeIntervalSince1970: $0 / 1000)
        }
        return (token, expiresAt)
    }
}
