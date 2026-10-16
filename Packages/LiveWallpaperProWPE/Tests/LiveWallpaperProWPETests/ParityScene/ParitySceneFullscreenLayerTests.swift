import LiveWallpaperProWPE
import simd
import Testing

private typealias F = ParitySceneFixtures

/// 1401e8aa0.c:1004-1050: a fullscreen layer's last-segment passes and bit4 publish draw the 2×2 quad.
struct ParitySceneFullscreenLayerTests {
    private static func fullscreen(colorBlendMode: Int = 0) -> WPEParitySceneObject {
        var layer = F.layer(colorBlendMode: colorBlendMode, effects: [WPEParitySceneEffect(id: "e", passes: [
            WPEParityScenePass(shader: "a"), WPEParityScenePass(shader: "b"),
        ])])
        layer.fullscreen = true
        return layer
    }

    @Test func lastSegmentPassesDrawTheTwoByTwoQuad() {
        let frame = WPEParitySceneFrameBuilder.build(F.scene([Self.fullscreen()]))
        for pass in ["L/e/0", "L/e/1"] {
            let draw = frame.draws[WPEPassIdentity(pass)]
            #expect(draw?.target == "backbuffer")
            #expect(draw?.geometry == .fullscreenQuad)
            #expect(draw?.fullscreenLayer == true)
            #expect(draw?.layerMatrices == false)
        }
    }

    @Test func bit4PublishDrawsTheTwoByTwoQuad() {
        let frame = WPEParitySceneFrameBuilder.build(F.scene([Self.fullscreen(colorBlendMode: 5)]))
        let publish = frame.draws["L/passthrough4"]
        #expect(publish?.target == "backbuffer")
        #expect(publish?.geometry == .fullscreenQuad)
        #expect(publish?.fullscreenLayer == true)
    }

    @Test func nonFullscreenFinalPassKeepsTheLayerMesh() {
        var layer = Self.fullscreen()
        layer.fullscreen = false
        let frame = WPEParitySceneFrameBuilder.build(F.scene([layer]))
        #expect(frame.draws["L/e/1"]?.geometry == .layerMesh)
        #expect(frame.draws.values.allSatisfy { !$0.fullscreenLayer })
    }

    @Test func fullscreenLayerKindDrawsTheEffectQuadWithTheLayerEffectConstants() throws {
        let layer = WPEParityLayerTransform(id: "L", origin: SIMD3(300, 200, 0), size: SIMD2(512, 256))
        let camera = WPEParityCamera(eye: SIMD3(960, 540, 1), center: SIMD3(960, 540, 0), up: SIMD3(0, 1, 0),
                                     size: SIMD2(1920, 1080), renderTargetSize: SIMD2(1920, 1080))
        let set = WPEParityLayerTransformSet(camera: camera, layers: [layer])
        let fullscreen = try set.draw("L", kind: .fullscreenLayer, parallax: .zero)
        let last = try set.draw("L", kind: .lastEffectPass, parallax: .zero)
        #expect(fullscreen.matrices.modelViewProjection == WPEParityUniformMatrices.effectPass.modelViewProjection)
        #expect(fullscreen.effectPass?.isLastPass == true)
        #expect(fullscreen.effectPass?.layerModelViewProjection == last.effectPass?.layerModelViewProjection)
        #expect(set.quad("L", kind: .fullscreenLayer) == .effectPass)
    }
}
