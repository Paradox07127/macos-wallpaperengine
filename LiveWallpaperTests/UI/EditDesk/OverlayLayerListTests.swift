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

    @Test("Rows run the widget group, its placements, then clock, music and effect")
    func rowOrder() {
        let widgets = [placement(.cpu), placement(.memory)]
        let rows = OverlayLayerList.rows(
            placements: widgets, boardEnabled: false, clockEnabled: true, musicEnabled: false, effectVisible: true
        )
        #expect(rows.count == 6)
        #expect(rows.map(\.kind) == [
            .board, .widget(.cpu), .widget(.memory), .clock, .music, .effect,
        ])
        #expect(rows.map(\.selection) == [
            .board, .widget(widgets[0].id), .widget(widgets[1].id), .clock, .music, .effect,
        ])
        #expect(rows.map(\.action) == [
            .toggle(isOn: false), .remove, .remove, .toggle(isOn: true), .toggle(isOn: false), .toggle(isOn: true),
        ])
    }

    @Test("An empty board still lists the widget group, clock, music and effect")
    func rowOrderWithEmptyBoard() {
        let rows = OverlayLayerList.rows(
            placements: [], boardEnabled: false, clockEnabled: false, musicEnabled: false, effectVisible: false
        )
        #expect(rows.count == 4)
        #expect(rows.map(\.kind) == [.board, .clock, .music, .effect])
        #expect(rows.allSatisfy { $0.action == .toggle(isOn: false) })
    }

    @Test("The layer count leaves out the widget group row, wherever it is shown")
    func layerCountSkipsWidgetGroup() throws {
        let rows = OverlayLayerList.rows(
            placements: [placement(.cpu), placement(.memory), placement(.gpu)],
            boardEnabled: false, clockEnabled: false, musicEnabled: false, effectVisible: false
        )
        // A new display lists the group row and its three default widgets; the off singletons are filtered out.
        #expect(OverlayLayerList.layerCount(Array(rows.prefix(4))) == 3)
        #expect(OverlayLayerList.layerCount(rows) == 6)
        let workspace = try RepositoryRoot.source("LiveWallpaper/Views/EditDesk/Overlay/OverlayWorkspace.swift")
        #expect(workspace.contains("OverlayLayerList.layerCount(rows)"), "OverlayWorkspace must count through the shared source")
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

    @Test("Each selection dispatches to its own inspector")
    func inspectorDispatch() {
        let id = UUID()
        #expect(OverlayLayerList.inspectorContent(for: .board) == .board)
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
        for file in ["OverlayWorkspace", "LayerNavigator", "ObjectInspector", "AddOverlayDrawer"] {
            let source = try RepositoryRoot.source("LiveWallpaper/Views/EditDesk/Overlay/\(file).swift")
            #expect(!source.contains("overlay.enabled"), "\(file) must not read the monitor overlay switch")
            #expect(!source.contains("@State private var selection"), "\(file) must not own a second selection")
        }
        let workspace = try RepositoryRoot.source("LiveWallpaper/Views/EditDesk/Overlay/OverlayWorkspace.swift")
        #expect(workspace.contains("effectVisible: session.effectVisible"))
        let navigator = try RepositoryRoot.source("LiveWallpaper/Views/EditDesk/Overlay/LayerNavigator.swift")
        #expect(navigator.contains("session.setEffectVisible("))
    }

    @Test("Agent folder access is one section, mounted by both inspectors and never inside the widget card")
    func agentAccessEntries() throws {
        let inspector = try RepositoryRoot.source("LiveWallpaper/Views/EditDesk/Overlay/ObjectInspector.swift")
        #expect(inspector.contains("AgentFolderAccessSection()"))
        #expect(inspector.contains("MonitorOverlaySection("))
        let legacy = try RepositoryRoot.source("LiveWallpaper/Views/Monitor/BoardSettingsView.swift")
        #expect(legacy.contains("AgentFolderAccessSection()"))
        let card = try RepositoryRoot.source("LiveWallpaper/Views/Monitor/WidgetSettingsPopover.swift")
        #expect(!card.contains("AgentFolderAccessSection"))
        let requesters = try RepositoryRoot.swiftFiles(under: "LiveWallpaper")
            .filter { try String(contentsOf: $0, encoding: .utf8).contains("SourceAuthorization.shared.requestAccess") }
            .map(\.lastPathComponent)
        #expect(requesters == ["AgentFolderAccessSection.swift"])
    }

    @Test("The board-full notice has no timer: it stays until the widgets change")
    func boardFullNotice() throws {
        let drawer = try RepositoryRoot.source("LiveWallpaper/Views/EditDesk/Overlay/AddOverlayDrawer.swift")
        #expect(!drawer.contains("Task.sleep"))
        #expect(drawer.contains(".onChange(of: interaction.placements)"))
    }

    @Test("The add strip lays its fourteen tiles out as seven columns by two rows")
    func drawerLayout() {
        #expect(AddOverlayDrawer.columns(for: OverlayLayerList.addItems.count) == 7)
        #expect(abs(AddOverlayDrawer.tileWidth(containerWidth: 1040, count: 14) - 968.0 / 7) < 0.001)
        #expect(abs(AddOverlayDrawer.tileWidth(containerWidth: 1280, count: 14) - 1208.0 / 7) < 0.001)
        #expect(AddOverlayDrawer.expandedHeight == 150)
        #expect(AddOverlayDrawer.collapsedHeight == 38)
    }

    @Test("The add strip has no category filter and fills its grid in board order")
    func noCategoryFilter() throws {
        for file in ["OverlayLayerList", "AddOverlayDrawer"] {
            let source = try RepositoryRoot.source("LiveWallpaper/Views/EditDesk/Overlay/\(file).swift")
            #expect(!source.contains("OverlayAddCategory"), "\(file) still filters the add strip by category")
            #expect(!source.contains("addItems(in:"), "\(file) still filters the add strip by category")
        }
        #expect(OverlayLayerList.addItems.map(\.id) == [
            "widget.systemOverview", "widget.cpu", "widget.memory", "widget.gpu", "widget.network", "widget.disk",
            "widget.power", "widget.processes", "widget.fleet", "widget.aiEngine", "widget.weather",
            "music", "clock", "effect",
        ])
    }

    @Test("The add strip never scrolls sideways")
    func drawerDoesNotScroll() throws {
        let drawer = try RepositoryRoot.source("LiveWallpaper/Views/EditDesk/Overlay/AddOverlayDrawer.swift")
        #expect(!drawer.contains("ScrollView(.horizontal)"))
    }

    @Test("The inspector has one switch per object: none in its header, none in the effect panel")
    func inspectorSwitches() throws {
        let inspector = try RepositoryRoot.source("LiveWallpaper/Views/EditDesk/Overlay/ObjectInspector.swift")
        #expect(!inspector.contains("headerToggle"))
        let panel = try #require(inspector.range(of: "OverlaysInspectorPanel("))
        let call = inspector[panel.lowerBound...].prefix(700)
        #expect(call.contains("showsVisibilityControl: false"))
    }

    @Test("Embedded widget settings use the settings group and row components")
    func embeddedWidgetSettings() throws {
        let card = try RepositoryRoot.source("LiveWallpaper/Views/Monitor/WidgetSettingsPopover.swift")
        #expect(card.contains("SettingRow("))
        #expect(card.contains("ContainerGroupBoxStyle()"))
    }
}
