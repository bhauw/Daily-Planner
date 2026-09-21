import Foundation
import XCTest
@testable import DailyPlannerApplication
@testable import DailyPlannerPlatform

@MainActor
final class MacVaultFolderPickerTests: XCTestCase {
    func testSelectedEmptyGeneratedDirectoryCreatesBookmarkWithoutChangingAttributes() async throws {
        let fixtureRoot = FileManager.default.temporaryDirectory
            .appending(path: "daily-planner-bookmark-fixture-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: fixtureRoot, withIntermediateDirectories: false)
        defer {
            try? FileManager.default.removeItem(at: fixtureRoot)
        }

        let before = try FileManager.default.attributesOfItem(atPath: fixtureRoot.path)
        let picker = MacVaultFolderPicker(selectURL: { fixtureRoot })

        let bookmark = try await picker.selectRootBookmark()

        let after = try FileManager.default.attributesOfItem(atPath: fixtureRoot.path)
        XCTAssertNotNil(bookmark)
        XCTAssertFalse(bookmark?.isEmpty ?? true)
        XCTAssertEqual(before as NSDictionary, after as NSDictionary)
    }

    func testCancellationReturnsNilBookmark() async throws {
        let picker = MacVaultFolderPicker(selectURL: { nil })
        let bookmark = try await picker.selectRootBookmark()

        XCTAssertNil(bookmark)
    }
}
