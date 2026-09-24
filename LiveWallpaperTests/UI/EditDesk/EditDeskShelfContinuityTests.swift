import CoreGraphics
import Foundation
@testable import LiveWallpaper
import LiveWallpaperCore
import Testing

/// Sweeps the whole 0 → 2 gesture at 0.01 and proves the shelf chrome has no jump in it: every
/// curve the chrome rides is checked for direction and step size, and the hint and filter row are
/// pinned to the card row they travel with.
@Suite("Edit Desk shelf chrome continuity")
@MainActor
struct EditDeskShelfContinuityTests {
    private typealias Curve = @MainActor (Double) -> Double
    private static let window = CGSize(width: 1280, height: 820)
    private static let samples: [Double] = (0 ... 200).map { Double($0) / 100 }
    private static let gap = Double(StageGeometry.chipRowGap)

    private func rowTop(_ p: Double) -> Double {
        Double(StageGeometry.shelfRowTop(progress: p, windowSize: Self.window))
    }

    private func hintTop(_ p: Double) -> Double {
        Double(HomeHints.shelfHintTop(progress: p, windowSize: Self.window))
    }

    private func chipTop(_ p: Double) -> Double {
        Double(StageGeometry.chipRowTop(progress: p, windowSize: Self.window))
    }

    /// Largest jump between neighbouring samples inside `range`, with the progress it happened at.
    private func maxStep(in range: ClosedRange<Double>, _ curve: Curve) -> (delta: Double, at: Double) {
        var worst = (delta: 0.0, at: 0.0)
        for (index, p) in Self.samples.enumerated() where index > 0 && range.contains(p) {
            let delta = abs(curve(p) - curve(Self.samples[index - 1]))
            if delta > worst.delta {
                worst = (delta, p)
            }
        }
        return worst
    }

    private var positionCurves: [(String, Curve)] {
        [("row top", rowTop), ("hint", hintTop), ("chip row", chipTop)]
    }

    private var shelfFades: [(String, Curve)] {
        [("filter row", ShelfChromeRide.opacity), ("scrim", EditDeskShelfScrim.opacity)]
    }

    // MARK: Position

    @Test("The filter row never teleports anywhere in the gesture")
    func chipRowHasNoJump() {
        let worst = maxStep(in: 0 ... 2, chipTop)
        #expect(worst.delta <= 6, Comment(rawValue: "chip row jumps \(worst.delta)pt at progress \(worst.at)"))
    }

    @Test("Every chrome curve creeps while the shelf rises")
    func firstLegStepsAreSmall() {
        for (name, curve) in positionCurves {
            let worst = maxStep(in: 0 ... 1, curve)
            #expect(worst.delta < 5, Comment(rawValue: "\(name) steps \(worst.delta)pt at progress \(worst.at)"))
        }
    }

    @Test("Chrome only ever travels upward")
    func curvesAreMonotonic() {
        for (name, curve) in positionCurves {
            for (index, p) in Self.samples.enumerated() where index > 0 {
                #expect(curve(p) <= curve(Self.samples[index - 1]), Comment(rawValue: "\(name) drops back at \(p)"))
            }
        }
    }

    @Test("The hint and the filter row are locked to the card row for the whole first leg")
    func chromeIsLockedToTheShelf() {
        for p in Self.samples where p <= 1 {
            #expect(chipTop(p) == rowTop(p) - Self.gap, Comment(rawValue: "chip row at \(p)"))
            #expect(hintTop(p) == rowTop(p) - Self.gap - 34, Comment(rawValue: "hint at \(p)"))
        }
    }

    @Test("The filter row reaches the same two seats it always had")
    func chipRowKeepsItsEndpoints() {
        #expect(chipTop(1) == 632, "the open shelf's seat")
        #expect(chipTop(2) == Double(StageGeometry.chipRowTopFull), "the library's seat")
    }

    // MARK: Opacity

    @Test("No chrome fade ever steps more than a tenth, and none of them leaves 0…1")
    func fadesAreContinuous() {
        let others: [(String, Curve)] = [("shelf hint", HomeHints.shelfHintOpacity), ("search field", LibrarySearchReveal.opacity)]
        for (name, curve) in shelfFades + others {
            for p in Self.samples {
                #expect((0 ... 1).contains(curve(p)), Comment(rawValue: "\(name) at \(p) → \(curve(p))"))
            }
            let worst = maxStep(in: 0 ... 2, curve)
            #expect(worst.delta <= 0.1, Comment(rawValue: "\(name) jumps \(worst.delta) at progress \(worst.at)"))
        }
    }

    @Test("The filter row fades in and then stays")
    func filterRowNeverFadesBack() {
        let row = ShelfChromeRide.opacity
        for (index, p) in Self.samples.enumerated() where index > 0 {
            #expect(row(p) >= row(Self.samples[index - 1]), Comment(rawValue: "the filter row dips at \(p)"))
        }
        #expect(row(0) == 0, "the filter row shows at rest")
        #expect(row(2) == 1, "the filter row is short of the library")
    }

    @Test("The scrim fades in with the shelf and back out as its cards leave for the grid")
    func scrimFadesOutWithTheCards() {
        let scrim = EditDeskShelfScrim.opacity
        for (index, p) in Self.samples.enumerated() where index > 0 {
            let previous = scrim(Self.samples[index - 1])
            if p <= 1 {
                #expect(scrim(p) >= previous, Comment(rawValue: "the scrim dips at \(p) on the way to the shelf"))
            } else {
                #expect(scrim(p) <= previous, Comment(rawValue: "the scrim comes back at \(p) on the way to the grid"))
            }
        }
        #expect(scrim(0) == 0, "the scrim shows at rest")
        #expect(scrim(1) == 1, "the open shelf sits on a partial scrim")
        #expect(scrim(2) == 0, "the grid takes over from a scrim that is still showing")
    }

    @Test("The scrim leads the filter row it sits under on the way to the shelf")
    func scrimArrivesFirst() {
        for p in Self.samples where p <= 1 {
            #expect(
                EditDeskShelfScrim.opacity(p) >= ShelfChromeRide.opacity(p),
                Comment(rawValue: "the filter row outruns its own backdrop at \(p)")
            )
        }
    }

    @Test("The filter row is still too faint to aim at when it first appears")
    func fadedRowIsNotClickable() {
        #expect(ShelfChromeRide.opacity(0.5) < 0.5)
    }

    @Test("The search field is out of sight on the shelf, rises with the library and is whole there")
    func searchFieldBelongsToTheLibrary() {
        let search = LibrarySearchReveal.opacity
        for (index, p) in Self.samples.enumerated() where index > 0 {
            #expect(search(p) >= search(Self.samples[index - 1]), Comment(rawValue: "the search field dips at \(p)"))
        }
        #expect(search(1) == 0, "the search field shows on the shelf")
        #expect(search(1.5) > 0, "the search field waits for the landing")
        #expect(search(2) == 1, "the search field is short of the library")
    }
}
