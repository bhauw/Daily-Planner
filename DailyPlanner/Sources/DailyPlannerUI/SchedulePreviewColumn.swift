import DailyPlannerDomain
import Foundation
import SwiftUI

struct SchedulePreviewColumn: View {
    let events: [PlannerEvent]
    let localDay: Date

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ColumnHeader(
                eyebrow: "TODAY",
                title: PlannerFormatting.localDay(localDay),
                detail: "\(events.count) \(events.count == 1 ? "item" : "items")"
            )

            Divider()

            if events.isEmpty {
                EmptyColumnState(
                    symbolName: "calendar",
                    title: "Your day is clear",
                    detail: "Planning calendar items will appear here after a refresh."
                )
            } else {
                ScrollView {
                    LazyVStack(spacing: 8) {
                        ForEach(events, id: \.id) { event in
                            PlannerEventRow(event: event, showsDuration: true)
                        }
                    }
                    .padding(16)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color(nsColor: .windowBackgroundColor))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Schedule preview")
        .accessibilityValue("\(PlannerFormatting.localDay(localDay)), \(events.count)")
        .accessibilityIdentifier("schedule-preview-column")
        .background {
            PlannerAccessibilityMarker(
                identifier: "schedule-preview-column",
                label: "Schedule preview",
                value: "\(PlannerFormatting.localDay(localDay)), \(events.count)"
            )
        }
    }
}
