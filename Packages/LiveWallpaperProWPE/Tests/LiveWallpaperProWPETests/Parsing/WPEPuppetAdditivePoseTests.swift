import LiveWallpaperProWPE
import simd
import Testing

@Suite("Puppet additive reference pose")
struct WPEPuppetAdditivePoseTests {
    private func key(_ frame: Int, translation: SIMD3<Float> = .zero,
                     angle: Float = 0, scale: SIMD3<Float> = SIMD3(repeating: 1)) -> WPEPuppetAnimKey {
        WPEPuppetAnimKey(frame: frame, translation: translation, euler: SIMD3(0, 0, angle), scale: scale)
    }

    private func animation(_ id: Int, keys: [WPEPuppetAnimKey], mode: String = "single") -> WPEPuppetAnimation {
        WPEPuppetAnimation(id: id, name: "pose", mode: mode, fps: 2, frameCount: 2,
                           channels: [WPEPuppetAnimChannel(boneIndex: 0, keyframes: keys)])
    }

    private func layers(blend: Float = 1, allAdditive: Bool = false) -> [WPEPuppetAnimationLayer] {
        let base = animation(1, keys: [key(0), key(1), key(2)])
        let intro = animation(2, keys: [
            key(0, translation: SIMD3(30, -20, 0), angle: .pi / 4, scale: SIMD3(0.8, 0.8, 1)),
            key(1, translation: SIMD3(15, -10, 0), angle: .pi / 8, scale: SIMD3(0.9, 0.9, 1)),
            key(2),
        ])
        return [WPEPuppetAnimationLayer(animation: base, rate: 1, additive: allAdditive, blend: 1),
                WPEPuppetAnimationLayer(animation: intro, rate: 1, additive: true, blend: blend)]
    }

    @Test("An intro returning to the base pose leaves no scale, rotation or translation behind",
          arguments: [false, true])
    func introSettlesAtReference(allAdditive: Bool) {
        for time in [1.0, 6.0] {
            let palette = WPEPuppetAnimationEvaluator.palette(layers: layers(allAdditive: allAdditive), bones: [], at: time)
            #expect(simd_almost_equal_elements(palette[0], matrix_identity_float4x4, 1e-5))
        }
    }

    @Test("Frame zero preserves the authored opening pose instead of returning identity")
    func firstFrameIsAnOpeningPose() {
        let palette = WPEPuppetAnimationEvaluator.palette(layers: layers(), bones: [], at: 0)
        let point = palette[0] * SIMD4<Float>(10, 0, 0, 1)
        #expect(abs(point.x - (30 + 8 / sqrt(2))) < 1e-4)
        #expect(abs(point.y - (-20 + 8 / sqrt(2))) < 1e-4)
    }

    @Test("The opening interpolation and partial blend use the common reference pose")
    func interpolatedAndWeightedOpening() {
        let palette = WPEPuppetAnimationEvaluator.palette(layers: layers(blend: 0.5), bones: [], at: 0.5)
        let origin = palette[0] * SIMD4<Float>(0, 0, 0, 1)
        #expect(simd_distance(origin, SIMD4<Float>(7.5, -5, 0, 1)) < 1e-5)
        let column = palette[0].columns.0
        #expect(abs(simd_length(SIMD3(column.x, column.y, column.z)) - 0.95) < 1e-5)
    }

    @Test("An inactive intro cannot change the base pose")
    func zeroBlendIsNeutral() {
        for time in [0.0, 0.5, 1.0] {
            let palette = WPEPuppetAnimationEvaluator.palette(layers: layers(blend: 0), bones: [], at: time)
            #expect(simd_almost_equal_elements(palette[0], matrix_identity_float4x4, 1e-5))
        }
    }

    @Test("A loop with a distinct starting pose keeps its own additive reference", arguments: ["loop", "mirror"])
    func loopKeepsItsOwnReference(mode: String) {
        let base = animation(1, keys: [key(0)], mode: "loop")
        let loop = animation(2, keys: [
            key(0, translation: SIMD3(30, -20, 0), angle: .pi / 8, scale: SIMD3(0.8, 0.8, 1)),
            key(1, translation: SIMD3(36, -20, 0), angle: .pi / 4, scale: SIMD3(0.88, 0.88, 1)),
            key(2, translation: SIMD3(30, -20, 0), angle: .pi / 8, scale: SIMD3(0.8, 0.8, 1)),
        ], mode: mode)
        let stack = [WPEPuppetAnimationLayer(animation: base, rate: 1, additive: false, blend: 1),
                     WPEPuppetAnimationLayer(animation: loop, rate: 1, additive: true, blend: 1)]
        for time in [0.0, 1.0, 6.0] {
            let palette = WPEPuppetAnimationEvaluator.palette(layers: stack, bones: [], at: time)
            #expect(simd_almost_equal_elements(palette[0], matrix_identity_float4x4, 1e-5))
        }
        let peak = WPEPuppetAnimationEvaluator.palette(layers: stack, bones: [], at: 0.5)
        #expect(abs(peak[0].columns.3.x - 6) < 1e-5)
        #expect(abs(simd_length(peak[0].columns.0) - 1.1) < 1e-5)
    }

    @Test("An assembled character sheet remains assembled when its opening settles")
    func characterSheetKeepsItsReferencePose() {
        func raw(_ translation: Float) -> [Float] {
            [1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, translation, 0, 0, 1]
        }
        let bones = [WPEPuppetBone(index: 0, parentIndex: nil, rawMatrix: raw(100)),
                     WPEPuppetBone(index: 1, parentIndex: 0, rawMatrix: raw(50))]
        let root = key(0, translation: SIMD3(10, 0, 0))
        let child = key(0, translation: SIMD3(2, 0, 0))
        let base = WPEPuppetAnimation(id: 1, name: "assembled", mode: "single", fps: 2, frameCount: 2,
                                      channels: [WPEPuppetAnimChannel(boneIndex: 0, keyframes: [root]),
                                                 WPEPuppetAnimChannel(boneIndex: 1, keyframes: [child])])
        let intro = animation(2, keys: [key(0, translation: SIMD3(20, 0, 0), scale: SIMD3(0.8, 0.8, 1)),
                                        key(2, translation: root.translation)])
        let stack = [WPEPuppetAnimationLayer(animation: base, rate: 1, additive: true, blend: 1),
                     WPEPuppetAnimationLayer(animation: intro, rate: 1, additive: true, blend: 1)]
        let settled = WPEPuppetAnimationEvaluator.palette(layers: stack, bones: bones, at: 6)
        #expect(simd_distance(settled[0] * SIMD4<Float>(100, 0, 0, 1), SIMD4<Float>(10, 0, 0, 1)) < 1e-5)
        #expect(simd_distance(settled[1] * SIMD4<Float>(150, 0, 0, 1), SIMD4<Float>(12, 0, 0, 1)) < 1e-5)
        let opening = WPEPuppetAnimationEvaluator.palette(layers: stack, bones: bones, at: 0)
        #expect(simd_distance(opening[1] * SIMD4<Float>(150, 0, 0, 1), SIMD4<Float>(21.6, 0, 0, 1)) < 1e-4)
    }

    @Test("A collapsed first-frame eyelid retains absolute scale at rest and during a blink")
    func collapsedEyelidStillAnimates() {
        let base = animation(1, keys: [key(0), key(1), key(2)])
        let blink = animation(2, keys: [key(0, scale: SIMD3(0, 0, 1)),
                                        key(1, scale: SIMD3(1, 0.5, 1)),
                                        key(2, scale: SIMD3(0, 0, 1))])
        let stack = [WPEPuppetAnimationLayer(animation: base, rate: 1, additive: false, blend: 1),
                     WPEPuppetAnimationLayer(animation: blink, rate: 1, additive: true, blend: 1)]
        for time in [0.0, 1.0] {
            let palette = WPEPuppetAnimationEvaluator.palette(layers: stack, bones: [], at: time)
            #expect(simd_distance(palette[0] * SIMD4<Float>(3, 2, 0, 1), SIMD4<Float>(0, 0, 0, 1)) < 1e-5)
        }
        let peak = WPEPuppetAnimationEvaluator.palette(layers: stack, bones: [], at: 0.5)
        #expect(simd_distance(peak[0] * SIMD4<Float>(3, 2, 0, 1), SIMD4<Float>(3, 1, 0, 1)) < 1e-5)
    }
}
