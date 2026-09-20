import CoreGraphics
import Foundation
import LiveWallpaperCore

/// What a layer row stands for. Board widgets carry their kind; the other three are singletons.
enum OverlayLayerKind: Equatable {
    case widget(MonitorWidgetKind)
    case clock
    case music
    case effect
}

/// The trailing control of a layer row. Board widgets are added and removed, not hidden, so
/// their action removes rather than toggles.
enum OverlayLayerAction: Equatable {
    case remove
    case toggle(isOn: Bool)
}

struct OverlayLayerRow: Identifiable, Equatable {
    let selection: OverlaySelection
    let kind: OverlayLayerKind
    let action: OverlayLayerAction

    var id: OverlaySelection {
        selection
    }
}

enum OverlayAddItem: Identifiable, Equatable {
    case widget(MonitorWidgetKind)
    case music
    case clock
    case effect

    var id: String {
        switch self {
        case let .widget(kind): "widget.\(kind.rawValue)"
        case .music: "music"
        case .clock: "clock"
        case .effect: "effect"
        }
    }
}

enum OverlayAddCategory: String, CaseIterable, Identifiable {
    case all, system, weather, music, clock, effect, agent

    var id: String {
        rawValue
    }
}

/// Which editor the selected object gets. `empty` is the "no selection" placeholder.
enum OverlayInspectorContent: Equatable {
    case widget(UUID)
    case music
    case clock
    case effect
    case empty
}

enum OverlayLayerList {
    static func rows(
        placements: [MonitorWidgetPlacement], clockEnabled: Bool, musicEnabled: Bool, effectVisible: Bool
    ) -> [OverlayLayerRow] {
        placements.map {
            OverlayLayerRow(selection: .widget($0.id), kind: .widget($0.kind), action: .remove)
        } + [
            OverlayLayerRow(selection: .clock, kind: .clock, action: .toggle(isOn: clockEnabled)),
            OverlayLayerRow(selection: .music, kind: .music, action: .toggle(isOn: musicEnabled)),
            OverlayLayerRow(selection: .effect, kind: .effect, action: .toggle(isOn: effectVisible)),
        ]
    }

    /// `MonitorWidgetKind.allCases` already drops the decode-only `nixieClock`.
    static let addItems: [OverlayAddItem] =
        MonitorWidgetKind.allCases.map(OverlayAddItem.widget) + [.music, .clock, .effect]

    static func addItems(in category: OverlayAddCategory) -> [OverlayAddItem] {
        switch category {
        case .all: addItems
        case .system: addItems.filter {
                guard case let .widget(kind) = $0 else { return false }
                return kind != .weather && kind != .fleet
            }
        case .weather: [.widget(.weather), .effect]
        case .music: [.music]
        case .clock: [.clock]
        case .effect: [.effect]
        case .agent: [.widget(.fleet)]
        }
    }

    static func inspectorContent(for selection: OverlaySelection?) -> OverlayInspectorContent {
        switch selection {
        case let .widget(id): .widget(id)
        case .music: .music
        case .clock: .clock
        case .effect: .effect
        case nil: .empty
        }
    }
}

/// Column height budget: the layer list is capped, the drawer is fixed per state, and the
/// object inspector takes what is left.
enum OverlayColumnLayout {
    static let rowHeight: CGFloat = 30
    static let headerHeight: CGFloat = 30
    static let maxVisibleRows = 6
    static let drawerCollapsedHeight: CGFloat = 30
    static let drawerExpandedHeight: CGFloat = 190
    static let minInspectorHeight: CGFloat = 200

    struct Heights: Equatable {
        var layers: CGFloat
        var inspector: CGFloat
        var drawer: CGFloat
    }

    static func heights(total: CGFloat, rowCount: Int, drawerExpanded: Bool) -> Heights {
        let drawer = drawerExpanded ? drawerExpandedHeight : drawerCollapsedHeight
        let visibleRows = min(max(rowCount, 0), maxVisibleRows)
        let wanted = headerHeight + CGFloat(visibleRows) * rowHeight
        let budget = max(total - drawer, 0)
        // Short windows shrink the layer list, not the inspector: the inspector holds the
        // controls being edited, the list only navigates to them.
        let layers = min(wanted, max(budget - minInspectorHeight, 0))
        return Heights(layers: layers, inspector: budget - layers, drawer: drawer)
    }
}
