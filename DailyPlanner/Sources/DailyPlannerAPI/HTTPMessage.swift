import CryptoKit
import Foundation

/// Minimal HTTP/1.1 request and response value types, plus the security primitives the server
/// relies on. Everything here is transport-only: no logging, no content strings retained.
enum HTTPMethod: String {
    case get = "GET"
    case head = "HEAD"
    /// Added with the first write route, and no wider than that.
    ///
    /// POST was deliberately absent while the engine was read-only, and opening it is the one
    /// real decision in this file. It is fenced on every side: `RequestGuard` serves POST only
    /// on the finite `APIWriteRoute` set, only with the per-launch bearer token, only from a
    /// loopback `Origin` that is actually present, and only with a JSON content type. A form
    /// post from a random page cannot satisfy the last two at once.
    case post = "POST"
}

/// Byte budgets for a single request. Small on purpose: this server answers one local page, and
/// the only body it ever receives is a message the user typed.
enum HTTPLimits {
    /// The request line plus all headers.
    static let maxHeaderBytes = 16 * 1024
    /// The framed body. A long email is a few kilobytes; 64 KB is generous and still bounded.
    static let maxBodyBytes = 64 * 1024
}

struct HTTPRequest {
    let method: String          // raw verb; only GET/HEAD/POST are ever served
    let path: String            // path without query string
    let query: String?
    /// Header names are lowercased for case-insensitive lookup.
    let headers: [String: String]
    /// The framed request body, exactly `Content-Length` bytes. Empty for GET and HEAD — a
    /// read verb carrying a body is refused during framing rather than silently ignored.
    let body: Data

    init(method: String, path: String, query: String?, headers: [String: String], body: Data = Data()) {
        self.method = method
        self.path = path
        self.query = query
        self.headers = headers
        self.body = body
    }

    func header(_ name: String) -> String? {
        headers[name.lowercased()]
    }

    /// Parses the request line and headers from a raw buffer. Returns nil if the header block
    /// is incomplete or malformed. The body is not read here — `HTTPFraming.frame` owns framing
    /// and is the only thing that attaches one.
    ///
    /// A repeated framing header (`Content-Length`, `Transfer-Encoding`, `Host`) is malformed,
    /// not last-one-wins. Collapsing duplicates into a dictionary is how two parties end up
    /// disagreeing about where a request ends.
    static func parse(_ data: Data) -> HTTPRequest? {
        guard let terminator = data.range(of: Data("\r\n\r\n".utf8)) else { return nil }
        let headerData = data[data.startIndex..<terminator.lowerBound]
        guard let text = String(data: headerData, encoding: .utf8) else { return nil }

        var lines = text.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else { return nil }
        lines.removeFirst()

        let parts = requestLine.split(separator: " ")
        guard parts.count >= 2 else { return nil }
        let method = String(parts[0])
        let target = String(parts[1])

        let path: String
        let query: String?
        if let mark = target.firstIndex(of: "?") {
            path = String(target[target.startIndex..<mark])
            query = String(target[target.index(after: mark)...])
        } else {
            path = target
            query = nil
        }

        var headers: [String: String] = [:]
        for line in lines where !line.isEmpty {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = line[line.startIndex..<colon]
                .trimmingCharacters(in: .whitespaces)
                .lowercased()
            let value = line[line.index(after: colon)...]
                .trimmingCharacters(in: .whitespaces)
            if framingHeaders.contains(name), headers[name] != nil { return nil }
            headers[name] = value
        }

        return HTTPRequest(method: method, path: path, query: query, headers: headers)
    }

    /// Headers that decide where one request ends and the next begins.
    private static let framingHeaders: Set<String> = ["content-length", "transfer-encoding", "host"]
}

/// The result of trying to read one whole request out of what has arrived so far.
///
/// Framing lives here, not in the server, so every rule below is exercised directly by tests
/// rather than through a socket.
enum HTTPFraming {
    /// More bytes are needed; keep receiving.
    case incomplete
    /// A complete request, body included.
    case complete(HTTPRequest)
    /// The bytes cannot be framed. The response is finite and carries no request content.
    case refused(HTTPResponse)

    static func frame(_ buffer: Data) -> HTTPFraming {
        guard let terminator = buffer.range(of: Data("\r\n\r\n".utf8)) else {
            // No header terminator yet. Only a flood can be judged this early.
            return buffer.count > HTTPLimits.maxHeaderBytes ? .refused(.headersTooLarge) : .incomplete
        }
        guard buffer.distance(from: buffer.startIndex, to: terminator.lowerBound) <= HTTPLimits.maxHeaderBytes else {
            return .refused(.headersTooLarge)
        }
        guard let head = HTTPRequest.parse(buffer) else { return .refused(.malformedRequest) }

        // Chunked (and every other transfer coding) is not implemented. Accepting the header
        // and then ignoring the coding is exactly how request smuggling starts, so a request
        // that asks for one is refused rather than guessed at.
        guard head.header("transfer-encoding") == nil else { return .refused(.malformedRequest) }

        let expected: Int
        switch contentLength(head.header("content-length")) {
        case .absent:
            expected = 0
        case .invalid:
            return .refused(.malformedRequest)
        case .tooLarge:
            return .refused(.bodyTooLarge)
        case .value(let count):
            expected = count
        }

        // Only POST carries a body on this server. A GET or HEAD with one is refused rather
        // than dropped: a body the server discards is a body the client believed it sent.
        guard expected == 0 || head.method == HTTPMethod.post.rawValue else {
            return .refused(.malformedRequest)
        }

        let bodyStart = terminator.upperBound
        let available = buffer.distance(from: bodyStart, to: buffer.endIndex)
        guard available >= expected else { return .incomplete }

        // Exactly `expected` bytes. Anything after them is a pipelined request this server does
        // not serve — it answers one request per connection and then closes.
        let body = Data(buffer[bodyStart..<buffer.index(bodyStart, offsetBy: expected)])
        return .complete(
            HTTPRequest(
                method: head.method,
                path: head.path,
                query: head.query,
                headers: head.headers,
                body: body
            )
        )
    }

    private enum ContentLength {
        case absent, invalid, tooLarge
        case value(Int)
    }

    /// `Content-Length` must be plain ASCII digits. No sign, no whitespace, no `0x` — a lenient
    /// integer parser here is a disagreement about message length waiting to happen.
    private static func contentLength(_ raw: String?) -> ContentLength {
        guard let raw else { return .absent }
        guard !raw.isEmpty, raw.utf8.count <= 10,
              raw.unicodeScalars.allSatisfy({ (0x30...0x39).contains($0.value) }),
              let value = Int(raw) else {
            return .invalid
        }
        return value > HTTPLimits.maxBodyBytes ? .tooLarge : .value(value)
    }
}

struct HTTPResponse {
    let status: Int
    let reason: String
    var headers: [(String, String)]
    let body: Data

    static func json(_ status: Int, _ reason: String, _ body: Data) -> HTTPResponse {
        HTTPResponse(
            status: status,
            reason: reason,
            headers: [("Content-Type", "application/json; charset=utf-8")],
            body: body
        )
    }

    static func error(_ status: Int, _ reason: String, _ code: APIErrorCode, _ message: String) -> HTTPResponse {
        json(status, reason, APIJSON.encode(APIErrorBody(code, message)))
    }

    // The finite refusals framing can produce. Named so the server and its tests agree on them.
    static var headersTooLarge: HTTPResponse {
        .error(431, "Request Header Fields Too Large", .tooLarge, "Request too large.")
    }
    static var malformedRequest: HTTPResponse {
        .error(400, "Bad Request", .unavailable, "Malformed request.")
    }
    static var bodyTooLarge: HTTPResponse {
        .error(413, "Content Too Large", .tooLarge, "Request too large.")
    }

    /// Renders the response for the wire. Adds hardening headers and always closes the
    /// connection (this server is one-request-per-connection). For HEAD, the body is dropped
    /// but Content-Length still reflects the entity length.
    func serialize(includeBody: Bool) -> Data {
        var head = "HTTP/1.1 \(status) \(reason)\r\n"
        var merged = headers
        merged.append(("Content-Length", String(body.count)))
        merged.append(("Connection", "close"))
        merged.append(("Cache-Control", "no-store"))
        merged.append(("X-Content-Type-Options", "nosniff"))
        for (name, value) in merged {
            head += "\(name): \(value)\r\n"
        }
        head += "\r\n"
        var out = Data(head.utf8)
        if includeBody {
            out.append(body)
        }
        return out
    }
}

enum HTTPSecurity {
    /// Generates a per-launch bearer token: 256 bits of CSPRNG output, base64url without
    /// padding. Never persisted, never logged, never placed in a URL.
    static func generateBearerToken() -> String {
        let key = SymmetricKey(size: .bits256)
        let bytes = key.withUnsafeBytes { Data($0) }
        return base64URL(bytes)
    }

    static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    /// Constant-time comparison over the full length of both inputs, so a caller cannot learn
    /// how many leading bytes of a guess were correct from response timing.
    static func constantTimeEquals(_ lhs: String, _ rhs: String) -> Bool {
        let a = Array(lhs.utf8)
        let b = Array(rhs.utf8)
        var diff = UInt8(a.count == b.count ? 0 : 1)
        let count = max(a.count, b.count)
        var index = 0
        while index < count {
            let x = index < a.count ? a[index] : 0
            let y = index < b.count ? b[index] : 0
            diff |= (x ^ y)
            index += 1
        }
        return diff == 0
    }
}
