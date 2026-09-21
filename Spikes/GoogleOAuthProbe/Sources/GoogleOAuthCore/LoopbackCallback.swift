@preconcurrency import Network
import Foundation

public enum LoopbackCallbackError: String, Codable, Error, Equatable, Sendable {
    case nonLoopbackHost
    case invalidCallbackPath
    case malformedCallback
    case requestTooLarge
    case duplicateCallback
    case missingCode
    case stateMismatch
    case deniedConsent
    case timeout
    case browserCancelled
    case listenerFailed
}

struct LoopbackHTTPRequestHead: Equatable, Sendable {
    let requestTarget: String
    let hostHeader: String
}

struct LoopbackHTTPRequestAccumulator: Sendable {
    private static let terminator = Data([13, 10, 13, 10])

    private let maximumBytes: Int
    private var buffer = Data()

    init(maximumBytes: Int) {
        self.maximumBytes = maximumBytes
    }

    mutating func append(_ fragment: Data) throws -> LoopbackHTTPRequestHead? {
        guard !fragment.isEmpty else { return nil }
        buffer.append(fragment)
        guard buffer.count <= maximumBytes else {
            throw LoopbackCallbackError.requestTooLarge
        }
        guard let terminatorRange = buffer.range(of: Self.terminator) else {
            return nil
        }
        let headerBytes = buffer[..<terminatorRange.lowerBound]
        guard let request = String(data: headerBytes, encoding: .utf8) else {
            throw LoopbackCallbackError.malformedCallback
        }
        let lines = request.components(separatedBy: "\r\n")
        let requestParts = (lines.first ?? "").split(separator: " ")
        guard requestParts.count == 3,
              requestParts[0] == "GET",
              requestParts[2] == "HTTP/1.1" || requestParts[2] == "HTTP/1.0" else {
            throw LoopbackCallbackError.malformedCallback
        }
        let hostLines = lines.filter { $0.lowercased().hasPrefix("host:") }
        guard hostLines.count == 1 else {
            throw LoopbackCallbackError.malformedCallback
        }
        let host = hostLines[0].dropFirst("host:".count).trimmingCharacters(in: .whitespaces)
        guard !host.isEmpty else {
            throw LoopbackCallbackError.malformedCallback
        }
        return LoopbackHTTPRequestHead(
            requestTarget: String(requestParts[1]),
            hostHeader: host
        )
    }
}

public enum LoopbackTermination: Sendable {
    case timeout
    case browserCancelled
}

public struct LoopbackCallback: Sendable {
    private let expectedState: String
    private var terminalError: LoopbackCallbackError?
    private var consumed = false

    public init(expectedState: String) {
        self.expectedState = expectedState
    }

    public mutating func terminate(_ termination: LoopbackTermination) {
        guard !consumed, terminalError == nil else { return }
        terminalError = termination == .timeout ? .timeout : .browserCancelled
    }

    public mutating func consume(requestTarget: String, hostHeader: String) throws -> String {
        if consumed {
            throw LoopbackCallbackError.duplicateCallback
        }
        if let terminalError {
            throw terminalError
        }
        guard Self.isExactLoopbackHost(hostHeader) else {
            throw LoopbackCallbackError.nonLoopbackHost
        }

        let components: URLComponents
        if let absolute = URLComponents(string: requestTarget), absolute.host != nil {
            guard absolute.host == "127.0.0.1" else {
                throw LoopbackCallbackError.nonLoopbackHost
            }
            components = absolute
        } else {
            guard let relative = URLComponents(string: "http://127.0.0.1\(requestTarget)") else {
                throw LoopbackCallbackError.malformedCallback
            }
            components = relative
        }
        guard components.path == "/oauth/callback" else {
            throw LoopbackCallbackError.invalidCallbackPath
        }

        let items = components.queryItems ?? []
        guard !Self.hasDuplicateSensitiveItems(items) else {
            throw LoopbackCallbackError.malformedCallback
        }
        let state = items.first(where: { $0.name == "state" })?.value ?? ""
        guard ConstantTime.equals(expectedState, state) else {
            throw LoopbackCallbackError.stateMismatch
        }
        if items.first(where: { $0.name == "error" })?.value == "access_denied" {
            consumed = true
            throw LoopbackCallbackError.deniedConsent
        }
        guard let code = items.first(where: { $0.name == "code" })?.value, !code.isEmpty else {
            throw LoopbackCallbackError.missingCode
        }

        consumed = true
        return code
    }

    private static func isExactLoopbackHost(_ value: String) -> Bool {
        if value == "127.0.0.1" { return true }
        guard value.hasPrefix("127.0.0.1:") else { return false }
        return UInt16(value.dropFirst("127.0.0.1:".count)) != nil
    }

    private static func hasDuplicateSensitiveItems(_ items: [URLQueryItem]) -> Bool {
        for name in ["code", "state", "error"] where items.filter({ $0.name == name }).count > 1 {
            return true
        }
        return false
    }
}

public final class LoopbackCallbackListener: @unchecked Sendable {
    public typealias ReadyHandler = @Sendable (Result<URL, LoopbackCallbackError>) -> Void
    public typealias CompletionHandler = @Sendable (Result<String, LoopbackCallbackError>) -> Void

    private let queue = DispatchQueue(label: "com.example.dailyplanner.google-oauth-loopback")
    private var listener: NWListener?
    private var callback: LoopbackCallback
    private var completion: CompletionHandler?
    private var timeoutWorkItem: DispatchWorkItem?
    private var completed = false
    private let maximumRequestHeadBytes = 16_384

    public init(expectedState: String) {
        callback = LoopbackCallback(expectedState: expectedState)
    }

    public func start(
        timeout: TimeInterval,
        onReady: @escaping ReadyHandler,
        completion: @escaping CompletionHandler
    ) throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        let listener = try NWListener(using: parameters, on: .any)
        self.listener = listener
        self.completion = completion

        listener.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            self.queue.async {
                switch state {
                case .ready:
                    guard let port = listener.port,
                          let url = URL(string: "http://127.0.0.1:\(port.rawValue)/oauth/callback") else {
                        onReady(.failure(.listenerFailed))
                        self.finish(.failure(.listenerFailed))
                        return
                    }
                    onReady(.success(url))
                case .failed:
                    onReady(.failure(.listenerFailed))
                    self.finish(.failure(.listenerFailed))
                default:
                    break
                }
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { return }
            self.queue.async {
                self.receive(connection)
            }
        }
        listener.start(queue: queue)

        let timeoutWorkItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.callback.terminate(.timeout)
            self.finish(.failure(.timeout))
        }
        self.timeoutWorkItem = timeoutWorkItem
        queue.asyncAfter(deadline: .now() + timeout, execute: timeoutWorkItem)
    }

    public func cancelForBrowserCancellation() {
        cancel(with: .browserCancelled)
    }

    public func cancel(with error: LoopbackCallbackError) {
        queue.async { [weak self] in
            guard let self else { return }
            if error == .browserCancelled {
                self.callback.terminate(.browserCancelled)
            }
            self.finish(.failure(error))
        }
    }

    private func receive(_ connection: NWConnection) {
        connection.start(queue: queue)
        receiveNext(connection, accumulator: LoopbackHTTPRequestAccumulator(maximumBytes: maximumRequestHeadBytes))
    }

    private func receiveNext(
        _ connection: NWConnection,
        accumulator: LoopbackHTTPRequestAccumulator
    ) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 4_096) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            self.queue.async {
                var nextAccumulator = accumulator
                do {
                    if let data, let head = try nextAccumulator.append(data) {
                        let result = self.parse(head)
                        self.respond(to: connection, success: result.isSuccess)
                        self.finish(result)
                    } else if isComplete || error != nil {
                        self.respond(to: connection, success: false)
                        self.finish(.failure(.malformedCallback))
                    } else {
                        self.receiveNext(connection, accumulator: nextAccumulator)
                    }
                } catch let callbackError as LoopbackCallbackError {
                    self.respond(to: connection, success: false)
                    self.finish(.failure(callbackError))
                } catch {
                    self.respond(to: connection, success: false)
                    self.finish(.failure(.malformedCallback))
                }
            }
        }
    }

    private func parse(_ head: LoopbackHTTPRequestHead) -> Result<String, LoopbackCallbackError> {
        do {
            return .success(
                try callback.consume(
                    requestTarget: head.requestTarget,
                    hostHeader: head.hostHeader
                )
            )
        } catch let error as LoopbackCallbackError {
            return .failure(error)
        } catch {
            return .failure(.malformedCallback)
        }
    }

    private func respond(to connection: NWConnection, success: Bool) {
        let status = success ? "200 OK" : "400 Bad Request"
        let body = success ? "Authorization received. You may close this window." : "Authorization was not accepted."
        let response = "HTTP/1.1 \(status)\r\nContent-Type: text/plain; charset=utf-8\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
        connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in
            connection.cancel()
        })
    }

    private func finish(_ result: Result<String, LoopbackCallbackError>) {
        guard !completed else { return }
        completed = true
        timeoutWorkItem?.cancel()
        listener?.cancel()
        completion?(result)
        completion = nil
    }
}

private extension Result {
    var isSuccess: Bool {
        if case .success = self { return true }
        return false
    }
}
