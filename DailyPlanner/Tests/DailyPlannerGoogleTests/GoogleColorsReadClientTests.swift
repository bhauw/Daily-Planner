import DailyPlannerDomain
import Foundation
import XCTest
@testable import DailyPlannerGoogle

final class GoogleColorsReadClientTests: XCTestCase {
    func testPaletteDecodesCalendarAndEventColoursAndNormalisesHex() async throws {
        let palette = try await client(colorsJSON(
            calendar: ["1": ("#ac725e", "#1d1d1d"), "24": ("#616161", "#ffffff")],
            event: ["11": ("#dc2127", "#1d1d1d")]
        )).palette(accessToken: token)

        XCTAssertEqual(palette.calendar["1"], GoogleColorEntry(background: "#AC725E", foreground: "#1D1D1D"))
        XCTAssertEqual(palette.calendar["24"]?.background, "#616161")
        XCTAssertEqual(palette.event["11"], GoogleColorEntry(background: "#DC2127", foreground: "#1D1D1D"))
    }

    func testPaletteEntryPrefersEventColourOverCalendarForSharedId() async throws {
        let palette = try await client(colorsJSON(
            calendar: ["5": ("#111111", "#eeeeee")],
            event: ["5": ("#222222", "#dddddd")]
        )).palette(accessToken: token)

        // A colorId defined at both levels renders with the event colour, matching Google.
        XCTAssertEqual(palette.entry(forColorID: "5")?.background, "#222222")
        XCTAssertNil(palette.entry(forColorID: "999"))
    }

    func testPaletteRejectsMalformedAndOversizedPayloadsThroughFinitePath() async {
        let malformed = [
            colorsJSON(calendar: ["1": ("039be5", "#fff000")], event: [:]),       // no leading '#'
            colorsJSON(calendar: ["1": ("#039be", "#fff000")], event: [:]),        // short hex
            colorsJSON(calendar: ["1x": ("#039be5", "#fff000")], event: [:]),      // non-integer id
            Data("not-json".utf8),
        ]
        for data in malformed {
            await assertFinite { _ = try await client(data).palette(accessToken: self.token) }
        }

        var many: [String: (String, String)] = [:]
        for index in 0...200 { many[String(index)] = ("#0a84ff", "#ffffff") }
        await assertFinite {
            _ = try await self.client(colorsJSON(calendar: many, event: [:])).palette(accessToken: self.token)
        }
    }

    func testProviderAndTransportFailuresMapToFiniteRedactedErrors() async {
        await assertFinite {
            _ = try await self.client(Data(), status: 503).palette(accessToken: self.token)
        }
        await assertFinite(expected: .offline) {
            _ = try await GoogleColorsReadClient(transport: FailingTransport(GoogleHTTPTransportError.requestFailed))
                .palette(accessToken: self.token)
        }
    }

    // MARK: - Helpers

    private let token = try! GoogleAccessToken(validating: "synthetic-access-token")

    private func client(_ data: Data, status: Int = 200) -> GoogleColorsReadClient {
        GoogleColorsReadClient(transport: StubTransport(status: status, data: data))
    }

    private func assertFinite(
        expected: GoogleColorsReadClientError? = nil,
        _ operation: () async throws -> Void,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        do {
            try await operation()
            XCTFail("expected finite colors client error", file: file, line: line)
        } catch let error as GoogleColorsReadClientError {
            if let expected { XCTAssertEqual(error, expected, file: file, line: line) }
        } catch {
            XCTFail("raw error escaped the colors client", file: file, line: line)
        }
    }
}

private func colorsJSON(
    calendar: [String: (String, String)],
    event: [String: (String, String)]
) -> Data {
    func map(_ input: [String: (String, String)]) -> [String: Any] {
        input.mapValues { ["background": $0.0, "foreground": $0.1] }
    }
    return try! JSONSerialization.data(withJSONObject: [
        "kind": "calendar#colors",
        "calendar": map(calendar),
        "event": map(event),
    ])
}

private struct StubTransport: GoogleHTTPTransport, @unchecked Sendable {
    let status: Int
    let data: Data
    func send(_ request: URLRequest) async throws -> GoogleHTTPResponse {
        GoogleHTTPResponse(statusCode: status, data: data)
    }
}

private struct FailingTransport: GoogleHTTPTransport, @unchecked Sendable {
    let error: any Error
    init(_ error: any Error) { self.error = error }
    func send(_ request: URLRequest) async throws -> GoogleHTTPResponse { throw error }
}
