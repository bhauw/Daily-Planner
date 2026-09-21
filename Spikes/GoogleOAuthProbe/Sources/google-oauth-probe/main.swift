import Foundation
import GoogleOAuthCore
import Darwin

private func writeJSON<T: Encodable>(_ value: T, to handle: FileHandle) {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    guard var data = try? encoder.encode(value) else { return }
    data.append(0x0A)
    handle.write(data)
}

private func localCleanup(
    tokenStore: any RefreshTokenStoring,
    cacheCleaner: any URLCacheClearing
) -> GoogleOAuthCleanupStatus {
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

private func runLiveReadOnly() async -> Int32 {
    let tokenStore = KeychainRefreshToken()
    let cacheCleaner = SharedURLCacheCleaner()
    let clientID: String
    do {
        clientID = try GoogleOAuthEnvironment.clientID(from: ProcessInfo.processInfo.environment)
    } catch {
        writeJSON(
            GoogleOAuthSafeFailureOutput(
                status: .failedSafe,
                primary: GoogleOAuthEnvironmentError.missingConfiguration.rawValue,
                cleanup: localCleanup(tokenStore: tokenStore, cacheCleaner: cacheCleaner)
            ),
            to: .standardError
        )
        return 78
    }

    let authorizationSession = LoopbackSystemBrowserAuthorizationSession()
    let client = GoogleReadOnlyClient(
        tokenStore: tokenStore,
        cacheCleaner: cacheCleaner
    )
    let controller = GoogleOAuthLiveController(
        authorizationSession: authorizationSession,
        readOnlyRunner: client,
        tokenStore: tokenStore,
        cacheCleaner: cacheCleaner
    )
    let liveTask = Task {
        try await controller.run(clientID: clientID, callbackTimeout: 180)
    }
    let signals = CancellationSignalBridge {
        liveTask.cancel()
    }
    let outcome = await liveTask.result
    signals.stop()

    switch outcome {
    case let .success(result):
        writeJSON(result, to: .standardOutput)
        return result.cleanupSucceeded ? 0 : 1
    case let .failure(failure as GoogleReadOnlyRunFailure):
        writeJSON(
            GoogleOAuthSafeFailureOutput(
                status: .failedSafe,
                primary: failure.primary.rawValue,
                cleanup: failure.cleanup
            ),
            to: .standardError
        )
        return 1
    case let .failure(failure as GoogleOAuthLiveControllerFailure):
        writeJSON(
            GoogleOAuthSafeFailureOutput(
                status: .failedSafe,
                primary: failure.primary.rawValue,
                cleanup: failure.cleanup
            ),
            to: .standardError
        )
        return 1
    case .failure:
        writeJSON(
            GoogleOAuthSafeFailureOutput(
                status: .failedSafe,
                primary: GoogleReadOnlyClientError.invalidResponse.rawValue,
                cleanup: localCleanup(tokenStore: tokenStore, cacheCleaner: cacheCleaner)
            ),
            to: .standardError
        )
        return 1
    }
}

private final class CancellationSignalBridge: @unchecked Sendable {
    private let interrupt: DispatchSourceSignal
    private let terminate: DispatchSourceSignal

    init(cancel: @escaping @Sendable () -> Void) {
        signal(SIGINT, SIG_IGN)
        signal(SIGTERM, SIG_IGN)
        interrupt = DispatchSource.makeSignalSource(signal: SIGINT, queue: .global())
        terminate = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .global())
        interrupt.setEventHandler(handler: cancel)
        terminate.setEventHandler(handler: cancel)
        interrupt.resume()
        terminate.resume()
    }

    func stop() {
        interrupt.cancel()
        terminate.cancel()
        signal(SIGINT, SIG_DFL)
        signal(SIGTERM, SIG_DFL)
    }
}

let arguments = Array(CommandLine.arguments.dropFirst())
let exitCode: Int32

switch arguments {
case ["--dry-run"]:
    print(GoogleOAuthDryRunReport.render())
    exitCode = 0
case ["--live-readonly"]:
    exitCode = await runLiveReadOnly()
default:
    FileHandle.standardError.write(Data("usage: google-oauth-probe --dry-run | --live-readonly\n".utf8))
    exitCode = 64
}

if exitCode != 0 {
    exit(exitCode)
}
