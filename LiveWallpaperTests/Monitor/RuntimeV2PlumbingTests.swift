import Testing
import Foundation
import LiveWallpaperCore
@testable import LiveWallpaper

@Suite("Monitor runtime v2 plumbing")
struct RuntimeV2PlumbingTests {

    @Test("Each widget kind flips exactly its sampler gate")
    func kindMapsToItsGate() {
        #expect(MonitorRuntime.systemOptions(for: [.gpu]) == options(gpu: true, sensors: true))
        #expect(MonitorRuntime.systemOptions(for: [.cpu]) == options(topProcesses: true, sensors: true))
        #expect(MonitorRuntime.systemOptions(for: [.processes]) == options(topProcesses: true))
        #expect(MonitorRuntime.systemOptions(for: [.memory]) == options(topProcesses: true))
        #expect(MonitorRuntime.systemOptions(for: [.disk]) == options(processIO: true))
        #expect(MonitorRuntime.systemOptions(for: [.aiEngine]) == options(ane: true))
        #expect(MonitorRuntime.systemOptions(for: [.power]) == options(accessories: true, sensors: true))
    }

    @Test("A kind with no expensive sampler leaves every gate off")
    func inertKindKeepsAllGatesOff() {
        #expect(MonitorRuntime.systemOptions(for: [.network]) == SystemMetricsSource.Options(
            gpu: false, topProcesses: false, ane: false, accessories: false
        ))
    }

    @Test("Empty kind set gates every expensive sampler off")
    func emptyKindsGateAllOff() {
        let opts = MonitorRuntime.systemOptions(for: [])
        #expect(opts.gpu == false)
        #expect(opts.topProcesses == false)
        #expect(opts.ane == false)
        #expect(opts.accessories == false)
        #expect(opts.sensors == false)
    }

    @Test("Multiple placed kinds union into their combined gates")
    func multipleKindsUnionGates() {
        let opts = MonitorRuntime.systemOptions(for: [.gpu, .power, .cpu])
        #expect(opts.gpu == true)
        #expect(opts.accessories == true)
        #expect(opts.topProcesses == true)
        #expect(opts.ane == false)
        #expect(opts.sensors == true)
    }

    @Test("Every kind placed turns every gate on")
    func allKindsAllGates() {
        let opts = MonitorRuntime.systemOptions(for: Set(MonitorWidgetKind.allCases))
        #expect(opts == SystemMetricsSource.Options(
            gpu: true, topProcesses: true, ane: true, accessories: true, sensors: true,
            processIO: true
        ))
    }

    @Test("The Disk widget demands the per-app I/O walk; others leave it off")
    func diskKindFlipsProcessIO() {
        #expect(MonitorRuntime.systemOptions(for: [.disk]).processIO == true)
        #expect(MonitorRuntime.systemOptions(for: [.cpu, .processes]).processIO == false)
    }

    @Test("activeWidgetKinds unions across leases")
    func kindsUnionAcrossLeases() {
        var a = MonitorRuntimeOptions(system: true)
        a.activeWidgetKinds = [.gpu, .cpu]
        var b = MonitorRuntimeOptions(system: true)
        b.activeWidgetKinds = [.power, .cpu]

        let merged = MonitorRuntime.merged([a, b])
        #expect(merged?.activeWidgetKinds == [.gpu, .cpu, .power])
        #expect(MonitorRuntime.systemOptions(for: merged?.activeWidgetKinds ?? []) == SystemMetricsSource.Options(
            gpu: true, topProcesses: true, ane: false, accessories: true, sensors: true
        ))
    }

    @Test("A single lease with kinds carries its set through the union unchanged")
    func singleLeaseKindsPreserved() {
        var lease = MonitorRuntimeOptions(system: true)
        lease.activeWidgetKinds = [.aiEngine]
        #expect(MonitorRuntime.merged([lease])?.activeWidgetKinds == [.aiEngine])
    }

    @Test("A lease that omits kinds doesn't erase another lease's set")
    func absentKindsDoesNotClearUnion() {
        var withKinds = MonitorRuntimeOptions(system: true)
        withKinds.activeWidgetKinds = [.gpu]
        let plain = MonitorRuntimeOptions(system: true)

        #expect(MonitorRuntime.merged([withKinds, plain])?.activeWidgetKinds == [.gpu])
        #expect(MonitorRuntime.merged([plain, withKinds])?.activeWidgetKinds == [.gpu])
    }

    @Test("v1 leases (no activeWidgetKinds) leave the union set nil")
    func v1LeasesLeaveUnionNil() {
        let systemOnly = MonitorRuntimeOptions(system: true, topProcesses: true)
        let quiet = MonitorRuntimeOptions(system: false)
        #expect(MonitorRuntime.merged([systemOnly, quiet])?.activeWidgetKinds == nil)
    }

    private func options(
        gpu: Bool = false, topProcesses: Bool = false, ane: Bool = false,
        accessories: Bool = false, sensors: Bool = false, processIO: Bool = false
    ) -> SystemMetricsSource.Options {
        SystemMetricsSource.Options(
            gpu: gpu, topProcesses: topProcesses, ane: ane, accessories: accessories,
            sensors: sensors, processIO: processIO
        )
    }
}
