import Foundation
import XCTest
@testable import DailyPlannerAPI

final class PlannerAPIServiceTests: XCTestCase {
    // A fixed instant so the synthetic data and day string are deterministic.
    private let referenceDate = Date(timeIntervalSince1970: 1_800_000_000)

    private func service() -> PlannerAPIService {
        PlannerAPIService(referenceDate: referenceDate)
    }

    private func object(_ data: Data) -> [String: Any] {
        (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
    }

    func testHealthShape() {
        let json = object(service().health())
        XCTAssertEqual(json["ok"] as? Bool, true)
        XCTAssertEqual(json["mode"] as? String, "read-only")
    }

    func testPreviewReturnsContractShape() async throws {
        let json = object(try await service().preview())
        let queue = json["queue"] as? [[String: Any]]
        let schedule = json["schedule"] as? [[String: Any]]
        XCTAssertNotNil(json["day"] as? String)
        // The seeded planning calendar yields the two synthetic school items.
        XCTAssertEqual(queue?.count, 2)
        XCTAssertEqual(schedule?.count, 2)

        let categories = Set(["school", "career", "finance", "personal", "other"])
        let kinds = Set(["event", "deadline", "extracurricular", "advertisement"])
        for event in queue ?? [] {
            XCTAssertNotNil(event["id"] as? String)
            XCTAssertNotNil(event["title"] as? String)
            XCTAssertTrue(categories.contains(event["category"] as? String ?? ""))
            XCTAssertTrue(kinds.contains(event["kind"] as? String ?? ""))
            XCTAssertNotNil(event["start"] as? String)
            // Contract keys must be present even when null.
            XCTAssertTrue(event.keys.contains("end"))
            XCTAssertTrue(event.keys.contains("due"))
            XCTAssertTrue(event.keys.contains("location"))
        }
    }

    func testPreviewStartIsISO8601WithOffset() async throws {
        let json = object(try await service().preview())
        let first = (json["queue"] as? [[String: Any]])?.first
        let start = first?["start"] as? String ?? ""
        // e.g. 2027-01-15T09:00:00-08:00 — must carry a real offset, not a bare 'Z'-less string.
        XCTAssertTrue(start.contains("T"))
        XCTAssertTrue(start.hasSuffix(":00") || start.contains("+") || start.contains("-"))
        let formatter = ISO8601DateFormatter()
        XCTAssertNotNil(formatter.date(from: start), "start must be parseable ISO8601")
    }

    func testCalendarsHaveMappedRoles() async throws {
        let json = object(try await service().calendars())
        let calendars = json["calendars"] as? [[String: Any]] ?? []
        XCTAssertEqual(calendars.count, 2)
        let roles = Set(calendars.compactMap { $0["role"] as? String })
        XCTAssertEqual(roles, ["planning", "excluded"])
        // Never leaks the domain's raw `excludedReference` spelling to the wire.
        XCTAssertFalse(roles.contains("excludedReference"))
    }

    func testSettingsShape() {
        let json = object(service().settingsPayload())
        XCTAssertEqual(json["vaultSelected"] as? Bool, false)
        XCTAssertEqual((json["scanTimes"] as? [String])?.count, 3)
        let safety = json["safety"] as? [String: Any]
        XCTAssertEqual(safety?["mode"] as? String, "read-only")
        XCTAssertEqual(safety?["externalWrites"] as? Bool, false)
        XCTAssertEqual(safety?["label"] as? String, "Read-only · no external writes")
    }

    /// The wire shape must match the web client's `Draft` exactly. It previously shared only
    /// `id` with it — the engine sent subject/recipient/body/status/contextUsed while the client
    /// read title/summary/kind — so every row in the Mail list rendered blank.
    func testDraftsMatchTheClientContract() async {
        let json = object(await service().drafts())
        let drafts = json["drafts"] as? [[String: Any]] ?? []
        XCTAssertFalse(drafts.isEmpty)
        for draft in drafts {
            XCTAssertNotNil(draft["id"] as? String)
            XCTAssertNotNil(draft["title"] as? String, "the client renders `title`")
            XCTAssertNotNil(draft["summary"] as? String, "the client renders `summary`")
            let kind = draft["kind"] as? String
            XCTAssertTrue(
                ["reply", "bundle", "event", "task"].contains(kind ?? ""),
                "kind must be one of the client's DraftKind values, got \(kind ?? "nil")"
            )
        }
    }

    func testTasksHaveFiveLists() async {
        let json = object(await service().tasks())
        let lists = json["lists"] as? [[String: Any]] ?? []
        XCTAssertEqual(lists.count, 5)
        let names = Set(lists.compactMap { $0["name"] as? String })
        XCTAssertEqual(names, ["School", "Career", "Extracurricular", "Personal", "Finance"])
    }
}
