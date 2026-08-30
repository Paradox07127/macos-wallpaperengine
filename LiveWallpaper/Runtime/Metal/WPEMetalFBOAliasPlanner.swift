#if !LITE_BUILD
import Foundation

/// Computes a memory-aliasing layout for render-target (FBO) textures: assigns each
/// an OFFSET in a shared heap so non-overlapping-lifetime targets can share memory
/// while concurrently-alive ones never overlap — turning "sum of every FBO" into
/// "≈ peak concurrent". `WPEMetalRenderTargetPool.prepareAliasPlan` consumes only
/// `Plan.heapSize`; the heap is `.automatic` so Metal suballocates, and the offsets
/// here just prove that size is enough.
///
/// Algorithm: a classic time-ordered offset allocator — intervals placed in start
/// order (largest first on ties), each given the lowest offset free for its whole
/// lifetime. Greedy first-fit: near-optimal for these cascade-shaped lifetimes,
/// always correct.
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

    /// `alignment` rounds each offset up so placed textures meet the heap's
    /// allocation alignment (the GPU step passes the device's real value;
    /// tests/estimates can pass 1).
    static func plan(_ intervals: [Interval], alignment: Int = 1) -> Plan {
        let align = max(alignment, 1)
        let ordered = intervals.sorted {
            $0.firstPass != $1.firstPass ? $0.firstPass < $1.firstPass : $0.size > $1.size
        }

        var placements: [Placement] = []
        placements.reserveCapacity(ordered.count)
        var heapSize = 0

        for interval in ordered {
            // Ranges occupied by intervals alive at the same time as this one.
            let conflicts = placements
                .filter { placed in
                    guard let placedInterval = ordered.first(where: { $0.id == placed.id }) else { return false }
                    return placedInterval.firstPass <= interval.lastPass
                        && interval.firstPass <= placedInterval.lastPass
                }
                .map { (start: $0.offset, end: $0.offset + $0.size) }
                .sorted { $0.start < $1.start }

            // Lowest aligned offset whose [offset, offset+size) clears every
            // conflicting range.
            var offset = 0
            for range in conflicts {
                if offset + interval.size <= range.start {
                    break // fits in the gap before this conflict
                }
                offset = max(offset, roundUp(range.end, to: align))
            }

            placements.append(Placement(id: interval.id, offset: offset, size: interval.size))
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
