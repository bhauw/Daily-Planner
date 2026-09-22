import Foundation
import os

/// Maps an authenticated request to a response. All security checks run in `RequestGuard`
/// first; by the time `respond` dispatches, the request is known to be an allowed method from a
/// loopback origin with a valid token for `/api/*`, and — because the guard enforces that verbs
/// and paths agree — a request that arrives on an `APIWriteRoute` is known to be a POST.
///
/// Every branch but those two write routes reads and returns.
struct APIRouter: Sendable {
    let guardCheck: RequestGuard
    let service: PlannerAPIService
    let assets: StaticWebAssets

    func respond(to request: HTTPRequest) async -> HTTPResponse {
        if let rejection = guardCheck.reject(request) {
            return rejection
        }
        if let route = APIWriteRoute.matching(request.path) {
            return await write(route, body: request.body)
        }
        switch request.path {
        case "/api/health":
            return .json(200, "OK", service.health())
        case "/api/preview":
            return await safe("/api/preview") { try await service.preview() }
        case "/api/week":
            return await safe("/api/week") { try await service.week() }
        case "/api/calendars":
            return await safe("/api/calendars") { try await service.calendars() }
        case "/api/settings":
            return .json(200, "OK", service.settingsPayload())
        case "/api/drafts":
            return .json(200, "OK", await service.drafts())
        case "/api/tasks":
            return .json(200, "OK", await service.tasks())
        default:
            if request.path.hasPrefix("/api/") {
                return .error(404, "Not Found", .notFound, "No such resource.")
            }
            return assets.response(for: request.path)
        }
    }

    /// Carries out one write and reports it in finite terms.
    ///
    /// Every outcome is logged as route plus a finite label — never a recipient, a subject, an
    /// event title or Google's own error text. The connect path shipped with no logging at all
    /// and cost most of a day to diagnose when it failed; a path that can change someone's
    /// mailbox is not the one to repeat that on.
    private func write(_ route: APIWriteRoute, body: Data) async -> HTTPResponse {
        do {
            let payload: Data
            switch route {
            case .sendMail:
                payload = try await service.sendMail(body)
            case .createEvent:
                payload = try await service.createEvent(body)
            case .moveEvent:
                payload = try await service.moveEvent(body)
            case .draftReply:
                payload = try await service.draftReply(body)
            }
            APIDiagnostics.log.info("\(route.rawValue, privacy: .public) ok")
            return .json(200, "OK", payload)
        } catch let failure as APIWriteFailure {
            APIDiagnostics.log.error(
                "\(route.rawValue, privacy: .public) refused: \(failure.logLabel, privacy: .public)"
            )
            return failure.response
        } catch {
            APIDiagnostics.log.error(
                "\(route.rawValue, privacy: .public) failed: \(String(describing: type(of: error)), privacy: .public)"
            )
            return APIWriteFailure.providerUnavailable.response
        }
    }

    /// Wraps an async producer so a workflow failure becomes a finite, content-free 503 rather
    /// than leaking an error description. No provider string, path, or identity is ever echoed
    /// to the client.
    ///
    /// The failure is recorded to the unified log as the route plus the error's *type name* —
    /// never its description, which can carry a provider URL, a calendar title or a message
    /// subject. That is enough to tell a transport failure from a decode failure, and a blank
    /// 503 with no signal at all made a real calendar outage undiagnosable from the app.
    private func safe(_ route: String, _ producer: () async throws -> Data) async -> HTTPResponse {
        do {
            return .json(200, "OK", try await producer())
        } catch {
            APIDiagnostics.log.error(
                "\(route, privacy: .public) failed: \(String(describing: type(of: error)), privacy: .public) \(String(describing: error), privacy: .public)"
            )
            return .error(503, "Service Unavailable", .unavailable, "Data temporarily unavailable.")
        }
    }
}

enum APIDiagnostics {
    static let log = Logger(subsystem: "com.example.dailyplanner", category: "api")
}
