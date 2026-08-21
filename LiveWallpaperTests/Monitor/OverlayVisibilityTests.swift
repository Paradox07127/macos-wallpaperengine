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

    /// A window made hit-testable purely for Now Playing's transport controls
    /// must not swallow desktop clicks in the board's empty space. The two
    /// halves of that contract live in different files, so pin both.
    @Test("a widget claiming the pointer never makes empty board space opaque")
    func widgetPointerDoesNotSwallowDesktopClicks() throws {
        let controller = try RepositoryRoot.source(
            "LiveWallpaper/Monitor/Overlay/OverlayController.swift"
        )
        // The window's ignoresMouseEvents flag is display-wide, so the narrowing
        // has to be the same scope the board view filters hits with — one
        // resolver, never two independent conditions that can drift apart.
        let interactive = try sourceBlock(controller, from: "private func updateInteractive(")
        #expect(interactive.contains("HostView.pointerScope(for: host.config"))
        #expect(interactive.contains("host.window.setInteractive(scope != .none)"))
        #expect(interactive.contains("host.board.setPointerScope(scope)"))

        // AppKit dispatches by window frame and SwiftUI cannot hand an event
        // back to the window below, so the widget-only case must be filtered in
        // hitTest — behaviour pinned in BoardPointerScopeTests.
        let host = try RepositoryRoot.source("LiveWallpaper/Monitor/Board/HostView.swift")
        let hitTest = try sourceBlock(host, from: "override func hitTest(")
        #expect(hitTest.contains("acceptsPointer(atLocalPoint:"))
        #expect(hitTest.contains("return nil"))

        let root = try RepositoryRoot.source("LiveWallpaper/Monitor/Board/RootView.swift")
        // The empty-space tap target keys off the board-wide opt-in, never off
        // the window's interactive flag.
        #expect(root.contains(".allowsHitTesting(model.isEditing || model.acceptsBoardWidePointer)"))

        let model = try RepositoryRoot.source("LiveWallpaper/Monitor/Board/InteractionModel.swift")
        #expect(model.contains("var acceptsBoardWidePointer: Bool { baseConfiguration.mouseInteractionEnabled }"))
    }

    @Test("controller filters options and snapshots through visible hosts")
    func controllerDeliveryContracts() throws {
        let controller = try RepositoryRoot.source(
            "LiveWallpaper/Monitor/Overlay/OverlayController.swift"
        )
        let hostState = try sourceSlice(
            controller,
            from: "private final class Host {",
            to: "private var hosts:"
        )
        let hostCreation = try sourceSlice(
            controller,
            from: "let board = HostView(",
            to: "private func merging("
        )
        let merge = try sourceBlock(
            controller,
            from: "private func merging("
        )
        let visibilityUpdate = try sourceSlice(
            controller,
            from: "func updateVisibility(",
            to: "#if DEBUG"
        )
        let visibilityReconcile = try sourceSlice(
            controller,
            from: "private func reconcileVisibilityAndRuntime()",
            to: "private func makeOptions("
        )
        let options = try sourceSlice(
            controller,
            from: "private func makeOptions(",
            to: "private func scheduleRuntimeReconciliation()"
        )
        let delivery = try sourceSlice(
            controller,
            from: "private func applyDeliveryState()",
            to: "private func startPump()"
        )
        let pump = try sourceSlice(
            controller,
            from: "private func startPump()",
            to: "private func stopPump()"
        )
        let prime = try sourceSlice(
            controller,
            from: "private func primeHost(_ host: Host)",
            to: "private func pushLatest()"
        )
        let push = try sourceBlock(
            controller,
            from: "private func pushLatest()"
        )

        #expect(hostState.contains("var level: MonitorOverlayLevel"))
        #expect(hostState.contains("var isVisible = false"))
        #expect(hostState.contains("var isDeliveringSnapshots = false"))

        #expect(hostCreation.contains("board.setSuspended(true)"))
        #expect(hostCreation.contains("reconcileVisibilityAndRuntime()"))
        // A module host only knows its own widgets, so the edit it reports must
        // be folded back into the retained full board before it is persisted.
        #expect(hostCreation.contains("onOverlayEdited?(screenID, merging(edited, from: key))"))
        #expect(merge.contains("full.widgets.filter { !key.module.owns($0.kind) }"))
        #expect(merge.contains("boards[key.screenID] = merged"))
        #expect(visibilityUpdate.contains("guard self.isUserAbsent != isUserAbsent"))
        #expect(visibilityUpdate.contains("self.occludedScreenIDs != occludedScreenIDs"))
        #expect(visibilityReconcile.contains("MonitorOverlayVisibilityPolicy.resolve"))
        #expect(visibilityReconcile.contains("host.board.setSuspended(true)"))
        #expect(visibilityReconcile.contains("stopPump()"))

        #expect(
            options.contains(
                "for (key, host) in hosts where visibleHostKeys.contains(key)"
            )
        )
        #expect(delivery.contains("host.board.setSuspended(false)"))
        #expect(delivery.contains("newlyVisibleHosts.append(host)"))
        #expect(delivery.contains("primeHost(host)"))
        #expect(pump.contains("guard pumpTask == nil"))
        #expect(pump.contains("isDeliveringSnapshots"))

        #expect(prime.contains("guard host.isVisible, host.isDeliveringSnapshots"))
        #expect(push.contains("where host.isVisible && host.isDeliveringSnapshots"))
        #expect(push.contains("host.board.push(update.snapshot)"))
    }

    @Test("one serialized task owns acquire update pause and release ordering")
    func controllerRuntimeOrderingContracts() throws {
        let controller = try RepositoryRoot.source(
            "LiveWallpaper/Monitor/Overlay/OverlayController.swift"
        )
        let scheduling = try sourceSlice(
            controller,
            from: "private func scheduleRuntimeReconciliation()",
            to: "private func desiredRuntimeState()"
        )
        let applyRuntime = try sourceSlice(
            controller,
            from: "private func applyRuntimeState(",
            to: "private func applyDeliveryState()"
        )

        #expect(scheduling.contains("runtimeReconciliationRevision &+= 1"))
        #expect(scheduling.contains("guard runtimeReconciliationTask == nil"))
        #expect(scheduling.contains("await runRuntimeReconciliationLoop()"))
        #expect(scheduling.contains("guard revision == runtimeReconciliationRevision else"))
        #expect(scheduling.contains("applyDeliveryState()"))

        #expect(applyRuntime.contains("guard let lease = appliedRuntimeState.lease else"))
        #expect(applyRuntime.contains("await lease.release().value"))
        #expect(
            applyRuntime.contains(
                "guard let lease = appliedRuntimeState.lease,"
            )
        )
        #expect(applyRuntime.contains("await lease.setPaused(true).value"))
        #expect(applyRuntime.contains("let lease = runtimeLeaseSlot.acquire(options: options)"))
        #expect(applyRuntime.contains("await lease.waitUntilSettled()"))
        #expect(
            occursBefore(
                "await lease.updateOptions(options).value",
                "await lease.setPaused(false).value",
                in: applyRuntime
            )
        )

        #expect(!controller.contains("Task { await Runtime.shared"))
    }

    @Test("ScreenManager bridges absence and 85-percent union occlusion")
    func screenManagerSignalBridgeContracts() throws {
        let detector = try RepositoryRoot.source(
            "Packages/LiveWallpaperCore/Sources/LiveWallpaperCore/Power/FullScreenDetector.swift"
        )
        let monitor = try RepositoryRoot.source(
            "LiveWallpaper/App/ScreenManager+Monitor.swift"
        )
        let observers = try RepositoryRoot.source(
            "LiveWallpaper/App/ScreenManager+Observers.swift"
        )
        let automation = try RepositoryRoot.source(
            "LiveWallpaper/Runtime/Coordinators/WallpaperAutomationOrchestrator.swift"
        )
        let screens = try RepositoryRoot.source(
            "LiveWallpaper/App/ScreenManager+Screens.swift"
        )
        let window = try RepositoryRoot.source(
            "LiveWallpaper/Monitor/Overlay/OverlayWindow.swift"
        )

        let overlayReconcile = try sourceSlice(
            monitor,
            from: "func reconcileMonitorOverlays()",
            to: "func refreshMonitorOverlayVisibility()"
        )
        let visibilityBridge = try sourceSlice(
            monitor,
            from: "func refreshMonitorOverlayVisibility()",
            to: "private func scheduleMonitorOverlayReconcile()"
        )
        let desktopOverlayOwner = try sourceBlock(
            monitor,
            from: "var hasEnabledDesktopMonitorOverlay: Bool"
        )
        let overlayEnable = try sourceBlock(
            monitor,
            from: "func setMonitorOverlayEnabled("
        )
        let overlayLevel = try sourceBlock(
            monitor,
            from: "func setMonitorOverlayLevel("
        )
        let musicEnable = try sourceBlock(
            monitor,
            from: "func setMusicOverlayEnabled("
        )
        let musicLevel = try sourceBlock(
            monitor,
            from: "func setMusicOverlayLevel("
        )
        // Both setters route through the sole writer, which owns the reconcile.
        let overlayWriter = try sourceBlock(
            monitor,
            from: "private func mutateMonitorOverlays("
        )
        // The side effects moved into the shared applier so revalidation can
        // clear a reason from inside a policy refresh without recursing.
        let absence = try sourceBlock(
            observers,
            from: "private func applyUserAbsenceChange("
        )
        // Internal, not private: the absence safety-net tests drive this real
        // entry point rather than reconstructing its steps.
        let absenceEntryPoint = try sourceBlock(
            observers,
            from: "func setUserAbsence("
        )
        let fallbackPolling = try sourceBlock(
            observers,
            from: "func updateFullScreenFallbackPolling()"
        )
        let fullScreen = try sourceSlice(
            observers,
            from: "private func handleFullScreenChange(",
            to: "private func handlePowerStateChange("
        )
        let updateFrames = try sourceBlock(
            observers,
            from: "func updateAllWindowFrames()"
        )
        let wake = try sourceBlock(
            observers,
            from: "private func handleSystemWake()"
        )
        let refreshScreens = try sourceBlock(
            screens,
            from: "func refreshScreens("
        )
        let detectorOcclusion = try sourceSlice(
            detector,
            from: "for (screenID, fraction) in coverage",
            to: "updateIfChanged(fullScreen, occlusion, fractions)"
        )
        let detectorNotifications = try sourceSlice(
            detector,
            from: "private func setupNotifications()",
            to: "public var isFallbackPollingEnabled"
        )
        let windowInitialization = try sourceSlice(
            window,
            from: "init(screenFrame:",
            to: "func apply(level:"
        )

        #expect(overlayReconcile.contains("refreshMonitorOverlayVisibility()"))
        #expect(overlayReconcile.contains("fullScreenDetector.checkNow()"))
        #expect(overlayReconcile.contains("updateFullScreenFallbackPolling()"))
        #expect(visibilityBridge.contains("fullScreenDetector.isDesktopOccluded"))
        #expect(visibilityBridge.contains("isUserAbsent: isUserAbsent"))
        #expect(visibilityBridge.contains("OverlayController.shared.updateVisibility"))
        #expect(desktopOverlayOwner.contains("overlay.enabled && overlay.level == .desktop"))
        // The fallback poll feeds occlusion to desktop-level hosts of EITHER
        // module; missing music here would freeze it behind a full-screen window.
        #expect(desktopOverlayOwner.contains("overlay.musicEnabled && overlay.musicLevel == .desktop"))
        #expect(overlayEnable.contains("mutateMonitorOverlays("))
        #expect(overlayLevel.contains("mutateMonitorOverlays("))
        #expect(musicEnable.contains("$0.musicEnabled = enabled"))
        #expect(musicLevel.contains("$0.musicLevel = level"))
        #expect(overlayWriter.contains("scheduleMonitorOverlayReconcile()"))
        #expect(overlayWriter.contains("SettingsManager.shared.saveMonitorOverlays("))
        #expect(absenceEntryPoint.contains("applyUserAbsenceChange(reason, present: present)"))
        #expect(absenceEntryPoint.contains("refreshPerformancePolicyForAllScreens()"))
        #expect(absence.contains("refreshMonitorOverlayVisibility()"))
        #expect(absence.contains("automationOrchestrator.suspendForUserAbsence()"))
        #expect(absence.contains("automationOrchestrator.resumeAfterUserAbsence()"))
        #expect(automation.contains("isSuspendedForUserAbsence = true"))
        #expect(automation.contains("automationCoordinator.stop()"))
        #expect(automation.contains("startCoordinator(runInitialScheduleCheck: true)"))
        #expect(fullScreen.contains("refreshMonitorOverlayVisibility()"))
        #expect(fallbackPolling.contains("wallpaperPolicyNeedsPolling || hasEnabledDesktopMonitorOverlay"))
        #expect(updateFrames.contains("reconcileMonitorOverlays()"))
        #expect(refreshScreens.contains("updateAllWindowFrames()"))
        #expect(wake.contains("refreshScreens()"))
        #expect(occursBefore("refreshScreens()", "setUserAbsence(.systemSleep, present: false)", in: wake))

        #expect(detector.contains(".excludeDesktopElements"))
        #expect(detector.contains("Self.shouldExcludeWindowOwner(ownerName)"))
        #expect(detectorOcclusion.contains("occlusion[screenID] = fraction >= 0.85"))
        #expect(
            detectorNotifications.contains(
                "publisher(for: NSWorkspace.activeSpaceDidChangeNotification)"
            )
        )

        #expect(windowInitialization.contains(".canJoinAllSpaces"))
        #expect(windowInitialization.contains(".stationary"))
        #expect(windowInitialization.contains(".fullScreenAuxiliary"))

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
    @Test("music hosts its own window while the Monitor board stays off")
    func musicModuleRunsWithTheMonitorBoardOff() async {
        let runtime = makeRuntime()
        let controller = OverlayController(runtime: runtime)
        controller.apply(
            overlay: MonitorOverlayConfiguration(
                enabled: false,
                level: .desktop,
                musicEnabled: true,
                musicLevel: .front,
                board: MonitorBoardConfiguration(widgets: [Self.cpuWidget, Self.musicWidget])
            ),
            screenID: 401,
            screenFrame: NSRect(x: 0, y: 0, width: 800, height: 600)
        )
        await controller.waitUntilRuntimeSettled()

        #expect(controller.activeHostKeys == [key(401, .music)])
        #expect(controller.board(screenID: 401, module: .music)?.widgets.map(\.kind) == [.nowPlaying])
        #expect(controller.board(screenID: 401, module: .monitor) == nil)

        controller.teardownAll()
        await controller.waitUntilRuntimeSettled()
        await runtime.shutdown()
    }

    @MainActor
    @Test("an edit on one module's host never deletes the other module's widgets")
    func moduleEditPreservesTheOtherModulesWidgets() async throws {
        let runtime = makeRuntime()
        let controller = OverlayController(runtime: runtime)
        var reported: MonitorBoardConfiguration?
        controller.onOverlayEdited = { _, board in reported = board }

        controller.apply(
            overlay: MonitorOverlayConfiguration(
                enabled: true,
                level: .desktop,
                musicEnabled: true,
                musicLevel: .front,
                board: MonitorBoardConfiguration(widgets: [Self.cpuWidget, Self.musicWidget])
            ),
            screenID: 402,
            screenFrame: NSRect(x: 0, y: 0, width: 800, height: 600)
        )
        await controller.waitUntilRuntimeSettled()

        // Drag the music layer on its own host, which only ever saw that widget.
        var musicEdit = try #require(controller.board(screenID: 402, module: .music))
        musicEdit.widgets[0].x = 0.25
        let reportMusicEdit = try #require(controller.boardEditCallback(screenID: 402, module: .music))
        reportMusicEdit(musicEdit)

        let afterMusicEdit = try #require(reported)
        #expect(afterMusicEdit.widgets.count == 2)
        #expect(afterMusicEdit.widgets.contains { $0.id == Self.cpuWidget.id })
        #expect(afterMusicEdit.widgets.first { $0.kind == .nowPlaying }?.x == 0.25)

        // And the same in the other direction.
        var monitorEdit = try #require(controller.board(screenID: 402, module: .monitor))
        monitorEdit.widgets[0].y = 0.75
        let reportMonitorEdit = try #require(
            controller.boardEditCallback(screenID: 402, module: .monitor)
        )
        reportMonitorEdit(monitorEdit)

        let afterMonitorEdit = try #require(reported)
        #expect(afterMonitorEdit.widgets.count == 2)
        #expect(afterMonitorEdit.widgets.first { $0.kind == .cpu }?.y == 0.75)
        // The music widget keeps the position the earlier edit gave it.
        #expect(afterMonitorEdit.widgets.first { $0.kind == .nowPlaying }?.x == 0.25)

        controller.teardownAll()
        await controller.waitUntilRuntimeSettled()
        await runtime.shutdown()
    }

    @MainActor
    @Test("an edit keeps widgets of a module that has no host at all")
    func moduleEditPreservesWidgetsOfADisabledModule() async throws {
        let runtime = makeRuntime()
        let controller = OverlayController(runtime: runtime)
        var reported: MonitorBoardConfiguration?
        controller.onOverlayEdited = { _, board in reported = board }

        controller.apply(
            overlay: MonitorOverlayConfiguration(
                enabled: false,
                level: .desktop,
                musicEnabled: true,
                musicLevel: .front,
                board: MonitorBoardConfiguration(widgets: [Self.cpuWidget, Self.musicWidget])
            ),
            screenID: 403,
            screenFrame: NSRect(x: 0, y: 0, width: 800, height: 600)
        )
        await controller.waitUntilRuntimeSettled()

        var musicEdit = try #require(controller.board(screenID: 403, module: .music))
        musicEdit.widgets[0].x = 0.4
        let reportEdit = try #require(controller.boardEditCallback(screenID: 403, module: .music))
        reportEdit(musicEdit)

        let merged = try #require(reported)
        #expect(merged.widgets.map(\.kind) == [.nowPlaying, .cpu])
        #expect(merged.widgets.contains { $0.id == Self.cpuWidget.id })

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
        #expect(legacy.musicEnabled == false)

        let runtime = makeRuntime()
        let controller = OverlayController(runtime: runtime)
        var overlay = legacy
        overlay.board = MonitorBoardConfiguration(widgets: [Self.cpuWidget, Self.musicWidget])
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
    private static let musicWidget = MonitorWidgetPlacement(
        kind: .nowPlaying, size: .medium, x: 0, y: 0.5
    )

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

    private func sourceSlice(
        _ source: String,
        from startNeedle: String,
        to endNeedle: String
    ) throws -> String {
        guard let start = source.range(of: startNeedle),
              let end = source.range(
                  of: endNeedle,
                  range: start.upperBound ..< source.endIndex
              ) else {
            throw OverlayVisibilityFixtureError.missingSourceBoundary
        }
        return String(source[start.lowerBound ..< end.lowerBound])
    }

    private func sourceBlock(_ source: String, from startNeedle: String) throws -> String {
        guard let start = source.range(of: startNeedle),
              let openingBrace = source[start.lowerBound...].firstIndex(of: "{") else {
            throw OverlayVisibilityFixtureError.missingSourceBoundary
        }

        var depth = 0
        var index = openingBrace
        while index < source.endIndex {
            switch source[index] {
            case "{":
                depth += 1
            case "}":
                depth -= 1
                if depth == 0 {
                    return String(source[start.lowerBound ... index])
                }
            default:
                break
            }
            index = source.index(after: index)
        }
        throw OverlayVisibilityFixtureError.missingSourceBoundary
    }

    /// The series restarts only when the *sampled* set grows. Now Playing is
    /// pushed by notification and reads nothing out of the history, so turning
    /// the Music layer on must not cost every Monitor tile its sparkline.
    @Test("history resets on a new sampled kind, never on Now Playing")
    func historyResetIgnoresNonSamplingKinds() {
        #expect(!OverlayController.historyResetRequired(previous: [.cpu], next: [.cpu, .nowPlaying]))
        #expect(!OverlayController.historyResetRequired(previous: [], next: [.nowPlaying]))
        // A real sampled arrival still resets, alone or alongside Now Playing.
        #expect(OverlayController.historyResetRequired(previous: [.cpu], next: [.cpu, .gpu]))
        #expect(
            OverlayController.historyResetRequired(previous: [.cpu], next: [.cpu, .gpu, .nowPlaying])
        )
        // Losing a kind is not a gain.
        #expect(!OverlayController.historyResetRequired(previous: [.cpu, .gpu], next: [.cpu]))
        #expect(!OverlayController.historyResetRequired(previous: [.cpu], next: [.cpu]))
    }

    private func occursBefore(_ first: String, _ second: String, in source: String) -> Bool {
        guard let firstRange = source.range(of: first),
              let secondRange = source.range(of: second) else {
            return false
        }
        return firstRange.lowerBound < secondRange.lowerBound
    }
}

private enum OverlayVisibilityFixtureError: Error {
    case missingSourceBoundary
}
