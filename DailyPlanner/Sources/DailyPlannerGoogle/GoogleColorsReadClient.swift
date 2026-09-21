import DailyPlannerDomain
import Foundation

public enum GoogleColorsReadClientError: Error, Equatable, CaseIterable, Sendable {
    case cancelled
    case offline
    case providerUnavailable
    case malformedResponse
    case limitViolation
}

/// Reads `GET /calendar/v3/colors`, Google's `colorId -> {background, foreground}`
/// palette for calendars and events. Read-only, GET-only; the response is bounded and
/// decoded strictly, rejecting anything malformed through a finite error path.
public struct GoogleColorsReadClient: GoogleColorsReading, Sendable {
    public let transport: any GoogleHTTPTransport

    public init(transport: any GoogleHTTPTransport) {
        self.transport = transport
    }

    public func palette(accessToken: GoogleAccessToken) async throws -> GoogleColorPalette {
        do {
            try Task.checkCancellation()
            let response = try await transport.send(
                GoogleRequestBuilder.get(url: try ColorsURL.colors(), accessToken: accessToken)
            )
            return try ColorsWireDecoder.palette(from: response)
        } catch {
            throw mapColorsError(error)
        }
    }
}

private enum ColorsURL {
    static func colors() throws -> URL {
        var components = URLComponents()
        components.scheme = "https"
        components.host = "www.googleapis.com"
        components.path = "/calendar/v3/colors"
        guard let result = components.url else {
            throw GoogleColorsReadClientError.malformedResponse
        }
        return result
    }
}

private struct ColorsWirePalette: Decodable {
    let calendar: [String: ColorsWireEntry]?
    let event: [String: ColorsWireEntry]?
}

private struct ColorsWireEntry: Decodable {
    let background: String
    let foreground: String
}

private enum ColorsWireDecoder {
    private static let maximumColors = 128

    static func palette(from response: GoogleHTTPResponse) throws -> GoogleColorPalette {
        guard (200...299).contains(response.statusCode) else {
            throw GoogleColorsReadClientError.providerUnavailable
        }
        let wire: ColorsWirePalette
        do {
            wire = try JSONDecoder().decode(ColorsWirePalette.self, from: response.data)
        } catch {
            throw GoogleColorsReadClientError.malformedResponse
        }
        return GoogleColorPalette(
            calendar: try map(wire.calendar ?? [:]),
            event: try map(wire.event ?? [:])
        )
    }

    private static func map(_ wire: [String: ColorsWireEntry]) throws -> [String: GoogleColorEntry] {
        guard wire.count <= maximumColors else { throw GoogleColorsReadClientError.limitViolation }
        var result: [String: GoogleColorEntry] = [:]
        result.reserveCapacity(wire.count)
        for (colorID, entry) in wire {
            guard isColorID(colorID),
                  isHexColor(entry.background),
                  isHexColor(entry.foreground) else {
                throw GoogleColorsReadClientError.malformedResponse
            }
            result[colorID] = GoogleColorEntry(
                background: entry.background.uppercased(),
                foreground: entry.foreground.uppercased()
            )
        }
        return result
    }

    /// Google colour ids are short positive-integer strings (e.g. "1"..."24").
    static func isColorID(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 3
            && value.unicodeScalars.allSatisfy { (0x30...0x39).contains($0.value) }
    }

    /// A `#RRGGBB` hex colour.
    static func isHexColor(_ value: String) -> Bool {
        guard value.utf8.count == 7, value.hasPrefix("#") else { return false }
        return value.dropFirst().unicodeScalars.allSatisfy { scalar in
            (0x30...0x39).contains(scalar.value)
                || (0x41...0x46).contains(scalar.value)
                || (0x61...0x66).contains(scalar.value)
        }
    }
}

private func mapColorsError(_ error: any Error) -> GoogleColorsReadClientError {
    if let error = error as? GoogleColorsReadClientError { return error }
    if error is CancellationError { return .cancelled }
    if let error = error as? GoogleHTTPTransportError {
        switch error {
        case .cancelled: return .cancelled
        case .requestFailed: return .offline
        case .nonHTTPResponse: return .providerUnavailable
        }
    }
    return .malformedResponse
}
