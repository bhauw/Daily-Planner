import DailyPlannerDomain
import SwiftUI

public enum PlannerPalette {
    // Fallback category colours, fixed by the product brief and each verified ≥4.5:1
    // against the app background `#1E1E1E` (WCAG relative-luminance). Explicit hex values
    // rather than system colours so the measured contrast is stable and provable.
    public static let school = rgb(0x0A, 0x84, 0xFF)          // #0A84FF · 4.57:1
    public static let schoolDeadline = rgb(0xB3, 0x9E, 0xEB)  // #B39EEB · 7.15:1
    public static let extracurricular = rgb(0x30, 0xD1, 0x58) // #30D158 · 8.25:1
    public static let career = rgb(0xFF, 0xD6, 0x0A)          // #FFD60A · 11.81:1
    /// Finance is **lavender**, not the career yellow. The previous mapping returned the
    /// career colour here — the brief's documented bug — so it is fixed and locked by test.
    public static let finance = schoolDeadline                // #B39EEB · 7.15:1
    /// Softened from the old `NSColor.magenta` (#FF00FF): still distinct, no longer the one
    /// harsh note in a calm palette.
    public static let personal = rgb(0xFF, 0x6A, 0xC1)        // #FF6AC1 · 6.42:1
    /// A commute already present in the calendar. Warm tan, honouring Braxton's "Commute"
    /// colour while staying accessible (raw graphite/brown failed the contrast floor).
    public static let commute = rgb(0xCB, 0xA1, 0x6B)         // #CBA16B · 7.03:1
    /// A real job. Lifted graphite so it reads as neutral-but-present against the background.
    public static let work = rgb(0xAE, 0xB4, 0xBE)            // #AEB4BE · 8.00:1

    private static func rgb(_ r: Int, _ g: Int, _ b: Int) -> Color {
        Color(red: Double(r) / 255, green: Double(g) / 255, blue: Double(b) / 255)
    }

    static func presentation(for event: PlannerEvent) -> PlannerCategoryPresentation {
        if event.kind == .extracurricular {
            return PlannerCategoryPresentation(
                label: "Extracurricular",
                symbolName: "figure.run",
                color: extracurricular
            )
        }

        switch event.category {
        case .school where event.kind == .deadline:
            return PlannerCategoryPresentation(
                label: "School deadline",
                symbolName: "calendar.badge.exclamationmark",
                color: schoolDeadline
            )
        case .school:
            return PlannerCategoryPresentation(
                label: "School",
                symbolName: "graduationcap.fill",
                color: school
            )
        case .career:
            return PlannerCategoryPresentation(
                label: "Career",
                symbolName: "briefcase.fill",
                color: career
            )
        case .finance:
            return PlannerCategoryPresentation(
                label: "Finance",
                symbolName: "dollarsign.circle.fill",
                color: finance
            )
        case .personal:
            return PlannerCategoryPresentation(
                label: "Personal",
                symbolName: "person.fill",
                color: personal
            )
        case .commute:
            return PlannerCategoryPresentation(
                label: "Commute",
                symbolName: "car.fill",
                color: commute
            )
        case .work:
            return PlannerCategoryPresentation(
                label: "Work",
                symbolName: "hammer.fill",
                color: work
            )
        case .other:
            return PlannerCategoryPresentation(
                label: "Other",
                symbolName: "circle.grid.2x2.fill",
                color: .secondary
            )
        }
    }
}

struct PlannerCategoryPresentation {
    let label: String
    let symbolName: String
    let color: Color
}

enum PlannerFormatting {
    static let vancouver = TimeZone(identifier: "America/Vancouver")
        ?? TimeZone(secondsFromGMT: 0)!

    static func time(_ date: Date) -> String {
        var style = Date.FormatStyle(date: .omitted, time: .shortened)
        style.timeZone = vancouver
        return date.formatted(style)
    }

    static func localDay(_ date: Date) -> String {
        var style = Date.FormatStyle(date: .long, time: .omitted)
        style.timeZone = vancouver
        return date.formatted(style)
    }
}
