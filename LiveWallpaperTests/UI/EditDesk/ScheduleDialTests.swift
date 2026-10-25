import AppKit
@testable import LiveWallpaper
import LiveWallpaperCore
import Testing

@Suite("Schedule dial") @MainActor
struct ScheduleDialTests {
    @Test("All 24 hours round-trip through the dial; midnight and wrapping slot midpoints are stable")
    func geometry() {
        let center = CGPoint(x: 200, y: 200)
        for hour in 0 ..< 24 {
            let point = ScheduleDialGeometry.point(hour: Double(hour), radius: 100, center: center)
            #expect(ScheduleDialGeometry.minute(at: point, center: center) == hour * 60)
        }
        #expect(ScheduleDialGeometry.midpoint(ScheduleSlot(startHour: 22, endHour: 6, label: "Night")) == 2)
        #expect(ScheduleDialGeometry.midpoint(ScheduleSlot(startHour: 0, endHour: 24, label: "Day")) == 12)
        let beforeBoundary = ScheduleDialGeometry.point(hour: 5.8, radius: 100, center: center)
        #expect(Int(ScheduleDialGeometry.fractionalHour(at: beforeBoundary, center: center)) == 5)
        #expect(ScheduleDialGeometry.minute(at: beforeBoundary, center: center) == 360)
        #expect(ScheduleDialGeometry.span(ScheduleSlot(startHour: 8, endHour: 8, label: "Empty")) == 0)
    }

    @Test("A pointer angle snaps to the nearest half hour, wrapping 23:50 to midnight")
    func pointerSnapsToHalfHour() {
        let center = CGPoint(x: 200, y: 200)
        func minute(_ hour: Int, _ minute: Int) -> Int {
            let point = ScheduleDialGeometry.point(hour: Double(hour) + Double(minute) / 60, radius: 100, center: center)
            return ScheduleDialGeometry.minute(at: point, center: center)
        }
        #expect(minute(7, 14) == 420)
        #expect(minute(7, 16) == 450, "07:16 snapped to the hour instead of the half hour")
        #expect(minute(23, 50) == 0)
    }

    private func drag(_ start: Int, _ end: Int, movingEnd: Bool, to minute: Int, among others: [ScheduleSlot] = []) -> [Int] {
        let slot = ScheduleSlot(startMinute: start, endMinute: end, label: "Slot")
        let minutes = ScheduleDialGeometry.draggedMinutes(slot, movingEnd: movingEnd, pointer: nil, to: minute, among: [slot] + others)
        return [minutes.start, minutes.end]
    }

    @Test("Either edge can be dragged across midnight to make or undo an overnight slot")
    func edgeDragCrossesMidnight() {
        #expect(drag(1080, 1320, movingEnd: true, to: 120) == [1080, 120], "the end could not pass midnight")
        #expect(drag(60, 360, movingEnd: false, to: 1380) == [1380, 360], "the start could not pass midnight")
        #expect(drag(1320, 120, movingEnd: true, to: 1380) == [1320, 1380], "dragging back did not undo the overnight slot")
        #expect(drag(1080, 1320, movingEnd: true, to: 0) == [1080, 1440])
    }

    @Test("An edge drag keeps at least 30 minutes, choosing the shorter slot on a tie")
    func edgeDragKeepsHalfHour() {
        #expect(drag(420, 540, movingEnd: true, to: 420) == [420, 450], "the end landed on the start")
        #expect(drag(420, 540, movingEnd: false, to: 540) == [510, 540], "the start landed on the end")
    }

    @Test("An edge drag stops at the neighbouring slot's edge, including across midnight")
    func edgeDragStopsAtNeighbour() {
        let morning = ScheduleSlot(startMinute: 360, endMinute: 720, label: "Morning")
        let afternoon = ScheduleSlot(startMinute: 780, endMinute: 1080, label: "Afternoon")
        #expect(drag(360, 720, movingEnd: true, to: 900, among: [afternoon]) == [360, 780], "the end ran into the next slot")
        #expect(drag(780, 1080, movingEnd: false, to: 600, among: [morning]) == [720, 1080], "the start ran into the previous slot")
        let night = ScheduleSlot(startMinute: 120, endMinute: 360, label: "Night")
        #expect(drag(1200, 1380, movingEnd: true, to: 180, among: [night]) == [1200, 120], "the end ran past midnight into the next slot")
    }

    @Test("A clamped edge stays put while the pointer keeps going, and follows again once it comes back")
    func clampedEdgeDoesNotJump() {
        let slot = ScheduleSlot(startMinute: 600, endMinute: 1080, label: "Slot")
        var pointer: Int?
        var edges: [Int] = []
        for minute in [840, 600, 570, 540, 900] {
            let moved = ScheduleDialGeometry.draggedMinutes(slot, movingEnd: true, pointer: pointer, to: minute, among: [slot])
            pointer = moved.pointer
            edges.append(contentsOf: [moved.start, moved.end])
        }
        #expect(edges[4 ..< 8] == [600, 630, 600, 630], "the end jumped across its own start into a 23-hour slot")
        #expect(edges[8 ..< 10] == [600, 900])
    }

    @Test("Dragging an edge of a 30-minute slot at either end of the day stays in range")
    func halfHourSlotDrag() {
        #expect(drag(0, 30, movingEnd: false, to: 600) == [0, 30], "the start passed its own end")
        #expect(drag(1410, 1440, movingEnd: true, to: 0) == [1410, 1440])
    }

    @Test("Callout lanes never overlap or clip, including clustered sections and compact overflow selection")
    func calloutPacking() {
        for size in [CGSize(width: 650, height: 460), CGSize(width: 420, height: 360)] {
            let radius = Double(size.width) * (size.width < 560 ? 0.20 : 0.225)
            let width = min(148, Double(size.width) * 0.225)
            for slots in [ScheduleSlot.defaultSlots, (0 ..< 24).map { ScheduleSlot(startHour: $0, endHour: $0 + 1, label: "Slot") },
                          (0 ..< 12).map { ScheduleSlot(startHour: $0, endHour: $0 + 1, label: "Cluster") }, [],
                          [ScheduleSlot(startHour: 0, endHour: 24, label: "Day")]] {
                let selected = slots.last?.id
                let callouts = ScheduleDialGeometry.callouts(slots: slots, selectedID: selected, size: size, radius: radius, cardWidth: width)
                if let selected {
                    #expect(callouts.contains { $0.id == selected })
                }
                for callout in callouts {
                    #expect(callout.frame.minY >= 19.9)
                    #expect(callout.frame.maxY <= size.height - 19.9)
                    #expect(callout.frame.minX >= 0 && callout.frame.maxX <= size.width)
                    #expect(callout.frame.height >= 28)
                }
                for left in [false, true] {
                    let lane = callouts.filter { $0.left == left }.sorted { $0.frame.minY < $1.frame.minY }
                    for (first, second) in zip(lane, lane.dropFirst()) {
                        #expect(second.frame.minY - first.frame.maxY >= 5.9)
                    }
                }
                #expect(Set(callouts.map(\.id)).count == callouts.count)
            }
        }
    }
}
