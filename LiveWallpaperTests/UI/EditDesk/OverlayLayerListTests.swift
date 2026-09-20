import Foundation
@testable import LiveWallpaper
import LiveWallpaperCore
import Testing

@Suite("Overlay layer column")
struct OverlayLayerListTests {
    private func placement(_ kind: MonitorWidgetKind) -> MonitorWidgetPlacement {
        MonitorWidgetPlacement(kind: kind, size: .small, x: 0.1, y: 0.1)
    }

    private func isWidget(_ item: OverlayAddItem) -> Bool {
        if case .widget = item {
            true
        } else {
            false
        }
    }

    @Test("Rows run board placements, then clock, music and effect")
    func rowOrder() {
        let widgets = [placement(.cpu), placement(.memory)]
        let rows = OverlayLayerList.rows(
            placements: widgets, clockEnabled: true, musicEnabled: false, effectVisible: true
        )
        #expect(rows.count == 5)
        #expect(rows.map(\.kind) == [
            .widget(.cpu), .widget(.memory), .clock, .music, .effect,
        ])
        #expect(rows.map(\.selection) == [
            .widget(widgets[0].id), .widget(widgets[1].id), .clock, .music, .effect,
        ])
        #expect(rows.map(\.action) == [
            .remove, .remove, .toggle(isOn: true), .toggle(isOn: false), .toggle(isOn: true),
        ])
    }

    @Test("An empty board still lists clock, music and effect")
    func rowOrderWithEmptyBoard() {
        let rows = OverlayLayerList.rows(
            placements: [], clockEnabled: false, musicEnabled: false, effectVisible: false
        )
        #expect(rows.count == 3)
        #expect(rows.map(\.kind) == [.clock, .music, .effect])
        #expect(rows.allSatisfy { $0.action == .toggle(isOn: false) })
    }

    @Test("The add grid holds fourteen items and never the decode-only nixie clock")
    func addItems() {
        let items = OverlayLayerList.addItems
        #expect(items.count == 14)
        #expect(!items.contains(.widget(.nixieClock)))
        #expect(items.filter(isWidget).count == 11)
        #expect(items.suffix(3) == [.music, .clock, .effect])
        #expect(Set(items.map(\.id)).count == 14)
    }

    @Test("Category chips filter the same fourteen items")
    func categoryFilter() {
        #expect(OverlayLayerList.addItems(in: .all) == OverlayLayerList.addItems)
        #expect(OverlayLayerList.addItems(in: .weather) == [.widget(.weather), .effect])
        #expect(OverlayLayerList.addItems(in: .agent) == [.widget(.fleet)])
        #expect(OverlayLayerList.addItems(in: .music) == [.music])
        #expect(OverlayLayerList.addItems(in: .clock) == [.clock])
        #expect(OverlayLayerList.addItems(in: .effect) == [.effect])
        let system = OverlayLayerList.addItems(in: .system)
        #expect(system.count == 9)
        #expect(!system.contains(.widget(.weather)) && !system.contains(.widget(.fleet)))
        let covered = OverlayAddCategory.allCases.filter { $0 != .all }
            .flatMap { OverlayLayerList.addItems(in: $0) }
        #expect(Set(covered.map(\.id)) == Set(OverlayLayerList.addItems.map(\.id)))
    }

    @Test("Each selection dispatches to its own inspector")
    func inspectorDispatch() {
        let id = UUID()
        #expect(OverlayLayerList.inspectorContent(for: .widget(id)) == .widget(id))
        #expect(OverlayLayerList.inspectorContent(for: .music) == .music)
        #expect(OverlayLayerList.inspectorContent(for: .clock) == .clock)
        #expect(OverlayLayerList.inspectorContent(for: .effect) == .effect)
        #expect(OverlayLayerList.inspectorContent(for: nil) == .empty)
    }

    @Test("The effect row reads the applied particle effect, never the monitor overlay switch")
    func effectVisibilitySource() throws {
        let session = try RepositoryRoot.source("LiveWallpaper/Views/EditDesk/Overlay/OverlayEditorSession.swift")
        let start = try #require(session.range(of: "var effectVisible: Bool {"))
        let end = try #require(session.range(of: "}", range: start.upperBound ..< session.endIndex))
        #expect(session[start.upperBound ..< end.lowerBound].contains("draft.selectedParticleEffect != .none"))
        for file in ["OverlayInspectorColumn", "LayerNavigator", "ObjectInspector", "AddOverlayDrawer"] {
            let source = try RepositoryRoot.source("LiveWallpaper/Views/EditDesk/Overlay/\(file).swift")
            #expect(!source.contains("overlay.enabled"), "\(file) must not read the monitor overlay switch")
            #expect(!source.contains("@State private var selection"), "\(file) must not own a second selection")
        }
        let column = try RepositoryRoot.source("LiveWallpaper/Views/EditDesk/Overlay/OverlayInspectorColumn.swift")
        #expect(column.contains("effectVisible: session.effectVisible"))
        let navigator = try RepositoryRoot.source("LiveWallpaper/Views/EditDesk/Overlay/LayerNavigator.swift")
        #expect(navigator.contains("session.setEffectVisible("))
    }

    @Test("Column heights cap the layer list, fix the drawer and leave the inspector the rest")
    func columnHeights() {
        for total in [644.0, 764.0] as [CGFloat] {
            for rowCount in [3, 6, 14] {
                for expanded in [false, true] {
                    let heights = OverlayColumnLayout.heights(
                        total: total, rowCount: rowCount, drawerExpanded: expanded
                    )
                    #expect(heights.drawer == (expanded ? 190 : 30))
                    #expect(heights.layers <= 30 + 6 * 30)
                    #expect(heights.layers == 30 + CGFloat(min(rowCount, 6)) * 30)
                    #expect(heights.inspector >= 200)
                    #expect(heights.layers + heights.inspector + heights.drawer == total)
                }
            }
        }
    }

    @Test("A short column shrinks the layer list before the inspector floor")
    func columnHeightsUnderPressure() {
        let heights = OverlayColumnLayout.heights(total: 360, rowCount: 6, drawerExpanded: true)
        #expect(heights.drawer == 190)
        #expect(heights.inspector == 170)
        #expect(heights.layers == 0)
    }
}
