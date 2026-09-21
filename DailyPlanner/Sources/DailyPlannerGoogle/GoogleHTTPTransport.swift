import Foundation

public protocol GoogleHTTPTransport: Sendable {
    func send(_ request: URLRequest) async throws -> GoogleHTTPResponse
}

public struct GoogleHTTPResponse: Sendable {
    public let statusCode: Int
    public let data: Data

    public init(statusCode: Int, data: Data) {
        self.statusCode = statusCode
        self.data = data
    }
}

public final class URLSessionGoogleHTTPTransport: GoogleHTTPTransport, @unchecked Sendable {
    private let session: URLSession

    public convenience init() {
        self.init(protocolClasses: nil)
    }

    convenience init(protocolClasses: [AnyClass]) {
        self.init(protocolClasses: Optional(protocolClasses))
    }

    private init(protocolClasses: [AnyClass]?) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCredentialStorage = nil
        if let protocolClasses {
            configuration.protocolClasses = protocolClasses
        }
        session = URLSession(
            configuration: configuration,
            delegate: GoogleNoRedirectSessionDelegate(),
            delegateQueue: nil
        )
    }

    public func send(_ request: URLRequest) async throws -> GoogleHTTPResponse {
        try GoogleNetworkPolicy.validate(request)
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch is CancellationError {
            throw GoogleHTTPTransportError.cancelled
        } catch let error as URLError where error.code == .cancelled {
            throw GoogleHTTPTransportError.cancelled
        } catch {
            throw GoogleHTTPTransportError.requestFailed
        }
        guard let response = response as? HTTPURLResponse else {
            throw GoogleHTTPTransportError.nonHTTPResponse
        }
        return GoogleHTTPResponse(statusCode: response.statusCode, data: data)
    }
}

private final class GoogleNoRedirectSessionDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}

public enum GoogleHTTPTransportError: Error, Equatable, Sendable {
    case requestFailed
    case cancelled
    case nonHTTPResponse
}
