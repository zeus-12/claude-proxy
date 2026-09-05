import Foundation

/// Decides whether a request carrying a browser `Origin` may reach an endpoint.
///
/// A loopback endpoint is reachable from every page the user has open: a browser
/// will send a cross-origin request to `127.0.0.1` without asking. API-key
/// protection is optional, so the key cannot be the thing that stops that.
/// `Origin` can: the browser attaches it and page JavaScript can neither forge
/// nor suppress it, while curl, the OpenAI SDKs and native clients send no
/// `Origin` at all. An empty allowlist is therefore invisible to ordinary
/// clients and total against web pages.
enum OriginPolicy {
    enum Decision: Equatable {
        /// No `Origin` header, so not a browser page and nothing to echo back.
        case allowedWithoutOrigin
        /// An allowlisted browser origin, to be echoed in `Access-Control-Allow-Origin`.
        case allowed(String)
        case denied

        var isDenied: Bool { self == .denied }

        /// The value to echo, or nil when no `Access-Control-Allow-Origin`
        /// header should be sent at all.
        var echoedOrigin: String? {
            if case .allowed(let origin) = self { return origin }
            return nil
        }
    }

    /// Browser origins permitted to call the endpoints. Empty by design: nothing
    /// ships allowlisted, so a page can only ever be added deliberately.
    static let allowed: Set<String> = []

    static func decide(originHeader: String?) -> Decision {
        decide(originHeader: originHeader, allowed: allowed)
    }

    static func decide(originHeader: String?, allowed: Set<String>) -> Decision {
        guard let origin = originHeader?.trimmingCharacters(in: .whitespacesAndNewlines),
              !origin.isEmpty else {
            return .allowedWithoutOrigin
        }
        // A `file://` page and a sandboxed iframe both send the literal `null`,
        // which names no origin — matching it would allowlist every one of them.
        guard origin != "null", allowed.contains(origin) else { return .denied }
        return .allowed(origin)
    }
}
