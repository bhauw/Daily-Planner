import AppKit
import Foundation

public enum GoogleOAuthEnvironmentError: String, Error, Equatable, Sendable {
    case missingConfiguration
}

public enum GoogleOAuthEnvironment {
    public static let clientIDKey = "DAILY_PLANNER_GOOGLE_CLIENT_ID"

    public static func clientID(from environment: [String: String]) throws -> String {
        guard let value = environment[clientIDKey]?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else {
            throw GoogleOAuthEnvironmentError.missingConfiguration
        }
        return value
    }
}

public struct GoogleOAuthSafeFailureOutput: Codable, Equatable, Sendable {
    public enum Status: String, Codable, Sendable {
        case failedSafe = "FAILED_SAFE"
    }

    public let status: Status
    public let primary: String
    public let cleanup: GoogleOAuthCleanupStatus

    public init(status: Status, primary: String, cleanup: GoogleOAuthCleanupStatus) {
        self.status = status
        self.primary = primary
        self.cleanup = cleanup
    }
}

public struct OAuthAuthorizationGrant: Sendable {
    public let code: String
    public let request: OAuthRequest

    public init(code: String, request: OAuthRequest) {
        self.code = code
        self.request = request
    }
}

public protocol SystemBrowserOpening: Sendable {
    func open(_ url: URL) async -> Bool
}

public struct WorkspaceSystemBrowser: SystemBrowserOpening {
    public init() {}

    public func open(_ url: URL) async -> Bool {
        await MainActor.run {
            NSWorkspace.shared.open(url)
        }
    }
}

public protocol OAuthAuthorizationSession: Sendable {
    func authorize(clientID: String, timeout: TimeInterval) async throws -> OAuthAuthorizationGrant
    func cancel() async
}

public final class LoopbackSystemBrowserAuthorizationSession: OAuthAuthorizationSession, @unchecked Sendable {
    private let browser: any SystemBrowserOpening
    private let lock = NSLock()
    private var activeListener: LoopbackCallbackListener?

    public init(browser: any SystemBrowserOpening = WorkspaceSystemBrowser()) {
        self.browser = browser
    }

    public func authorize(
        clientID: String,
        timeout: TimeInterval
    ) async throws -> OAuthAuthorizationGrant {
        let pkce = try PKCEPair.generate()
        let state = try OAuthState.generate()
        let listener = LoopbackCallbackListener(expectedState: state)
        setActiveListener(listener)
        defer { setActiveListener(nil) }

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let completionGate = AuthorizationCompletionGate(continuation)
                let requestBox = LockedAuthorizationRequest()
                do {
                    try listener.start(
                        timeout: timeout,
                        onReady: { [browser] result in
                            switch result {
                            case let .success(redirectURL):
                                guard let portValue = redirectURL.port,
                                      let port = UInt16(exactly: portValue) else {
                                    listener.cancel(with: .listenerFailed)
                                    return
                                }
                                do {
                                    let request = try OAuthRequest(
                                        clientID: clientID,
                                        redirectPort: port,
                                        pkce: pkce,
                                        state: state
                                    )
                                    requestBox.set(request)
                                    Task {
                                        if !(await browser.open(request.authorizationURL)) {
                                            listener.cancelForBrowserCancellation()
                                        }
                                    }
                                } catch {
                                    listener.cancel(with: .listenerFailed)
                                }
                            case let .failure(error):
                                listener.cancel(with: error)
                            }
                        },
                        completion: { result in
                            switch result {
                            case let .success(code):
                                guard let request = requestBox.get() else {
                                    completionGate.resume(.failure(.listenerFailed))
                                    return
                                }
                                completionGate.resume(
                                    .success(OAuthAuthorizationGrant(code: code, request: request))
                                )
                            case let .failure(error):
                                completionGate.resume(.failure(error))
                            }
                        }
                    )
                } catch {
                    completionGate.resume(.failure(.listenerFailed))
                }
            }
        } onCancel: {
            listener.cancelForBrowserCancellation()
        }
    }

    public func cancel() async {
        currentListener()?.cancelForBrowserCancellation()
    }

    private func setActiveListener(_ listener: LoopbackCallbackListener?) {
        lock.lock()
        activeListener = listener
        lock.unlock()
    }

    private func currentListener() -> LoopbackCallbackListener? {
        lock.lock()
        defer { lock.unlock() }
        return activeListener
    }
}

public protocol GoogleReadOnlyRunning: Sendable {
    func run(
        authorizationCode: String,
        request: OAuthRequest
    ) async throws -> GoogleReadOnlyProbeResult
}

extension GoogleReadOnlyClient: GoogleReadOnlyRunning {}

public struct GoogleOAuthLiveControllerFailure: Codable, Error, Equatable, Sendable {
    public let primary: LoopbackCallbackError
    public let cleanup: GoogleOAuthCleanupStatus

    public init(primary: LoopbackCallbackError, cleanup: GoogleOAuthCleanupStatus) {
        self.primary = primary
        self.cleanup = cleanup
    }
}

public struct GoogleOAuthLiveController: Sendable {
    private let authorizationSession: any OAuthAuthorizationSession
    private let readOnlyRunner: any GoogleReadOnlyRunning
    private let tokenStore: any RefreshTokenStoring
    private let cacheCleaner: any URLCacheClearing

    public init(
        authorizationSession: any OAuthAuthorizationSession,
        readOnlyRunner: any GoogleReadOnlyRunning,
        tokenStore: any RefreshTokenStoring,
        cacheCleaner: any URLCacheClearing
    ) {
        self.authorizationSession = authorizationSession
        self.readOnlyRunner = readOnlyRunner
        self.tokenStore = tokenStore
        self.cacheCleaner = cacheCleaner
    }

    public func run(
        clientID: String,
        callbackTimeout: TimeInterval
    ) async throws -> GoogleReadOnlyProbeResult {
        let grant: OAuthAuthorizationGrant
        do {
            grant = try await authorizationSession.authorize(
                clientID: clientID,
                timeout: callbackTimeout
            )
        } catch {
            await authorizationSession.cancel()
            let primary = (error as? LoopbackCallbackError) ?? .listenerFailed
            throw GoogleOAuthLiveControllerFailure(
                primary: primary,
                cleanup: cleanupBeforeGrant()
            )
        }

        return try await readOnlyRunner.run(
            authorizationCode: grant.code,
            request: grant.request
        )
    }

    private func cleanupBeforeGrant() -> GoogleOAuthCleanupStatus {
        let keychainDeletion: GoogleCleanupDisposition
        do {
            try tokenStore.delete()
            keychainDeletion = .succeeded
        } catch {
            keychainDeletion = .failed
        }
        cacheCleaner.clear()
        return GoogleOAuthCleanupStatus(
            remoteRevocation: .notRequired,
            keychainDeletion: keychainDeletion,
            cacheCleared: true
        )
    }
}

private final class LockedAuthorizationRequest: @unchecked Sendable {
    private let lock = NSLock()
    private var request: OAuthRequest?

    func set(_ request: OAuthRequest) {
        lock.lock()
        self.request = request
        lock.unlock()
    }

    func get() -> OAuthRequest? {
        lock.lock()
        defer { lock.unlock() }
        return request
    }
}

private final class AuthorizationCompletionGate: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<OAuthAuthorizationGrant, any Error>?

    init(_ continuation: CheckedContinuation<OAuthAuthorizationGrant, any Error>) {
        self.continuation = continuation
    }

    func resume(_ result: Result<OAuthAuthorizationGrant, LoopbackCallbackError>) {
        lock.lock()
        let continuation = continuation
        self.continuation = nil
        lock.unlock()
        guard let continuation else { return }
        continuation.resume(with: result.mapError { $0 as any Error })
    }
}
