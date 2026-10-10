import AppKit
import CoreGraphics
import Foundation
@testable import LiveWallpaper
import LiveWallpaperCore
import Testing

@Suite("RR-15 Monitor overlay visibility lifecycle")
struct OverlayVisibilityLifecycleCharacterizationTests {
    @Test("desktop uses detector occlusion while front remains paintable")
    func levelAndDesktopSurfacePolicy() {
        let visibleDesktop = MonitorOverlayVisibilityPolicy.resolve(
            hosts: [input(1, level: .desktop, occluded: false)],
            isUserAbsent: false
        )
        #expect(
            visibleDesktop
                == decision(
                    disposition: .active,
                    visible: [key(1)],
                    suspended: []
                )
        )

        let occludedDesktop = MonitorOverlayVisibilityPolicy.resolve(
            hosts: [input(1, level: .desktop, occluded: true)],
            isUserAbsent: false
        )
        #expect(
            occludedDesktop
                == decision(
                    disposition: .paused,
                    visible: [],
                    suspended: [key(1)]
                )
        )

        let frontAboveOcclusion = MonitorOverlayVisibilityPolicy.resolve(
            hosts: [input(1, level: .front, occluded: true)],
            isUserAbsent: false
        )
        #expect(
            frontAboveOcclusion
                == decision(
                    disposition: .active,
                    visible: [key(1)],
                    suspended: []
                )
        )
    }

    @Test("the two modules on one display are judged independently")
    func perModuleVisibilityOnOneDisplay() {
        let result = MonitorOverlayVisibilityPolicy.resolve(
            hosts: [
                input(1, module: .monitor, level: .desktop, occluded: true),
                input(1, module: .music, level: .front, occluded: true),
            ],
            isUserAbsent: false
        )

        #expect(
            result
                == decision(
                    disposition: .active,
                    visible: [key(1, .music)],
                    suspended: [key(1, .monitor)]
                )
        )
    }

    @Test("same-level stacking puts Music above Monitor regardless of insertion order")
    func stackingOrderIsIndependentOfCreationOrder() {
        #expect(OverlayController.stackingOrder([.monitor, .music]) == [.monitor, .music])
        #expect(OverlayController.stackingOrder([.music, .monitor]) == [.monitor, .music])
    }

    @Test("user absence suspends every retained host and stops delivery")
    func userAbsencePolicy() {
        let result = MonitorOverlayVisibilityPolicy.resolve(
            hosts: [
                input(1, level: .desktop, occluded: false),
                input(2, level: .front, occluded: false),
            ],
            isUserAbsent: true
        )

        #expect(
            result
                == decision(
                    disposition: .paused,
                    visible: [],
                    suspended: [key(1), key(2)]
                )
        )
        #expect(!result.pumpShouldRun)
        #expect(result.visibleHostKeys.isEmpty)
    }

    @Test("mixed displays expose only paintable snapshot recipients")
    func mixedMultiScreenVisibleUnion() {
        let result = MonitorOverlayVisibilityPolicy.resolve(
            hosts: [
                input(1, level: .desktop, occluded: true),
                input(2, level: .desktop, occluded: false),
                input(3, level: .front, occluded: true),
            ],
            isUserAbsent: false
        )

        #expect(
            result
                == decision(
                    disposition: .active,
                    visible: [key(2), key(3)],
                    suspended: [key(1)]
                )
        )
        #expect(result.pumpShouldRun)
        #expect(result.visibleHostKeys == [key(2), key(3)])
    }

    @Test("host removal transitions active to paused to released")
    func hostRemovalLifecycle() {
        let both = MonitorOverlayVisibilityPolicy.resolve(
            hosts: [
                input(1, level: .desktop, occluded: true),
                input(2, level: .front, occluded: true),
            ],
            isUserAbsent: false
        )
        #expect(
            both
                == decision(
                    disposition: .active,
                    visible: [key(2)],
                    suspended: [key(1)]
                )
        )

        let visibleRemoved = MonitorOverlayVisibilityPolicy.resolve(
            hosts: [input(1, level: .desktop, occluded: true)],
            isUserAbsent: false
        )
        #expect(
            visibleRemoved
                == decision(
                    disposition: .paused,
                    visible: [],
                    suspended: [key(1)]
                )
        )

        let allRemoved = MonitorOverlayVisibilityPolicy.resolve(
            hosts: [],
            isUserAbsent: false
        )
        #expect(
            allRemoved
                == decision(
                    disposition: .released,
                    visible: [],
                    suspended: []
                )
        )
    }

    @Test("ordinary Finder windows participate in desktop occlusion")
    func finderWindowOwnerPolicy() {
        #expect(!FullScreenDetector.shouldExcludeWindowOwner("Finder"))
        #expect(FullScreenDetector.shouldExcludeWindowOwner("Dock"))
        #expect(FullScreenDetector.shouldExcludeWindowOwner("Window Server"))
        #expect(FullScreenDetector.shouldExcludeWindowOwner("SystemUIServer"))
    }

    // MARK: - Two modules, one board (live controller)

    @MainActor
    @Test("real overlay window releases empty space, hidden hosts and the last removed widget")
    func optedInWindowLifecycle() async throws {
        let runtime = makeRuntime()
        let controller = OverlayController(runtime: runtime)
        controller.debugPointerIsCaptured = false
        defer { controller.teardownAll() }
        var overlay = MonitorOverlayConfiguration(
            enabled: true, level: .desktop,
            board: MonitorBoardConfiguration(widgets: [
                MonitorWidgetPlacement(kind: .cpu, size: .small, x: 0.5, y: 0.5),
            ], mouseInteractionEnabled: true)
        )
        let frame = NSRect(x: 0, y: 0, width: 800, height: 600)
        controller.apply(overlay: overlay, screenID: 409, screenFrame: frame)
        let window = try #require(controller.debugWindow(screenID: 409, module: .monitor))
        let tile = window.convertPoint(toScreen: NSPoint(x: 497, y: 197))
        let empty = window.convertPoint(toScreen: NSPoint(x: 700, y: 50))
        #expect(window.acceptsMouseMovedEvents)
        #expect(controller.debugIsTrackingPointer)
        controller.debugMovePointer(to: tile)
        #expect(!window.ignoresMouseEvents)
        controller.debugMovePointer(to: empty)
        #expect(window.ignoresMouseEvents)
        controller.debugMovePointer(to: tile)
        controller.updateVisibility(isUserAbsent: true, occludedScreenIDs: [])
        #expect(window.ignoresMouseEvents)
        #expect(!controller.debugIsTrackingPointer)
        controller.updateVisibility(isUserAbsent: false, occludedScreenIDs: [])
        #expect(controller.debugIsTrackingPointer)
        controller.debugMovePointer(to: tile)
        #expect(!window.ignoresMouseEvents)
        overlay.board.widgets[0].isHidden = true
        controller.apply(overlay: overlay, screenID: 409, screenFrame: frame)
        #expect(window.ignoresMouseEvents)
        #expect(!controller.debugIsTrackingPointer)
        overlay.board.widgets.removeAll()
        controller.apply(overlay: overlay, screenID: 409, screenFrame: frame)
        #expect(window.ignoresMouseEvents)
        controller.teardownAll()
        await controller.waitUntilRuntimeSettled()
        await runtime.shutdown()
    }

    @MainActor
    @Test("music hosts its own window while the Monitor board stays off")
    func musicModuleRunsWithTheMonitorBoardOff() async {
        let runtime = makeRuntime()
        let controller = OverlayController(runtime: runtime)
        controller.apply(
            overlay: MonitorOverlayConfiguration(
                enabled: false,
                level: .desktop,
                music: MusicOverlayConfiguration(enabled: true, level: .front),
                board: MonitorBoardConfiguration(widgets: [Self.cpuWidget])
            ),
            screenID: 401,
            screenFrame: NSRect(x: 0, y: 0, width: 800, height: 600)
        )
        await controller.waitUntilRuntimeSettled()

        #expect(controller.activeHostKeys == [key(401, .music)])
        #expect(controller.music(screenID: 401)?.enabled == true)
        #expect(controller.board(screenID: 401, module: .monitor) == nil)

        controller.teardownAll()
        await controller.waitUntilRuntimeSettled()
        await runtime.shutdown()
    }

    @MainActor
    @Test("a board edit is reported verbatim and never carries the music layer")
    func boardEditIsReportedVerbatim() async throws {
        let runtime = makeRuntime()
        let controller = OverlayController(runtime: runtime)
        var reported: MonitorBoardConfiguration?
        controller.onOverlayEdited = { _, board in reported = board }

        let music = MusicOverlayConfiguration(enabled: true, level: .front, x: 0.25)
        controller.apply(
            overlay: MonitorOverlayConfiguration(
                enabled: true,
                level: .desktop,
                music: music,
                board: MonitorBoardConfiguration(widgets: [Self.cpuWidget])
            ),
            screenID: 402,
            screenFrame: NSRect(x: 0, y: 0, width: 800, height: 600)
        )
        await controller.waitUntilRuntimeSettled()

        var edit = try #require(controller.board(screenID: 402, module: .monitor))
        edit.widgets[0].y = 0.75
        let report = try #require(controller.boardEditCallback(screenID: 402, module: .monitor))
        report(edit)

        let after = try #require(reported)
        #expect(after.widgets.map(\.kind) == [.cpu])
        #expect(after.widgets.first?.y == 0.75)
        #expect(controller.music(screenID: 402) == music)

        controller.teardownAll()
        await controller.waitUntilRuntimeSettled()
        await runtime.shutdown()
    }

    @MainActor
    @Test("a config written before the split runs Monitor only")
    func legacyConfigurationRunsMonitorOnly() async throws {
        let legacy = try JSONDecoder().decode(
            MonitorOverlayConfiguration.self,
            from: Data(#"{ "enabled": true, "level": "front" }"#.utf8)
        )
        #expect(legacy.music == .default)

        let runtime = makeRuntime()
        let controller = OverlayController(runtime: runtime)
        var overlay = legacy
        overlay.board = MonitorBoardConfiguration(widgets: [Self.cpuWidget])
        controller.apply(
            overlay: overlay,
            screenID: 404,
            screenFrame: NSRect(x: 0, y: 0, width: 800, height: 600)
        )
        await controller.waitUntilRuntimeSettled()

        #expect(controller.activeHostKeys == [key(404, .monitor)])
        #expect(controller.board(screenID: 404, module: .monitor)?.widgets.map(\.kind) == [.cpu])

        controller.teardownAll()
        await controller.waitUntilRuntimeSettled()
        await runtime.shutdown()
    }

    private static let cpuWidget = MonitorWidgetPlacement(kind: .cpu, size: .medium, x: 0, y: 0)


    /// nil factory override → the real MainActor registry, same as production.
    private func makeRuntime() -> Runtime {
        Runtime(
            grants: MonitorGrantAccess(
                resolveRoots: { (claude: nil, codex: nil) },
                release: {}
            ),
            sourceFactories: nil
        )
    }

    private func input(
        _ id: CGDirectDisplayID,
        module: MonitorOverlayModule = .monitor,
        level: MonitorOverlayLevel,
        occluded: Bool
    ) -> MonitorOverlayVisibilityInput {
        MonitorOverlayVisibilityInput(
            key: key(id, module),
            level: level,
            isDesktopOccluded: occluded
        )
    }

    private func key(
        _ id: CGDirectDisplayID,
        _ module: MonitorOverlayModule = .monitor
    ) -> MonitorOverlayHostKey {
        MonitorOverlayHostKey(screenID: id, module: module)
    }

    private func decision(
        disposition: MonitorOverlayVisibilityDecision.RuntimeDisposition,
        visible: Set<MonitorOverlayHostKey>,
        suspended: Set<MonitorOverlayHostKey>
    ) -> MonitorOverlayVisibilityDecision {
        MonitorOverlayVisibilityDecision(
            runtimeDisposition: disposition,
            visibleHostKeys: visible,
            suspendedHostKeys: suspended
        )
    }

    @Test("history resets on a new sampled kind, never on Now Playing")
    func historyResetIgnoresNonSamplingKinds() {
        #expect(OverlayController.historyResetRequired(previous: [.cpu], next: [.cpu, .gpu]))
        #expect(!OverlayController.historyResetRequired(previous: [.cpu, .gpu], next: [.cpu]))
        #expect(!OverlayController.historyResetRequired(previous: [.cpu], next: [.cpu]))
    }

    @Test("A widgets-only overlay takes mouse events only while the pointer is over a control")
    func windowGateFollowsThePointer() {
        #expect(!OverlayPointerGate.windowTakesMouseEvents(scope: .widgetsOnly, pointerIsOverLiveArea: false))
        #expect(OverlayPointerGate.windowTakesMouseEvents(scope: .widgetsOnly, pointerIsOverLiveArea: true))
        #expect(!OverlayPointerGate.windowTakesMouseEvents(scope: .none, pointerIsOverLiveArea: true))
        #expect(OverlayPointerGate.windowTakesMouseEvents(scope: .wholeBoard, pointerIsOverLiveArea: false))
    }

    @Test("The overlay window is click-through unless it is made interactive")
    @MainActor
    func windowStartsClickThrough() {
        let window = OverlayWindow(screenFrame: NSRect(x: 0, y: 0, width: 400, height: 300), level: .desktop)
        #expect(window.ignoresMouseEvents, "a fresh overlay must not eat desktop clicks")
        window.setInteractive(true)
        #expect(!window.ignoresMouseEvents)
        window.setInteractive(false)
        #expect(window.ignoresMouseEvents)
    }

    @Test("Reframing a parked overlay keeps it off every display")
    @MainActor
    func applyFrameKeepsParkedOverlayOffDisplays() {
        let window = OverlayWindow(screenFrame: NSRect(x: 0, y: 0, width: 400, height: 300), level: .desktop)
        TestHostWindowParking.park(window)
        let target = NSRect(x: 100, y: 50, width: 800, height: 600)

        window.applyFrame(target)
        #expect(NSScreen.screens.allSatisfy { !$0.frame.intersects(window.frame) })
        #expect(TestHostWindowParking.logicalFrame(window) == target)
    }

}
