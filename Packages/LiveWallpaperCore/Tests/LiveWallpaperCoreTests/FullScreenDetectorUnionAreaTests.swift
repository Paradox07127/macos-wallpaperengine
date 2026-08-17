import CoreGraphics
import Testing
@testable import LiveWallpaperCore

@Suite("FullScreenDetector union-area sweep vs cell reference")
struct FullScreenDetectorUnionAreaTests {

    // MARK: - Reference implementation

    /// Verbatim port of the pre-sweep coordinate-compression algorithm the
    /// sweep-line replaced (cell midpoint containment), including its
    /// filter/sort/cap preamble.
    private func cellReferenceUnionArea(of rects: [CGRect], cap: Int = 80) -> CGFloat {
        let rects = rects
            .filter { $0.width > 0 && $0.height > 0 }
            .sorted { ($0.width * $0.height) > ($1.width * $1.height) }
            .prefix(cap)
        guard !rects.isEmpty else { return 0 }

        var xSet = Set<CGFloat>()
        var ySet = Set<CGFloat>()
        for r in rects {
            xSet.insert(r.minX); xSet.insert(r.maxX)
            ySet.insert(r.minY); ySet.insert(r.maxY)
        }
        let xs = xSet.sorted()
        let ys = ySet.sorted()

        var area: CGFloat = 0
        for i in 0 ..< (xs.count - 1) {
            let x0 = xs[i], x1 = xs[i + 1]
            let w = x1 - x0
            if w <= 0 { continue }
            let cx = (x0 + x1) / 2
            for j in 0 ..< (ys.count - 1) {
                let y0 = ys[j], y1 = ys[j + 1]
                let h = y1 - y0
                if h <= 0 { continue }
                let cy = (y0 + y1) / 2
                if rects.contains(where: { $0.minX <= cx && cx < $0.maxX && $0.minY <= cy && cy < $0.maxY }) {
                    area += w * h
                }
            }
        }
        return area
    }

    // MARK: - Seeded RNG

    private struct SplitMix64: RandomNumberGenerator {
        var state: UInt64
        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
    }

    /// Integer-coordinate rects like real CGWindowList bounds: negative
    /// origins (multi-display global space), overlaps, containments, and a
    /// sprinkle of degenerate zero-size rects.
    private func randomIntegerRects(count: Int, using rng: inout SplitMix64) -> [CGRect] {
        (0 ..< count).map { _ in
            let degenerate = Int.random(in: 0 ..< 10, using: &rng) == 0
            let x = CGFloat(Int.random(in: -2000 ... 4000, using: &rng))
            let y = CGFloat(Int.random(in: -2000 ... 4000, using: &rng))
            let w = degenerate ? 0 : CGFloat(Int.random(in: 1 ... 2500, using: &rng))
            let h = degenerate ? 0 : CGFloat(Int.random(in: 1 ... 2500, using: &rng))
            return CGRect(x: x, y: y, width: w, height: h)
        }
    }

    // MARK: - Tests

    @Test("100 randomized integer rect sets match the cell reference exactly")
    func randomizedSetsMatchReference() {
        var rng = SplitMix64(state: 0xC0FF_EE00_DEAD_BEEF)
        for round in 0 ..< 100 {
            let count = Int.random(in: 1 ... 30, using: &rng)
            let rects = randomIntegerRects(count: count, using: &rng)
            let sweep = FullScreenDetector.unionArea(of: rects)
            let reference = cellReferenceUnionArea(of: rects)
            // Integer coordinates keep every product/sum exact in Double,
            // so the two algorithms must agree bit-for-bit.
            #expect(sweep == reference, "round \(round): sweep \(sweep) != reference \(reference)")
        }
    }

    @Test("A set above the 80-window cap still matches the reference")
    func overCapMatchesReference() {
        var rng = SplitMix64(state: 42)
        let rects = randomIntegerRects(count: 100, using: &rng)
        #expect(FullScreenDetector.unionArea(of: rects) == cellReferenceUnionArea(of: rects))
    }

    @Test("Fractional coordinates stay within float tolerance of the reference")
    func fractionalCoordinatesCloseToReference() {
        var rng = SplitMix64(state: 7)
        for _ in 0 ..< 20 {
            let rects: [CGRect] = (0 ..< 20).map { _ in
                CGRect(
                    x: CGFloat.random(in: -2000 ... 4000, using: &rng),
                    y: CGFloat.random(in: -2000 ... 4000, using: &rng),
                    width: CGFloat.random(in: 0.1 ... 2500, using: &rng),
                    height: CGFloat.random(in: 0.1 ... 2500, using: &rng)
                )
            }
            let sweep = FullScreenDetector.unionArea(of: rects)
            let reference = cellReferenceUnionArea(of: rects)
            #expect(abs(sweep - reference) <= max(1, reference) * 1e-9)
        }
    }

    @Test("Empty and all-degenerate inputs are zero")
    func emptyIsZero() {
        #expect(FullScreenDetector.unionArea(of: []) == 0)
        #expect(FullScreenDetector.unionArea(of: [
            CGRect(x: 5, y: 5, width: 0, height: 300),
            CGRect(x: 5, y: 5, width: 300, height: 0),
        ]) == 0)
    }

    @Test("Exact tiling covers the full screen area once")
    func fullCoverTiling() {
        let tiles = [
            CGRect(x: 0, y: 0, width: 960, height: 540),
            CGRect(x: 960, y: 0, width: 960, height: 540),
            CGRect(x: 0, y: 540, width: 960, height: 540),
            CGRect(x: 960, y: 540, width: 960, height: 540),
            // Redundant overlap on top must not change the union.
            CGRect(x: 100, y: 100, width: 1000, height: 800),
        ]
        // CGFloat literal: a bare Int literal takes the macro's heterogeneous
        // == path, which is always false.
        #expect(FullScreenDetector.unionArea(of: tiles) == CGFloat(1920 * 1080))
    }
}
