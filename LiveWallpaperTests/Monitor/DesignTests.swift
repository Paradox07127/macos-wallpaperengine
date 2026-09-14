import Testing
import SwiftUI
@testable import LiveWallpaper

struct DesignTests {
    private func approx(_ a: Double, _ b: Double, _ t: Double, _ label: String) {
        #expect(abs(a - b) <= t, "\(label): \(a) vs \(b) (Δ \(abs(a - b)))")
    }

    @Test("Linear components stay inside the unit gamut")
    func linearInGamut() {
        let (r, g, b) = Design.linearSRGB(l: 0.62, c: 0.045, h: 250)
        for v in [r, g, b] { #expect(v >= 0 && v <= 1) }
    }

    @Test("Load band colour matches the band identity at each side")
    func loadBandColorMatchesTokens() {
        #expect(colorEq(Design.loadBandColor(0.2), Design.loadSteel))
        #expect(colorEq(Design.loadBandColor(0.6), Design.signalAmber))
        #expect(colorEq(Design.loadBandColor(0.95), Design.signalCoral))
    }

    @Test("Ring and state dot change band at exactly the same readings")
    func loadBandsAgreeAcrossElements() {
        for fraction in stride(from: 0.0, through: 1.0, by: 0.01) {
            let ringIsHot = colorEq(Design.loadBandColor(fraction), Design.signalCoral)
            let dotIsHot = colorEq(Design.loadDotColor(fraction), Design.signalCoral)
            #expect(ringIsHot == dotIsHot, "hot band disagrees at \(fraction)")

            let ringIsElevated = colorEq(Design.loadBandColor(fraction), Design.signalAmber)
            let dotIsElevated = colorEq(Design.loadDotColor(fraction), Design.signalAmber)
            #expect(ringIsElevated == dotIsElevated, "elevated band disagrees at \(fraction)")
        }
    }

    /// Resting is the one place they are meant to differ: the ring keeps a live
    /// metric's steel, the dot goes quiet.
    @Test("At rest the ring reads as measuring and the dot as idle")
    func restingBandsDifferByRole() {
        #expect(colorEq(Design.loadBandColor(0.1), Design.loadSteel))
        #expect(colorEq(Design.loadDotColor(0.1), Design.signalIdle))
    }

    @Test("Load thresholds stay ordered and inside the unit range")
    func loadThresholdsOrdered() {
        #expect(Design.Load.elevated > 0)
        #expect(Design.Load.elevated < Design.Load.hot)
        #expect(Design.Load.hot < 1)
    }

    @Test("Type scale honours the mock's clamps")
    func typeScale() {
        let small = Design.TypeScale(cellHeight: 60)
        approx(small.hero, 24, 1e-9, "hero floor")
        let mid = Design.TypeScale(cellHeight: 100)
        approx(mid.hero, 36, 1e-9, "hero mid")
        approx(mid.sub, 36 * 0.52, 1e-9, "sub")
        let big = Design.TypeScale(cellHeight: 200)
        approx(big.hero, 46, 1e-9, "hero cap")
        approx(big.label, 12, 1e-9, "label cap")
    }

    @Test("Ticks map recency to x and height; out-of-window dropped")
    func tickFade() {
        let now = 1000.0
        let ticks = TickTrack.ticks(events: [1000, 910, 820, 500, 1100], now: now, span: 180)
        #expect(ticks.count == 3)
        approx(ticks[0].x, 1.0, 1e-9, "recent x")
        approx(ticks[0].heightFraction, 0.84, 1e-9, "recent height")
        approx(ticks[1].x, 0.5, 1e-9, "mid x")
        approx(ticks[1].heightFraction, 0.38 + 0.5 * 0.46, 1e-9, "mid height")
        approx(ticks[2].x, 0.0, 1e-9, "old x")
        approx(ticks[2].heightFraction, 0.38, 1e-9, "old height")
    }

    @Test("Zero/negative span yields no ticks")
    func tickZeroSpan() {
        #expect(TickTrack.ticks(events: [1, 2, 3], now: 3, span: 0).isEmpty)
    }
}

private func colorEq(_ a: Color, _ b: Color) -> Bool {
    let ra = a.resolve(in: .init())
    let rb = b.resolve(in: .init())
    return abs(ra.red - rb.red) < 0.001
        && abs(ra.green - rb.green) < 0.001
        && abs(ra.blue - rb.blue) < 0.001
}
