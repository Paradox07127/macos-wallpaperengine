import CoreGraphics
import Foundation
@testable import LiveWallpaper
import LiveWallpaperCore
import Testing

@Suite("Overlay canvas geometry")
struct OverlayGeometryTests {
    @Test("Display ratios fit within and stay centred in the hero", arguments: [
        CGSize(width: 1600, height: 900), CGSize(width: 1600, height: 1000), CGSize(width: 900, height: 1600),
    ])
    func aspectFit(_ logical: CGSize) {
        let container = CGRect(x: 24, y: 140, width: 860, height: 484)
        let rect = OverlayGeometry.aspectFit(logicalSize: logical, in: container)
        #expect(container.insetBy(dx: -0.001, dy: -0.001).contains(rect))
        #expect(abs(rect.width / rect.height - logical.width / logical.height) < 0.0001)
        #expect(abs(rect.midX - container.midX) < 0.0001)
        #expect(abs(rect.midY - container.midY) < 0.0001)
    }

    @Test("Music uses the same visible rectangle as the reference-width preview", arguments: [
        CGSize(width: 1600, height: 900), CGSize(width: 1600, height: 1000), CGSize(width: 900, height: 1600),
    ])
    func musicCoordinateEquivalence(_ logical: CGSize) {
        let canvas = OverlayGeometry.aspectFit(logicalSize: logical, in: CGRect(x: 0, y: 0, width: 860, height: 484)).size
        let scale = canvas.width / logical.width
        let safe = MonitorSafeAreaInsets(top: 0.03, leading: 0.02, bottom: 0.08)
        for size in [MusicOverlaySize.small, .medium, .large] {
            for origin in [CGPoint(x: 0.25, y: 0.3), CGPoint(x: 0.98, y: 0.98), .zero] {
                var music = MusicOverlayConfiguration.default
                music.size = size
                music.x = origin.x
                music.y = origin.y
                let geometry = MonitorBoardGeometry(boardSize: canvas, referenceWidth: logical.width, safeArea: safe)
                let cells = MusicOverlayLayout.cells(for: music.size)
                let footprint = geometry.pixelSize(columns: cells.columns, rows: cells.rows)
                let old = geometry.renderRect(forRawRect: CGRect(
                    origin: geometry.clampOrigin(CGPoint(x: music.x * canvas.width, y: music.y * canvas.height), footprint: footprint),
                    size: footprint
                ))
                let actual = OverlayGeometry.screenRect(OverlayGeometry.musicRect(music, logicalSize: logical, safeArea: safe), renderScale: scale)
                expectEqual(actual, old)
            }
        }
    }

    @Test("Clock has one scale conversion, including clamped widths and safe areas", arguments: [
        CGSize(width: 1600, height: 900), CGSize(width: 1600, height: 1000), CGSize(width: 900, height: 1600),
    ])
    func clockCoordinateEquivalence(_ logical: CGSize) {
        let canvas = OverlayGeometry.aspectFit(logicalSize: logical, in: CGRect(x: 0, y: 0, width: 860, height: 484)).size
        let safe = MonitorSafeAreaInsets(top: 0.03, bottom: 0.1, trailing: 0.04)
        for width in [180.0, 600, 1600] {
            var clock = ClockOverlayConfiguration.default
            clock.width = width
            clock.x = 0.9
            clock.y = 0.9
            let old = ClockOverlayLayout.renderRect(configuration: clock, canvas: canvas, referenceWidth: logical.width, safeArea: safe)
            let actual = OverlayGeometry.screenRect(OverlayGeometry.clockRect(clock, logicalSize: logical, safeArea: safe),
                                                    renderScale: canvas.width / logical.width)
            expectEqual(actual, old)
        }
    }

    @Test("Snap threshold is divided by render scale, with a beyond-threshold control")
    func scaledSnapThreshold() {
        let geometry = MonitorBoardGeometry(boardSize: CGSize(width: 2400, height: 1800))
        let near = OverlayGeometry.snap(freeRect: CGRect(x: 60, y: 400, width: 200, height: 100),
                                        geometry: geometry, candidates: [], renderScale: 0.2, enabled: true)
        let far = OverlayGeometry.snap(freeRect: CGRect(x: 80, y: 400, width: 200, height: 100),
                                       geometry: geometry, candidates: [], renderScale: 0.2, enabled: true)
        #expect(near.snappedX && near.origin.x == 0)
        #expect(!far.snappedX && far.origin.x == 80)
        let bypassed = OverlayGeometry.snap(freeRect: CGRect(x: 60, y: 400, width: 200, height: 100),
                                            geometry: geometry, candidates: [], renderScale: 0.2, enabled: false)
        #expect(!bypassed.snapped && bypassed.origin.x == 60)
    }

    @Test("Neighbourhood is also divided by scale")
    func scaledNeighbourhood() {
        let geometry = MonitorBoardGeometry(boardSize: CGSize(width: 3000, height: 2400))
        let candidate = MonitorBoardItem(id: UUID(), rect: CGRect(x: 600, y: 200, width: 100, height: 100))
        let near = OverlayGeometry.snap(freeRect: CGRect(x: 540, y: 850, width: 200, height: 100),
                                        geometry: geometry, candidates: [candidate], renderScale: 0.2, enabled: true)
        #expect(near.snappedX)
        #expect(near.guideX?.partner == candidate.rect)
        let far = OverlayGeometry.snap(freeRect: CGRect(x: 540, y: 1050, width: 200, height: 100),
                                       geometry: geometry, candidates: [candidate], renderScale: 0.2, enabled: true)
        #expect(!far.snappedX)
    }

    @Test("Decorations retain screen-point dimensions")
    func decorationDimensions() {
        #expect(OverlayGeometry.decorationLineWidth(forRenderScale: 0.2) == 5)
        #expect(OverlayGeometry.decorationLineWidth(forRenderScale: 1) == 1)
        #expect(OverlayGeometry.gridSpacing(forRenderScale: 0.2) == 250)
        #expect(OverlayGeometry.gridSpacing(forRenderScale: 1) == 50)
    }

    @Test("Lift, landing, and reduced-motion timings match MOTION 14")
    func motionConstants() {
        #expect(OverlayGeometry.liftScale == 1.03)
        #expect(OverlayGeometry.liftResponse == 0.2)
        #expect(OverlayGeometry.liftDamping == 0.82)
        #expect(OverlayGeometry.dropDuration == 0.12)
        #expect(OverlayGeometry.reducedMotionDuration == 0.15)
    }

    private func expectEqual(_ actual: CGRect, _ expected: CGRect) {
        #expect(abs(actual.minX - expected.minX) <= 0.5)
        #expect(abs(actual.minY - expected.minY) <= 0.5)
        #expect(abs(actual.width - expected.width) <= 0.5)
        #expect(abs(actual.height - expected.height) <= 0.5)
    }
}
