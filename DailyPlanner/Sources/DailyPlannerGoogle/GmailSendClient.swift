import DailyPlannerDomain
import Foundation

public enum GmailSendClientError: Error, Equatable, CaseIterable, Sendable {
    case cancelled
    case offline
    /// Google refused the message — a revoked grant, a quota, a rejected recipient. The
    /// provider's own words never travel with this; the status is mapped and discarded.
    case refused
    case providerUnavailable
    case malformedResponse
}

/// Sends one message through `POST /gmail/v1/users/me/messages/send`.
///
/// Gmail takes a whole RFC 2822 message, base64url encoded, in a `raw` field. That means this
/// client assembles a header block by hand — which is exactly why `PlannerOutgoingMail` refuses
/// a line break anywhere that lands in one. By the time a message reaches this type, an address
/// or subject cannot end a header early and start another.
///
/// No `From` header is written. Gmail fills it with the authenticated account, so the app never
/// needs to know or store the user's own address to send as them.
public struct GmailSendClient: Sendable {
    public let transport: any GoogleHTTPTransport

    public init(transport: any GoogleHTTPTransport) {
        self.transport = transport
    }

    public func send(
        _ mail: PlannerOutgoingMail,
        accessToken: GoogleAccessToken
    ) async throws -> PlannerSentMail {
        do {
            try Task.checkCancellation()
            let body = try Self.requestBody(for: mail)
            let request = try GoogleRequestBuilder.postJSON(
                url: Self.sendURL, accessToken: accessToken, body: body
            )
            let response = try await transport.send(request)
            switch response.statusCode {
            case 200...299:
                return try Self.decode(response.data)
            // 401/403 is a grant that no longer permits this; 400 is a message Google would not
            // take. All three are the user's to resolve, and none of them is a retry.
            case 400, 401, 403, 429:
                throw GmailSendClientError.refused
            default:
                throw GmailSendClientError.providerUnavailable
            }
        } catch {
            throw Self.map(error)
        }
    }

    static let sendURL = URL(string: "https://gmail.googleapis.com/gmail/v1/users/me/messages/send")!

    /// `{"raw": "<base64url RFC 2822>", "threadId": "…"}`.
    static func requestBody(for mail: PlannerOutgoingMail) throws -> Data {
        var payload: [String: String] = [
            "raw": HTTPBase64.url(Data(RFC2822Message.render(mail).utf8))
        ]
        if let threadID = mail.threadID {
            payload["threadId"] = threadID
        }
        guard let data = try? JSONSerialization.data(
            withJSONObject: payload, options: [.sortedKeys, .withoutEscapingSlashes]
        ) else {
            throw GmailSendClientError.malformedResponse
        }
        return data
    }

    private struct Wire: Decodable {
        let id: String
        let threadId: String?
    }

    static func decode(_ data: Data) throws -> PlannerSentMail {
        guard let wire = try? JSONDecoder().decode(Wire.self, from: data), !wire.id.isEmpty else {
            throw GmailSendClientError.malformedResponse
        }
        return PlannerSentMail(id: wire.id, threadID: wire.threadId)
    }

    private static func map(_ error: Error) -> GmailSendClientError {
        switch error {
        case is CancellationError:
            return .cancelled
        case let error as GmailSendClientError:
            return error
        case let error as GoogleHTTPTransportError:
            return error == .cancelled ? .cancelled : .offline
        default:
            // A policy rejection lands here. It is a bug in this client, not a provider outage,
            // but it must still not send — so it fails closed like everything else.
            return .refused
        }
    }
}

/// Renders a `PlannerOutgoingMail` as an RFC 2822 message.
///
/// Separate from the client and internal-visible so the exact bytes are asserted in tests. Mail
/// assembly is the kind of code that looks obviously right and is subtly wrong — a missing blank
/// line between headers and body turns the whole message into headers.
enum RFC2822Message {
    static func render(_ mail: PlannerOutgoingMail) -> String {
        var lines: [String] = []
        lines.append("To: " + mail.to.map(\.value).joined(separator: ", "))
        if !mail.cc.isEmpty {
            lines.append("Cc: " + mail.cc.map(\.value).joined(separator: ", "))
        }
        if !mail.bcc.isEmpty {
            // Gmail strips this header on send and delivers the blind copies; it is the
            // documented way to bcc through the API.
            lines.append("Bcc: " + mail.bcc.map(\.value).joined(separator: ", "))
        }
        lines.append("Subject: " + encodedSubject(mail.subject))
        if let inReplyTo = mail.inReplyTo {
            // Both headers, because clients differ on which they thread by.
            lines.append("In-Reply-To: " + inReplyTo)
            lines.append("References: " + inReplyTo)
        }
        lines.append("MIME-Version: 1.0")
        lines.append("Content-Type: text/plain; charset=\"UTF-8\"")
        // Base64 rather than 8bit: it survives any line length or character in the body without
        // this code having to implement quoted-printable folding correctly.
        lines.append("Content-Transfer-Encoding: base64")

        let body = wrap(Data(mail.body.utf8).base64EncodedString(), at: 76)
        // The blank line is the whole message format. Headers, CRLF CRLF, body.
        return lines.joined(separator: "\r\n") + "\r\n\r\n" + body
    }

    /// A subject that is plain printable ASCII goes out as-is; anything else becomes RFC 2047
    /// encoded words, folded so no header line exceeds the 76-octet guidance.
    static func encodedSubject(_ subject: String) -> String {
        if subject.unicodeScalars.allSatisfy({ (0x20...0x7E).contains($0.value) }), subject.utf8.count <= 900 {
            return subject
        }
        // Each encoded word must stay under 76 characters including the `=?UTF-8?B?` and `?=`
        // wrappers, so the payload is chunked at 45 source bytes — and never mid-character,
        // because half a UTF-8 sequence decodes to a replacement glyph on the far side.
        var words: [String] = []
        var chunk = ""
        for character in subject {
            let candidate = chunk + String(character)
            if candidate.utf8.count > 45 {
                words.append("=?UTF-8?B?" + Data(chunk.utf8).base64EncodedString() + "?=")
                chunk = String(character)
            } else {
                chunk = candidate
            }
        }
        if !chunk.isEmpty {
            words.append("=?UTF-8?B?" + Data(chunk.utf8).base64EncodedString() + "?=")
        }
        // Continuation lines start with a space — that is what makes them a folded header
        // rather than a new one.
        return words.joined(separator: "\r\n ")
    }

    static func wrap(_ text: String, at width: Int) -> String {
        guard width > 0, text.count > width else { return text }
        var lines: [String] = []
        var index = text.startIndex
        while index < text.endIndex {
            let end = text.index(index, offsetBy: width, limitedBy: text.endIndex) ?? text.endIndex
            lines.append(String(text[index..<end]))
            index = end
        }
        return lines.joined(separator: "\r\n")
    }
}

/// base64url, unpadded — the encoding Gmail's `raw` field is specified in.
enum HTTPBase64 {
    static func url(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

extension GmailSendClientError: PlannerWriteFailure {
    public var writeOutcome: PlannerWriteOutcome {
        switch self {
        case .cancelled: return .cancelled
        case .refused: return .refused
        // A malformed response means the send may well have happened and we could not read the
        // receipt. It is reported as not-through rather than refused, and it is never retried
        // automatically — a duplicate send is worse than an unclear one.
        case .offline, .providerUnavailable, .malformedResponse: return .unavailable
        }
    }
}
