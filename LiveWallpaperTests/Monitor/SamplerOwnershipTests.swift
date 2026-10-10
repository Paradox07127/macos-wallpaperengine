#if !LITE_BUILD
import AppKit
import Foundation
@testable import LiveWallpaper
import LiveWallpaperCore
import os
import Testing

@Suite("AF-14: monitor sampler ownership characterization", .serialized)
struct MonitorSamplerOwnershipCharacterizationTests {
    @Test("menu and settings references share one task and balance independently")
    func visibleReferenceLifecycle() {
        var counter = MonitoringReferenceCounter()

        #expect(counter.count == 0)
        let menuStarted = counter.start()
        #expect(menuStarted)
        #expect(counter.count == 1)
        let settingsStarted = counter.start()
        #expect(!settingsStarted)
        #expect(counter.count == 2)
        let firstStopped = counter.stop()
        #expect(!firstStopped)
        #expect(counter.count == 1)
        let lastStopped = counter.stop()
        #expect(lastStopped)
        #expect(counter.count == 0)
        let extraStopped = counter.stop()
        #expect(!extraStopped)

        let restarted = counter.start()
        #expect(restarted)
        let restartedAgain = counter.start()
        #expect(!restartedAgain)
        let didReset = counter.reset()
        #expect(didReset)
        #expect(counter.count == 0)
        let stoppedAfterReset = counter.stop()
        #expect(!stoppedAfterReset)
        let resetAfterReset = counter.reset()
        #expect(!resetAfterReset)
    }

    @Test("watcher is app-lifetime across sleep wake and rejects late termination callbacks")
    @MainActor
    func memoryPressureWatcherLifecycle() async {
        let watcher = AF14MemoryPressureWatcher()
        let manager = ScreenManager(startupOptions: ScreenManagerStartupOptions(
            restoreSavedWallpapers: false,
            startAutomation: false,
            powerMonitor: FakePowerMonitor(),
            fullScreenDetector: FakeFullScreenDetector(),
            playableVideoLoader: FakePlayableVideoLoader(),
            displayRegistry: FakeDisplayRegistry(),
            memoryPressureWatcher: watcher,
            featureCatalog: .unconfigured
        ))

        #expect(watcher.startCount == 1)
        #expect(watcher.stopCount == 0)
        #expect(!manager.isUnderMemoryPressure)

        watcher.emit(.warning)
        await settleMainActorTasks()
        #expect(manager.isUnderMemoryPressure)
        watcher.emit(.critical)
        await settleMainActorTasks()
        #expect(manager.isUnderMemoryPressure)
        watcher.emit(.normal)
        await settleMainActorTasks()
        #expect(!manager.isUnderMemoryPressure)

        NSWorkspace.shared.notificationCenter.post(
            name: NSWorkspace.screensDidSleepNotification,
            object: nil
        )
        NSWorkspace.shared.notificationCenter.post(
            name: NSWorkspace.screensDidWakeNotification,
            object: nil
        )
        NSWorkspace.shared.notificationCenter.post(
            name: NSWorkspace.willSleepNotification,
            object: nil
        )
        NSWorkspace.shared.notificationCenter.post(
            name: NSWorkspace.didWakeNotification,
            object: nil
        )
        #expect(watcher.startCount == 1)
        #expect(watcher.stopCount == 0)

        manager.tearDownForTermination()
        manager.tearDownForTermination()
        #expect(watcher.startCount == 1)
        #expect(watcher.stopCount == 1)

        watcher.emitLate(.critical)
        await settleMainActorTasks()
        #expect(!manager.isUnderMemoryPressure)
    }

    @Test("v2 unions every lease's demand into one system concern set")
    func monitorV2DemandUnion() {
        var wallpaper = MonitorRuntimeOptions(system: true)
        wallpaper.activeWidgetKinds = [.cpu, .gpu]
        wallpaper.gpuSampleSeconds = 6

        var overlay = MonitorRuntimeOptions(system: true)
        overlay.activeWidgetKinds = [.memory, .network]
        overlay.gpuSampleSeconds = 2

        var agentsOnly = MonitorRuntimeOptions(system: false)
        agentsOnly.agents = true

        let merged = Runtime.merged([wallpaper, overlay, agentsOnly])
        #expect(merged?.system == true)
        #expect(merged?.agents == true)
        #expect(merged?.activeWidgetKinds == [.cpu, .gpu, .memory, .network])
        #expect(merged?.gpuSampleSeconds == 2)

        let gates = Runtime.systemOptions(for: merged?.activeWidgetKinds ?? [])
        #expect(gates.gpu)
        #expect(gates.topProcesses)
        #expect(gates.sensors)
        #expect(!gates.ane)
        #expect(!gates.accessories)
        #expect(!gates.processIO)
    }

    @Test("empty and agent-only widget sets do not demand system metrics")
    func agentOnlyDemandGate() {
        #expect(!MonitorRuntimeOptions.requiresSystemMetrics(for: []))
        // Every agent-only kind, not `.fleet` twice: these three are the set `mixedDemandGate`
        // subtracts, so a kind that quietly starts demanding system metrics has to show up here.
        #expect(!MonitorRuntimeOptions.requiresSystemMetrics(for: [.fleet]))
        #expect(!MonitorRuntimeOptions.requiresSystemMetrics(for: [.weather]))
        #expect(!MonitorRuntimeOptions.requiresSystemMetrics(for: [.nixieClock]))
        #expect(!MonitorRuntimeOptions.requiresSystemMetrics(for: [.fleet, .weather, .nixieClock]))

        let kinds: Set<MonitorWidgetKind> = [.fleet]
        let options = MonitorRuntimeOptions(
            system: MonitorRuntimeOptions.requiresSystemMetrics(for: kinds),
            agents: kinds.contains(.fleet),
            activeWidgetKinds: kinds
        )
        #expect(!options.system)
        #expect(options.agents)
    }

    @Test("mixed system and agent widgets keep both pipelines demanded")
    func mixedDemandGate() {
        #expect(MonitorRuntimeOptions.requiresSystemMetrics(for: [.cpu, .fleet]))
        #expect(MonitorRuntimeOptions.requiresSystemMetrics(for: [.network]))

        let kinds: Set<MonitorWidgetKind> = [.cpu, .fleet]
        let options = MonitorRuntimeOptions(
            system: MonitorRuntimeOptions.requiresSystemMetrics(for: kinds),
            agents: kinds.contains(.fleet),
            activeWidgetKinds: kinds
        )
        #expect(options.system)
        #expect(options.agents)

        let nonSystemKinds: Set<MonitorWidgetKind> = [.fleet, .weather, .nixieClock]
        for kind in Set(MonitorWidgetKind.allCases).subtracting(nonSystemKinds) {
            #expect(MonitorRuntimeOptions.requiresSystemMetrics(for: [kind]))
        }
    }

    @MainActor
    private func settleMainActorTasks() async {
        for _ in 0 ..< 4 {
            await Task.yield()
        }
    }

}

private final class AF14MemoryPressureWatcher: MemoryPressureWatching {
    private struct State {
        var level = SystemMemoryPressureLevel.normal
        var startCount = 0
        var stopCount = 0
        var handler: SystemMemoryPressureChangeHandler?
        var lateHandler: SystemMemoryPressureChangeHandler?
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    var startCount: Int {
        state.withLock { $0.startCount }
    }

    var stopCount: Int {
        state.withLock { $0.stopCount }
    }

    func start(onChange: SystemMemoryPressureChangeHandler?) {
        state.withLock { state in
            state.startCount += 1
            guard state.handler == nil else { return }
            state.handler = onChange
        }
    }

    func stop() {
        state.withLock { state in
            state.stopCount += 1
            state.lateHandler = state.handler
            state.handler = nil
        }
    }

    func currentLevel() -> SystemMemoryPressureLevel {
        state.withLock { $0.level }
    }

    func emit(_ level: SystemMemoryPressureLevel) {
        let handler = state.withLock { state -> SystemMemoryPressureChangeHandler? in
            state.level = level
            return state.handler
        }
        handler?(level)
    }

    func emitLate(_ level: SystemMemoryPressureLevel) {
        state.withLock { $0.lateHandler }?(level)
    }
}

#endif
