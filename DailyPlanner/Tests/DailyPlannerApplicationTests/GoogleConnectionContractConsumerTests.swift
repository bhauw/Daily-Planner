import XCTest
import DailyPlannerDomain

final class GoogleConnectionContractConsumerTests: XCTestCase {
    func testDomainConsumersCanConstructPendingIdentityAndConnectionReceipt() throws {
        let binding = try GoogleIdentityBinding(normalizing: "student@example.test")
        let pendingIdentity = GooglePendingIdentity(
            displayEmail: "Student@example.test",
            binding: binding
        )
        let receipt = GoogleConnectionReceipt(
            scopes: ["gmail.readonly", "calendar.readonly", "tasks.readonly"],
            refreshSucceeded: true,
            gmailProfileRead: true,
            calendarListRead: true,
            taskListsRead: true,
            binding: binding
        )

        XCTAssertEqual(pendingIdentity.displayEmail, "Student@example.test")
        XCTAssertEqual(pendingIdentity.binding, binding)
        XCTAssertEqual(receipt.scopes, ["gmail.readonly", "calendar.readonly", "tasks.readonly"])
        XCTAssertTrue(receipt.refreshSucceeded)
        XCTAssertTrue(receipt.gmailProfileRead)
        XCTAssertTrue(receipt.calendarListRead)
        XCTAssertTrue(receipt.taskListsRead)
        XCTAssertEqual(receipt.binding, binding)
    }
}
