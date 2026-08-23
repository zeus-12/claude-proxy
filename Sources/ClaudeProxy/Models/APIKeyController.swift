import Foundation
import Combine

@MainActor
final class APIKeyController: ObservableObject {
    @Published private(set) var states: [APIKeyScope: APIKeyState] = [:]
    @Published private(set) var errors: [APIKeyScope: String] = [:]

    private let loadState: @Sendable (APIKeyScope) -> APIKeyState
    private let authenticationEnabled: @Sendable (APIKeyScope) -> Bool
    private var hasStartedLoading = false

    init(
        loadState: @escaping @Sendable (APIKeyScope) -> APIKeyState = { APIKey.state($0) },
        authenticationEnabled: @escaping @Sendable (APIKeyScope) -> Bool = {
            APIKey.isAuthenticationEnabled($0)
        }
    ) {
        self.loadState = loadState
        self.authenticationEnabled = authenticationEnabled

        // AppDelegate owns this controller before NSApplication finishes
        // launching. Never read Keychain here: SecItemCopyMatching may wait for
        // a macOS approval prompt, which used to block creation of the status
        // item and leave an apparently headless process running forever.
        for scope in APIKeyScope.allCases {
            states[scope] = authenticationEnabled(scope)
                ? .unavailable("Loading key…")
                : .disabled
        }
    }

    /// Resolve enabled keys only after the menu-bar item exists. Security calls
    /// run off the main actor so a Keychain approval prompt cannot freeze AppKit.
    func loadEnabledKeys() {
        guard !hasStartedLoading else { return }
        hasStartedLoading = true

        for scope in APIKeyScope.allCases where authenticationEnabled(scope) {
            let loadState = self.loadState
            Task { @MainActor [weak self] in
                let loaded = await Task.detached(priority: .utility) {
                    loadState(scope)
                }.value
                guard let self else { return }
                if self.authenticationEnabled(scope) {
                    self.states[scope] = loaded
                    if case .unavailable(let reason) = loaded {
                        self.errors[scope] = reason
                    } else {
                        self.errors[scope] = nil
                    }
                } else {
                    self.states[scope] = .disabled
                    self.errors[scope] = nil
                }
            }
        }
    }

    func state(_ scope: APIKeyScope) -> APIKeyState {
        states[scope] ?? .unavailable("Not loaded")
    }

    func key(_ scope: APIKeyScope) -> String? {
        if case .required(let key) = state(scope) { return key }
        return nil
    }

    func isEnforced(_ scope: APIKeyScope) -> Bool {
        if case .required = state(scope) { return true }
        return false
    }

    func isEnabled(_ scope: APIKeyScope) -> Bool {
        authenticationEnabled(scope)
    }

    func masked(_ scope: APIKeyScope) -> String {
        guard let key = key(scope) else { return "" }
        return String(repeating: "•", count: max(key.count - 4, 8)) + key.suffix(4)
    }

    func error(_ scope: APIKeyScope) -> String? { errors[scope] }

    func save(_ value: String, for scope: APIKeyScope) {
        apply(APIKey.set(value, for: scope), scope)
    }

    func regenerate(_ scope: APIKeyScope) {
        apply(APIKey.regenerate(scope).map { _ in () }, scope)
    }

    func setEnabled(_ enabled: Bool, for scope: APIKeyScope) {
        apply(APIKey.setAuthenticationEnabled(enabled, for: scope), scope)
    }

    func disable(_ scope: APIKeyScope) {
        setEnabled(false, for: scope)
    }

    private func refresh(_ scope: APIKeyScope) {
        let state = APIKey.state(scope)
        states[scope] = state
        if case .unavailable(let reason) = state { errors[scope] = reason }
        else { errors[scope] = nil }
    }

    private func apply(_ result: Result<Void, APIKeyError>, _ scope: APIKeyScope) {
        refresh(scope)
        if case .failure(let error) = result { errors[scope] = error.message }
    }
}
