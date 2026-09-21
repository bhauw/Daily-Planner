import Foundation

/// The security gate every request passes through before any handler runs. Pure and
/// synchronous so it can be exercised directly in tests. It enforces, in order: allowed method,
/// loopback `Host`, matching `Origin`, and — for `/api/*` — a valid bearer token compared in
/// constant time. Static asset paths are reachable without a token (the web view must load the
/// page before it has one) but still require a loopback `Host`.
///
/// POST is served only on `APIWriteRoute`, and it is held to two rules a GET is not:
///
///  - **`Origin` must be present and allowed**, not merely allowed when present. A page on
///    another origin can make a browser issue a cross-site POST, and the browser always attaches
///    `Origin` to it. Requiring the header is what makes a drive-by write fail; accepting a
///    missing one would leave exactly the hole the token is there to close.
///  - **`Content-Type` must be JSON.** `application/x-www-form-urlencoded`, `multipart/form-data`
///    and `text/plain` are the three types an HTML form can send without a preflight. Refusing
///    them means a cross-site write cannot even be formed without CORS, which the browser will
///    not grant.
///
/// Neither replaces the bearer token; they are the layers that hold if it ever leaks into a page.
struct RequestGuard {
    let token: String
    let port: UInt16
    /// Extra origins accepted only in dev mode (the Vite dev server). Empty in production, so
    /// the default posture is strictly the loopback page itself.
    var extraAllowedOrigins: Set<String> = []

    private var allowedHosts: Set<String> {
        ["127.0.0.1:\(port)", "localhost:\(port)"]
    }

    private var allowedOrigins: Set<String> {
        Set(["http://127.0.0.1:\(port)", "http://localhost:\(port)"]).union(extraAllowedOrigins)
    }

    private static let methodNotAllowed = HTTPResponse.error(
        405, "Method Not Allowed", .methodNotAllowed, "Method not allowed."
    )
    private static let unrecognizedOrigin = HTTPResponse.error(
        401, "Unauthorized", .forbiddenOrigin, "Unrecognized origin."
    )

    /// Returns a rejection response if the request must not proceed, or nil if it is allowed.
    func reject(_ request: HTTPRequest) -> HTTPResponse? {
        // 1. Method — GET, HEAD and POST. Every other verb is refused here, before routing, so
        //    no PUT/PATCH/DELETE path can exist anywhere behind this gate.
        guard let method = HTTPMethod(rawValue: request.method) else {
            return Self.methodNotAllowed
        }

        // 2. Host must be loopback. Guards against DNS-rebinding style access.
        guard let host = request.header("host"), allowedHosts.contains(host) else {
            return Self.unrecognizedOrigin
        }

        // 3. Verb and path must agree. A write route answers POST and nothing else; every other
        //    route answers reads and nothing else. A POST to `/api/preview` is method-not-allowed
        //    and says so — the route shape is not a secret (the page that uses it is served on
        //    this same port without a token), so there is nothing to protect by blurring it, and
        //    an honest 405 is what makes the next failure here diagnosable.
        let writeRoute = APIWriteRoute.matching(request.path)
        switch method {
        case .post:
            guard writeRoute != nil else { return Self.methodNotAllowed }
        case .get, .head:
            guard writeRoute == nil else { return Self.methodNotAllowed }
        }

        // 4. Origin must be the loopback page itself. Never `*`. Required outright for POST —
        //    see the type comment for why the "when present" form is not enough for a write.
        let origin = request.header("origin")
        if let origin, !allowedOrigins.contains(origin) {
            return Self.unrecognizedOrigin
        }
        if method == .post, origin == nil {
            return Self.unrecognizedOrigin
        }

        // 5. API routes require the per-launch bearer token. Static paths do not.
        if request.path.hasPrefix("/api/") {
            guard let authorization = request.header("authorization"),
                  let presented = bearerToken(authorization),
                  HTTPSecurity.constantTimeEquals(presented, token) else {
                return .error(401, "Unauthorized", .unauthorized, "Authentication required.")
            }
        }

        // 6. JSON only, on a write. Refusing the three form-encodable types is what keeps a
        //    cross-site write from being expressible without CORS at all.
        if method == .post {
            guard let contentType = request.header("content-type"),
                  Self.isJSON(contentType) else {
                return .error(415, "Unsupported Media Type", .invalidRequest, "Expected JSON.")
            }
        }

        return nil
    }

    /// `application/json`, with or without parameters. Anything else — including the types an
    /// HTML form can post — is refused.
    private static func isJSON(_ contentType: String) -> Bool {
        let base = contentType.split(separator: ";", maxSplits: 1, omittingEmptySubsequences: false)[0]
            .trimmingCharacters(in: .whitespaces)
            .lowercased()
        return base == "application/json"
    }

    private func bearerToken(_ authorization: String) -> String? {
        let prefix = "Bearer "
        guard authorization.hasPrefix(prefix) else { return nil }
        return String(authorization.dropFirst(prefix.count))
    }
}
