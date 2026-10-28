import Testing
import Foundation
@testable import LiveWallpaper

struct ProcessesWidgetTests {

    private func proc(_ name: String, _ cpu: Double, _ mem: UInt64 = 0) -> MonitorProcessSample {
        MonitorProcessSample(name: name, cpuPercent: cpu, memBytes: mem)
    }

    @Test("nil / empty input yields no rows")
    func emptyInput() {
        #expect(ProcessesWidgetView.topProcesses(nil, limit: 5).isEmpty)
        #expect(ProcessesWidgetView.topProcesses([], limit: 5).isEmpty)
    }

    @Test("rows are re-sorted by cpu% descending and capped to the limit")
    func sortsAndCaps() {
        let input = [proc("a", 7), proc("b", 52), proc("c", 23), proc("d", 31), proc("e", 18), proc("f", 9)]
        let rows = ProcessesWidgetView.topProcesses(input, limit: 5)
        #expect(rows.count == 5)
        #expect(rows.map(\.cpuPercent) == [52, 31, 23, 18, 9])
        #expect(rows.first?.name == "b")
    }

    @Test("ties preserve the sampler's original order (stable)")
    func stableOnTies() {
        let input = [proc("first23", 23), proc("hi", 52), proc("second23", 23)]
        let rows = ProcessesWidgetView.topProcesses(input, limit: 5)
        #expect(rows.map(\.name) == ["hi", "first23", "second23"])
    }

    @Test("a limit larger than the list returns every row")
    func limitBeyondCount() {
        let rows = ProcessesWidgetView.topProcesses([proc("a", 5), proc("b", 9)], limit: 5)
        #expect(rows.count == 2)
    }

    @Test("cpuText: whole number ≥10, one decimal under 10, clamped at 0.0")
    func cpuTextFormat() {
        #expect(ProcessesWidgetView.cpuText(52) == "52")
        #expect(ProcessesWidgetView.cpuText(23.4) == "23")
        #expect(ProcessesWidgetView.cpuText(23.6) == "24")
        #expect(ProcessesWidgetView.cpuText(0.44) == "0.4")
        #expect(ProcessesWidgetView.cpuText(3.24) == "3.2")
        #expect(ProcessesWidgetView.cpuText(9.97) == "10")
        #expect(ProcessesWidgetView.cpuText(-3) == "0.0")
    }

    @Test("bar fraction normalizes to the busiest row, clamped 0…1")
    func barNormalizesToMax() {
        #expect(ProcessesWidgetView.barFraction(52, maxCPU: 52) == 1)
        #expect(abs(ProcessesWidgetView.barFraction(26, maxCPU: 52) - 0.5) < 1e-9)
        #expect(ProcessesWidgetView.barFraction(0, maxCPU: 0) == 0)
    }

    @Test("Process rows fill the current height and ignore a legacy count limit")
    @MainActor
    func rowCapacityAtAppleFrames() {
        var system = MonitorSystemSnapshot()
        system.topProcesses = (0 ..< 40).map { proc("process-\($0)", Double(40 - $0)) }
        @MainActor func displayed(_ height: CGFloat, large: Bool) -> [MonitorProcessSample] {
            let context = MonitorWidgetContext(
                snapshot: MonitorSnapshot(timestamp: 0, system: system), history: MonitorHistorySnapshot(),
                placement: .init(kind: .processes, size: large ? .large : .medium, options: ["count": .number(1)]),
                isEditing: false, reduceMotion: true, now: Date()
            )
            return ProcessesWidgetView(context: context).displayedProcesses(
                frameHeight: height, scaleHeight: height / (large ? 4 : 2)
            )
        }
        let medium = displayed(170, large: false)
        let large = displayed(376, large: true)
        #expect(medium.count > 5)
        #expect(large.count > 12, "A tall widget must use the rows below the old sampler/count ceiling")
        #expect(displayed(220, large: true).count < large.count)
        #expect(large.map(\.name) == system.topProcesses?.prefix(large.count).map(\.name))
    }

    @Test("degenerate height yields zero capacity (the view floors displayed rows at 1)")
    func rowCapacityDegenerate() {
        #expect(ProcessesWidgetView.rowCapacity(frameHeight: 40, scaleHeight: 85) == 0)
    }

    @Test("capacity grows monotonically with frame height")
    func rowCapacityMonotonic() {
        let short = ProcessesWidgetView.rowCapacity(frameHeight: 190, scaleHeight: 94)
        let tall = ProcessesWidgetView.rowCapacity(frameHeight: 376, scaleHeight: 94)
        #expect(short <= tall)
    }

    @Test("header keeps the CPU/MEM acronym when the column is wide enough")
    func headerFitsTextWhenWide() {
        #expect(ProcessesWidgetView.headerFitsText(columnWidth: 44, labelSize: 12))
        #expect(ProcessesWidgetView.headerFitsText(columnWidth: 34, labelSize: 9))
    }

    @Test("header falls back to an SF Symbol when the column is too narrow")
    func headerFallsBackToIconWhenNarrow() {
        #expect(!ProcessesWidgetView.headerFitsText(columnWidth: 10, labelSize: 12))
        #expect(!ProcessesWidgetView.headerFitsText(columnWidth: 15, labelSize: 12))
    }
}
