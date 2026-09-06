import XCTest
@testable import LiveWallpaper
import LiveWallpaperCore

final class CPUWidgetTests: XCTestCase {
    func testCompositionPercentsMirrorMock() {
        let (u, s, idle) = CPUWidgetView.compositionPercents(user: 0.26, system: 0.11)
        XCTAssertEqual(u, 26)
        XCTAssertEqual(s, 11)
        XCTAssertEqual(idle, 63)
        XCTAssertEqual(u + s + idle, 100)
    }

    func testCompositionPercentsNeverNegativeIdle() {
        let (_, _, idle) = CPUWidgetView.compositionPercents(user: 0.7, system: 0.6)
        XCTAssertEqual(idle, 0)
    }

    func testIdentityLineComposesDynamicGroups() {
        let info = MonitorCPUInfo(
            deviceName: "Apple M5 Pro",
            coreCount: 18,
            coreGroups: [
                MonitorCPUCoreGroup(name: "Super", physicalCount: 6),
                MonitorCPUCoreGroup(name: "Performance", physicalCount: 12)
            ]
        )
        let identity = CPUWidgetView.identityLine(info)
        XCTAssertEqual(identity?.deviceName, "Apple M5 Pro")
        XCTAssertEqual(identity?.coreSummary, "18 cores (6 Super + 12 Performance)")
    }

    func testIdentityLineUsesRealGroupNamesNotHardcodedPE() {
        let info = MonitorCPUInfo(
            deviceName: "Apple M1",
            coreCount: 8,
            coreGroups: [
                MonitorCPUCoreGroup(name: "Performance", physicalCount: 4),
                MonitorCPUCoreGroup(name: "Efficiency", physicalCount: 4)
            ]
        )
        let identity = CPUWidgetView.identityLine(info)
        XCTAssertEqual(identity?.coreSummary, "8 cores (4 Performance + 4 Efficiency)")
    }

    func testIdentityLineNilWhenInfoAbsent() {
        XCTAssertNil(CPUWidgetView.identityLine(nil))
    }

    func testIdentityLineDeviceOnlyWhenNoGroups() {
        let info = MonitorCPUInfo(deviceName: "Apple M2", coreCount: nil, coreGroups: nil)
        let identity = CPUWidgetView.identityLine(info)
        XCTAssertEqual(identity?.deviceName, "Apple M2")
        XCTAssertNil(identity?.coreSummary)
    }

    func testCoreGroupLoadsSlicesByPhysicalCount() {
        let perCore = (0..<18).map { Double($0) / 18.0 }
        let info = MonitorCPUInfo(
            deviceName: nil,
            coreCount: 18,
            coreGroups: [
                MonitorCPUCoreGroup(name: "Super", physicalCount: 6),
                MonitorCPUCoreGroup(name: "Performance", physicalCount: 12)
            ]
        )
        let groups = CPUWidgetView.coreGroupLoads(perCore: perCore, cpuInfo: info)
        XCTAssertEqual(groups?.count, 2)
        XCTAssertEqual(groups?[0].name, "Super")
        XCTAssertEqual(groups?[0].loads.count, 6)
        XCTAssertEqual(groups?[1].name, "Performance")
        XCTAssertEqual(groups?[1].loads.count, 12)
        XCTAssertEqual(groups?[0].loads.last, 5.0 / 18.0)
        XCTAssertEqual(groups?[1].loads.first, 6.0 / 18.0)
    }

    func testCoreGroupLoadsNilWhenNoPerCore() {
        let info = MonitorCPUInfo(deviceName: nil, coreCount: 8, coreGroups: nil)
        XCTAssertNil(CPUWidgetView.coreGroupLoads(perCore: nil, cpuInfo: info))
        XCTAssertNil(CPUWidgetView.coreGroupLoads(perCore: [], cpuInfo: info))
    }

    func testCoreGroupLoadsFallsBackToSingleGroupWithoutTopology() {
        let perCore = [0.1, 0.2, 0.3, 0.4]
        let groups = CPUWidgetView.coreGroupLoads(perCore: perCore, cpuInfo: nil)
        XCTAssertEqual(groups?.count, 1)
        XCTAssertEqual(groups?[0].name, "CPU")
        XCTAssertEqual(groups?[0].loads, perCore)
    }

    func testCoreGroupLoadsHandlesTopologyDrift() {
        let perCore = [0.1, 0.2, 0.3, 0.4, 0.5]
        let info = MonitorCPUInfo(
            deviceName: nil, coreCount: 4,
            coreGroups: [MonitorCPUCoreGroup(name: "Super", physicalCount: 4)]
        )
        let groups = CPUWidgetView.coreGroupLoads(perCore: perCore, cpuInfo: info)
        XCTAssertEqual(groups?.count, 2)
        XCTAssertEqual(groups?[0].loads.count, 4)
        XCTAssertEqual(groups?[1].name, "CPU")
        XCTAssertEqual(groups?[1].loads, [0.5])
    }

    func testWholePercentRoundsAndClamps() {
        XCTAssertEqual(CPUWidgetView.wholePercent(0.374), "37%")
        XCTAssertEqual(CPUWidgetView.wholePercent(1.4), "100%")
        XCTAssertEqual(CPUWidgetView.wholePercent(-0.2), "0%")
    }

    func testWholeNumberRoundsAndClampsWithoutPercentSign() {
        XCTAssertEqual(CPUWidgetView.wholeNumber(0.374), "37")
        XCTAssertEqual(CPUWidgetView.wholeNumber(1.4), "100")
        XCTAssertEqual(CPUWidgetView.wholeNumber(-0.2), "0")
        XCTAssertFalse(CPUWidgetView.wholeNumber(0.5).contains("%"))
    }

    func testRPMValueRoundsAndClamps() {
        XCTAssertEqual(CPUWidgetView.rpmValue(1_454.4), "1454")
        XCTAssertEqual(CPUWidgetView.rpmValue(1_454.6), "1455")
        XCTAssertEqual(CPUWidgetView.rpmValue(-10), "0")
    }

    func testCpuTextRoundsAndClamps() {
        XCTAssertEqual(CPUWidgetView.cpuText(52.4), "52")
        XCTAssertEqual(CPUWidgetView.cpuText(0.44), "0.4")
        XCTAssertEqual(CPUWidgetView.cpuText(3.24), "3.2")
        XCTAssertEqual(CPUWidgetView.cpuText(9.96), "10.0")
        XCTAssertEqual(CPUWidgetView.cpuText(-3), "0.0")
    }

    func testBarFractionRelativeToBusiest() {
        XCTAssertEqual(CPUWidgetView.barFraction(26, maxCPU: 52), 0.5, accuracy: 1e-9)
        XCTAssertEqual(CPUWidgetView.barFraction(80, maxCPU: 52), 1)
        XCTAssertEqual(CPUWidgetView.barFraction(10, maxCPU: 0), 1)
    }

    func testLoadTextSingleUsesLoadAverage1() {
        var sys = MonitorSystemSnapshot()
        sys.loadAverage1 = 3.42
        XCTAssertEqual(CPUWidgetView.loadText(system: sys, triple: false), "3.42")
    }

    func testLoadTextTripleJoinsFirstThree() {
        var sys = MonitorSystemSnapshot()
        sys.cpuLoadAvg = [3.42, 2.88, 2.41]
        XCTAssertEqual(CPUWidgetView.loadText(system: sys, triple: true), "3.42 · 2.88 · 2.41")
    }

    func testLoadTextTripleFallsBackToSingleWhenNoTriple() {
        var sys = MonitorSystemSnapshot()
        sys.loadAverage1 = 1.5
        XCTAssertEqual(CPUWidgetView.loadText(system: sys, triple: true), "1.50")
    }

    func testLoadTextNilWhenNothingReported() {
        XCTAssertNil(CPUWidgetView.loadText(system: MonitorSystemSnapshot(), triple: false))
        XCTAssertNil(CPUWidgetView.loadText(system: nil, triple: true))
    }

    func testTopCPUProcessesSortsDescendingStableAndCaps() {
        let procs = [
            MonitorProcessSample(name: "A", cpuPercent: 12, memBytes: 0),
            MonitorProcessSample(name: "B", cpuPercent: 52, memBytes: 0),
            MonitorProcessSample(name: "C", cpuPercent: 23, memBytes: 0),
            MonitorProcessSample(name: "D", cpuPercent: 23, memBytes: 0)
        ]
        let top = CPUWidgetView.topCPUProcesses(procs, limit: 3)
        XCTAssertEqual(top?.map(\.name), ["B", "C", "D"])
    }

    func testTopCPUProcessesNilWhenNoData() {
        XCTAssertNil(CPUWidgetView.topCPUProcesses(nil, limit: 4))
        XCTAssertNil(CPUWidgetView.topCPUProcesses([], limit: 4))
    }

    func testHistoryWindowDefaultsPerSize() {
        XCTAssertEqual(MonitorCPUDraft.historyWindow(place(.small)), 30)
        XCTAssertEqual(MonitorCPUDraft.historyWindow(place(.medium)), 60)
        XCTAssertEqual(MonitorCPUDraft.historyWindow(place(.large)), 120)
    }

    func testHistoryWindowExplicitOverrideAndInvalidFallback() {
        let set = MonitorCPUDraft.settingHistoryWindow(120, on: place(.medium))
        XCTAssertEqual(MonitorCPUDraft.historyWindow(set), 120)
        var bogus = place(.medium)
        bogus.options[MonitorCPUDraft.historyWindowKey] = .number(45)
        XCTAssertEqual(MonitorCPUDraft.historyWindow(bogus), 60)
    }

    func testShowTogglesDefaultTrueAndRoundTrip() {
        XCTAssertTrue(MonitorCPUDraft.showHeatmap(place(.medium)))
        XCTAssertTrue(MonitorCPUDraft.showComposition(place(.medium)))
        XCTAssertTrue(MonitorCPUDraft.showSensors(place(.medium)))

        // The settings popover writes these keys through its generic
        // `settingBool(_:key:default:on:)`, so assert the getters against a
        // stored option rather than a typed setter of their own.
        var p = place(.medium)
        p.options[MonitorCPUDraft.showHeatmapKey] = .bool(false)
        p.options[MonitorCPUDraft.showCompositionKey] = .bool(false)
        p.options[MonitorCPUDraft.showSensorsKey] = .bool(false)
        XCTAssertFalse(MonitorCPUDraft.showHeatmap(p))
        XCTAssertFalse(MonitorCPUDraft.showComposition(p))
        XCTAssertFalse(MonitorCPUDraft.showSensors(p))
    }

    private func place(_ size: MonitorWidgetSize) -> MonitorWidgetPlacement {
        MonitorWidgetPlacement(kind: .cpu, size: size)
    }

    // MARK: - Core heat strip geometry (many-core machines)

    /// Width one cell gets in a row of `cellsPerRow` equal-flexible cells laid
    /// out by `HStack(spacing: gap)` — SwiftUI's own rule, restated here so the
    /// numbers below are arithmetic rather than a screenshot.
    private func cellWidth(cellsPerRow: Int, columnWidth: CGFloat, gap: CGFloat) -> CGFloat {
        (columnWidth - gap * CGFloat(cellsPerRow - 1)) / CGFloat(cellsPerRow)
    }

    /// M tile: 356 pt wide − 32 pt content inset = 324; − 104 pt gauge column
    /// − 7 pt row spacing = 213 for the right column; − 9 pt cluster spacing,
    /// halved between two clusters.
    private let compactClusterColumn: CGFloat = 102

    /// L tile: 324 pt of content − 9 pt spacing, halved with the process column.
    private let tallClusterColumn: CGFloat = 157.5

    /// `HeatCell` draws a 1 pt `strokeBorder`, which insets from both edges, so a
    /// cell narrower than this has more border than fill.
    private let legibleCellWidth: CGFloat = 6

    func testCoreStripRowsReproducesTheShippedMediumRuleUpToSixteenCores() {
        for count in 1 ... 16 {
            let shipped = count > 8 ? 2 : 1
            XCTAssertEqual(
                CPUWidgetView.coreStripRows(coreCount: count, cap: CPUWidgetView.compactCoreCellsPerRow),
                shipped,
                "M strip re-lays out a \(count)-core cluster that used to render correctly"
            )
        }
    }

    func testCoreStripRowsKeepsTwelveCoreClustersOnOneRowInLarge() {
        for count in 1 ... 12 {
            XCTAssertEqual(
                CPUWidgetView.coreStripRows(coreCount: count, cap: CPUWidgetView.tallCoreCellsPerRow),
                1,
                "L strip wraps a \(count)-core cluster that used to fit on one row"
            )
        }
    }

    func testCoreStripCellsPerRowBalancesTheRowsItSplitsInto() {
        XCTAssertEqual(CPUWidgetView.coreStripCellsPerRow(coreCount: 18, rows: 3), 6)
        XCTAssertEqual(CPUWidgetView.coreStripCellsPerRow(coreCount: 24, rows: 2), 12)
        XCTAssertEqual(CPUWidgetView.coreStripCellsPerRow(coreCount: 20, rows: 3), 7)
        XCTAssertEqual(CPUWidgetView.coreStripCellsPerRow(coreCount: 12, rows: 1), 12)
    }

    /// A 36-core Mac Studio, split the way Apple silicon splits: the big cluster
    /// is what used to be squeezed. Control group first — the single row the L
    /// strip drew before is measurably below the legibility floor, so the floor
    /// is discriminating rather than trivially satisfied.
    func testThirtySixCoreClusterStaysLegibleInTheLargeTile() {
        let biggestCluster = 24
        let beforeWrapping = cellWidth(cellsPerRow: biggestCluster, columnWidth: tallClusterColumn,
                                       gap: CPUWidgetView.tallCoreCellGap)
        XCTAssertLessThan(beforeWrapping, legibleCellWidth, "Control group: the un-wrapped row was not actually too narrow")

        let cap = CPUWidgetView.tallCoreCellsPerRow
        for clusterSize in [12, 24, 36] {
            let rows = CPUWidgetView.coreStripRows(coreCount: clusterSize, cap: cap)
            let perRow = CPUWidgetView.coreStripCellsPerRow(coreCount: clusterSize, rows: rows)
            let width = cellWidth(cellsPerRow: perRow, columnWidth: tallClusterColumn,
                                  gap: CPUWidgetView.tallCoreCellGap)
            XCTAssertGreaterThanOrEqual(width, legibleCellWidth,
                                        "L strip draws \(clusterSize) cores at \(width) pt per cell")
        }
    }

    /// The M strip already wrapped, so 36 cores were never squeezed there; this
    /// records that, and that the wrap now applied makes them wider still.
    func testThirtySixCoreClusterWasAlreadyLegibleInTheMediumTile() {
        let biggestCluster = 24
        let beforeCap = cellWidth(cellsPerRow: 12, columnWidth: compactClusterColumn,
                                  gap: CPUWidgetView.compactCoreCellGap) // old rule: 2 rows of 12
        XCTAssertGreaterThanOrEqual(beforeCap, legibleCellWidth)

        let rows = CPUWidgetView.coreStripRows(coreCount: biggestCluster, cap: CPUWidgetView.compactCoreCellsPerRow)
        let perRow = CPUWidgetView.coreStripCellsPerRow(coreCount: biggestCluster, rows: rows)
        let afterCap = cellWidth(cellsPerRow: perRow, columnWidth: compactClusterColumn,
                                 gap: CPUWidgetView.compactCoreCellGap)
        XCTAssertGreaterThan(afterCap, beforeCap)
    }

    func testCoreStripBandHeightHoldsThroughTwoRowsThenGrowsPerRow() {
        let base: CGFloat = 13.75 // max(scale.caption * 1.25, 13) at M's caption of 11
        let gap = CPUWidgetView.compactCoreCellGap
        XCTAssertEqual(CPUWidgetView.coreStripBandHeight(base: base, rows: 1, gap: gap), base, accuracy: 0.0001)
        XCTAssertEqual(CPUWidgetView.coreStripBandHeight(base: base, rows: 2, gap: gap), base, accuracy: 0.0001)
        XCTAssertEqual(CPUWidgetView.coreStripBandHeight(base: base, rows: 3, gap: gap), 21.625, accuracy: 0.0001)
        XCTAssertEqual(CPUWidgetView.coreStripBandHeight(base: base, rows: 4, gap: gap), 29.5, accuracy: 0.0001)

        // Every row is the height a two-row band already gave its cells, so a
        // third row lengthens the strip instead of halving the cells again.
        let threeRow = CPUWidgetView.coreStripBandHeight(base: base, rows: 3, gap: gap)
        XCTAssertEqual((threeRow - gap * 2) / 3, (base - gap) / 2, accuracy: 0.0001)
    }

    func testCoreStripGeometryAbsorbsDegenerateInput() {
        XCTAssertEqual(CPUWidgetView.coreStripRows(coreCount: 0, cap: 8), 1)
        XCTAssertEqual(CPUWidgetView.coreStripRows(coreCount: -4, cap: 8), 1)
        XCTAssertEqual(CPUWidgetView.coreStripRows(coreCount: 8, cap: 0), 1)
        XCTAssertEqual(CPUWidgetView.coreStripCellsPerRow(coreCount: 0, rows: 0), 1)
        XCTAssertEqual(CPUWidgetView.coreStripBandHeight(base: 13.75, rows: 0, gap: 2), 13.75, accuracy: 0.0001)
    }

    /// The 36-core case end to end: the strip's own grouping still slices the
    /// per-core array by cluster, and each cluster wraps to a legible row.
    func testThirtySixCoreTopologySlicesAndWrapsPerCluster() {
        let perCore = (0 ..< 36).map { Double($0) / 36 }
        let info = MonitorCPUInfo(
            deviceName: "Apple M5 Ultra",
            coreCount: 36,
            coreGroups: [
                MonitorCPUCoreGroup(name: "Efficiency", physicalCount: 12),
                MonitorCPUCoreGroup(name: "Performance", physicalCount: 24),
            ]
        )
        let groups = CPUWidgetView.coreGroupLoads(perCore: perCore, cpuInfo: info)
        XCTAssertEqual(groups?.map(\.loads.count), [12, 24])
        XCTAssertEqual(CPUWidgetView.coreCountText(groups ?? []), "36")

        let rows = (groups ?? []).map {
            CPUWidgetView.coreStripRows(coreCount: $0.loads.count, cap: CPUWidgetView.tallCoreCellsPerRow)
        }
        XCTAssertEqual(rows, [1, 2])
    }
}
