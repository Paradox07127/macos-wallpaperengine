import Testing
import SwiftUI
@testable import LiveWallpaper

struct DesignTests {
    private func approx(_ a: Double, _ b: Double, _ t: Double, _ label: String) {
        #expect(abs(a - b) <= t, "\(label): \(a) vs \(b) (Δ \(abs(a - b)))")
    }

    @Test("Linear components stay inside the unit gamut")
    func linearInGamut() {
        let (r, g, b) = MonitorDesign.linearSRGB(l: 0.62, c: 0.045, h: 250)
        for v in [r, g, b] { #expect(v >= 0 && v <= 1) }
    }

    @Test("Load band colour matches the band identity at each side")
    func loadBandColorMatchesTokens() {
        #expect(colorEq(MonitorDesign.loadBandColor(0.2), MonitorDesign.loadSteel))
        #expect(colorEq(MonitorDesign.loadBandColor(0.6), MonitorDesign.signalAmber))
        #expect(colorEq(MonitorDesign.loadBandColor(0.95), MonitorDesign.signalCoral))
    }

    @Test("Type scale honours the mock's clamps")
    func typeScale() {
        let small = MonitorDesign.TypeScale(cellHeight: 60)
        approx(small.hero, 24, 1e-9, "hero floor")
        let mid = MonitorDesign.TypeScale(cellHeight: 100)
        approx(mid.hero, 36, 1e-9, "hero mid")
        approx(mid.sub, 36 * 0.52, 1e-9, "sub")
        let big = MonitorDesign.TypeScale(cellHeight: 200)
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
