import Foundation
import Security

enum APIKeyState: Equatable, Sendable {
    case required(String)
    case disabled
    case unavailable(String)
}

struct APIKeyError: LocalizedError, Equatable, Sendable {
    let message: String
    var errorDescription: String? { message }
}

enum APIKeyScope: String, CaseIterable, Sendable {
    case claude
    case codex
    case voice

    var label: String {
        switch self {
        case .claude: return "Claude"
        case .codex: return "Codex"
        case .voice: return "Voice"
        }
    }
}

enum APIKey {
    private static let service = "ClaudeProxy-api-key"
    private static let enabledPrefix = "endpointAuthenticationEnabled."

    private static let lock = NSLock()
    private static var cached: [APIKeyScope: APIKeyState] = [:]

    static func state(_ scope: APIKeyScope) -> APIKeyState {
        lock.lock()
        defer { lock.unlock() }

        // Authentication is opt-in. This check deliberately happens before
        // looking at the cache or Keychain so opening settings never causes a
        // macOS password prompt for a feature the user has not enabled.
        guard authenticationEnabled(scope) else {
            cached[scope] = .disabled
            return .disabled
        }

        if let cached = cached[scope] { return cached }

        let resolved: APIKeyState
        var result = read(scope.rawValue)
        // Preserve the existing combined Chat key as the Claude endpoint key.
        // Copy it instead of deleting the legacy item so migration is recoverable.
        if case .absent = result, scope == .claude,
           case .success(let legacy) = read("chat") {
            if case .success = write(legacy, scope) { result = .success(legacy) }
        }
        switch result {
        case .success(let stored):
            resolved = stored.isEmpty ? .disabled : .required(stored)
        case .absent:
            let fresh = generate()
            if case .failure(let error) = write(fresh, scope) {
                resolved = .unavailable(error.message)
            } else {
                resolved = .required(fresh)
            }
        case .failure(let reason):
            resolved = .unavailable(reason)
        }
        cached[scope] = resolved
        return resolved
    }

    static func current(_ scope: APIKeyScope) -> String? {
        if case .required(let key) = state(scope) { return key }
        return nil
    }

    static func isAuthenticationEnabled(_ scope: APIKeyScope) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return authenticationEnabled(scope)
    }

    @discardableResult
    static func setAuthenticationEnabled(
        _ enabled: Bool,
        for scope: APIKeyScope
    ) -> Result<Void, APIKeyError> {
        lock.lock()
        UserDefaults.standard.set(enabled, forKey: enabledPrefix + scope.rawValue)
        cached[scope] = enabled ? nil : .disabled
        lock.unlock()

        guard enabled else { return .success(()) }
        if case .unavailable(let reason) = state(scope) {
            return .failure(APIKeyError(message: reason))
        }
        return .success(())
    }

    @discardableResult
    static func set(_ value: String, for scope: APIKeyScope) -> Result<Void, APIKeyError> {
        lock.lock()
        defer { lock.unlock() }

        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            UserDefaults.standard.set(false, forKey: enabledPrefix + scope.rawValue)
            cached[scope] = .disabled
            return .success(())
        }
        switch write(trimmed, scope) {
        case .success:
            UserDefaults.standard.set(true, forKey: enabledPrefix + scope.rawValue)
            cached[scope] = .required(trimmed)
            return .success(())
        case .failure(let error):
            cached[scope] = .unavailable(error.message)
            return .failure(error)
        }
    }

    @discardableResult
    static func regenerate(_ scope: APIKeyScope) -> Result<String, APIKeyError> {
        let fresh = generate()
        return set(fresh, for: scope).map { fresh }
    }

    static func invalidateCache() {
        lock.lock()
        cached.removeAll()
        lock.unlock()
    }

    static func accepts(_ presented: String?, for scope: APIKeyScope) -> Bool {
        switch state(scope) {
        case .disabled:
            return true
        case .required(let key):
            return accepts(presented, required: key)
        case .unavailable:
            return false
        }
    }

    static func accepts(_ presented: String?, required: String?) -> Bool {
        guard let required, !required.isEmpty else { return true }
        guard let presented else { return false }
        return constantTimeEquals(presented, required)
    }

    static func generate() -> String {
        var bytes = [UInt8](repeating: 0, count: 24)
        if SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) != errSecSuccess {
            bytes = (0..<24).map { _ in UInt8.random(in: 0...255) }
        }
        return "cp-" + bytes.map { String(format: "%02x", $0) }.joined()
    }

    private static func constantTimeEquals(_ a: String, _ b: String) -> Bool {
        let lhs = Array(a.utf8), rhs = Array(b.utf8)
        var difference = UInt8(lhs.count == rhs.count ? 0 : 1)
        for i in 0..<max(lhs.count, rhs.count) {
            difference |= (i < lhs.count ? lhs[i] : 0) ^ (i < rhs.count ? rhs[i] : 0)
        }
        return difference == 0
    }

    private static func authenticationEnabled(_ scope: APIKeyScope) -> Bool {
        UserDefaults.standard.bool(forKey: enabledPrefix + scope.rawValue)
    }

    // MARK: - Keychain

    private enum ReadResult {
        case success(String)
        case absent
        case failure(String)
    }

    private static func read(_ account: String) -> ReadResult {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)

        switch status {
        case errSecSuccess:
            guard let data = item as? Data,
                  let value = String(data: data, encoding: .utf8) else {
                return .failure("The stored key is not readable text.")
            }
            return .success(value)
        case errSecItemNotFound:
            return .absent
        default:
            return .failure(describe(status))
        }
    }

    private static func write(_ value: String, _ scope: APIKeyScope) -> Result<Void, APIKeyError> {
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: scope.rawValue,
        ]
        let data = Data(value.utf8)

        let update = SecItemUpdate(base as CFDictionary,
                                   [kSecValueData as String: data] as CFDictionary)
        if update == errSecSuccess { return .success(()) }
        if update != errSecItemNotFound { return .failure(APIKeyError(message: describe(update))) }

        var insert = base
        insert[kSecValueData as String] = data
        insert[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlocked
        let add = SecItemAdd(insert as CFDictionary, nil)
        return add == errSecSuccess ? .success(()) : .failure(APIKeyError(message: describe(add)))
    }

    private static func describe(_ status: OSStatus) -> String {
        let detail = SecCopyErrorMessageString(status, nil).map { $0 as String }
            ?? "Keychain error \(status)"
        if status == errSecInteractionNotAllowed || status == errSecAuthFailed
            || status == errSecUserCanceled {
            return "\(detail) LLM Proxy could not reach its Keychain item — "
                 + "approve the macOS prompt, or set a key manually."
        }
        return detail
    }

    // MARK: - Presented credentials

    static func presented(headers: [String: String], query: [String: String] = [:]) -> String? {
        if let authorization = headers["authorization"] {
            let parts = authorization.split(separator: " ", maxSplits: 1).map(String.init)
            if parts.count == 2 {
                let scheme = parts[0].lowercased()
                if scheme == "bearer" || scheme == "token" {
                    return parts[1].trimmingCharacters(in: .whitespaces)
                }
            } else if parts.count == 1, !parts[0].isEmpty {
                return parts[0]
            }
        }
        if let key = headers["x-api-key"], !key.isEmpty { return key }
        if let protocols = headers["sec-websocket-protocol"] {
            let parts = protocols.split(separator: ",").map {
                $0.trimmingCharacters(in: .whitespaces)
            }
            if parts.count >= 2, parts[0].lowercased() == "token" { return parts[1] }
        }
        for name in ["token", "api_key", "key"] {
            if let value = query[name], !value.isEmpty { return value }
        }
        return nil
    }
}
