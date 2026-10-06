import AppKit
import Combine
@testable import LiveWallpaper
import LiveWallpaperCore
import Testing

@Suite("Monitor board follows Reduce Motion")
struct BoardReduceMotionTests {
    @MainActor
    @Test("Configuration updates publish through the model without replacing an unchanged root")
    func unchangedEnvironmentKeepsRoot() {
        let placement = MonitorWidgetPlacement(kind: .cpu, size: .small)
        var configuration = MonitorBoardConfiguration(
            widgets: [placement], mouseInteractionEnabled: true, reduceMotionOverride: false
        )
        let host = HostView(frame: NSRect(x: 0, y: 0, width: 800, height: 600), configuration: configuration)
        let rebuilds = host.debugRootViewRebuildCount
        var publications = 0
        let subscription = host.interactionModel.objectWillChange.sink { publications += 1 }
        defer { subscription.cancel() }

        for _ in 0 ..< 100 {
            host.apply(configuration: configuration)
        }
        #expect(host.debugRootViewRebuildCount == rebuilds)

        configuration.widgets[0].isHidden = true
        let safeArea = MonitorSafeAreaInsets(top: 0.1, bottom: 0.2)
        let priorPublications = publications
        host.apply(configuration: configuration, safeArea: safeArea)
        #expect(publications > priorPublications)
        #expect(host.interactionModel.placements == configuration.widgets)
        #expect(host.interactionModel.safeArea == safeArea)
        #expect(host.pointerScope == .none)
        #expect(host.debugRootViewRebuildCount == rebuilds)

        configuration.reduceMotionOverride = true
        host.apply(configuration: configuration)
        #expect(host.debugReduceMotion)
        #expect(host.debugRootViewRebuildCount == rebuilds + 1)
        host.apply(configuration: configuration)
        #expect(host.debugRootViewRebuildCount == rebuilds + 1)
    }

    @MainActor
    @Test("An unchanged environment still cancels a drag and superseded debounced edits")
    func unchangedEnvironmentCancelsSupersededEdits() {
        let placement = MonitorWidgetPlacement(kind: .cpu, size: .small)
        let configuration = MonitorBoardConfiguration(widgets: [placement], reduceMotionOverride: true)
        let host = HostView(frame: NSRect(x: 0, y: 0, width: 800, height: 600), configuration: configuration)
        var persisted: [MonitorBoardConfiguration] = []
        host.onConfigurationEdited = { persisted.append($0) }
        host.setEditing(true)
        host.interactionModel.boardSize = host.bounds.size
        host.interactionModel.beginDrag(placement.id, grabOffset: .zero)
        #expect(host.interactionModel.drag != nil)
        host.interactionModel.setHidden(placement.id, to: true)
        let rebuilds = host.debugRootViewRebuildCount

        host.apply(configuration: configuration)
        host.flushPendingEdits()
        #expect(host.interactionModel.drag == nil)
        #expect(host.interactionModel.placements.first?.isHidden == false)
        #expect(persisted.isEmpty)
        #expect(host.debugRootViewRebuildCount == rebuilds)
    }

    @MainActor
    @Test("A board already on the desktop picks up the switch; a configured override still wins")
    func boardFollowsTheSwitch() {
        let host = HostView(
            frame: NSRect(x: 0, y: 0, width: 800, height: 600),
            configuration: MonitorBoardConfiguration(widgets: [])
        )
        host.reduceMotionWatcherOverride = false
        host.apply(configuration: MonitorBoardConfiguration(widgets: []))
        #expect(host.debugReduceMotion == false)

        host.reduceMotionWatcherOverride = true
        NSWorkspace.shared.notificationCenter.post(
            name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil
        )
        #expect(host.debugReduceMotion == true, "the board kept the value it read at init")

        host.apply(configuration: MonitorBoardConfiguration(widgets: [], reduceMotionOverride: false))
        #expect(host.debugReduceMotion == false)
    }
}
