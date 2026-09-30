#if !LITE_BUILD
import CoreGraphics
@testable import LiveWallpaper
import LiveWallpaperCore
import Testing

@Suite("Scene span output mapping")
struct WPESceneSpanMappingTests {
    private func mapping(_ mode: WPEPresentFitMode, canvas: CGRect, screen: CGRect) throws -> WPEPresentUniforms {
        let full = WPEPresentUniforms.make(fitMode: mode, sourceWidth: 3840, sourceHeight: 1080,
                                           targetWidth: Int(canvas.width), targetHeight: Int(canvas.height))
        return try #require(full.sliced(to: VideoSpanRenderConfiguration(canvasFrame: canvas, screenFrame: screen)))
    }

    @Test("Adjacent screens sample the same scene coordinate at their join")
    func adjacentJoin() throws {
        let canvas = CGRect(x: -1920, y: 0, width: 3840, height: 1080)
        let left = try mapping(.stretch, canvas: canvas, screen: CGRect(x: -1920, y: 0, width: 1920, height: 1080))
        let right = try mapping(.stretch, canvas: canvas, screen: CGRect(x: 0, y: 0, width: 1920, height: 1080))
        let a = try #require(left.scenePointer(fromDrawablePointer: SIMD2(1, 0.5)))
        let b = try #require(right.scenePointer(fromDrawablePointer: SIMD2(0, 0.5)))
        #expect(abs(a.x - 0.5) < 0.00001)
        #expect(a == b)
        #expect(left.scenePointer(fromDrawablePointer: SIMD2(0, 0.5))?.x == 0)
        #expect(right.scenePointer(fromDrawablePointer: SIMD2(1, 0.5))?.x == 1)
    }

    @Test("Vertical offsets retain top-down texture coordinates")
    func verticalJoin() throws {
        let canvas = CGRect(x: 0, y: -1080, width: 1920, height: 2160)
        let lower = try mapping(.stretch, canvas: canvas, screen: CGRect(x: 0, y: -1080, width: 1920, height: 1080))
        let upper = try mapping(.stretch, canvas: canvas, screen: CGRect(x: 0, y: 0, width: 1920, height: 1080))
        #expect(lower.scenePointer(fromDrawablePointer: SIMD2(0.5, 0))?.y == 0.5)
        #expect(upper.scenePointer(fromDrawablePointer: SIMD2(0.5, 1))?.y == 0.5)
        #expect(lower.scenePointer(fromDrawablePointer: SIMD2(0.5, 1))?.y == 1)
        #expect(upper.scenePointer(fromDrawablePointer: SIMD2(0.5, 0))?.y == 0)
    }

    @Test("Contain is applied once to the canvas rather than once to each display")
    func containUsesWholeCanvas() throws {
        let canvas = CGRect(x: 0, y: 0, width: 3840, height: 2160)
        let screen = CGRect(x: 0, y: 0, width: 1920, height: 2160)
        let u = try mapping(.contain, canvas: canvas, screen: screen)
        #expect(u.scenePointer(fromDrawablePointer: SIMD2(0.5, 0.1)) == nil)
        #expect(try abs(#require(u.scenePointer(fromDrawablePointer: SIMD2(1, 0.5))).x - 0.5) < 0.00001)
    }

    @Test("A physical layout gap remains a gap in the sampled scene")
    func gapsArePreserved() throws {
        let canvas = CGRect(x: 0, y: 0, width: 5000, height: 1080)
        let a = try mapping(.stretch, canvas: canvas, screen: CGRect(x: 0, y: 0, width: 2000, height: 1080))
        let b = try mapping(.stretch, canvas: canvas, screen: CGRect(x: 3000, y: 0, width: 2000, height: 1080))
        #expect(try abs(#require(a.scenePointer(fromDrawablePointer: SIMD2(1, 0.5))).x - 0.4) < 0.00001)
        #expect(try abs(#require(b.scenePointer(fromDrawablePointer: SIMD2(0, 0.5))).x - 0.6) < 0.00001)
    }

    @Test("Invalid and out-of-canvas display rectangles are rejected")
    func invalidGeometry() {
        let u = WPEPresentUniforms.make(fitMode: .stretch, sourceWidth: 1, sourceHeight: 1, targetWidth: 1, targetHeight: 1)
        let canvas = CGRect(x: 0, y: 0, width: 100, height: 100)
        #expect(u.sliced(to: .init(canvasFrame: canvas, screenFrame: .zero)) == nil)
        #expect(u.sliced(to: .init(canvasFrame: canvas, screenFrame: CGRect(x: 90, y: 0, width: 20, height: 100))) == nil)
    }
}
#endif
