import AppKit
import SwiftUI
import XCTest
@testable import DailyPlannerApplication
@testable import DailyPlannerUI

@MainActor
final class PlannerRootViewAccessibilityTests: XCTestCase {
    func testHostingRootDoesNotLoadPrivateStateBeforeExplicitRefresh() async {
        let harness = PlannerModelHarness.make(planningSchool: true)

        let root = host(
            PlannerRootView(model: harness.model),
            width: 1100,
            height: 680
        )
        defer { root.close() }
        try? await Task.sleep(for: .milliseconds(50))

        XCTAssertEqual(harness.store.loadCount, 0)
        XCTAssertEqual(harness.connection.credentialPresenceCount, 0)
    }

    func testHostingSettingsDoesNotLoadPrivateStateBeforeExplicitAction() async {
        let harness = PlannerModelHarness.make(
            planningSchool: true,
            googleState: .readyToConnect
        )

        let settings = host(
            PlannerSettingsView(model: harness.model),
            width: 720,
            height: 640
        )
        defer { settings.close() }
        try? await Task.sleep(for: .milliseconds(50))

        XCTAssertEqual(harness.store.loadCount, 0)
        XCTAssertEqual(harness.connection.credentialPresenceCount, 0)
        XCTAssertEqual(harness.connection.actions, [])
        XCTAssertEqual(harness.browser.openCount, 0)
    }

    func testHostedRootRefreshActionPopulatesPreviewOnlyAfterExplicitActivation() async throws {
        let harness = PlannerModelHarness.make(planningSchool: true)
        let root = host(
            PlannerRootView(model: harness.model),
            width: 1100,
            height: 680
        )
        defer { root.close() }
        try? await Task.sleep(for: .milliseconds(50))

        let snapshot = HostedAccessibilitySnapshot.capture(from: root)
        let refresh = try XCTUnwrap(
            accessibilityControl(identifier: "refresh-planning-preview-button", in: root)
        )
        XCTAssertEqual(refresh.accessibilityLabel(), "Refresh preview")
        XCTAssertTrue(snapshot.enabledControlIdentifiers.contains("refresh-planning-preview-button"))
        XCTAssertTrue(harness.model.preview.queue.isEmpty)
        XCTAssertEqual(harness.store.loadCount, 0)
        XCTAssertEqual(harness.connection.credentialPresenceCount, 0)

        refresh.performClick(nil)

        let previewLoaded = await waitForHostedUpdate { !harness.model.preview.queue.isEmpty }
        XCTAssertTrue(previewLoaded)
        XCTAssertEqual(harness.model.preview.queue.map(\.calendarID), [harness.schoolCalendarID])
        XCTAssertEqual(harness.store.loadCount, 1)
        XCTAssertEqual(harness.connection.credentialPresenceCount, 0)
        XCTAssertEqual(harness.browser.openCount, 0)
    }

    func testHostedSettingsRefreshActionPopulatesCalendarRolesOnlyAfterExplicitActivation() async throws {
        let harness = PlannerModelHarness.make(planningSchool: true)
        let settings = host(
            PlannerSettingsView(model: harness.model),
            width: 720,
            height: 640
        )
        defer { settings.close() }
        try? await Task.sleep(for: .milliseconds(50))

        let snapshot = HostedAccessibilitySnapshot.capture(from: settings)
        let refresh = try XCTUnwrap(
            accessibilityControl(identifier: "refresh-calendar-roles-button", in: settings)
        )
        XCTAssertEqual(refresh.accessibilityLabel(), "Refresh calendar roles")
        XCTAssertTrue(snapshot.enabledControlIdentifiers.contains("refresh-calendar-roles-button"))
        XCTAssertTrue(harness.model.calendarRoleRows.isEmpty)
        XCTAssertEqual(harness.store.loadCount, 0)
        XCTAssertEqual(harness.connection.credentialPresenceCount, 0)

        refresh.performClick(nil)

        let rolesLoaded = await waitForHostedUpdate { !harness.model.calendarRoleRows.isEmpty }
        XCTAssertTrue(rolesLoaded)
        XCTAssertEqual(harness.model.calendarRoleRows.map(\.calendarID), [harness.schoolCalendarID])
        XCTAssertEqual(harness.store.loadCount, 1)
        XCTAssertEqual(harness.connection.credentialPresenceCount, 0)
        XCTAssertEqual(harness.browser.openCount, 0)
    }

    func testHostedExplicitDataRefreshActionsAreKeyboardReachable() async throws {
        let rootHarness = PlannerModelHarness.make(planningSchool: true)
        let root = host(
            PlannerRootView(model: rootHarness.model),
            width: 1100,
            height: 680
        )
        defer { root.close() }
        try? await Task.sleep(for: .milliseconds(50))

        let settings = try XCTUnwrap(
            accessibilityControl(identifier: "planner-settings-button", in: root)
        )
        XCTAssertTrue(root.window.makeFirstResponder(settings))
        let rootVisited = try tabCycleIdentifiers(in: root.window, stepCount: 1)
        XCTAssertTrue(rootVisited.contains("refresh-planning-preview-button"))

        let settingsHarness = PlannerModelHarness.make(planningSchool: true)
        let settingsView = host(
            PlannerSettingsView(model: settingsHarness.model),
            width: 720,
            height: 640
        )
        defer { settingsView.close() }
        try? await Task.sleep(for: .milliseconds(50))

        XCTAssertEqual(
            (settingsView.window.firstResponder as? NSView)?.accessibilityIdentifier(),
            "choose-vault-root-button"
        )
        let settingsVisited = try tabCycleIdentifiers(in: settingsView.window, stepCount: 1)
        XCTAssertTrue(settingsVisited.contains("refresh-calendar-roles-button"))
    }

    func testHostedRootAndSettingsExposeSafeKeyboardReachableStructureAtMinimumSize() async {
        let harness = PlannerModelHarness.make(planningSchool: true)
        await harness.model.refresh()
        await harness.model.loadCalendarRoles()

        let root = host(
            PlannerRootView(model: harness.model),
            width: 1100,
            height: 680
        )
        defer { root.close() }
        let rootNodes = HostedAccessibilitySnapshot.capture(from: root)
        XCTAssertTrue(rootNodes.identifiers.isSuperset(of: [
            "m2a-safety-banner", "priority-queue-column", "schedule-preview-column",
            "assistant-status-column", "planner-settings-button", "refresh-planning-preview-button",
        ]))

        let settings = host(
            PlannerSettingsView(model: harness.model),
            width: 720,
            height: 560
        )
        defer { settings.close() }
        let settingsNodes = HostedAccessibilitySnapshot.capture(from: settings)
        XCTAssertTrue(settingsNodes.identifiers.contains("choose-vault-root-button"))
        XCTAssertTrue(settingsNodes.identifiers.contains("calendar-role-picker"))
        XCTAssertTrue(settingsNodes.enabledControlIdentifiers.contains("choose-vault-root-button"))
        XCTAssertTrue(settingsNodes.enabledControlIdentifiers.contains("calendar-role-picker"))
        XCTAssertTrue((rootNodes.labels + settingsNodes.labels).contains { $0.contains("School") })

        let exposedText = (rootNodes.exposedText + settingsNodes.exposedText).joined(separator: " ")
        for forbidden in [
            harness.schoolCalendarID.rawValue,
            "synthetic-event-title-canary",
            "/synthetic/private/canary",
            "opaque-bookmark-canary",
        ] {
            XCTAssertFalse(exposedText.contains(forbidden))
        }
    }

    func testConnectionStatesExposeExactlyApplicableControlsAndReachEachByTabWithoutSecrets() async throws {
        let expectedControls: [(GoogleConnectionWorkflowState, Set<String>)] = [
            (.notConfigured, [
                "google-client-identifier-field", "google-client-secret-field",
                "save-google-client-button",
            ]),
            (.readyToConnect, ["connect-google-button"]),
            (.connecting, ["cancel-google-button"]),
            (.awaitingConsent, ["cancel-google-button"]),
            (.confirmIdentity(displayEmail: "reader@example.test"), [
                "confirm-google-identity-button", "cancel-google-button",
            ]),
            // Read-only: the upgrade is real, so it is offered.
            (.connected(displayEmail: "reader@example.test", capability: .readOnly), [
                "enable-google-write-button", "disconnect-google-button",
            ]),
            // Already sending and scheduling: the upgrade would only delete the grant and start
            // consent again, so it must not be offered at all.
            (.connected(displayEmail: "writer@example.test", capability: .readWrite), [
                "disconnect-google-button",
            ]),
            (.cancelled, ["connect-google-button"]),
            (.offline, ["connect-google-button"]),
            (.scopeMismatch, ["connect-google-button"]),
            (.identityMismatch, ["connect-google-button"]),
            (.credentialUnavailable, [
                "google-client-identifier-field", "google-client-secret-field",
                "save-google-client-button",
            ]),
            (.providerUnavailable, ["connect-google-button"]),
            (.cleanupRequired, ["disconnect-google-button"]),
        ]
        var allIdentifiers: Set<String> = []
        var allExposedText: [String] = []

        for (state, expected) in expectedControls {
            let harness = PlannerModelHarness.make(planningSchool: true, googleState: state)
            if state == .notConfigured || state == .credentialUnavailable {
                harness.model.googleClientIdentifierDraft = "synthetic-client.apps.example.test"
                harness.model.googleClientSecretDraft = "synthetic-secret-canary"
            }
            let settings = host(
                PlannerSettingsView(model: harness.model),
                width: 720,
                height: 640
            )
            try? await Task.sleep(for: .milliseconds(50))
            let snapshot = HostedAccessibilitySnapshot.capture(from: settings)
            XCTAssertEqual(
                snapshot.identifiers.intersection(googleConnectionControlIdentifiers),
                expected,
                "Incorrect controls for \(state)"
            )
            XCTAssertEqual(
                snapshot.enabledControlIdentifiers.intersection(googleConnectionControlIdentifiers),
                expected,
                "Unavailable controls for \(state)"
            )
            // Enough steps to complete a cycle past the non-Google controls that share the
            // screen, so "reachable by tab" is about reachability rather than tab budget.
            let visitedIdentifiers = try tabCycleIdentifiers(
                in: settings.window,
                stepCount: expected.count + 8
            )
            // Subset, not equality, and deliberately so. macOS only tabs between plain buttons
            // when Full Keyboard Access is on, so which buttons Tab visits depends on a system
            // setting this test cannot own. Every state asserted before had at most one button,
            // so equality held by luck; the second button in the connected state exposed it.
            //
            // The property worth keeping is the safety one — Tab must never reach a control that
            // should not be offered at all. Presence and enabled-ness are still asserted exactly,
            // just above, so a missing control cannot slip through here.
            XCTAssertTrue(
                visitedIdentifiers.intersection(googleConnectionControlIdentifiers)
                    .isSubset(of: expected),
                "Tab traversal reached a control that state \(state) must not offer"
            )
            settings.close()
            allIdentifiers.formUnion(snapshot.identifiers)
            allExposedText.append(contentsOf: snapshot.exposedText)
        }

        XCTAssertEqual(allIdentifiers.intersection(googleConnectionControlIdentifiers), [
            "google-client-identifier-field", "google-client-secret-field",
            "save-google-client-button",
            "connect-google-button", "cancel-google-button",
            "confirm-google-identity-button", "disconnect-google-button",
            "enable-google-write-button",
        ])
        let exposedText = allExposedText.joined(separator: " ")
        for forbidden in [
            "synthetic-client.apps.example.test",
            "synthetic-secret-canary",
            "synthetic-token-canary",
            "authorization-code-canary",
            "https://auth.example.test/consent",
        ] {
            XCTAssertFalse(exposedText.contains(forbidden))
        }
    }

    func testConnectedIdentityIsConfinedToFocusedSettings() {
        let harness = PlannerModelHarness.make(
            googleState: .connected(displayEmail: "reader@example.test", capability: .readOnly)
        )
        let root = host(
            PlannerRootView(model: harness.model),
            width: 1100,
            height: 680
        )
        defer { root.close() }

        let rootText = HostedAccessibilitySnapshot.capture(from: root).exposedText.joined(separator: " ")
        XCTAssertFalse(rootText.contains("reader@example.test"))
        XCTAssertTrue(rootText.contains("Read-only · no actions executed"))

        let settings = host(
            PlannerSettingsView(model: harness.model),
            width: 720,
            height: 640
        )
        defer { settings.close() }
        let settingsText = HostedAccessibilitySnapshot.capture(from: settings).exposedText
            .joined(separator: " ")
        XCTAssertTrue(settingsText.contains("reader@example.test"))
    }

    func testCanaryGuidanceIsVisibleAndGenericWithoutStartingConnection() {
        let guidance = "Canary mode is ready. Click Connect to begin; nothing starts automatically."
        let harness = PlannerModelHarness.make(
            googleState: .readyToConnect,
            startsWithSettingsPresented: true,
            googleConnectionGuidance: guidance
        )
        let settings = host(
            PlannerSettingsView(model: harness.model),
            width: 720,
            height: 640
        )
        defer { settings.close() }

        let exposedText = HostedAccessibilitySnapshot.capture(from: settings).exposedText
            .joined(separator: " ")
        XCTAssertTrue(exposedText.contains(guidance))
        XCTAssertEqual(harness.connection.beginCount, 0)
        XCTAssertEqual(harness.browser.openCount, 0)
        for forbidden in ["--live-readonly-canary", "client-id", "token", "https://"] {
            XCTAssertFalse(exposedText.contains(forbidden))
        }
    }

    func testHostedSettingsPlacesInitialKeyboardFocusOnVaultControl() async {
        let harness = PlannerModelHarness.make(planningSchool: true)
        await harness.model.loadCalendarRoles()

        let settings = host(
            PlannerSettingsView(model: harness.model),
            width: 720,
            height: 560
        )
        defer { settings.close() }
        try? await Task.sleep(for: .milliseconds(50))

        XCTAssertEqual(
            (settings.window.firstResponder as? NSView)?.accessibilityIdentifier(),
            "choose-vault-root-button"
        )
    }

    func testHostedSettingsTabMovesFocusWhenGlobalKeyboardNavigationIsOff() async throws {
        let harness = PlannerModelHarness.make(planningSchool: true)
        await harness.model.loadCalendarRoles()

        let settings = host(
            PlannerSettingsView(model: harness.model),
            width: 720,
            height: 560
        )
        defer { settings.close() }
        try? await Task.sleep(for: .milliseconds(50))

        let initial = try XCTUnwrap(settings.window.firstResponder as? NSView)
        let tab = try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: settings.window.windowNumber,
            context: nil,
            characters: "\t",
            charactersIgnoringModifiers: "\t",
            isARepeat: false,
            keyCode: 48
        ))

        initial.keyDown(with: tab)

        let next = try XCTUnwrap(settings.window.firstResponder as? NSView)
        XCTAssertNotEqual(ObjectIdentifier(initial), ObjectIdentifier(next))
        XCTAssertEqual(next.accessibilityIdentifier(), "refresh-calendar-roles-button")
    }

    func testHostedSettingsTabCycleReachesSecureClientFieldAndSaveAction() async throws {
        let harness = PlannerModelHarness.make(planningSchool: true)
        harness.model.googleClientIdentifierDraft = "synthetic-client.apps.example.test"
        harness.model.googleClientSecretDraft = "synthetic-secret-canary"
        await harness.model.loadCalendarRoles()

        let settings = host(
            PlannerSettingsView(model: harness.model),
            width: 720,
            height: 640
        )
        defer { settings.close() }
        try? await Task.sleep(for: .milliseconds(50))

        var visitedIdentifiers: Set<String> = []
        for _ in 0..<8 {
            let tab = try XCTUnwrap(NSEvent.keyEvent(
                with: .keyDown,
                location: .zero,
                modifierFlags: [],
                timestamp: 0,
                windowNumber: settings.window.windowNumber,
                context: nil,
                characters: "\t",
                charactersIgnoringModifiers: "\t",
                isARepeat: false,
                keyCode: 48
            ))
            settings.window.sendEvent(tab)
            let responder = settings.window.firstResponder as? NSView
            let focusedControl = (responder as? NSTextView)?.delegate as? NSView
            if let identifier = (focusedControl ?? responder)?.accessibilityIdentifier(),
               !identifier.isEmpty {
                visitedIdentifiers.insert(identifier)
            }
        }

        XCTAssertTrue(
            visitedIdentifiers.contains("google-client-identifier-field"),
            "Visited: \(visitedIdentifiers.sorted())"
        )
        XCTAssertTrue(
            visitedIdentifiers.contains("google-client-secret-field"),
            "Visited: \(visitedIdentifiers.sorted())"
        )
        XCTAssertTrue(
            visitedIdentifiers.contains("save-google-client-button"),
            "Visited: \(visitedIdentifiers.sorted())"
        )
    }
}

private let googleConnectionControlIdentifiers: Set<String> = [
    "google-client-identifier-field", "google-client-secret-field", "save-google-client-button",
    "connect-google-button", "cancel-google-button",
    "confirm-google-identity-button", "disconnect-google-button",
    // Absent from this set until it cost a working connection twice: a control that is only
    // ever destructive when it is offered wrongly, and so was never asserted about at all.
    "enable-google-write-button",
]

@MainActor
private func tabCycleIdentifiers(in window: NSWindow, stepCount: Int) throws -> Set<String> {
    var visitedIdentifiers: Set<String> = []

    for _ in 0..<stepCount {
        let tab = try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: window.windowNumber,
            context: nil,
            characters: "\t",
            charactersIgnoringModifiers: "\t",
            isARepeat: false,
            keyCode: 48
        ))
        window.sendEvent(tab)
        let responder = window.firstResponder as? NSView
        let focusedControl = (responder as? NSTextView)?.delegate as? NSView
        if let identifier = (focusedControl ?? responder)?.accessibilityIdentifier(),
           !identifier.isEmpty {
            visitedIdentifiers.insert(identifier)
        }
    }

    return visitedIdentifiers
}

@MainActor
private func accessibilityControl(identifier: String, in fixture: HostedViewFixture) -> NSControl? {
    func find(in view: NSView) -> NSControl? {
        if let control = view as? NSControl,
           control.accessibilityIdentifier() == identifier {
            return control
        }
        for child in view.subviews {
            if let control = find(in: child) {
                return control
            }
        }
        return nil
    }

    return find(in: fixture.hostingView)
}

@MainActor
private func waitForHostedUpdate(_ condition: @escaping @MainActor () -> Bool) async -> Bool {
    for _ in 0..<20 {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return condition()
}

@MainActor
final class HostedViewFixture {
    let window: NSWindow
    let hostingView: NSView
    private var isClosed = false

    init(window: NSWindow, hostingView: NSView) {
        self.window = window
        self.hostingView = hostingView
    }

    func close() {
        guard !isClosed else { return }
        isClosed = true
        window.orderOut(nil)
    }
}

struct HostedAccessibilitySnapshot: Sendable {
    let identifiers: Set<String>
    let labels: [String]
    let exposedText: [String]
    let enabledControlIdentifiers: Set<String>

    @MainActor
    static func capture(from fixture: HostedViewFixture) -> HostedAccessibilitySnapshot {
        var identifiers: Set<String> = []
        var labels: [String] = []
        var exposedText: [String] = []
        var enabledControlIdentifiers: Set<String> = []
        var visited: Set<ObjectIdentifier> = []

        func record(
            identifier: String,
            label: String?,
            value: Any?,
            role: NSAccessibility.Role?,
            enabled: Bool
        ) {
            let label = label ?? ""
            let value = value.map(String.init(describing:)) ?? ""

            if !identifier.isEmpty { identifiers.insert(identifier) }
            if !label.isEmpty { labels.append(label) }
            exposedText.append(contentsOf: [identifier, label, value, role?.rawValue ?? ""])

            let controlRoles: Set<NSAccessibility.Role> = [
                .button, .popUpButton, .checkBox, .radioButton, .textField,
            ]
            if enabled, !identifier.isEmpty, let role, controlRoles.contains(role) {
                enabledControlIdentifiers.insert(identifier)
            }
        }

        func captureView(_ view: NSView) {
            let objectID = ObjectIdentifier(view)
            guard visited.insert(objectID).inserted else { return }

            record(
                identifier: view.accessibilityIdentifier(),
                label: view.accessibilityLabel(),
                value: view.accessibilityValue(),
                role: view.accessibilityRole(),
                enabled: (view as? NSControl)?.isEnabled ?? view.isAccessibilityEnabled()
            )
            view.subviews.forEach(captureView)
            (view.accessibilityChildren() ?? []).forEach { child in
                if let childView = child as? NSView {
                    captureView(childView)
                } else if let childElement = child as? NSAccessibilityElement {
                    captureAccessibilityElement(childElement)
                }
            }
        }

        func captureAccessibilityElement(_ element: NSAccessibilityElement) {
            let objectID = ObjectIdentifier(element)
            guard visited.insert(objectID).inserted else { return }

            record(
                identifier: element.accessibilityIdentifier() ?? "",
                label: element.accessibilityLabel(),
                value: element.accessibilityValue(),
                role: element.accessibilityRole(),
                enabled: element.isAccessibilityEnabled()
            )
            (element.accessibilityChildren() ?? []).forEach { child in
                if let childView = child as? NSView {
                    captureView(childView)
                } else if let childElement = child as? NSAccessibilityElement {
                    captureAccessibilityElement(childElement)
                }
            }
        }

        captureView(fixture.hostingView)
        return HostedAccessibilitySnapshot(
            identifiers: identifiers,
            labels: labels,
            exposedText: exposedText,
            enabledControlIdentifiers: enabledControlIdentifiers
        )
    }
}

@MainActor
func host<Content: View>(
    _ content: Content,
    width: CGFloat,
    height: CGFloat
) -> HostedViewFixture {
    _ = NSApplication.shared
    let frame = NSRect(x: 0, y: 0, width: width, height: height)
    let window = NSWindow(
        contentRect: frame,
        styleMask: [.titled, .closable, .resizable],
        backing: .buffered,
        defer: false
    )
    let hostingView = NSHostingView(rootView: content)
    hostingView.frame = frame
    window.contentView = hostingView
    window.setFrame(frame, display: false)
    window.makeKeyAndOrderFront(nil)
    hostingView.layoutSubtreeIfNeeded()
    RunLoop.main.run(until: Date().addingTimeInterval(0.01))
    return HostedViewFixture(window: window, hostingView: hostingView)
}
