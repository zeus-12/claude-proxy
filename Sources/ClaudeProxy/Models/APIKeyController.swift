import Combine
import Foundation

@MainActor
final class APIKeyController: ObservableObject {
    @Published private(set) var states: [APIKeyScope: APIKeyState] = [:]
    @Published private(set) var requiredScopes: Set<APIKeyScope> = []
    @Published private(set) var environmentManagedScopes: Set<APIKeyScope> = []

    private let loadState: @Sendable (APIKeyScope) -> APIKeyState

    init(
        loadState: @escaping @Sendable (APIKeyScope) -> APIKeyState = { APIKey.state($0) }
    ) {
        self.loadState = loadState
        for scope in APIKeyScope.allCases {
            states[scope] = loadState(scope)
            if APIKey.isRequired(scope) { requiredScopes.insert(scope) }
            if APIKey.isEnvironmentManaged(scope) { environmentManagedScopes.insert(scope) }
        }
    }

    func state(_ scope: APIKeyScope) -> APIKeyState {
        states[scope] ?? .disabled
    }

    func key(_ scope: APIKeyScope) -> String? {
        if case .required(let key) = state(scope) { return key }
        return nil
    }

    func isConfigured(_ scope: APIKeyScope) -> Bool {
        key(scope) != nil
    }

    func isRequired(_ scope: APIKeyScope) -> Bool {
        requiredScopes.contains(scope)
    }

    func isEnvironmentManaged(_ scope: APIKeyScope) -> Bool {
        environmentManagedScopes.contains(scope)
    }

    func setRequired(_ required: Bool, for scope: APIKeyScope) {
        guard !isEnvironmentManaged(scope) else { return }
        APIKey.setRequired(required, for: scope)
        if required {
            requiredScopes.insert(scope)
        } else {
            requiredScopes.remove(scope)
        }
    }

    @discardableResult
    func save(_ value: String, for scope: APIKeyScope) -> Bool {
        apply(APIKey.set(value, for: scope), scope: scope)
    }

    @discardableResult
    func generate(_ scope: APIKeyScope) -> String? {
        switch APIKey.regenerate(scope) {
        case .success(let key):
            states[scope] = .required(key)
            return key
        case .failure(let error):
            states[scope] = .unavailable(error.message)
            return nil
        }
    }

    func refresh(_ scope: APIKeyScope) {
        states[scope] = loadState(scope)
    }

    @discardableResult
    private func apply(
        _ result: Result<Void, APIKeyError>,
        scope: APIKeyScope
    ) -> Bool {
        switch result {
        case .success:
            states[scope] = APIKey.state(scope)
            return true
        case .failure(let error):
            states[scope] = .unavailable(error.message)
            return false
        }
    }
}
