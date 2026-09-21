import Foundation
import XCTest
@testable import DailyPlannerGoogle

final class GoogleNetworkPolicyTests: XCTestCase {
    func testPolicyAcceptsOnlyM2BReadRoutesWithBoundedQueryKeys() throws {
        // Break caught: a planned read route or its exact bounded query parameters are absent.
        let accepted = [
            providerGET("https://gmail.googleapis.com/gmail/v1/users/me/profile"),
            providerGET("https://gmail.googleapis.com/gmail/v1/users/me/messages?q=newer_than%3A30d&maxResults=100&pageToken=next"),
            providerGET("https://gmail.googleapis.com/gmail/v1/users/me/messages/opaque?format=metadata&metadataHeaders=From&metadataHeaders=Subject"),
            providerGET("https://gmail.googleapis.com/gmail/v1/users/me/messages/opaque?format=full"),
            providerGET("https://gmail.googleapis.com/gmail/v1/users/me/history?startHistoryId=123&historyTypes=messageAdded&historyTypes=messageDeleted&pageToken=next"),
            providerGET("https://www.googleapis.com/calendar/v3/users/me/calendarList?minAccessRole=reader&showDeleted=false&pageToken=next"),
            providerGET("https://www.googleapis.com/calendar/v3/calendars/opaque/events?singleEvents=true&showDeleted=true&timeMin=2026-09-10T00%3A00%3A00Z&timeMax=2026-09-17T00%3A00%3A00Z&maxResults=100&pageToken=next"),
            providerGET("https://www.googleapis.com/calendar/v3/calendars/opaque/events?singleEvents=true&showDeleted=true&syncToken=next&pageToken=next&maxResults=100"),
            providerGET("https://tasks.googleapis.com/tasks/v1/users/@me/lists?maxResults=100&pageToken=next"),
            providerGET("https://tasks.googleapis.com/tasks/v1/lists/opaque/tasks?showCompleted=false&showDeleted=false&showHidden=false&maxResults=100&pageToken=next"),
            providerGET("https://tasks.googleapis.com/tasks/v1/lists/opaque/tasks?showCompleted=true&showDeleted=true&showHidden=true&updatedMin=2026-09-10T00%3A00%3A00Z&maxResults=100"),
        ]

        try accepted.forEach { try GoogleNetworkPolicy.validate($0) }
    }

    func testPolicyAcceptsQueryOrderAndM2ACanaries() throws {
        // Break caught: equivalent query ordering or the accepted M2A canary routes are rejected.
        let accepted = [
            providerGET("https://gmail.googleapis.com/gmail/v1/users/me/messages?maxResults=100&q=after%3A1788112800"),
            providerGET("https://www.googleapis.com/calendar/v3/users/me/calendarList?maxResults=1"),
            providerGET("https://tasks.googleapis.com/tasks/v1/users/@me/lists?maxResults=1"),
            request("POST", "https://oauth2.googleapis.com/token", headers: ["Content-Type": "application/x-www-form-urlencoded"]),
            request("POST", "https://oauth2.googleapis.com/revoke", headers: ["Content-Type": "application/x-www-form-urlencoded"]),
        ]

        try accepted.forEach { try GoogleNetworkPolicy.validate($0) }
    }

    func testPolicyAllowsColorsReadOnlyAndRejectsNonGetAndNearMissPaths() {
        // Break caught: `/calendar/v3/colors` is either not GET-only, or a near-miss path or
        // a stray query slips through the fail-closed allowlist.
        XCTAssertNoThrow(
            try GoogleNetworkPolicy.validate(providerGET("https://www.googleapis.com/calendar/v3/colors"))
        )

        let rejected = [
            // Non-GET on the exact colours path — no mutation verb may reach it.
            providerRequest("POST", "https://www.googleapis.com/calendar/v3/colors"),
            providerRequest("PUT", "https://www.googleapis.com/calendar/v3/colors"),
            providerRequest("PATCH", "https://www.googleapis.com/calendar/v3/colors"),
            providerRequest("DELETE", "https://www.googleapis.com/calendar/v3/colors"),
            // Any query at all is unexpected on the colours endpoint.
            providerGET("https://www.googleapis.com/calendar/v3/colors?alt=json"),
            // Near-miss paths must not normalise onto the colours route.
            providerGET("https://www.googleapis.com/calendar/v3/colors/"),
            providerGET("https://www.googleapis.com/calendar/v3/color"),
            providerGET("https://www.googleapis.com/calendar/v3/colors/extra"),
            providerGET("https://www.googleapis.com/calendar/v4/colors"),
            providerGET("https://gmail.googleapis.com/calendar/v3/colors"),
        ]
        for candidate in rejected {
            XCTAssertThrowsError(try GoogleNetworkPolicy.validate(candidate))
        }
    }

    func testPolicyRejectsMutationsUploadsBatchUnknownQueriesAndAttachments() {
        // Break caught: a provider mutation or a route outside the exact read-only families reaches transport.
        let rejected = [
            providerRequest("POST", "https://gmail.googleapis.com/gmail/v1/users/me/messages/send"),
            providerRequest("PATCH", "https://www.googleapis.com/calendar/v3/calendars/x/events/y"),
            providerRequest("DELETE", "https://tasks.googleapis.com/tasks/v1/lists/x/tasks/y"),
            providerGET("https://gmail.googleapis.com/upload/gmail/v1/users/me/messages/x"),
            providerGET("https://www.googleapis.com/batch/calendar/v3"),
            providerGET("https://gmail.googleapis.com/gmail/v1/users/me/messages/x/attachments/y"),
            providerGET("https://gmail.googleapis.com/gmail/v1/users/me/messages?labelIds=INBOX"),
            providerGET("https://www.googleapis.com/calendar/v3/users/me/calendarList?showHidden=true"),
            providerGET("https://tasks.googleapis.com/tasks/v1/lists/x/tasks?dueMin=2026-09-10T00%3A00%3A00Z"),
        ]

        for candidate in rejected {
            XCTAssertThrowsError(try GoogleNetworkPolicy.validate(candidate))
        }
    }

    func testPolicyRejectsDuplicateSingletonsEmptyValuesBadEnumsAndOutOfRangeNumbers() {
        // Break caught: a decoded query multimap accepts duplicate, empty, invalid, or unbounded inputs.
        let rejected = [
            providerGET("https://gmail.googleapis.com/gmail/v1/users/me/messages?q=after%3A1&q=after%3A2"),
            providerGET("https://gmail.googleapis.com/gmail/v1/users/me/messages?q="),
            providerGET("https://gmail.googleapis.com/gmail/v1/users/me/messages?maxResults=100"),
            providerGET("https://gmail.googleapis.com/gmail/v1/users/me/messages?q=after%3A1"),
            providerGET("https://gmail.googleapis.com/gmail/v1/users/me/messages?maxResults=0&q=after%3A1"),
            providerGET("https://gmail.googleapis.com/gmail/v1/users/me/messages?maxResults=101&q=after%3A1"),
            providerGET("https://gmail.googleapis.com/gmail/v1/users/me/messages/x?format=raw"),
            providerGET("https://gmail.googleapis.com/gmail/v1/users/me/messages/x?metadataHeaders=To"),
            providerGET("https://gmail.googleapis.com/gmail/v1/users/me/history?startHistoryId=123&historyTypes=labelAdded"),
            providerGET("https://gmail.googleapis.com/gmail/v1/users/me/history?startHistoryId=123&historyTypes=messageAdded"),
            providerGET("https://www.googleapis.com/calendar/v3/users/me/calendarList?minAccessRole=writer"),
            providerGET("https://www.googleapis.com/calendar/v3/calendars/x/events?singleEvents=false"),
            providerGET("https://www.googleapis.com/calendar/v3/calendars/x/events?timeMin=2026-09-10T00%3A00%3A00Z"),
            providerGET("https://www.googleapis.com/calendar/v3/calendars/x/events?syncToken=x&timeMax=2026-09-17T00%3A00%3A00Z"),
            providerGET("https://tasks.googleapis.com/tasks/v1/lists/x/tasks?showCompleted=true"),
            providerGET("https://tasks.googleapis.com/tasks/v1/lists/x/tasks?updatedMin=2026-09-10T00%3A00%3A00Z&showCompleted=false"),
            providerGET("https://tasks.googleapis.com/tasks/v1/lists/x/tasks?maxResults=100&maxResults=100"),
        ]

        for candidate in rejected {
            XCTAssertThrowsError(try GoogleNetworkPolicy.validate(candidate))
        }
    }

    func testPolicyRejectsFragmentsCredentialsTraversalEncodedSeparatorsAndAmbiguousQueries() {
        // Break caught: URL or query normalization turns an ambiguous address into an approved read.
        let rejected = [
            providerGET("https://gmail.googleapis.com/gmail/v1/users/me/profile#fragment"),
            providerGET("https://user:password@gmail.googleapis.com/gmail/v1/users/me/profile"),
            providerGET("https://gmail.googleapis.com/gmail/v1/users/me/../me/profile"),
            providerGET("https://gmail.googleapis.com/gmail/v1/users/me/profile%2Fextra"),
            providerGET("https://gmail.googleapis.com/gmail/v1/users/me/%2e%2e/profile"),
            providerGET("https://gmail%2Egoogleapis.com/gmail/v1/users/me/profile"),
            providerGET("https://gmail.googleapis.com/gmail/v1/users/me/messages?q=after%253A1"),
            providerGET("https://tasks.googleapis.com/tasks/v1/lists/x/tasks?maxResults=1%26x=1"),
            providerGET("https://gmail.googleapis.com/gmail/v1/users/me/messages?q=after%3A1&&maxResults=1"),
        ]

        for candidate in rejected {
            XCTAssertThrowsError(try GoogleNetworkPolicy.validate(candidate))
        }
    }

    func testPolicyRejectsTrailingAndDoubleSlashesForStaticAndParameterizedRoutes() {
        // Break caught: path splitting normalizes an unsafe path into an approved route template.
        let rejected = [
            providerGET("https://gmail.googleapis.com/gmail/v1/users/me/profile/"),
            providerGET("https://gmail.googleapis.com/gmail//v1/users/me/profile"),
            providerGET("https://gmail.googleapis.com/gmail/v1/users/me/messages/opaque/?format=full"),
            providerGET("https://gmail.googleapis.com/gmail/v1/users/me/messages//opaque?format=full"),
            providerGET("https://www.googleapis.com/calendar/v3/calendars/opaque//events?singleEvents=true&showDeleted=true&timeMin=2026-09-10T00%3A00%3A00Z&timeMax=2026-09-17T00%3A00%3A00Z"),
        ]

        for candidate in rejected {
            XCTAssertThrowsError(try GoogleNetworkPolicy.validate(candidate))
        }
    }

    func testPolicyRequiresOnlyOneValidBearerHeaderForProviderRoutes() {
        // Break caught: an unauthenticated, malformed, or ambient credential header crosses the provider boundary.
        let noAuthorization = request("GET", "https://gmail.googleapis.com/gmail/v1/users/me/profile")
        var badAuthorization = providerGET("https://gmail.googleapis.com/gmail/v1/users/me/profile")
        badAuthorization.setValue("Basic c3ludGhldGlj", forHTTPHeaderField: "Authorization")
        var ambientHeader = providerGET("https://gmail.googleapis.com/gmail/v1/users/me/profile")
        ambientHeader.setValue("SID=synthetic", forHTTPHeaderField: "Cookie")
        var getWithBody = providerGET("https://gmail.googleapis.com/gmail/v1/users/me/profile")
        getWithBody.httpBody = Data("forbidden".utf8)

        for candidate in [noAuthorization, badAuthorization, ambientHeader, getWithBody] {
            XCTAssertThrowsError(try GoogleNetworkPolicy.validate(candidate))
        }
    }

    func testPolicyRejectsMissingURLEmptyMethodAndUnexpectedHostOrPort() {
        // Break caught: structurally incomplete or lookalike requests inherit permissive defaults.
        var missingURL = providerGET("https://gmail.googleapis.com/gmail/v1/users/me/profile")
        missingURL.url = nil
        var emptyMethod = providerGET("https://gmail.googleapis.com/gmail/v1/users/me/profile")
        emptyMethod.httpMethod = ""
        let rejected = [
            missingURL,
            emptyMethod,
            providerGET("http://gmail.googleapis.com/gmail/v1/users/me/profile"),
            providerGET("https://gmail.googleapis.com:444/gmail/v1/users/me/profile"),
            providerGET("https://gmail.googleapis.com.evil.example.test/gmail/v1/users/me/profile"),
            request("GET", "https://oauth2.googleapis.com/token"),
        ]

        for candidate in rejected {
            XCTAssertThrowsError(try GoogleNetworkPolicy.validate(candidate))
        }
    }
}

func request(_ method: String, _ url: String, headers: [String: String] = [:]) -> URLRequest {
    var request = URLRequest(url: URL(string: url)!)
    request.httpMethod = method
    headers.forEach { request.setValue($0.value, forHTTPHeaderField: $0.key) }
    return request
}

func providerGET(_ url: String) -> URLRequest {
    request("GET", url, headers: ["Authorization": "Bearer synthetic-access-token"])
}

func providerRequest(_ method: String, _ url: String) -> URLRequest {
    request(method, url, headers: ["Authorization": "Bearer synthetic-access-token"])
}
