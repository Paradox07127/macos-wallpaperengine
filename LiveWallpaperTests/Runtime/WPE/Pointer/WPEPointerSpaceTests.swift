#if !LITE_BUILD
import CoreGraphics
@testable import LiveWallpaper
import simd
import Testing

/// The pointer arrives normalised to the drawable, but the scene is cropped or inset by
/// `present` whenever the aspect ratios differ. Numbers below are measured: a 1920×1080
/// scene on this machine's 1728×1117 built-in display.
@Suite("WPE pointer space")
struct WPEPointerSpaceTests {
    private static let sceneW = 1920
    private static let sceneH = 1080
    private static let builtInW = 1728
    private static let builtInH = 1117

    private func uniforms(_ mode: WPEPresentFitMode, target: (Int, Int)) -> WPEPresentUniforms {
        WPEPresentUniforms.make(
            fitMode: mode,
            sourceWidth: Self.sceneW,
            sourceHeight: Self.sceneH,
            targetWidth: target.0,
            targetHeight: target.1
        )
    }

    /// Why the bug never showed on 16:9: there the transform is the identity.
    @Test("a matching aspect maps the pointer unchanged")
    func matchingAspectIsIdentity() throws {
        let u = uniforms(.cover, target: (1920, 1080))
        for p in [0.0, 0.25, 0.5, 1.0] {
            let mapped = try #require(u.scenePointer(fromDrawablePointer: SIMD2(p, p)))
            #expect(abs(mapped.x - p) < 0.0005)
            #expect(abs(mapped.y - p) < 0.0005)
        }
    }

    @Test("cover on the built-in display maps the centre to the centre")
    func coverKeepsTheCentre() throws {
        let u = uniforms(.cover, target: (Self.builtInW, Self.builtInH))
        let mapped = try #require(u.scenePointer(fromDrawablePointer: SIMD2(0.5, 0.5)))
        #expect(abs(mapped.x - 0.5) < 0.0005)
        #expect(abs(mapped.y - 0.5) < 0.0005)
    }

    /// uvScale.x = 0.8702, uvOffset.x = 0.0649 for this pair, so the edges move inward
    /// by 125 scene pixels and the error grows linearly from the centre.
    @Test("cover on the built-in display pulls the edges in by the cropped amount")
    func coverCropsTheEdges() throws {
        let u = uniforms(.cover, target: (Self.builtInW, Self.builtInH))
        let left = try #require(u.scenePointer(fromDrawablePointer: SIMD2(0.0, 0.5)))
        let right = try #require(u.scenePointer(fromDrawablePointer: SIMD2(1.0, 0.5)))
        #expect(abs(left.x * Double(Self.sceneW) - 125) < 2)
        #expect(abs(right.x * Double(Self.sceneW) - 1795) < 2)
        // The uncropped axis must not move.
        #expect(abs(left.y - 0.5) < 0.0005)
    }

    @Test("contain reports a pointer on the letterbox margin as outside the scene")
    func containRejectsTheMargin() {
        let u = uniforms(.contain, target: (Self.builtInW, Self.builtInH))
        // Scene is wider than the display, so `contain` bars run along the top/bottom.
        #expect(u.scenePointer(fromDrawablePointer: SIMD2(0.5, 0.01)) == nil)
        #expect(u.scenePointer(fromDrawablePointer: SIMD2(0.5, 0.5)) != nil)
    }

    @Test("stretch maps straight through")
    func stretchIsIdentity() throws {
        let u = uniforms(.stretch, target: (Self.builtInW, Self.builtInH))
        let mapped = try #require(u.scenePointer(fromDrawablePointer: SIMD2(0.2, 0.8)))
        #expect(abs(mapped.x - 0.2) < 0.0005)
        #expect(abs(mapped.y - 0.8) < 0.0005)
    }
}
#endif
