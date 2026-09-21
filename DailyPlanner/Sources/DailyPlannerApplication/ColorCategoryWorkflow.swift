import Foundation
import DailyPlannerDomain

/// Reads and persists the user-editable Google `colorId` → planner category mapping. Google's
/// colours are the source of truth for categorisation; this workflow lets Settings bind each
/// colour actually in use to a category, persisting the choice in the encrypted settings blob.
/// It never hardcodes one person's convention — the mapping ships empty.
public struct ColorCategoryWorkflow: Sendable {
    private let settingsStore: any PrivateSettingsStore
    private let catalogReader: any ColorCatalogReading

    public init(
        settingsStore: any PrivateSettingsStore,
        catalogReader: any ColorCatalogReading
    ) {
        self.settingsStore = settingsStore
        self.catalogReader = catalogReader
    }

    /// Every colour in use, plus any already-mapped colour no longer in the catalog, so a saved
    /// mapping stays visible and editable. Ordered by numeric colour id for a stable UI.
    public func rows() async throws -> [ColorCategoryRow] {
        let catalog: [ColorCatalogEntry]
        do {
            catalog = try await catalogReader.colorsInUse()
        } catch {
            throw PlanningWorkflowError.catalogUnavailable
        }

        let settings: PrivateSettings
        do {
            settings = try settingsStore.load()
        } catch {
            throw PlanningWorkflowError.settingsUnavailable
        }

        var entriesByID: [String: ColorCatalogEntry] = [:]
        for entry in catalog {
            entriesByID[entry.colorID] = entry
        }
        for colorID in settings.colorCategoryMapping.keys where entriesByID[colorID] == nil {
            entriesByID[colorID] = ColorCatalogEntry(
                colorID: colorID,
                background: "",
                foreground: "",
                label: "Colour \(colorID)"
            )
        }

        return entriesByID.values
            .map { ColorCategoryRow(entry: $0, category: settings.colorCategoryMapping[$0.colorID]) }
            .sorted { lhs, rhs in
                let lhsOrder = Int(lhs.entry.colorID) ?? .max
                let rhsOrder = Int(rhs.entry.colorID) ?? .max
                if lhsOrder != rhsOrder { return lhsOrder < rhsOrder }
                return lhs.entry.colorID < rhs.entry.colorID
            }
    }

    /// Assign (or, with `nil`, clear) the category for a colour and persist it. Clearing lets the
    /// colour fall back to the app's default palette rather than pinning it to a stale category.
    public func setCategory(_ category: PlannerCategory?, forColorID colorID: String) throws {
        var settings: PrivateSettings
        do {
            settings = try settingsStore.load()
        } catch {
            throw PlanningWorkflowError.settingsUnavailable
        }

        if let category {
            settings.colorCategoryMapping[colorID] = category
        } else {
            settings.colorCategoryMapping.removeValue(forKey: colorID)
        }

        do {
            try settingsStore.replace(settings)
        } catch {
            throw PlanningWorkflowError.settingsUnavailable
        }
    }
}
