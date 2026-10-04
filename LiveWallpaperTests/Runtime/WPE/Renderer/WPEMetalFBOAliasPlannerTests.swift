import Foundation
@testable import LiveWallpaper
import Testing

struct WPEMetalFBOAliasPlannerTests {
    private typealias Planner = WPEMetalFBOAliasPlanner
    private typealias Interval = WPEMetalFBOAliasPlanner.Interval

    /// The pre-optimization algorithm is the layout oracle, including first-match
    /// duplicate IDs, inclusive overlap and stable ordering of equal offsets.
    private func originalPlan(_ intervals: [Interval], alignment: Int) -> (plan: Planner.Plan, idComparisons: Int) {
        let align = max(alignment, 1)
        let ordered = intervals.sorted {
            $0.firstPass != $1.firstPass ? $0.firstPass < $1.firstPass : $0.size > $1.size
        }
        var placements: [Planner.Placement] = []
        var heapSize = 0
        var idComparisons = 0
        func roundUp(_ value: Int) -> Int {
            let remainder = value % align
            return remainder == 0 ? value : value + (align - remainder)
        }
        for interval in ordered {
            let conflicts = placements.filter { placed in
                guard let lifetime = ordered.first(where: {
                    idComparisons += 1
                    return $0.id == placed.id
                }) else { return false }
                return lifetime.firstPass <= interval.lastPass && interval.firstPass <= lifetime.lastPass
            }.map { (start: $0.offset, end: $0.offset + $0.size) }.sorted { $0.start < $1.start }
            var offset = 0
            for range in conflicts {
                if offset + interval.size <= range.start {
                    break
                }
                offset = max(offset, roundUp(range.end))
            }
            placements.append(.init(id: interval.id, offset: offset, size: interval.size))
            heapSize = max(heapSize, offset + interval.size)
        }
        return (Planner.Plan(placements: placements.sorted { $0.id < $1.id }, heapSize: heapSize), idComparisons)
    }

    private func assertNoLiveOverlap(_ plan: Planner.Plan, _ intervals: [Interval], sourceLocation: SourceLocation = #_sourceLocation) {
        let byID = Dictionary(uniqueKeysWithValues: intervals.map { ($0.id, $0) })
        for a in plan.placements {
            for b in plan.placements where a.id < b.id {
                guard let ia = byID[a.id], let ib = byID[b.id] else { continue }
                let lifetimesOverlap = ia.firstPass <= ib.lastPass && ib.firstPass <= ia.lastPass
                guard lifetimesOverlap else { continue }
                let memoryOverlap = a.offset < b.offset + b.size && b.offset < a.offset + a.size
                #expect(!memoryOverlap, "ids \(a.id)/\(b.id) are alive together but share memory", sourceLocation: sourceLocation)
            }
        }
    }

    @Test("Non-overlapping cascade fully aliases into one slot")
    func cascadeShares() {
        let intervals = [
            Interval(id: 0, size: 100, firstPass: 0, lastPass: 1),
            Interval(id: 1, size: 100, firstPass: 2, lastPass: 3),
            Interval(id: 2, size: 100, firstPass: 4, lastPass: 5)
        ]
        let plan = Planner.plan(intervals)
        #expect(plan.heapSize == 100)
        #expect(plan.placements.allSatisfy { $0.offset == 0 })
        assertNoLiveOverlap(plan, intervals)
    }

    @Test("Fully concurrent intervals never share memory")
    func concurrentNeverShares() {
        let intervals = (0..<3).map { Interval(id: $0, size: 100, firstPass: 0, lastPass: 5) }
        let plan = Planner.plan(intervals)
        #expect(plan.heapSize == 300)
        #expect(Set(plan.placements.map(\.offset)) == [0, 100, 200])
        assertNoLiveOverlap(plan, intervals)
    }

    @Test("Mixed lifetimes: non-overlapping pair shares, overlapping one is separate")
    func mixedSharing() {
        let intervals = [
            Interval(id: 0, size: 100, firstPass: 0, lastPass: 1),
            Interval(id: 1, size: 100, firstPass: 2, lastPass: 3),
            Interval(id: 2, size: 100, firstPass: 1, lastPass: 2)
        ]
        let plan = Planner.plan(intervals)
        #expect(plan.heapSize == 200)
        let offsets = Dictionary(uniqueKeysWithValues: plan.placements.map { ($0.id, $0.offset) })
        #expect(offsets[0] == 0)
        #expect(offsets[1] == 0)
        #expect(offsets[2] == 100)
        assertNoLiveOverlap(plan, intervals)
    }

    @Test("Heap size never exceeds the sum and never undercuts the concurrent peak")
    func boundsAreSane() {
        let intervals = [
            Interval(id: 0, size: 320, firstPass: 0, lastPass: 2),
            Interval(id: 1, size: 64, firstPass: 1, lastPass: 4),
            Interval(id: 2, size: 320, firstPass: 3, lastPass: 5),
            Interval(id: 3, size: 16, firstPass: 5, lastPass: 6)
        ]
        let plan = Planner.plan(intervals)
        let sum = intervals.reduce(0) { $0 + $1.size }
        #expect(plan.heapSize >= 384)
        #expect(plan.heapSize <= sum)
        assertNoLiveOverlap(plan, intervals)
    }

    @Test("Offsets honor alignment")
    func alignmentRespected() {
        let intervals = [
            Interval(id: 0, size: 100, firstPass: 0, lastPass: 1),
            Interval(id: 1, size: 100, firstPass: 0, lastPass: 1)
        ]
        let plan = Planner.plan(intervals, alignment: 64)
        let offsets = plan.placements.map(\.offset).sorted()
        #expect(offsets == [0, 128])
        #expect(plan.placements.allSatisfy { $0.offset % 64 == 0 })
        assertNoLiveOverlap(plan, intervals)
    }

    @Test("Empty input yields an empty plan")
    func emptyInput() {
        let plan = Planner.plan([])
        #expect(plan.placements.isEmpty)
        #expect(plan.heapSize == 0)
    }

    @Test("Randomized layouts exactly match the original first-fit algorithm",
          arguments: [-17, 0, 1, 2, 3, 7, 16, 64, 256])
    func randomizedOriginalEquivalence(alignment: Int) {
        for seed in 0 ..< 96 {
            var state = UInt64(seed + 1)
            func next(_ upper: Int) -> Int {
                state = state &* 6_364_136_223_846_793_005 &+ 1
                return Int((state >> 32) % UInt64(upper))
            }
            let intervals = (0 ..< (seed % 43)).map { index -> Interval in
                let first = next(36) - 4
                return Interval(id: seed.isMultiple(of: 3) ? index : next(13) - 4,
                                size: next(257), firstPass: first, lastPass: first + next(14) - 3)
            }
            #expect(Planner.plan(intervals, alignment: alignment) == originalPlan(intervals, alignment: alignment).plan,
                    "seed=\(seed), alignment=\(alignment), intervals=\(intervals)")
        }
    }

    @Test("Inclusive endpoints, same-start ordering, empty size and duplicate first-match semantics stay exact",
          arguments: [0, 1, 3, 64])
    func semanticBoundariesMatchOriginal(alignment: Int) {
        let cases: [[Interval]] = [
            [.init(id: 0, size: 0, firstPass: 0, lastPass: 0)],
            [.init(id: 0, size: 33, firstPass: 0, lastPass: 2),
             .init(id: 1, size: 17, firstPass: 2, lastPass: 3),
             .init(id: 2, size: 33, firstPass: 3, lastPass: 4)],
            [.init(id: 8, size: 65, firstPass: 0, lastPass: 0),
             .init(id: 2, size: 65, firstPass: 0, lastPass: 8),
             .init(id: 4, size: 0, firstPass: 0, lastPass: 8),
             .init(id: 6, size: 17, firstPass: 0, lastPass: 8)],
            [.init(id: 7, size: 33, firstPass: 0, lastPass: 0),
             .init(id: 7, size: 65, firstPass: 2, lastPass: 9),
             .init(id: 1, size: 17, firstPass: 3, lastPass: 4)],
            [.init(id: 5, size: 0, firstPass: 0, lastPass: 8),
             .init(id: 5, size: 33, firstPass: 0, lastPass: 0),
             .init(id: 3, size: 17, firstPass: 1, lastPass: 2)],
            [.init(id: 3, size: 40, firstPass: -2, lastPass: 8),
             .init(id: 3, size: 19, firstPass: 0, lastPass: -1),
             .init(id: 1, size: 17, firstPass: 1, lastPass: 0),
             .init(id: 9, size: 0, firstPass: 2, lastPass: 2)],
        ]
        for intervals in cases {
            #expect(Planner.plan(intervals, alignment: alignment) == originalPlan(intervals, alignment: alignment).plan)
        }
    }

    @Test("Persona-scale layout cost is measured without a wall-clock pass threshold",
          arguments: [256, 4096])
    func personaScaleLayoutCost(alignment: Int) {
        let clock = ContinuousClock()
        // Persona has 960 authored objects, not necessarily 960 alias intervals. This
        // stresses that scale and a larger bound without claiming to replay its GPU requests.
        for count in [96, 960, 2048] {
            let concurrent = (0 ..< count).map {
                Interval(id: $0, size: ($0 % 9 + 1) * 4096, firstPass: 0, lastPass: 9)
            }
            let start = clock.now
            let plan = Planner.plan(concurrent, alignment: alignment)
            let duration = start.duration(to: clock.now)
            var cursor = 0
            let expected = concurrent.sorted { $0.size > $1.size }.map { interval in
                let placement = Planner.Placement(id: interval.id, offset: cursor, size: interval.size)
                cursor += interval.size
                let remainder = cursor % alignment
                if remainder != 0 {
                    cursor += alignment - remainder
                }
                return placement
            }
            #expect(plan.placements == expected.sorted { $0.id < $1.id })
            #expect(plan.heapSize == expected.map { $0.offset + $0.size }.max())
            if count == 96 {
                let referenceStart = clock.now
                let reference = originalPlan(concurrent, alignment: alignment)
                print("[fbo-alias-cost] n=\(count) alignment=\(alignment) optimized=\(duration) "
                    + "reference=\(referenceStart.duration(to: clock.now)) idComparisons=\(reference.idComparisons)")
                #expect(plan == reference.plan)
                #expect(reference.idComparisons > count * count)
            } else {
                print("[fbo-alias-cost] n=\(count) alignment=\(alignment) optimized=\(duration) mode=all-concurrent")
            }
            let cascade = concurrent.map {
                Interval(id: $0.id, size: $0.size, firstPass: $0.id * 2, lastPass: $0.id * 2 + 1)
            }
            let cascadeStart = clock.now
            let cascadePlan = Planner.plan(cascade, alignment: alignment)
            print("[fbo-alias-cost] n=\(count) alignment=\(alignment) "
                + "optimized=\(cascadeStart.duration(to: clock.now)) mode=cascade")
            #expect(cascadePlan.placements.allSatisfy { $0.offset == 0 })
            #expect(cascadePlan.heapSize == cascade.map(\.size).max())
        }
    }
}
