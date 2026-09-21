import Foundation
import XCTest
@testable import DailyPlannerPlatform

@MainActor
final class MacSystemBrowserTests: XCTestCase {
    func testInjectedWorkspaceReceivesExactURLAndReturnsItsResult() async throws {
        let acceptedWorkspace = RecordingWorkspaceURLopener(result: true)
        let acceptedBrowser = MacSystemBrowser(workspace: acceptedWorkspace)
        let expectedURL = try XCTUnwrap(URL(string: "https://auth.example.test/consent?opaque=canary"))

        let accepted = await acceptedBrowser.open(expectedURL)
        XCTAssertTrue(accepted)
        XCTAssertEqual(acceptedWorkspace.openedURLs, [expectedURL])

        let rejectedWorkspace = RecordingWorkspaceURLopener(result: false)
        let rejectedBrowser = MacSystemBrowser(workspace: rejectedWorkspace)

        let rejected = await rejectedBrowser.open(expectedURL)
        XCTAssertFalse(rejected)
        XCTAssertEqual(rejectedWorkspace.openedURLs, [expectedURL])
    }
}

final class LaunchModeTests: XCTestCase {
    func testOnlyExactSingletonPostExecutableCanaryFlagEnablesCanaryMode() {
        XCTAssertEqual(
            LaunchMode.parse(arguments: ["DailyPlannerApp", "--live-readonly-canary"]),
            .liveReadOnlyCanary
        )

        for arguments in [
            [],
            ["DailyPlannerApp"],
            ["DailyPlannerApp", "--unknown"],
            ["DailyPlannerApp", "--live-readonly-canary", "extra"],
            ["DailyPlannerApp", "--live-readonly-canary", "--live-readonly-canary"],
            ["DailyPlannerApp", "--client-id=synthetic-client.apps.example.test"],
            ["DailyPlannerApp", "--token=synthetic-token-canary"],
            ["--live-readonly-canary"],
        ] {
            XCTAssertEqual(LaunchMode.parse(arguments: arguments), .standard)
        }
    }
}

@MainActor
private final class RecordingWorkspaceURLopener: WorkspaceURLOpening, @unchecked Sendable {
    private(set) var openedURLs: [URL] = []
    private let result: Bool

    init(result: Bool) {
        self.result = result
    }

    func open(_ url: URL) -> Bool {
        openedURLs.append(url)
        return result
    }
}
