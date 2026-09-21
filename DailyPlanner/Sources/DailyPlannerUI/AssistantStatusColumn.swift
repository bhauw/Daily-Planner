import SwiftUI

struct AssistantStatusColumn: View {
    let state: AssistantState

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ColumnHeader(
                eyebrow: "ASSISTANT",
                title: "Status",
                detail: "Not included"
            )

            Divider()

            VStack(alignment: .leading, spacing: 16) {
                Label("Unavailable in M2", systemImage: "lock.shield")
                    .font(.headline)

                Text("Assistant suggestions and external actions are not included in M2.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Divider()

                Label("No actions executed", systemImage: "checkmark.shield")
                    .font(.callout.weight(.medium))
            }
            .padding(16)

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color(nsColor: .controlBackgroundColor))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Assistant status")
        .accessibilityValue("Unavailable in M2")
        .accessibilityIdentifier("assistant-status-column")
        .background {
            PlannerAccessibilityMarker(
                identifier: "assistant-status-column",
                label: "Assistant status",
                value: "Unavailable in M2"
            )
        }
    }
}
