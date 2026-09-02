#if !LITE_BUILD
import Foundation
import LiveWallpaperCore

struct WPEProjectSettingsPresentation: Equatable {
    struct Section: Identifiable, Equatable {
        let id: String
        let title: String
        let properties: [WallpaperEngineProjectPropertySchema.Property]
    }

    enum SettingsRow: Identifiable, Equatable {
        case sectionHeader(Section)
        case property(WallpaperEngineProjectPropertySchema.Property)

        var id: String {
            switch self {
            case .sectionHeader(let section):
                return "section:\(section.id)"
            case .property(let property):
                return "property:\(property.key)"
            }
        }
    }

    let values: [String: WallpaperEngineProjectPropertyValue]
    let sections: [Section]
    let visibleKeys: Set<String>

    init(
        schema: WallpaperEngineProjectPropertySchema,
        overrides: [String: WallpaperEngineProjectPropertyValue],
        excludedKeys: Set<String> = [],
        isInteractive: (WallpaperEngineProjectPropertySchema.PropertyType) -> Bool = Self.isSceneInteractive
    ) {
        let values = schema.effectiveValues(overrides: overrides)
        var sections: [Section] = []
        var currentID: String?
        var currentTitle: String?
        var currentGroupIsVisible = false
        var currentProperties: [WallpaperEngineProjectPropertySchema.Property] = []
        var visibleKeys = Set<String>()

        func flushCurrentSection() {
            guard let currentID,
                  let currentTitle,
                  currentGroupIsVisible,
                  !currentProperties.isEmpty else {
                currentProperties.removeAll(keepingCapacity: true)
                return
            }
            sections.append(Section(
                id: currentID,
                title: currentTitle,
                properties: currentProperties
            ))
            currentProperties.removeAll(keepingCapacity: true)
        }

        for property in schema.properties {
            if property.type == .group {
                flushCurrentSection()
                currentID = property.key
                currentTitle = property.displayText
                currentGroupIsVisible = WallpaperEngineProjectPropertySchema.visiblePropertyConditionMatches(condition: property.condition, values: values)
                continue
            }

            guard !excludedKeys.contains(property.key),
                  isInteractive(property.type),
                  !property.isPromotionalLink,
                  WallpaperEngineProjectPropertySchema.visiblePropertyConditionMatches(condition: property.condition, values: values) else {
                continue
            }

            if currentID == nil {
                currentID = Self.ungroupedSectionID
                currentTitle = "Settings"
                currentGroupIsVisible = true
            }

            guard currentGroupIsVisible else {
                continue
            }

            currentProperties.append(property)
            visibleKeys.insert(property.key)
        }
        flushCurrentSection()

        self.values = values
        self.sections = sections
        self.visibleKeys = visibleKeys
    }

    static func isSceneInteractive(_ type: WallpaperEngineProjectPropertySchema.PropertyType) -> Bool {
        switch type {
        case .bool, .slider, .combo, .color, .textinput: return true
        case .file, .directory, .sceneTexture, .userShortcut, .group, .text, .unsupported: return false
        }
    }

    static func prunedSectionIDs(
        _ sectionIDs: Set<String>,
        for sections: [Section]
    ) -> Set<String> {
        sectionIDs.intersection(sections.map(\.id))
    }

    static let ungroupedSectionID = "__ungrouped"

    /// A scene whose author grouped nothing gets a flat list: one collapsible
    /// group wrapping every property is a lid with nothing beside it.
    func rows(expandedSectionIDs: Set<String>) -> [SettingsRow] {
        if sections.count == 1, sections.first?.id == Self.ungroupedSectionID {
            guard let section = sections.first else { return [] }
            return section.properties.map(SettingsRow.property)
        }

        return sections.flatMap { section -> [SettingsRow] in
            var rows: [SettingsRow] = [.sectionHeader(section)]
            guard expandedSectionIDs.contains(section.id) else { return rows }
            rows.append(contentsOf: section.properties.map(SettingsRow.property))
            return rows
        }
    }
}
#endif
