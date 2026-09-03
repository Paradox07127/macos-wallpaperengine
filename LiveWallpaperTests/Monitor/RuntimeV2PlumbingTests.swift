import Testing
import Foundation
import LiveWallpaperCore
@testable import LiveWallpaper

@Suite("Monitor runtime v2 plumbing")
struct RuntimeV2PlumbingTests {

    @Test("GPU cadence divides by the board's real sample interval")
    func gpuCadenceFollowsTheBaseInterval() {
        // The default board: 1s base, GPU asked for every 6s. Dividing by the
        // old fixed 2s tick gave 3, i.e. twice the GPU reads the user asked for.
        #expect(Runtime.gpuCadence(forSeconds: 6, baseInterval: 1) == 6)
        // Fastest board: 0.5s base was 4x over-sampling.
        #expect(Runtime.gpuCadence(forSeconds: 6, baseInterval: 0.5) == 12)
        // Slowest board: never below one sample per tick.
        #expect(Runtime.gpuCadence(forSeconds: 6, baseInterval: 5) == 2)
        #expect(Runtime.gpuCadence(forSeconds: 2, baseInterval: 5) == 1)
    }

    @Test("GPU cadence rounds up so it never samples faster than requested")
    func gpuCadenceRoundsUp() {
        // 6s over a 4s tick is 1.5 — rounding to nearest would sample every 4s.
        #expect(Runtime.gpuCadence(forSeconds: 6, baseInterval: 4) == 2)
        #expect(Runtime.gpuCadence(forSeconds: nil, baseInterval: 1) == nil)
        #expect(Runtime.gpuCadence(forSeconds: 6, baseInterval: 0) == nil)
    }

    @Test("Each widget kind flips exactly its sampler gate")
    func kindMapsToItsGate() {
        #expect(Runtime.systemOptions(for: [.gpu]) == options(gpu: true, sensors: true))
        #expect(Runtime.systemOptions(for: [.cpu]) == options(topProcesses: true, sensors: true, cpu: true))
        #expect(Runtime.systemOptions(for: [.processes]) == options(topProcesses: true))
        #expect(Runtime.systemOptions(for: [.memory]) == options(topProcesses: true, memory: true))
        #expect(Runtime.systemOptions(for: [.disk]) == options(processIO: true, disk: true))
        #expect(Runtime.systemOptions(for: [.aiEngine]) == options(ane: true))
        #expect(Runtime.systemOptions(for: [.power]) == options(accessories: true, sensors: true, power: true))
    }

    // MARK: - Per-widget demand narrowing

    private func widget(
        _ kind: MonitorWidgetKind,
        _ options: [String: MonitorWidgetOptionValue] = [:],
        size: MonitorWidgetSize = .large
    ) -> MonitorWidgetPlacement {
        MonitorWidgetPlacement(kind: kind, size: size, options: options)
    }

    @Test("Turning a section off stops its sampler, not just its drawing")
    func toggledOffSectionNarrowsTheSampler() {
        let gpuNoSensors = MonitorSampleDemand.of([widget(.gpu, ["showSensors": .bool(false)])])
        #expect(Runtime.narrowed(Runtime.systemOptions(for: [.gpu]), to: gpuNoSensors).sensors == false)

        let memNoProcs = MonitorSampleDemand.of([widget(.memory, ["showTopProcesses": .bool(false)])])
        #expect(Runtime.narrowed(Runtime.systemOptions(for: [.memory]), to: memNoProcs).topProcesses == false)

        let diskNoProcs = MonitorSampleDemand.of([widget(.disk, ["showTopProcesses": .bool(false)])])
        #expect(Runtime.narrowed(Runtime.systemOptions(for: [.disk]), to: diskNoProcs).processIO == false)
    }

    @Test("An absent option key counts as showing, so nothing is narrowed away")
    func defaultOnKeepsSamplersLive() {
        let demand = MonitorSampleDemand.of([widget(.gpu), widget(.memory), widget(.disk)])
        let kinds: Set<MonitorWidgetKind> = [.gpu, .memory, .disk]
        #expect(Runtime.narrowed(Runtime.systemOptions(for: kinds), to: demand)
                == Runtime.systemOptions(for: kinds))
    }

    @Test("CPU's untoggleable process column keeps the walk alive")
    func cpuAlwaysDemandsTopProcesses() {
        // CPU has no "show top processes" switch, so no combination may drop it.
        let demand = MonitorSampleDemand.of([widget(.cpu, ["showSensors": .bool(false)])])
        #expect(demand.topProcesses == true)
        #expect(demand.sensors == false)
        let narrowed = Runtime.narrowed(Runtime.systemOptions(for: [.cpu]), to: demand)
        #expect(narrowed.topProcesses == true)
        #expect(narrowed.sensors == false)
    }

    @Test("One widget still wanting a sampler keeps it on for the whole board")
    func demandUnionsAcrossWidgets() {
        let demand = MonitorSampleDemand.of([
            widget(.gpu, ["showSensors": .bool(false)]),
            widget(.gpu, ["showSensors": .bool(true)]),
        ])
        #expect(demand.sensors == true)
    }

    /// The tap and its FFT are the most expensive thing a Now Playing layer can
    /// ask for, and turning the effects off used to leave both running. The
    /// layer is not a widget, so the demand rides the runtime options.
    @Test("The audio tap follows the Now Playing layer's reactive switch")
    func musicOptionsCarryTheAudioDemand() {
        var reactive = NowPlayingOptions()
        reactive.audioReactive = true
        var off = NowPlayingOptions()
        off.audioReactive = false

        #expect(NowPlayingOptions(reactive.applied(to: [:])).audioReactive)
        #expect(!NowPlayingOptions(off.applied(to: [:])).audioReactive)
        // Absent key means on, so an untouched layer still gets its effects.
        #expect(NowPlayingOptions([:]).audioReactive)

        // The factory is the consumer: no music, no source; music without the
        // effects, no tap.
        #expect(SourceRegistration.nowPlayingFactory(MonitorRuntimeOptions()).isEmpty)
        #expect(!SourceRegistration.nowPlayingFactory(
            MonitorRuntimeOptions(music: true, musicAudioReactive: false)
        ).isEmpty)
    }

    @Test("Power has no options popover, so its sensor row is never narrowed away at the sizes that draw it")
    func powerAlwaysDemandsSensors() {
        #expect(MonitorSampleDemand.of([widget(.power)]).sensors == true)
    }

    @Test("Demand only asks for what the placement's rendered size actually draws")
    func demandRespectsPlacementSize() {
        // CPUWidgetView only reads topCPUProcesses inside largeBody.
        #expect(MonitorSampleDemand.of([widget(.cpu, size: .small)]).topProcesses == false)
        // MemoryWidgetView only reads showsTopProcesses inside large(cellHeight:).
        #expect(MonitorSampleDemand.of([widget(.memory, size: .medium)]).topProcesses == false)
        // DiskWidgetView only reads topIOProcesses inside large(cellHeight:).
        #expect(MonitorSampleDemand.of([widget(.disk, size: .medium)]).processIO == false)
        // PowerWidgetView's smallBody never references socTempC.
        #expect(MonitorSampleDemand.of([widget(.power, size: .small)]).sensors == false)

        // Control group: `.large` still demands everything, as before.
        #expect(MonitorSampleDemand.of([widget(.cpu, size: .large)]).topProcesses == true)
        #expect(MonitorSampleDemand.of([widget(.memory, size: .large)]).topProcesses == true)
        #expect(MonitorSampleDemand.of([widget(.disk, size: .large)]).processIO == true)
        #expect(MonitorSampleDemand.of([widget(.power, size: .medium)]).sensors == true)
    }

    @Test("A nil demand leaves the kind baseline untouched")
    func nilDemandFailsOpen() {
        let kinds = Set(MonitorWidgetKind.allCases)
        #expect(Runtime.narrowed(Runtime.systemOptions(for: kinds), to: nil)
                == Runtime.systemOptions(for: kinds))
    }

    @Test("A kind with no expensive sampler flips only its own base group")
    func inertKindKeepsAllGatesOff() {
        #expect(Runtime.systemOptions(for: [.network]) == options(network: true))
    }

    @Test("Empty kind set gates every expensive sampler off")
    func emptyKindsGateAllOff() {
        let opts = Runtime.systemOptions(for: [])
        #expect(opts.gpu == false)
        #expect(opts.topProcesses == false)
        #expect(opts.ane == false)
        #expect(opts.accessories == false)
        #expect(opts.sensors == false)
    }

    @Test("Multiple placed kinds union into their combined gates")
    func multipleKindsUnionGates() {
        let opts = Runtime.systemOptions(for: [.gpu, .power, .cpu])
        #expect(opts.gpu == true)
        #expect(opts.accessories == true)
        #expect(opts.topProcesses == true)
        #expect(opts.ane == false)
        #expect(opts.sensors == true)
    }

    @Test("Every kind placed turns every gate on")
    func allKindsAllGates() {
        let opts = Runtime.systemOptions(for: Set(MonitorWidgetKind.allCases))
        #expect(opts == SystemMetricsSource.Options(
            gpu: true, topProcesses: true, ane: true, accessories: true, sensors: true,
            processIO: true, cpu: true, memory: true, network: true, disk: true, power: true
        ))
    }

    @Test("The Disk widget demands the per-app I/O walk; others leave it off")
    func diskKindFlipsProcessIO() {
        #expect(Runtime.systemOptions(for: [.disk]).processIO == true)
        #expect(Runtime.systemOptions(for: [.cpu, .processes]).processIO == false)
    }

    @Test("activeWidgetKinds unions across leases")
    func kindsUnionAcrossLeases() {
        var a = MonitorRuntimeOptions(system: true)
        a.activeWidgetKinds = [.gpu, .cpu]
        var b = MonitorRuntimeOptions(system: true)
        b.activeWidgetKinds = [.power, .cpu]

        let merged = Runtime.merged([a, b])
        #expect(merged?.activeWidgetKinds == [.gpu, .cpu, .power])
        #expect(Runtime.systemOptions(for: merged?.activeWidgetKinds ?? []) == options(
            gpu: true, topProcesses: true, accessories: true, sensors: true,
            cpu: true, power: true
        ))
    }

    @Test("A single lease with kinds carries its set through the union unchanged")
    func singleLeaseKindsPreserved() {
        var lease = MonitorRuntimeOptions(system: true)
        lease.activeWidgetKinds = [.aiEngine]
        #expect(Runtime.merged([lease])?.activeWidgetKinds == [.aiEngine])
    }

    @Test("A lease that omits kinds doesn't erase another lease's set")
    func absentKindsDoesNotClearUnion() {
        var withKinds = MonitorRuntimeOptions(system: true)
        withKinds.activeWidgetKinds = [.gpu]
        let plain = MonitorRuntimeOptions(system: true)

        #expect(Runtime.merged([withKinds, plain])?.activeWidgetKinds == [.gpu])
        #expect(Runtime.merged([plain, withKinds])?.activeWidgetKinds == [.gpu])
    }

    @Test("v1 leases (no activeWidgetKinds) leave the union set nil")
    func v1LeasesLeaveUnionNil() {
        let systemOnly = MonitorRuntimeOptions(system: true, topProcesses: true)
        let quiet = MonitorRuntimeOptions(system: false)
        #expect(Runtime.merged([systemOnly, quiet])?.activeWidgetKinds == nil)
    }

    private func options(
        gpu: Bool = false, topProcesses: Bool = false, ane: Bool = false,
        accessories: Bool = false, sensors: Bool = false, processIO: Bool = false,
        cpu: Bool = false, memory: Bool = false, network: Bool = false,
        disk: Bool = false, power: Bool = false
    ) -> SystemMetricsSource.Options {
        SystemMetricsSource.Options(
            gpu: gpu, topProcesses: topProcesses, ane: ane, accessories: accessories,
            sensors: sensors, processIO: processIO,
            cpu: cpu, memory: memory, network: network, disk: disk, power: power
        )
    }
}
