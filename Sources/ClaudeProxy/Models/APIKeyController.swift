import Foundation
import Combine

@MainActor
final class APIKeyController: ObservableObject {
    @Published private(set) var states: [APIKeyScope: APIKeyState] = [:]
    @Published private(set) var errors: [APIKeyScope: String] = [:]

    init() {
        for scope in APIKeyScope.allCases { refresh(scope) }
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
        APIKey.isAuthenticationEnabled(scope)
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
