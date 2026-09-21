import DailyPlannerDomain
import Foundation

public struct GoogleAuthorizationGrant: Sendable {
    public let authorizationCode: String
    public let request: GoogleOAuthRequest

    public init(authorizationCode: String, request: GoogleOAuthRequest) {
        self.authorizationCode = authorizationCode
        self.request = request
    }
}

public enum GoogleAuthorizationSessionError: Error, Equatable, Sendable {
    case alreadyAuthorizing
    case listenerFailed
    case requestConstructionFailed
    case invalidCallback
    case browserRejected
    case cancelled
    case timedOut
}

public final class GoogleAuthorizationSession: @unchecked Sendable {
    public typealias ListenerFactory = @Sendable () throws -> any GoogleLoopbackListening

    private enum Startup {
        case waiting
        case preparing
        case ready(GoogleOAuthRequest)
    }

    private struct ActiveAuthorization {
        let identifier: UUID
        let clientIdentifier: String
        /// Which approved scope set this consent screen is asking for.
        let capability: GoogleGrantedCapability
        let listener: any GoogleLoopbackListening
        let continuation: CheckedContinuation<GoogleAuthorizationGrant, Error>
        var startup: Startup = .waiting
        var consentStarted = false
        var browserAttempted = false
        var timeoutTask: Task<Void, Never>?
        var consentTask: Task<Void, Never>?
    }

    private let lock = NSLock()
    private let listenerFactory: ListenerFactory
    private let browser: any SystemBrowserOpening
    private var active: ActiveAuthorization?

    public init(
        listenerFactory: @escaping ListenerFactory = { GoogleLoopbackListener() },
        browser: any SystemBrowserOpening
    ) {
        self.listenerFactory = listenerFactory
        self.browser = browser
    }

    deinit {
        cancel()
    }

    /// `capability` decides which approved scope set the consent screen asks for. It defaults to
    /// read-only so every existing caller keeps its current behaviour; only an explicit request
    /// for write access asks the user to grant sending and event creation.
    public func authorize(
        clientIdentifier: String,
        timeout: Duration,
        capability: GoogleGrantedCapability = .readOnly,
        onAwaitingConsent: @escaping @Sendable () async -> Void = {}
    ) async throws -> GoogleAuthorizationGrant {
        let identifier = UUID()
        return try await withTaskCancellationHandler {
            guard !Task.isCancelled else {
                throw GoogleAuthorizationSessionError.cancelled
            }

            let listener: any GoogleLoopbackListening
            do {
                listener = try listenerFactory()
            } catch {
                if Task.isCancelled {
                    throw GoogleAuthorizationSessionError.cancelled
                }
                throw GoogleAuthorizationSessionError.listenerFailed
            }
            guard !Task.isCancelled else {
                listener.cancel()
                throw GoogleAuthorizationSessionError.cancelled
            }

            return try await withCheckedThrowingContinuation { continuation in
                let installed = locked { active -> Bool in
                    guard active == nil else { return false }
                    active = ActiveAuthorization(
                        identifier: identifier,
                        clientIdentifier: clientIdentifier,
                        capability: capability,
                        listener: listener,
                        continuation: continuation
                    )
                    return true
                }

                guard installed else {
                    listener.cancel()
                    continuation.resume(throwing: Task.isCancelled
                        ? GoogleAuthorizationSessionError.cancelled
                        : GoogleAuthorizationSessionError.alreadyAuthorizing)
                    return
                }

                if Task.isCancelled {
                    finish(identifier: identifier, result: .failure(.cancelled))
                    return
                }

                do {
                    try listener.start(timeout: timeout) { [weak self] event in
                        self?.handle(event, identifier: identifier, onAwaitingConsent: onAwaitingConsent)
                    }
                } catch {
                    handleStartupFailure(identifier: identifier)
                }

                let timeoutTask = Task { [weak self] in
                    do {
                        try await Task.sleep(for: timeout)
                    } catch {
                        return
                    }
                    self?.finish(identifier: identifier, result: .failure(.timedOut))
                }
                let retained = locked { active -> Bool in
                    guard active?.identifier == identifier else { return false }
                    active?.timeoutTask = timeoutTask
                    return true
                }
                if !retained { timeoutTask.cancel() }
            }
        } onCancel: {
            self.finish(identifier: identifier, result: .failure(.cancelled))
        }
    }

    public func cancel() {
        let identifier = locked { $0?.identifier }
        guard let identifier else { return }
        finish(identifier: identifier, result: .failure(.cancelled))
    }

    private func handle(
        _ event: GoogleLoopbackEvent,
        identifier: UUID,
        onAwaitingConsent: @escaping @Sendable () async -> Void
    ) {
        switch event {
        case .ready(let port):
            handleReady(port: port, identifier: identifier, onAwaitingConsent: onAwaitingConsent)
        case .callback(let target, let acknowledgment):
            handleCallback(target: target, acknowledgment: acknowledgment, identifier: identifier)
        case .startupFailed:
            handleStartupFailure(identifier: identifier)
        case .invalidRequest:
            finish(identifier: identifier, result: .failure(.invalidCallback))
        case .timedOut:
            finish(identifier: identifier, result: .failure(.timedOut))
        }
    }

    private func handleReady(
        port: Int,
        identifier: UUID,
        onAwaitingConsent: @escaping @Sendable () async -> Void
    ) {
        let ready: (clientIdentifier: String, capability: GoogleGrantedCapability)? = locked { active in
            guard active?.identifier == identifier,
                  case .waiting = active?.startup,
                  let clientIdentifier = active?.clientIdentifier,
                  let capability = active?.capability else { return nil }
            active?.startup = .preparing
            return (clientIdentifier, capability)
        }
        guard let ready else { return }
        let readyClientIdentifier = ready.clientIdentifier

        let request: GoogleOAuthRequest
        do {
            request = try GoogleOAuthRequest(
                clientIdentifier: readyClientIdentifier,
                redirectPort: port,
                pkce: PKCEPair.generate(),
                state: OAuthState.generate(),
                scopes: ready.capability.scopes
            )
        } catch {
            finish(identifier: identifier, result: .failure(.requestConstructionFailed))
            return
        }

        let becameReady = locked { active -> Bool in
            guard active?.identifier == identifier,
                  case .preparing = active?.startup else { return false }
            active?.startup = .ready(request)
            return true
        }
        guard becameReady else { return }

        let consentTask = Task { [weak self] in
            guard self?.beginConsentIfActive(identifier: identifier) == true else { return }
            await onAwaitingConsent()
            await self?.openBrowserIfActive(identifier: identifier)
        }
        let retained = locked { active -> Bool in
            guard active?.identifier == identifier else { return false }
            active?.consentTask = consentTask
            return true
        }
        if !retained { consentTask.cancel() }
    }

    private func beginConsentIfActive(identifier: UUID) -> Bool {
        locked { active in
            guard active?.identifier == identifier,
                  active?.consentStarted == false,
                  case .ready = active?.startup else { return false }
            active?.consentStarted = true
            return true
        }
    }

    private func openBrowserIfActive(identifier: UUID) async {
        let request: GoogleOAuthRequest? = locked { active in
            guard active?.identifier == identifier,
                  active?.browserAttempted == false,
                  case .ready(let request) = active?.startup else { return nil }
            active?.browserAttempted = true
            return request
        }
        guard let request else { return }

        let opened = await browser.open(request.authorizationURL)
        if !opened {
            finish(identifier: identifier, result: .failure(.browserRejected))
        }
    }

    private func handleCallback(
        target: String,
        acknowledgment: any GoogleLoopbackAcknowledging,
        identifier: UUID
    ) {
        let request: GoogleOAuthRequest? = locked { active in
            guard active?.identifier == identifier,
                  case .ready(let request) = active?.startup else { return nil }
            return request
        }
        guard let request else {
            acknowledgment.respond(.failure)
            finish(identifier: identifier, result: .failure(.invalidCallback))
            return
        }

        do {
            let callback = try GoogleOAuthCallback.parse(target: target, expectedState: request.state)
            let grant = GoogleAuthorizationGrant(
                authorizationCode: callback.authorizationCode,
                request: request
            )
            guard let completed = claimActiveAuthorization(identifier: identifier) else {
                acknowledgment.respond(.failure)
                return
            }
            acknowledgment.respond(.success)
            complete(completed, result: .success(grant))
        } catch GoogleOAuthCallbackError.authorizationDenied {
            acknowledgment.respond(.failure)
            finish(identifier: identifier, result: .failure(.cancelled))
        } catch {
            acknowledgment.respond(.failure)
            finish(identifier: identifier, result: .failure(.invalidCallback))
        }
    }

    private func handleStartupFailure(identifier: UUID) {
        let shouldFail = locked { active -> Bool in
            guard active?.identifier == identifier else { return false }
            if case .waiting = active?.startup { return true }
            return false
        }
        if shouldFail {
            finish(identifier: identifier, result: .failure(.listenerFailed))
        }
    }

    private func finish(
        identifier: UUID,
        result: Result<GoogleAuthorizationGrant, GoogleAuthorizationSessionError>
    ) {
        guard let completed = claimActiveAuthorization(identifier: identifier) else { return }
        complete(completed, result: result)
    }

    private func claimActiveAuthorization(identifier: UUID) -> ActiveAuthorization? {
        locked { active in
            guard active?.identifier == identifier else { return nil }
            defer { active = nil }
            return active
        }
    }

    private func complete(
        _ completed: ActiveAuthorization,
        result: Result<GoogleAuthorizationGrant, GoogleAuthorizationSessionError>
    ) {
        completed.timeoutTask?.cancel()
        completed.consentTask?.cancel()
        completed.listener.cancel()
        switch result {
        case .success(let grant):
            completed.continuation.resume(returning: grant)
        case .failure(let error):
            completed.continuation.resume(throwing: error)
        }
    }

    @discardableResult
    private func locked<T>(_ body: (inout ActiveAuthorization?) -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body(&active)
    }
}
