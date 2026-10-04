#if !LITE_BUILD
import Foundation

/// Time-ordered offset allocator: intervals in start order (largest first on ties), each given the lowest offset free for its whole lifetime. Greedy first-fit.
enum WPEMetalFBOAliasPlanner {
    /// A render target's memory request + its inclusive within-frame lifetime
    /// `[firstPass, lastPass]` (pass indices in the flattened render order).
    struct Interval: Equatable {
        let id: Int
        let size: Int
        let firstPass: Int
        let lastPass: Int
    }

    struct Placement: Equatable {
        let id: Int
        let offset: Int
        let size: Int
    }

    struct Plan: Equatable {
        let placements: [Placement]
        let heapSize: Int
    }

    /// `alignment` rounds each offset up so placed textures meet the heap's allocation alignment (the GPU step passes the device's real value; tests/estimates can pass 1).
    static func plan(_ intervals: [Interval], alignment: Int = 1) -> Plan {
        let align = max(alignment, 1)
        let ordered = intervals.sorted {
            $0.firstPass != $1.firstPass ? $0.firstPass < $1.firstPass : $0.size > $1.size
        }
        // Production IDs are unique, but preserve the original first-match lifetime
        // for duplicate IDs rather than silently changing the planner's input semantics.
        let firstIntervalByID = Dictionary(ordered.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })

        var placements: [Placement] = []
        placements.reserveCapacity(ordered.count)
        var active: [(placement: Placement, lifetime: Interval)] = []
        var heapSize = 0

        for interval in ordered {
            // Inclusive lifetimes: a target ending at this pass still conflicts. Starts
            // are nondecreasing, so expired placements can never conflict again.
            active.removeAll { $0.lifetime.lastPass < interval.firstPass }

            var offset = 0
            for entry in active {
                // Retain this half of the original overlap test even for reversed
                // intervals or duplicate IDs resolved to their first lifetime.
                guard entry.lifetime.firstPass <= interval.lastPass else { continue }
                if offset + interval.size <= entry.placement.offset {
                    break
                }
                offset = max(offset, roundUp(entry.placement.offset + entry.placement.size, to: align))
            }

            let placement = Placement(id: interval.id, offset: offset, size: interval.size)
            placements.append(placement)
            // Equal offsets keep insertion order, matching the original stable sort.
            let insertionIndex = active.firstIndex { $0.placement.offset > offset } ?? active.endIndex
            active.insert((placement, firstIntervalByID[interval.id, default: interval]), at: insertionIndex)
            heapSize = max(heapSize, offset + interval.size)
        }

        return Plan(
            placements: placements.sorted { $0.id < $1.id },
            heapSize: heapSize
        )
    }

    private static func roundUp(_ value: Int, to alignment: Int) -> Int {
        guard alignment > 1 else { return value }
        let remainder = value % alignment
        return remainder == 0 ? value : value + (alignment - remainder)
    }
}
#endif
