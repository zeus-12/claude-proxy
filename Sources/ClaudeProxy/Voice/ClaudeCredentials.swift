import Foundation
import Security

enum ClaudeCredentialsError: LocalizedError {
    case noCredentials(OSStatus)
    case tokenNotFound

    var errorDescription: String? {
        switch self {
        case .noCredentials(let s):
            return "Could not read the Claude Code OAuth token from the Keychain (status \(s)). "
                 + "Open Claude Code once and approve Keychain access for this app."
        case .tokenNotFound:
            return "Claude Code Keychain entry did not contain an accessToken."
        }
    }
}

/// Reads the Claude Code subscription OAuth token from the macOS Keychain. The
/// token is created by Claude Code; the first read from this app triggers a
/// macOS approval prompt (the user clicks "Always Allow").
enum ClaudeCredentials {
    private static let lock = NSLock()
    private static var cached: String?

    /// Returns the OAuth token, reading from the Keychain only on the first call
    /// (or when `forceRefresh` is set). The Keychain read triggers the macOS
    /// approval prompt, so caching means the user sees it at most once per app
    /// launch — not on every dictation press.
    static func accessToken(forceRefresh: Bool = false) throws -> String {
        lock.lock()
        defer { lock.unlock() }
        if !forceRefresh, let cached { return cached }

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
        guard let json = try? JSONSerialization.jsonObject(with: data),
              let token = findToken(json) else {
            throw ClaudeCredentialsError.tokenNotFound
        }
        cached = token
        return token
    }

    /// The Keychain blob is JSON; the access token is nested. Find it anywhere.
    private static func findToken(_ obj: Any) -> String? {
        if let dict = obj as? [String: Any] {
            if let t = dict["accessToken"] as? String, !t.isEmpty { return t }
            for (_, v) in dict {
                if let t = findToken(v) { return t }
            }
        }
        return nil
    }
}
