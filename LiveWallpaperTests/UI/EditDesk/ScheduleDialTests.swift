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
            #expect(ScheduleDialGeometry.hour(at: point, center: center) == hour)
        }
        #expect(ScheduleDialGeometry.midpoint(ScheduleSlot(startHour: 22, endHour: 6, label: "Night")) == 2)
        #expect(ScheduleDialGeometry.midpoint(ScheduleSlot(startHour: 0, endHour: 24, label: "Day")) == 12)
        let beforeBoundary = ScheduleDialGeometry.point(hour: 5.75, radius: 100, center: center)
        #expect(Int(ScheduleDialGeometry.fractionalHour(at: beforeBoundary, center: center)) == 5)
        #expect(ScheduleDialGeometry.hour(at: beforeBoundary, center: center) == 6)
        #expect(ScheduleDialGeometry.span(ScheduleSlot(startHour: 8, endHour: 8, label: "Empty")) == 0)
    }

    @Test("An edge drag keeps at least one hour and never crosses the other edge or flips across midnight")
    func edgeDragClamp() {
        func drag(_ start: Int, _ end: Int, movingEnd: Bool, to minute: Int) -> [Int] {
            let minutes = ScheduleDialGeometry.draggedMinutes(ScheduleSlot(startMinute: start, endMinute: end, label: "Slot"), movingEnd: movingEnd, to: minute)
            return [minutes.start, minutes.end]
        }
        #expect(drag(360, 720, movingEnd: true, to: 360) == [360, 420], "the end landed on the start")
        #expect(drag(600, 1080, movingEnd: true, to: 540) == [600, 660], "the end crossed the start into a 23-hour wrap")
        #expect(drag(600, 1080, movingEnd: true, to: 0) == [600, 1440])
        #expect(drag(600, 1080, movingEnd: true, to: 120) == [600, 1440], "a drag just past midnight snapped back to the start")
        #expect(drag(600, 1080, movingEnd: true, to: 840) == [600, 840])
        #expect(drag(600, 1080, movingEnd: false, to: 1080) == [1020, 1080])
        #expect(drag(600, 1080, movingEnd: false, to: 1200) == [1020, 1080])
        #expect(drag(600, 1080, movingEnd: false, to: 1380) == [0, 1080])
        #expect(drag(1320, 360, movingEnd: true, to: 1380) == [1320, 1440], "a wrapping slot's end crossed its start")
        #expect(drag(1320, 360, movingEnd: true, to: 180) == [1320, 180])
        #expect(drag(1320, 360, movingEnd: false, to: 300) == [420, 360], "a wrapping slot's start crossed its end")
        #expect(drag(1320, 360, movingEnd: false, to: 0) == [1380, 360], "a wrapping slot's start flipped across midnight")
        #expect(drag(1080, 0, movingEnd: false, to: 1200) == [1200, 1440])
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
