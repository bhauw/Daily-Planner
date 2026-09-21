import DailyPlannerApplication
import DailyPlannerDomain
import SwiftUI

/// The settings surface.
///
/// Presented two ways: as a sheet over `PlannerRootView`, and as the entire content of the
/// Settings window. In the window there is nothing behind it to dismiss back to, so `onDone`
/// lets the host close the window instead of clearing a sheet flag that was never set.
public struct PlannerSettingsView: View {
    @ObservedObject private var model: PlannerAppModel
    private let onDone: (() -> Void)?

    public init(model: PlannerAppModel, onDone: (() -> Void)? = nil) {
        self.model = model
        self.onDone = onDone
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Settings")
                        .font(.title2.weight(.semibold))
                    Text("Local permissions and calendar roles")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Done") {
                    if let onDone {
                        onDone()
                    } else {
                        Task { await model.dismissSettings() }
                    }
                }
                .keyboardShortcut(.defaultAction)
            }
            .padding(20)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    googleConnectionSection

                    settingsSection(
                        title: "Vault permission",
                        detail: "Remember access to one folder without displaying or sharing its location."
                    ) {
                        VaultSelectionButton(accessibilityValue: model.vaultPermissionLabel) {
                            Task { await model.chooseVaultRoot() }
                        }
                        .fixedSize()

                        Text(model.vaultPermissionLabel)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }

                    settingsSection(
                        title: "Calendar roles",
                        detail: "Only calendars explicitly marked Planning may influence the preview."
                    ) {
                        PlannerActionButton(
                            title: "Refresh calendar roles",
                            identifier: "refresh-calendar-roles-button",
                            accessibilityValue: "Refresh the local calendar roles",
                            systemImage: "arrow.clockwise"
                        ) {
                            Task { await model.loadCalendarRoles() }
                        }
                        .fixedSize()

                        if model.calendarRoleRows.isEmpty {
                            Label("No calendars available", systemImage: "calendar.badge.exclamationmark")
                                .foregroundStyle(.secondary)
                        } else {
                            ForEach(model.calendarRoleRows, id: \.calendarID) { row in
                                HStack(spacing: 16) {
                                    Label(row.displayName, systemImage: "calendar")
                                        .lineLimit(2)
                                    Spacer()
                                    CalendarRolePopUpButton(
                                        displayName: row.displayName,
                                        role: row.role
                                    ) { role in
                                        Task { await model.setRole(role, for: row.calendarID) }
                                    }
                                    .frame(width: 180, height: 28)
                                }
                                .padding(.vertical, 4)
                            }
                        }
                    }

                    categoryColoursSection
                }
                .padding(20)
            }
        }
        .task { await model.loadColorMappings() }
        .frame(minWidth: 640, minHeight: 480)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var categoryColoursSection: some View {
        settingsSection(
            title: "Category colours",
            detail: "Your Google Calendar colours decide an event's category. Assign each colour "
                + "in use to a category; unassigned colours fall back to the default palette."
        ) {
            PlannerActionButton(
                title: "Refresh colours",
                identifier: "refresh-color-mappings-button",
                accessibilityValue: "Reload the Google colours in use",
                systemImage: "arrow.clockwise"
            ) {
                Task { await model.loadColorMappings() }
            }
            .fixedSize()

            if model.colorMappingRows.isEmpty {
                Label(
                    "No calendar colours yet — connect Google to map them.",
                    systemImage: "paintpalette"
                )
                .foregroundStyle(.secondary)
            } else {
                ForEach(model.colorMappingRows) { row in
                    HStack(spacing: 16) {
                        // Swatch + text label are always paired — the mapping is never
                        // conveyed by colour alone, so it survives for colour-blind users.
                        ColorSwatch(hex: row.entry.background)
                        Text(row.entry.label)
                            .lineLimit(1)
                        Spacer()
                        Picker(
                            "Category for \(row.entry.label)",
                            selection: categoryBinding(for: row)
                        ) {
                            Text("Unmapped").tag(PlannerCategory?.none)
                            ForEach(PlannerCategory.allCases, id: \.self) { category in
                                Text(categoryLabel(category)).tag(PlannerCategory?.some(category))
                            }
                        }
                        .labelsHidden()
                        .accessibilityLabel("Category for \(row.entry.label)")
                        .frame(width: 180, height: 28)
                    }
                    .padding(.vertical, 4)
                }
            }
        }
    }

    private func categoryBinding(for row: ColorCategoryRow) -> Binding<PlannerCategory?> {
        Binding(
            get: { row.category },
            set: { newValue in
                Task { await model.setColorCategory(newValue, forColorID: row.entry.colorID) }
            }
        )
    }

    private func categoryLabel(_ category: PlannerCategory) -> String {
        switch category {
        case .school: "School"
        case .career: "Career"
        case .finance: "Finance"
        case .personal: "Personal"
        case .commute: "Commute"
        case .work: "Work"
        case .other: "Other"
        }
    }

    private var googleConnectionSection: some View {
        settingsSection(
            title: "Google connection",
            detail: "Reads your mail, calendar and tasks. Sending and scheduling always ask first."
        ) {
            VStack(alignment: .leading, spacing: 12) {
                if let guidance = model.googleConnectionGuidance {
                    Text(guidance)
                        .font(.callout.weight(.medium))
                        .background {
                            PlannerAccessibilityMarker(
                                identifier: "google-canary-guidance",
                                label: "Canary connection guidance",
                                value: guidance
                            )
                        }
                }

                Label(
                    model.googleConnectionState.statusMessage,
                    systemImage: model.googleConnectionState.statusSymbol
                )
                .font(.callout)
                .foregroundStyle(.secondary)

                PlannerActionButton(
                    title: "Check connection status",
                    identifier: "load-google-connection-state-button",
                    accessibilityValue: "Read the current connection status",
                    isEnabled: !model.googleConnectionState.isPendingConnection
                ) {
                    Task { await model.loadGoogleConnectionState() }
                }
                .fixedSize()

                googleConnectionControls
            }
        }
    }

    /// The client id and secret fields, with advice about what was typed.
    ///
    /// Shown both before a client is configured and after, because a *wrong* client secret puts
    /// the app in exactly the same state as a right one — ready to connect — and the fields used
    /// to disappear at that point. A user whose secret Google refuses could then see the error
    /// but had nowhere to correct it, short of disconnecting and losing the configuration. The
    /// engine has always allowed a replacement here; only this view hid it.
    @ViewBuilder
    private var clientConfigurationFields: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("OAuth client identifier")
                .font(.callout.weight(.medium))
            GoogleClientIdentifierSecureField(text: $model.googleClientIdentifierDraft)
                .frame(maxWidth: .infinity, minHeight: 22)
            if let advice = model.googleClientIdentifierAdvice {
                Label(advice, systemImage: "exclamationmark.circle")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }

            Text("OAuth client secret")
                .font(.callout.weight(.medium))
            GoogleClientSecretSecureField(text: $model.googleClientSecretDraft)
                .frame(maxWidth: .infinity, minHeight: 22)
            if let advice = model.googleClientSecretAdvice {
                Label(advice, systemImage: "exclamationmark.circle")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }

            PlannerActionButton(
                title: "Save client configuration",
                identifier: "save-google-client-button",
                accessibilityValue: "Save the secure client configuration",
                isEnabled: model.canSaveGoogleClientConfiguration
            ) {
                Task { await model.saveGoogleClientConfiguration() }
            }
            .fixedSize()
        }
    }

    @ViewBuilder
    private var googleConnectionControls: some View {
        switch model.googleConnectionState {
        case .notConfigured, .credentialUnavailable:
            clientConfigurationFields

        case .readyToConnect, .cancelled, .offline, .scopeMismatch, .identityMismatch,
             .providerUnavailable:
            PlannerActionButton(
                title: "Connect with sending & scheduling",
                identifier: "connect-google-button",
                accessibilityValue: "Explicitly begin connection with sending and scheduling"
            ) {
                // Google cannot widen a grant after the fact, so asking for writes up front is
                // the difference between consenting once and consenting twice. Nothing is sent
                // or scheduled without an explicit confirmation in the app.
                Task { await model.connectGoogle(capability: .readWrite) }
            }
            .fixedSize()

            // Collapsed, because most of the time the saved client is fine and this is noise.
            // Open, it is the only way to fix a client secret Google refuses.
            DisclosureGroup("Replace client configuration") {
                clientConfigurationFields
                    .padding(.top, 8)
            }
            .font(.callout)
            .padding(.top, 4)

        case .connecting, .awaitingConsent:
            HStack(spacing: 12) {
                ProgressView()
                    .controlSize(.small)
                PlannerActionButton(
                    title: "Cancel",
                    identifier: "cancel-google-button",
                    accessibilityValue: "Cancel pending connection"
                ) {
                    Task { await model.cancelGoogleConnection() }
                }
                .fixedSize()
            }

        case .confirmIdentity(let displayEmail):
            VStack(alignment: .leading, spacing: 10) {
                Text("Confirm connection for \(displayEmail)")
                    .font(.callout.weight(.medium))
                    .background {
                        PlannerAccessibilityMarker(
                            identifier: "google-pending-identity",
                            label: "Pending Google identity",
                            value: displayEmail
                        )
                    }
                HStack(spacing: 12) {
                    PlannerActionButton(
                        title: "Confirm identity",
                        identifier: "confirm-google-identity-button",
                        accessibilityValue: "Confirm the displayed identity"
                    ) {
                        Task { await model.confirmGoogleIdentity() }
                    }
                    .fixedSize()

                    PlannerActionButton(
                        title: "Cancel",
                        identifier: "cancel-google-button",
                        accessibilityValue: "Cancel pending connection"
                    ) {
                        Task { await model.cancelGoogleConnection() }
                    }
                    .fixedSize()
                }
            }

        case .connected(let displayEmail, let capability):
            VStack(alignment: .leading, spacing: 10) {
                Text("Connected as \(displayEmail)")
                    .font(.callout.weight(.medium))
                    .background {
                        PlannerAccessibilityMarker(
                            identifier: "google-connected-identity",
                            label: "Connected Google identity",
                            value: displayEmail
                        )
                    }

                // What this connection can do, from the scopes Google granted. This used to
                // state the read-only case unconditionally, so a connection WITH sending and
                // scheduling was told it had neither — next to a button that deletes the grant
                // and starts consent again. Braxton lost a working connection to it twice.
                if capability.canSendMail {
                    Label(
                        "Sending and scheduling are enabled. Nothing is sent without your confirmation.",
                        systemImage: "checkmark.circle"
                    )
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                } else {
                    Text(
                        """
                        Sending mail and creating events need permissions this connection does not \
                        have. Google cannot add them to an existing sign-in, so enabling them means \
                        approving access again.
                        """
                    )
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                }

                HStack(spacing: 12) {
                    // Offered only when it would actually add something. Shown to a connection
                    // that already sends, it is a button whose only effect is to destroy a
                    // working grant.
                    if !capability.canSendMail {
                        PlannerActionButton(
                            title: "Enable sending & scheduling",
                            identifier: "enable-google-write-button",
                            accessibilityValue: "Reconnect granting permission to send mail and create events"
                        ) {
                            Task { await model.enableGoogleWriteAccess() }
                        }
                        .fixedSize()
                    }

                    PlannerActionButton(
                        title: "Disconnect",
                        identifier: "disconnect-google-button",
                        accessibilityValue: "Remove the connection"
                    ) {
                        Task { await model.disconnectGoogle() }
                    }
                    .fixedSize()
                }
            }

        case .cleanupRequired:
            PlannerActionButton(
                title: "Retry cleanup",
                identifier: "disconnect-google-button",
                accessibilityValue: "Retry connection cleanup"
            ) {
                Task { await model.disconnectGoogle() }
            }
            .fixedSize()
        }
    }

    @ViewBuilder
    private func settingsSection<Content: View>(
        title: String,
        detail: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.headline)
            Text(detail)
                .font(.callout)
                .foregroundStyle(.secondary)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
    }

}

/// A small colour chip rendering a real Google `#RRGGBB` swatch. Decorative only — the row's
/// text label carries the meaning, so the mapping never depends on colour perception.
private struct ColorSwatch: View {
    let hex: String

    var body: some View {
        RoundedRectangle(cornerRadius: 4)
            .fill(Self.color(hex) ?? Color(nsColor: .separatorColor))
            .frame(width: 16, height: 16)
            .overlay(
                RoundedRectangle(cornerRadius: 4)
                    .strokeBorder(Color(nsColor: .separatorColor), lineWidth: 1)
            )
            .accessibilityHidden(true)
    }

    static func color(_ hex: String) -> Color? {
        guard hex.hasPrefix("#"), hex.count == 7,
              let value = Int(hex.dropFirst(), radix: 16) else { return nil }
        return Color(
            red: Double((value >> 16) & 0xFF) / 255,
            green: Double((value >> 8) & 0xFF) / 255,
            blue: Double(value & 0xFF) / 255
        )
    }
}

private extension GoogleConnectionWorkflowState {
    var statusMessage: String {
        switch self {
        case .notConfigured:
            "No client configuration is configured."
        case .readyToConnect:
            "Ready for an explicit connection."
        case .connecting:
            "Preparing the connection."
        case .awaitingConsent:
            "Waiting for consent in the system browser."
        case .confirmIdentity:
            "Identity confirmation is required."
        case .connected(_, let capability):
            capability.canSendMail
                ? "Connected, with sending and scheduling."
                : "Connected, read-only."
        case .cancelled:
            "The connection was cancelled."
        case .offline:
            "The connection is unavailable while offline."
        case .scopeMismatch:
            "The approved access was not granted."
        case .identityMismatch:
            "The selected identity did not match."
        case .credentialUnavailable:
            "Secure credential storage is unavailable."
        case .providerUnavailable:
            "The provider is temporarily unavailable."
        case .cleanupRequired:
            "Connection cleanup must be retried."
        }
    }

    var statusSymbol: String {
        switch self {
        case .connected:
            "checkmark.shield"
        case .connecting, .awaitingConsent:
            "hourglass"
        case .cleanupRequired, .credentialUnavailable, .providerUnavailable:
            "exclamationmark.triangle"
        default:
            "lock.shield"
        }
    }
}
