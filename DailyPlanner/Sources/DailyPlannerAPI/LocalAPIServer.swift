import Foundation
import Network

/// A loopback-only HTTP/1.1 server for the planner engine, built on `Network.framework`
/// (`NWListener`) with no external package. It binds `127.0.0.1` exclusively on a random high
/// port chosen at launch, mints a per-launch bearer token, and serves the API and the web
/// bundle. The transport now frames request bodies so the finite set of write routes can take
/// one; which verbs reach which paths is decided in `RequestGuard`, not here.
///
/// Logging is deliberately absent: no request line, body, header, path, or token is ever
/// written out. The only observable signals are the listener state and the returned port/token.
public final class LocalAPIServer: @unchecked Sendable {
    /// The bearer token minted for this launch. Injected into the web view; never persisted.
    public let token: String

    /// Swappable so the engine can open instantly on the synthetic source and upgrade to the
    /// live Google-backed one once credentials resolve, instead of blocking app launch behind a
    /// Keychain prompt. All access is serialized on `queue`.
    private var service: PlannerAPIService
    private let webRoot: URL?
    private let extraAllowedOrigins: Set<String>
    private let queue = DispatchQueue(label: "com.example.dailyplanner.api", qos: .userInitiated)

    private var listener: NWListener?
    private var boundPort: UInt16?
    /// Held only between `start()` and the listener reaching `.ready`/`.failed`; resumed exactly
    /// once. All access is serialized on `queue`, so no additional lock is needed.
    private var startContinuation: CheckedContinuation<UInt16, Error>?

    /// - Parameters:
    ///   - referenceDate: instant the synthetic data is generated around (defaults to now).
    ///   - webRoot: directory of built web assets to serve at `/`; nil serves a placeholder.
    ///   - extraAllowedOrigins: additional accepted `Origin` values (dev only, e.g. the Vite
    ///     dev server). Empty in production so only the loopback page is accepted.
    public convenience init(referenceDate: Date = Date(), webRoot: URL? = nil, extraAllowedOrigins: Set<String> = []) {
        self.init(
            service: PlannerAPIService(referenceDate: referenceDate),
            webRoot: webRoot,
            extraAllowedOrigins: extraAllowedOrigins
        )
    }

    /// Starts the server over an already-built service — used to serve the live Google-backed
    /// source once an account is connected, instead of the synthetic one. Everything about the
    /// transport, the bearer token and the request guard is identical either way; only the data
    /// source differs — and with it whether the write routes have anything to call.
    public init(
        service: PlannerAPIService,
        webRoot: URL? = nil,
        extraAllowedOrigins: Set<String> = []
    ) {
        self.service = service
        self.webRoot = webRoot
        self.extraAllowedOrigins = extraAllowedOrigins
        self.token = HTTPSecurity.generateBearerToken()
    }

    /// Replaces the data source in place. Existing connections keep the router they already
    /// built; every subsequent request uses the new service.
    public func replaceService(_ newService: PlannerAPIService) {
        queue.async { self.service = newService }
    }

    /// Starts the listener and resolves with the bound loopback port once it is ready.
    /// Throws if the listener fails to come up.
    public func start() async throws -> UInt16 {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                self.startContinuation = continuation
                do {
                    try self.startLocked()
                } catch {
                    self.resumeStart(.failure(error))
                }
            }
        }
    }

    /// Resumes the pending `start()` continuation exactly once. Must be called on `queue`.
    private func resumeStart(_ result: Result<UInt16, Error>) {
        guard let continuation = startContinuation else { return }
        startContinuation = nil
        continuation.resume(with: result)
    }

    public func stop() {
        queue.async {
            self.listener?.cancel()
            self.listener = nil
        }
    }

    /// The bound port, once `start()` has completed.
    public var port: UInt16? {
        queue.sync { boundPort }
    }

    private func startLocked() throws {
        // Bind loopback ONLY. `requiredLocalEndpoint` pins the listener to 127.0.0.1 so it is
        // never reachable on a LAN interface; the port is left ephemeral (random high port).
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: .any)
        parameters.allowLocalEndpointReuse = true

        let listener = try NWListener(using: parameters)
        self.listener = listener

        listener.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                guard let rawPort = self.listener?.port?.rawValue else {
                    self.resumeStart(.failure(LocalAPIServerError.noPort))
                    return
                }
                self.boundPort = rawPort
                self.resumeStart(.success(rawPort))
            case .failed(let error):
                self.resumeStart(.failure(error))
            case .cancelled:
                self.resumeStart(.failure(LocalAPIServerError.cancelled))
            default:
                break
            }
        }

        listener.newConnectionHandler = { [weak self] connection in
            self?.handle(connection)
        }

        listener.start(queue: queue)
    }

    private func handle(_ connection: NWConnection) {
        connection.start(queue: queue)
        receive(connection, buffer: Data())
    }

    /// Accumulates bytes until `HTTPFraming` can read one whole request out of them.
    ///
    /// This used to stop at the header terminator and hand the buffer straight to the parser —
    /// correct while every route was a GET, and wrong the moment one of them takes a body. A
    /// request whose body arrives in a second TCP segment would otherwise have been dispatched
    /// with that body still in flight.
    private func receive(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else { connection.cancel(); return }
            if error != nil {
                connection.cancel()
                return
            }

            var accumulated = buffer
            if let data { accumulated.append(data) }

            // Hard ceiling on one request, independent of what its headers claim. Framing has
            // its own header and body budgets; this is the backstop that holds when a client
            // simply never stops sending.
            if accumulated.count > HTTPLimits.maxHeaderBytes + HTTPLimits.maxBodyBytes {
                self.send(.bodyTooLarge, on: connection, includeBody: true)
                return
            }

            switch HTTPFraming.frame(accumulated) {
            case .complete(let request):
                self.dispatch(request, on: connection)
            case .refused(let response):
                self.send(response, on: connection, includeBody: true)
            case .incomplete:
                if isComplete {
                    // The peer closed mid-request; there is nothing left to wait for.
                    connection.cancel()
                } else {
                    self.receive(connection, buffer: accumulated)
                }
            }
        }
    }

    private func dispatch(_ request: HTTPRequest, on connection: NWConnection) {
        let includeBody = request.method != HTTPMethod.head.rawValue
        let router = APIRouter(
            guardCheck: RequestGuard(
                token: token,
                port: boundPort ?? 0,
                extraAllowedOrigins: extraAllowedOrigins
            ),
            service: service,
            assets: StaticWebAssets(root: webRoot)
        )
        Task {
            let response = await router.respond(to: request)
            self.send(response, on: connection, includeBody: includeBody)
        }
    }

    private func send(_ response: HTTPResponse, on connection: NWConnection, includeBody: Bool) {
        let data = response.serialize(includeBody: includeBody)
        connection.send(content: data, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }
}

public enum LocalAPIServerError: Error, Sendable {
    case noPort
    case cancelled
}
