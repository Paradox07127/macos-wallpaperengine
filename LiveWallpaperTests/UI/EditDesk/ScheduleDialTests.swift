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
        func drag(_ start: Int, _ end: Int, movingEnd: Bool, to hour: Int) -> [Int] {
            let hours = ScheduleDialGeometry.draggedHours(ScheduleSlot(startHour: start, endHour: end, label: "Slot"), movingEnd: movingEnd, to: hour)
            return [hours.start, hours.end]
        }
        #expect(drag(6, 12, movingEnd: true, to: 6) == [6, 7], "the end landed on the start")
        #expect(drag(10, 18, movingEnd: true, to: 9) == [10, 11], "the end crossed the start into a 23-hour wrap")
        #expect(drag(10, 18, movingEnd: true, to: 0) == [10, 24])
        #expect(drag(10, 18, movingEnd: true, to: 2) == [10, 24], "a drag just past midnight snapped back to the start")
        #expect(drag(10, 18, movingEnd: true, to: 14) == [10, 14])
        #expect(drag(10, 18, movingEnd: false, to: 18) == [17, 18])
        #expect(drag(10, 18, movingEnd: false, to: 20) == [17, 18])
        #expect(drag(10, 18, movingEnd: false, to: 23) == [0, 18])
        #expect(drag(22, 6, movingEnd: true, to: 23) == [22, 24], "a wrapping slot's end crossed its start")
        #expect(drag(22, 6, movingEnd: true, to: 3) == [22, 3])
        #expect(drag(22, 6, movingEnd: false, to: 5) == [7, 6], "a wrapping slot's start crossed its end")
        #expect(drag(22, 6, movingEnd: false, to: 0) == [23, 6], "a wrapping slot's start flipped across midnight")
        #expect(drag(18, 0, movingEnd: false, to: 20) == [20, 24])
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
