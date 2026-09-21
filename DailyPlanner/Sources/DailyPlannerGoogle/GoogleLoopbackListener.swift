import Foundation
import Network

public enum GoogleLoopbackResponse: Equatable, Sendable {
    case success
    case failure
}

public protocol GoogleLoopbackAcknowledging: Sendable {
    func respond(_ response: GoogleLoopbackResponse)
}

public enum GoogleLoopbackEvent: Sendable {
    case ready(port: Int)
    case callback(target: String, acknowledgment: any GoogleLoopbackAcknowledging)
    case startupFailed
    case invalidRequest
    case timedOut
}

public protocol GoogleLoopbackListening: Sendable {
    func start(
        timeout: Duration,
        handler: @escaping @Sendable (GoogleLoopbackEvent) -> Void
    ) throws
    func cancel()
}

public enum GoogleLoopbackListenerError: Error, Equatable, Sendable {
    case alreadyStarted
    case startupFailed
}

struct GoogleLoopbackRequestHead: Equatable, Sendable {
    static let maximumByteCount = 8 * 1_024

    let target: String

    static func parse(_ data: Data) throws -> GoogleLoopbackRequestHead {
        guard !data.isEmpty, data.count <= maximumByteCount,
              data.suffix(4) == Data([13, 10, 13, 10]),
              let head = String(data: data, encoding: .utf8),
              head.unicodeScalars.allSatisfy({ $0.value == 9 || $0.value == 13 || $0.value == 10 || (0x20...0x7E).contains($0.value) }) else {
            throw GoogleLoopbackRequestHeadError.invalid
        }

        let lines = head.components(separatedBy: "\r\n")
        guard lines.count >= 4, lines.suffix(2).allSatisfy(\.isEmpty) else {
            throw GoogleLoopbackRequestHeadError.invalid
        }
        let requestParts = lines[0].split(separator: " ", omittingEmptySubsequences: false)
        guard requestParts.count == 3,
              requestParts[0] == "GET",
              !requestParts[1].isEmpty,
              requestParts[2] == "HTTP/1.1" else {
            throw GoogleLoopbackRequestHeadError.invalid
        }

        for line in lines.dropFirst().dropLast(2) {
            guard !line.isEmpty, let colon = line.firstIndex(of: ":") else {
                throw GoogleLoopbackRequestHeadError.invalid
            }
            let name = line[..<colon]
            let value = line[line.index(after: colon)...]
            guard !name.isEmpty,
                  name.utf8.allSatisfy(isHTTPTokenByte),
                  value.unicodeScalars.allSatisfy({ $0.value == 9 || (0x20...0x7E).contains($0.value) }) else {
                throw GoogleLoopbackRequestHeadError.invalid
            }
        }

        return GoogleLoopbackRequestHead(target: String(requestParts[1]))
    }
}

enum GoogleLoopbackRequestHeadError: Error, Equatable, Sendable {
    case invalid
}

struct GoogleLoopbackStartupGate: Sendable {
    enum Signal: Sendable { case ready, failed }
    enum Action: Equatable, Sendable {
        case announceReady
        case failStartup
        case preserveAcceptedConnections
        case ignore
    }

    private enum Phase: Sendable { case waiting, ready, terminal }
    private var phase: Phase = .waiting

    mutating func receive(_ signal: Signal) -> Action {
        switch (phase, signal) {
        case (.waiting, .ready):
            phase = .ready
            return .announceReady
        case (.waiting, .failed):
            phase = .terminal
            return .failStartup
        case (.ready, .failed):
            return .preserveAcceptedConnections
        case (.ready, .ready), (.terminal, _):
            return .ignore
        }
    }
}

final class GoogleLoopbackResponseCancellationGate: @unchecked Sendable {
    private struct State {
        var didCancel = false
        var fallback: DispatchWorkItem?
    }

    private let lock = NSLock()
    private let cancelAction: @Sendable () -> Void
    private var state = State()

    init(cancel: @escaping @Sendable () -> Void) {
        cancelAction = cancel
    }

    var hasPendingFallback: Bool {
        locked { $0.fallback != nil }
    }

    func registerFallback(_ fallback: DispatchWorkItem) {
        let accepted = locked { state -> Bool in
            guard !state.didCancel, state.fallback == nil else { return false }
            state.fallback = fallback
            return true
        }
        if !accepted { fallback.cancel() }
    }

    func sendCompleted() {
        cancelOnce(retiringFallback: true)
    }

    func fallbackFired() {
        cancelOnce(retiringFallback: false)
    }

    private func cancelOnce(retiringFallback: Bool) {
        let result: (shouldCancel: Bool, fallback: DispatchWorkItem?) = locked { state in
            guard !state.didCancel else { return (false, nil) }
            state.didCancel = true
            let fallback = state.fallback
            state.fallback = nil
            return (true, fallback)
        }
        guard result.shouldCancel else { return }
        if retiringFallback { result.fallback?.cancel() }
        cancelAction()
    }

    @discardableResult
    private func locked<T>(_ body: (inout State) -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body(&state)
    }
}

public final class GoogleLoopbackListener: GoogleLoopbackListening, @unchecked Sendable {
    private struct OwnedConnection {
        let connection: NWConnection
        var head = Data()
    }

    private struct State {
        enum Lifecycle { case idle, running, terminal }

        var lifecycle: Lifecycle = .idle
        var startupGate = GoogleLoopbackStartupGate()
        var listener: NWListener?
        var connections: [ObjectIdentifier: OwnedConnection] = [:]
        var handler: (@Sendable (GoogleLoopbackEvent) -> Void)?
        var timeoutTask: Task<Void, Never>?
    }

    private static let successResponse = response(
        status: "200 OK",
        body: "<html><body>Authorization received. You may close this window.</body></html>"
    )
    private static let failureResponse = response(
        status: "400 Bad Request",
        body: "<html><body>Authorization could not be completed.</body></html>"
    )

    private let lock = NSLock()
    private let queue = DispatchQueue(label: "DailyPlanner.GoogleLoopbackListener")
    private var state = State()

    public init() {}

    deinit {
        cancel()
    }

    public func start(
        timeout: Duration,
        handler: @escaping @Sendable (GoogleLoopbackEvent) -> Void
    ) throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)

        let listener: NWListener
        do {
            listener = try NWListener(using: parameters)
        } catch {
            throw GoogleLoopbackListenerError.startupFailed
        }

        listener.stateUpdateHandler = { [weak self, weak listener] listenerState in
            guard let self, let listener else { return }
            self.handleListenerState(listenerState, listener: listener)
        }
        listener.newConnectionHandler = { [weak self] connection in
            self?.accept(connection)
        }

        let installed = locked { state -> Bool in
            guard state.lifecycle == .idle else { return false }
            state.lifecycle = .running
            state.listener = listener
            state.handler = handler
            return true
        }
        guard installed else {
            listener.cancel()
            throw GoogleLoopbackListenerError.alreadyStarted
        }

        let timeoutTask = Task { [weak self] in
            do {
                try await Task.sleep(for: timeout)
            } catch {
                return
            }
            self?.terminate(event: .timedOut, responseConnection: nil, response: nil)
        }
        let retainsTimeout = locked { state -> Bool in
            guard state.lifecycle == .running else { return false }
            state.timeoutTask = timeoutTask
            return true
        }
        if retainsTimeout {
            // Starting Network.framework may schedule user handlers, so keep it outside the state lock.
            listener.start(queue: queue)
        } else {
            timeoutTask.cancel()
            listener.cancel()
        }
    }

    public func cancel() {
        let resources = takeResourcesForCancellation()
        resources.timeoutTask?.cancel()
        resources.listener?.cancel()
        resources.connections.forEach { $0.cancel() }
    }

    private func handleListenerState(_ listenerState: NWListener.State, listener: NWListener) {
        switch listenerState {
        case .ready:
            let readiness: (handler: @Sendable (GoogleLoopbackEvent) -> Void, port: Int)? = locked { state in
                guard state.lifecycle == .running,
                      state.listener === listener,
                      let port = listener.port else { return nil }
                guard state.startupGate.receive(.ready) == .announceReady else { return nil }
                guard let handler = state.handler else { return nil }
                return (handler, Int(port.rawValue))
            }
            if let readiness {
                readiness.handler(.ready(port: readiness.port))
            }
        case .failed:
            let action = locked { state -> GoogleLoopbackStartupGate.Action in
                guard state.lifecycle == .running else { return .ignore }
                return state.startupGate.receive(.failed)
            }
            if action == .failStartup {
                terminate(event: .startupFailed, responseConnection: nil, response: nil)
            }
        default:
            break
        }
    }

    private func accept(_ connection: NWConnection) {
        let accepted = locked { state -> Bool in
            guard state.lifecycle == .running else { return false }
            state.connections[ObjectIdentifier(connection)] = OwnedConnection(connection: connection)
            return true
        }
        guard accepted else {
            connection.cancel()
            return
        }

        connection.stateUpdateHandler = { [weak self, weak connection] connectionState in
            guard let self, let connection else { return }
            switch connectionState {
            case .failed, .cancelled:
                self.remove(connection)
            default:
                break
            }
        }
        connection.start(queue: queue)
        receive(from: connection)
    }

    private func receive(from connection: NWConnection) {
        let maximumLength = locked { state -> Int? in
            guard state.lifecycle == .running,
                  let owned = state.connections[ObjectIdentifier(connection)] else { return nil }
            return max(1, GoogleLoopbackRequestHead.maximumByteCount + 1 - owned.head.count)
        }
        guard let maximumLength else { return }

        connection.receive(
            minimumIncompleteLength: 1,
            maximumLength: maximumLength
        ) { [weak self, weak connection] content, _, isComplete, error in
            guard let self, let connection else { return }
            self.consume(content, from: connection, isComplete: isComplete, error: error)
        }
    }

    private func consume(_ content: Data?, from connection: NWConnection, isComplete: Bool, error: NWError?) {
        enum NextAction {
            case receive
            case parse(Data)
            case reject
            case none
        }

        let action: NextAction = locked { state in
            let identifier = ObjectIdentifier(connection)
            guard state.lifecycle == .running, var owned = state.connections[identifier] else {
                return .none
            }
            if let content { owned.head.append(content) }
            state.connections[identifier] = owned

            if owned.head.count > GoogleLoopbackRequestHead.maximumByteCount {
                return .reject
            }
            if owned.head.range(of: Data([13, 10, 13, 10])) != nil {
                return .parse(owned.head)
            }
            if error != nil || isComplete {
                return .reject
            }
            return .receive
        }

        switch action {
        case .receive:
            receive(from: connection)
        case .parse(let data):
            do {
                let request = try GoogleLoopbackRequestHead.parse(data)
                deliverCallback(target: request.target, responseConnection: connection)
            } catch {
                terminate(event: .invalidRequest, responseConnection: connection, response: Self.failureResponse)
            }
        case .reject:
            terminate(event: .invalidRequest, responseConnection: connection, response: Self.failureResponse)
        case .none:
            break
        }
    }

    private func remove(_ connection: NWConnection) {
        locked { state in
            state.connections.removeValue(forKey: ObjectIdentifier(connection))
        }
    }

    private func deliverCallback(target: String, responseConnection: NWConnection) {
        let resources: (handler: (@Sendable (GoogleLoopbackEvent) -> Void)?, listener: NWListener?, connections: [NWConnection], timeoutTask: Task<Void, Never>?) = locked { state in
            guard state.lifecycle == .running else { return (nil, nil, [], nil) }
            state.lifecycle = .terminal
            state.connections.removeValue(forKey: ObjectIdentifier(responseConnection))
            let result = (state.handler, state.listener, state.connections.values.map(\.connection), state.timeoutTask)
            state.handler = nil
            state.listener = nil
            state.connections.removeAll()
            state.timeoutTask = nil
            return result
        }
        guard let handler = resources.handler else {
            responseConnection.cancel()
            return
        }

        resources.timeoutTask?.cancel()
        resources.listener?.cancel()
        resources.connections.forEach { $0.cancel() }
        let queue = self.queue
        let acknowledgment = OneShotGoogleLoopbackAcknowledgment { response in
            Self.send(response: response, on: responseConnection, queue: queue)
        }
        handler(.callback(target: target, acknowledgment: acknowledgment))
    }

    private func terminate(event: GoogleLoopbackEvent, responseConnection: NWConnection?, response: Data?) {
        let resources: (handler: (@Sendable (GoogleLoopbackEvent) -> Void)?, listener: NWListener?, connections: [NWConnection], timeoutTask: Task<Void, Never>?) = locked { state in
            guard state.lifecycle == .running else { return (nil, nil, [], nil) }
            state.lifecycle = .terminal
            let result = (state.handler, state.listener, state.connections.values.map(\.connection), state.timeoutTask)
            state.handler = nil
            state.listener = nil
            state.connections.removeAll()
            state.timeoutTask = nil
            return result
        }
        guard let handler = resources.handler else { return }

        resources.timeoutTask?.cancel()
        resources.listener?.cancel()
        resources.connections.filter { $0 !== responseConnection }.forEach { $0.cancel() }
        if let responseConnection, let response {
            Self.send(data: response, on: responseConnection, queue: queue)
        }
        handler(event)
    }

    private static func send(response: GoogleLoopbackResponse, on connection: NWConnection, queue: DispatchQueue) {
        let data = response == .success ? successResponse : failureResponse
        send(data: data, on: connection, queue: queue)
    }

    private static func send(data: Data, on connection: NWConnection, queue: DispatchQueue) {
        let gate = GoogleLoopbackResponseCancellationGate {
            connection.cancel()
        }
        let fallback = DispatchWorkItem { [gate] in
            gate.fallbackFired()
        }
        gate.registerFallback(fallback)
        queue.asyncAfter(deadline: .now() + 1, execute: fallback)
        connection.send(content: data, completion: .contentProcessed { _ in
            gate.sendCompleted()
        })
    }

    private func takeResourcesForCancellation() -> (listener: NWListener?, connections: [NWConnection], timeoutTask: Task<Void, Never>?) {
        locked { state in
            guard state.lifecycle != .terminal else { return (nil, [], nil) }
            state.lifecycle = .terminal
            let result = (state.listener, state.connections.values.map(\.connection), state.timeoutTask)
            state.handler = nil
            state.listener = nil
            state.connections.removeAll()
            state.timeoutTask = nil
            return result
        }
    }

    @discardableResult
    private func locked<T>(_ body: (inout State) -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body(&state)
    }

    private static func response(status: String, body: String) -> Data {
        let bodyData = Data(body.utf8)
        let head = "HTTP/1.1 \(status)\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(bodyData.count)\r\nConnection: close\r\nCache-Control: no-store\r\n\r\n"
        var response = Data(head.utf8)
        response.append(bodyData)
        return response
    }
}

private final class OneShotGoogleLoopbackAcknowledgment: GoogleLoopbackAcknowledging, @unchecked Sendable {
    private let lock = NSLock()
    private var action: (@Sendable (GoogleLoopbackResponse) -> Void)?

    init(action: @escaping @Sendable (GoogleLoopbackResponse) -> Void) {
        self.action = action
    }

    deinit {
        takeAction()?(.failure)
    }

    func respond(_ response: GoogleLoopbackResponse) {
        takeAction()?(response)
    }

    private func takeAction() -> (@Sendable (GoogleLoopbackResponse) -> Void)? {
        lock.lock()
        defer { lock.unlock() }
        defer { action = nil }
        return action
    }
}

private func isHTTPTokenByte(_ byte: UInt8) -> Bool {
    switch byte {
    case 48...57, 65...90, 97...122,
         33, 35, 36, 37, 38, 39, 42, 43, 45, 46, 94, 95, 96, 124, 126:
        true
    default:
        false
    }
}
