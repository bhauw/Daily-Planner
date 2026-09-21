import Foundation

/// A single Google Calendar colour definition. An opaque `colorId` resolves to a
/// background/foreground hex pair. Colour data is non-content metadata — unlike a
/// calendar title, it is safe to persist and display.
public struct GoogleColorEntry: Codable, Equatable, Hashable, Sendable {
    public let background: String
    public let foreground: String

    public init(background: String, foreground: String) {
        self.background = background
        self.foreground = foreground
    }
}

/// The palette returned by `GET /calendar/v3/colors`: `colorId -> entry` for both
/// calendar-level and event-level colours. Values are the source of truth; we never
/// hardcode hex values for a colour name.
public struct GoogleColorPalette: Codable, Equatable, Sendable {
    public let calendar: [String: GoogleColorEntry]
    public let event: [String: GoogleColorEntry]

    public init(calendar: [String: GoogleColorEntry], event: [String: GoogleColorEntry]) {
        self.calendar = calendar
        self.event = event
    }

    public static let empty = GoogleColorPalette(calendar: [:], event: [:])

    /// The hex swatch for a colour actually in use on an event or calendar. Event
    /// colours take precedence over calendar colours for a shared id, matching how
    /// Google renders an event that overrides its calendar's colour.
    public func entry(forColorID colorID: String) -> GoogleColorEntry? {
        event[colorID] ?? calendar[colorID]
    }
}

/// Resolves a planner category from Google colours. Google's colours are the source
/// of truth for categorisation; the app's abstract mapping is the fallback.
public enum GoogleColorCategory {
    /// The colour that actually governs an event: its own colour if present, otherwise
    /// the colour it inherits from its calendar. Inheritance is explicit here so the
    /// effective colour is never silently left nil.
    public static func effectiveColorID(
        eventColorID: String?,
        calendarColorID: String?
    ) -> String? {
        if let eventColorID, !eventColorID.isEmpty { return eventColorID }
        if let calendarColorID, !calendarColorID.isEmpty { return calendarColorID }
        return nil
    }

    /// Resolve the planner category for an event, honouring colour inheritance and the
    /// user's persisted mapping. A colour the user has not mapped (or an event with no
    /// colour at all) falls back to `fallback`, which is never nil.
    public static func category(
        forEventColorID eventColorID: String?,
        calendarColorID: String?,
        mapping: [String: PlannerCategory],
        fallback: PlannerCategory = .other
    ) -> PlannerCategory {
        guard let effective = effectiveColorID(
            eventColorID: eventColorID,
            calendarColorID: calendarColorID
        ), let mapped = mapping[effective] else {
            return fallback
        }
        return mapped
    }
}

/// A Google colour actually in use in the connected account: the opaque `colorID` plus the
/// real background/foreground swatch to render, and a non-content `label` (e.g. the Google
/// colour name) — never a calendar title.
public struct ColorCatalogEntry: Equatable, Sendable, Identifiable {
    public let colorID: String
    public let background: String
    public let foreground: String
    public let label: String
    public var id: String { colorID }

    public init(colorID: String, background: String, foreground: String, label: String) {
        self.colorID = colorID
        self.background = background
        self.foreground = foreground
        self.label = label
    }
}

/// One editable row in the colour→category mapping Settings editor: a colour in use paired
/// with the category the user has assigned it (nil when unmapped, so it falls back).
public struct ColorCategoryRow: Equatable, Sendable, Identifiable {
    public let entry: ColorCatalogEntry
    public let category: PlannerCategory?
    public var id: String { entry.colorID }

    public init(entry: ColorCatalogEntry, category: PlannerCategory?) {
        self.entry = entry
        self.category = category
    }
}

/// Braxton renamed Google's stock event colours; those names are his real taxonomy.
/// The `/calendar/v3/colors` endpoint returns `colorId -> hex`, and Google's colour
/// *names* map to stable `colorId`s — but the hex values differ per account theme, so
/// we never hardcode them. This seed documents the intended semantics that Settings
/// offers when binding each colour actually in use; the persisted mapping ships empty.
///
/// Note: "school deadline" and "extracurricular" are represented as `PlannerItemKind`
/// values, not categories, so this colour→*category* seed maps them to their closest
/// category. Colour alone never carries the deadline/extracurricular distinction.
public enum GoogleColorTaxonomy {
    /// colour display name (as it appears in Google) → the planner category Braxton uses.
    public static let seedByColorName: [String: PlannerCategory] = [
        "Tomato": .school,        // "Homework or Exam"
        "Banana": .career,        // "Recruiting"
        "Sage": .personal,        // "LIFT" (extracurricular)
        "Lavender": .finance,     // "Financials"
        "Grape": .personal,       // "Personal"
        "Graphite": .work,        // "Work" — a real job, a hard scheduling conflict
        "Peacock": .school,       // classes / calendar default
    ]
}
