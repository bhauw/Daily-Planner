import DailyPlannerDomain
import SwiftUI

public struct PlannerRootView: View {
    @StateObject private var model: PlannerAppModel

    public init(model: PlannerAppModel) {
        _model = StateObject(wrappedValue: model)
    }

    public var body: some View {
        VStack(spacing: 0) {
            safetyRail

            if let failure = model.failure {
                Label(failure.message, systemImage: "exclamationmark.triangle")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .background(Color(nsColor: .controlBackgroundColor))
            }

            GeometryReader { proxy in
                let availableWidth = max(0, proxy.size.width - 2)
                let widths = ThreeColumnLayoutPolicy.widths(total: availableWidth)

                HStack(spacing: 0) {
                    PriorityQueueColumn(events: model.preview.queue)
                        .frame(width: widths.left)
                    Divider()
                    SchedulePreviewColumn(
                        events: model.preview.schedule,
                        localDay: model.previewIntervalStart
                    )
                    .frame(width: widths.center)
                    Divider()
                    AssistantStatusColumn(state: model.assistantState)
                        .frame(width: widths.right)
                }
            }
        }
        .frame(minWidth: 1100, minHeight: 680)
        .sheet(isPresented: settingsBinding) {
            PlannerSettingsView(model: model)
                .frame(width: 720, height: 560)
        }
    }

    private var safetyRail: some View {
        HStack(spacing: 8) {
            Image(systemName: "lock.shield.fill")
                .foregroundStyle(.orange)
            Text(model.safetyBanner)
                .font(.callout.weight(.semibold))
            Spacer()
            PlannerActionButton(
                title: "Refresh preview",
                identifier: "refresh-planning-preview-button",
                accessibilityValue: "Refresh the local planning preview",
                systemImage: "arrow.clockwise"
            ) {
                Task { await model.refresh() }
            }
            .fixedSize()
            PlannerActionButton(
                title: "Settings",
                identifier: "planner-settings-button",
                accessibilityValue: "Configure Google read-only access, vault permission, and calendar roles",
                systemImage: "gearshape"
            ) {
                model.showSettings()
            }
            .fixedSize()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(Color.orange.opacity(0.16))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Read-only safety")
        .accessibilityValue("Read-only · no actions executed")
        .accessibilityIdentifier("m2a-safety-banner")
        .background {
            PlannerAccessibilityMarker(
                identifier: "m2a-safety-banner",
                label: "Read-only safety",
                value: "Read-only · no actions executed"
            )
        }
    }

    private var settingsBinding: Binding<Bool> {
        Binding(
            get: { model.isSettingsPresented },
            set: { isPresented in
                if !isPresented { Task { await model.dismissSettings() } }
            }
        )
    }
}

private extension PlannerAppModel {
    var previewIntervalStart: Date {
        preview.schedule.first?.start ?? Date()
    }
}

private extension PlannerAppFailure {
    var message: String {
        switch self {
        case .settingsUnavailable:
            "Settings are unavailable."
        case .catalogUnavailable:
            "Calendars are unavailable."
        case .selectionUnavailable:
            "Folder selection is unavailable."
        case .refreshUnavailable:
            "The preview could not be refreshed."
        case .referenceViewUnavailable:
            "The reference calendar is unavailable."
        }
    }
}
