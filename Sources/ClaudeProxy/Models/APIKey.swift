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

/// Stores the proxy's optional API keys in the app's private Application
/// Support directory. These are not provider credentials: they only protect a
/// loopback endpoint (or a tunnel the owner deliberately places in front of it).
///
/// Earlier builds used Keychain. A self-signed menu-bar app can trigger a
/// password dialog merely by reading such an item; macOS then makes that dialog
/// modal to the app, which made Settings look frozen. File storage with mode
/// 0600 gives the token the same user-account boundary as the subscriptions it
/// gates, without any hidden system interaction.
enum APIKey {
    private static let lock = NSLock()
    private static var cached: [APIKeyScope: APIKeyState] = [:]

    static func state(_ scope: APIKeyScope) -> APIKeyState {
        lock.lock()
        defer { lock.unlock() }

        if let override = environmentKey(for: scope) {
            return .required(override)
        }

        if let cached = cached[scope] { return cached }

        let resolved: APIKeyState
        do {
            let data = try Data(contentsOf: fileURL(for: scope))
            guard let value = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
                  !value.isEmpty else {
                resolved = .disabled
                cached[scope] = resolved
                return resolved
            }
            resolved = .required(value)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            resolved = .disabled
        } catch {
            resolved = .unavailable("Unable to read the API key. \(error.localizedDescription)")
        }

        cached[scope] = resolved
        return resolved
    }

    static func current(_ scope: APIKeyScope) -> String? {
        if case .required(let key) = state(scope) { return key }
        return nil
    }

    static func isConfigured(_ scope: APIKeyScope) -> Bool {
        current(scope) != nil
    }

    static func isRequired(_ scope: APIKeyScope) -> Bool {
        protectionEnabled(
            environmentKey: environmentKey(for: scope),
            preference: UserDefaults.standard.bool(forKey: requirementName(for: scope))
        )
    }

    static func protectionEnabled(environmentKey: String?, preference: Bool) -> Bool {
        let key = environmentKey?.trimmingCharacters(in: .whitespacesAndNewlines)
        return key?.isEmpty == false || preference
    }

    static func setRequired(_ required: Bool, for scope: APIKeyScope) {
        UserDefaults.standard.set(required, forKey: requirementName(for: scope))
    }

    /// An environment key forces protection on and cannot be turned off from the
    /// UI, so the toggle has to be shown as locked rather than as a switch whose
    /// "off" the server would ignore.
    static func isEnvironmentManaged(_ scope: APIKeyScope) -> Bool {
        environmentKey(for: scope) != nil
    }

    @discardableResult
    static func set(_ value: String, for scope: APIKeyScope) -> Result<Void, APIKeyError> {
        lock.lock()
        defer { lock.unlock() }

        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return .failure(APIKeyError(message: "Enter or generate an API key."))
        }

        do {
            let directory = supportDirectory
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o700],
                ofItemAtPath: directory.path
            )
            let url = fileURL(for: scope)
            try Data(trimmed.utf8).write(to: url, options: .atomic)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: url.path
            )
            cached[scope] = .required(trimmed)
            return .success(())
        } catch {
            let message = "Unable to save the API key. \(error.localizedDescription)"
            cached[scope] = .unavailable(message)
            return .failure(APIKeyError(message: message))
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

    static func authorizes(_ presented: String?, for scope: APIKeyScope) -> Bool {
        authorizes(
            presented,
            protectionEnabled: isRequired(scope),
            required: current(scope)
        )
    }

    static func authorizes(
        _ presented: String?,
        protectionEnabled: Bool,
        required: String?
    ) -> Bool {
        guard protectionEnabled else { return true }
        guard let required else { return false }
        return accepts(presented, required: required)
    }

    static func accepts(_ presented: String?, required: String) -> Bool {
        guard !required.isEmpty else { return false }
        guard let presented else { return false }
        return constantTimeEquals(presented, required)
    }

    static func generate() -> String {
        var bytes = [UInt8](repeating: 0, count: 24)
        if SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) != errSecSuccess {
            bytes = (0..<24).map { _ in UInt8.random(in: 0...255) }
        }
        return "llmp-" + bytes.map { String(format: "%02x", $0) }.joined()
    }

    private static var supportDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            // Keep the legacy directory so endpoint settings migrate in place.
            .appendingPathComponent("ClaudeProxy", isDirectory: true)
    }

    private static func fileURL(for scope: APIKeyScope) -> URL {
        supportDirectory.appendingPathComponent("\(scope.rawValue)-access-key")
    }

    static func environmentName(for scope: APIKeyScope) -> String {
        "LLM_PROXY_ACCESS_KEY_\(scope.rawValue.uppercased())"
    }

    private static func environmentKey(for scope: APIKeyScope) -> String? {
        let value = ProcessInfo.processInfo.environment[environmentName(for: scope)]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return value?.isEmpty == false ? value : nil
    }

    private static func requirementName(for scope: APIKeyScope) -> String {
        "apiKeyRequired.\(scope.rawValue)"
    }

    private static func constantTimeEquals(_ a: String, _ b: String) -> Bool {
        let lhs = Array(a.utf8), rhs = Array(b.utf8)
        var difference = UInt8(lhs.count == rhs.count ? 0 : 1)
        for index in 0..<max(lhs.count, rhs.count) {
            difference |= (index < lhs.count ? lhs[index] : 0)
                ^ (index < rhs.count ? rhs[index] : 0)
        }
        return difference == 0
    }

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
