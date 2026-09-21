import DailyPlannerDomain
import SwiftUI

struct PriorityQueueColumn: View {
    let events: [PlannerEvent]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ColumnHeader(
                eyebrow: "PRIORITY",
                title: "Up next",
                detail: countLabel
            )

            Divider()

            if events.isEmpty {
                EmptyColumnState(
                    symbolName: "checklist",
                    title: "No planning items",
                    detail: "Choose a planning calendar in Settings, then refresh."
                )
            } else {
                ScrollView {
                    LazyVStack(spacing: 8) {
                        ForEach(events, id: \.id) { event in
                            PlannerEventRow(event: event, showsDuration: false)
                        }
                    }
                    .padding(16)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color(nsColor: .controlBackgroundColor))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Priority queue")
        .accessibilityValue("\(events.count)")
        .accessibilityIdentifier("priority-queue-column")
        .background {
            PlannerAccessibilityMarker(
                identifier: "priority-queue-column",
                label: "Priority queue",
                value: "\(events.count)"
            )
        }
    }

    private var countLabel: String {
        "\(events.count) \(events.count == 1 ? "item" : "items")"
    }
}

struct PlannerEventRow: View {
    let event: PlannerEvent
    let showsDuration: Bool

    private var presentation: PlannerCategoryPresentation {
        PlannerPalette.presentation(for: event)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: presentation.symbolName)
                    .foregroundStyle(presentation.color)
                Text(presentation.label)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 8)
                Text(PlannerFormatting.time(event.start))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            Text(event.title)
                .font(.body.weight(.medium))
                .lineLimit(2)

            if showsDuration {
                Text("\(PlannerFormatting.time(event.start))–\(PlannerFormatting.time(event.end))")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
        .overlay(alignment: .leading) {
            RoundedRectangle(cornerRadius: 2)
                .fill(presentation.color)
                .frame(width: 4)
                .padding(.vertical, 8)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            "\(presentation.label), \(event.kind.accessibleLabel), \(PlannerFormatting.time(event.start))"
        )
        .background {
            PlannerAccessibilityMarker(
                identifier: "",
                label: "\(presentation.label), \(event.kind.accessibleLabel), \(PlannerFormatting.time(event.start))",
                value: presentation.symbolName
            )
        }
    }
}

private extension PlannerItemKind {
    var accessibleLabel: String {
        switch self {
        case .event: "event"
        case .deadline: "deadline"
        case .task: "task"
        case .extracurricular: "extracurricular"
        case .advertisement: "advertisement"
        }
    }
}

struct ColumnHeader: View {
    let eyebrow: String
    let title: String
    let detail: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(eyebrow)
                .font(.caption2.weight(.bold))
                .tracking(1.1)
                .foregroundStyle(.secondary)
            HStack(alignment: .firstTextBaseline) {
                Text(title)
                    .font(.title2.weight(.semibold))
                Spacer()
                Text(detail)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
        .padding(16)
    }
}

struct EmptyColumnState: View {
    let symbolName: String
    let title: String
    let detail: String

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: symbolName)
                .font(.title)
                .foregroundStyle(.secondary)
            Text(title)
                .font(.headline)
            Text(detail)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(24)
    }
}
