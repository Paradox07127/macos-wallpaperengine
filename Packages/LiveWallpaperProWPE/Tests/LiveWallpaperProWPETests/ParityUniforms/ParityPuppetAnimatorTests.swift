import Foundation
@testable import LiveWallpaperProWPE
import simd
import XCTest

final class ParityPuppetAnimatorTests: XCTestCase {
    private func floats(_ matrix: simd_float4x4) -> [Float] {
        [matrix.columns.0, matrix.columns.1, matrix.columns.2, matrix.columns.3].flatMap { [$0.x, $0.y, $0.z, $0.w] }
    }

    private func translation(_ value: SIMD3<Float>) -> simd_float4x4 {
        var matrix = matrix_identity_float4x4
        matrix.columns.3 = SIMD4(value, 1)
        return matrix
    }

    private func key(_ frame: Int, _ translation: SIMD3<Float>, rotationZ: Float = 0) -> WPEPuppetAnimKey {
        WPEPuppetAnimKey(frame: frame, translation: translation, euler: SIMD3(0, 0, rotationZ), scale: SIMD3(1, 1, 1))
    }

    private func animation(id: Int, mode: String = "loop", fps: Float = 4,
                           channels: [[WPEPuppetAnimKey]]) -> WPEPuppetAnimation {
        WPEPuppetAnimation(id: id, name: "a\(id)", mode: mode, fps: fps, frameCount: channels[0].count - 1,
                           channels: channels.enumerated().map { WPEPuppetAnimChannel(boneIndex: $0, keyframes: $1) })
    }

    /// Root bound at (1, 0, 0), child at (0, 2, 0) under it.
    private func chain(_ animations: [WPEPuppetAnimation]) -> WPEPuppetModel {
        WPEPuppetModel(version: 23, meshes: [], bones: [
            WPEPuppetBone(index: 0, parentIndex: nil, rawMatrix: floats(translation(SIMD3(1, 0, 0)))),
            WPEPuppetBone(index: 1, parentIndex: 0, rawMatrix: floats(translation(SIMD3(0, 2, 0)))),
        ], animations: animations)
    }

    private func layer(_ animation: Int, id: Int = 1, rate: Double = 1, blend: Double = 1,
                       additive: Bool = false) -> WPESceneAnimationLayer {
        WPESceneAnimationLayer(id: id, rate: rate, visible: true, blend: blend, animation: animation, additive: additive)
    }

    private func rotationZ(_ angle: Float) -> simd_quatf {
        simd_quatf(angle: angle, axis: SIMD3(0, 0, 1))
    }

    private func assertEqual(_ lhs: simd_float4x4, _ rhs: simd_float4x4, accuracy: Float = 1e-5,
                             file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(simd_almost_equal_elements(lhs, rhs, accuracy), "\(lhs) != \(rhs)", file: file, line: line)
    }

    private func rotatingChild(mode: String = "loop", frames: Int = 1) -> WPEPuppetModel {
        let root = (0 ... frames).map { key($0, SIMD3(1, 0, 0)) }
        let child = (0 ... frames).map { key($0, SIMD3(0, 2, 0), rotationZ: Float($0) * .pi / 2) }
        return chain([animation(id: 7, mode: mode, channels: [root, child])])
    }

    func testBindPoseKeysGiveIdentityRows() {
        let animator = WPEParityPuppetAnimator(model: rotatingChild(), layers: [layer(7)])
        XCTAssertEqual(animator.bones.count, 6)
        for bone in 0 ..< 2 {
            for row in 0 ..< 3 {
                let expected = SIMD4<Float>((0 ..< 4).map { $0 == row ? 1 : 0 })
                XCTAssertLessThan(simd_length(animator.bones[bone * 3 + row] - expected), 1e-5, "bone \(bone) row \(row)")
            }
        }
    }

    func testDisabledLayerKeepsIdentityCursorAndHotRateBlend() {
        let disabled = WPESceneAnimationLayer(id: 42, rate: 1, visible: false, blend: 1, animation: 7)
        var animator = WPEParityPuppetAnimator(model: rotatingChild(frames: 2), layers: [layer(999), disabled])
        XCTAssertEqual(animator.layers.count, 1)
        XCTAssertEqual(animator.layers[0].id, 42)
        XCTAssertEqual(animator.layers[0].sceneIndex, 1)
        XCTAssertFalse(animator.layers[0].enabled)
        animator.advance(dt: 0.25)
        XCTAssertEqual(animator.layers[0].time, 0)
        assertEqual(animator.palette[1], matrix_identity_float4x4)
        XCTAssertFalse(animator.updateLayer(at: 0, enabled: true), "missing animations do not shift authored indices")
        XCTAssertTrue(animator.updateLayer(at: 1, enabled: true, rate: 2))
        animator.advance(dt: 0.0625)
        XCTAssertEqual(animator.layers[0].time, 0.125)
        XCTAssertTrue(animator.updateLayer(at: 1, enabled: false))
        animator.advance(dt: 0.25)
        XCTAssertEqual(animator.layers[0].time, 0.125, "disabled playback holds its cursor")
        XCTAssertTrue(animator.updateLayer(at: 1, enabled: true, rate: 0, blend: 0.5))
        animator.advance(dt: 0.1)
        XCTAssertEqual(animator.layers[0].time, 0.125)
        XCTAssertEqual(animator.layers[0].weight, 0.5)
        let blended = simd_normalize(rotationZ(0) * 0.5 + rotationZ(.pi / 4) * 0.5)
        let expected = translation(SIMD3(1, 2, 0)) * simd_float4x4(blended) * translation(SIMD3(-1, -2, 0))
        assertEqual(animator.palette[1], expected)
    }

    func testAuthoredLayerDefaultsReachTheBonePalette() throws {
        // Native 14026c680 initializes rate=1, blendtime=0.5; 1401730d0 only parses keys present in JSON.
        let document = try ParityCameraFixture.document(json: """
        {"camera":{"eye":"0 0 10","center":"0 0 0","up":"0 1 0"},
         "general":{"orthogonalprojection":{"width":16,"height":16}},
         "objects":[{"id":1,"image":"models/puppet.json","animationlayers":[
          {"id":42,"animation":7,"name":" idle ","blendin":true}]}]}
        """)
        let authored = try XCTUnwrap(document.imageObjects.first).animationLayers
        var animator = WPEParityPuppetAnimator(model: rotatingChild(frames: 2), layers: authored)
        animator.advance(dt: 0.125)
        XCTAssertEqual(animator.layers[0].name, " idle ", "names are not trimmed")
        XCTAssertEqual(animator.layers[0].frame, 0.5, accuracy: 1e-6)
        XCTAssertEqual(animator.layers[0].weight, 0.5, accuracy: 1e-6)
        // At half a frame the sample rotates 45 degrees; blend-in weight halves that to 22.5 degrees.
        let expected = translation(SIMD3(1, 2, 0)) * simd_float4x4(rotationZ(.pi / 8))
            * translation(SIMD3(-1, -2, 0))
        assertEqual(animator.palette[1], expected)
    }

    func testHostPlaybackControlsPreservePauseSeekAndNativeEndedQualification() {
        var animator = WPEParityPuppetAnimator(model: rotatingChild(mode: "single", frames: 2), layers: [layer(7)])
        animator.advance(dt: 0.125)
        let held = animator.palette
        XCTAssertTrue(animator.controlLayer(at: 0, action: .pause))
        XCTAssertFalse(animator.layers[0].isPlaying)
        animator.advance(dt: 0.5)
        XCTAssertEqual(animator.layers[0].frame, 0.5)
        assertEqual(animator.palette[1], held[1])
        XCTAssertTrue(animator.controlLayer(at: 0, action: .setFrame(1.5)))
        XCTAssertEqual(animator.layers[0].frame, 1.5)
        assertEqual(animator.palette[1], held[1]) // Host writes wait for object evaluation.
        animator.advance(dt: 0)
        XCTAssertEqual(animator.layers[0].frame, 1.5)
        XCTAssertTrue(animator.endedLayers.isEmpty)
        XCTAssertTrue(animator.controlLayer(at: 0, action: .play))
        animator.advance(dt: 0.25)
        XCTAssertEqual(animator.layers[0].frame, 2)
        XCTAssertFalse(animator.layers[0].isPlaying)
        XCTAssertEqual(animator.endedLayers, [0])
        animator.advance(dt: 0.25)
        XCTAssertTrue(animator.endedLayers.isEmpty, "a finished single only notifies once")
        XCTAssertTrue(animator.controlLayer(at: 0, action: .play))
        XCTAssertEqual(animator.layers[0].frame, 0, "play restarts a finished single")
        XCTAssertTrue(animator.layers[0].isPlaying)
        XCTAssertTrue(animator.controlLayer(at: 0, action: .setFrame(1.5)))
        animator.advance(dt: 0.25)
        XCTAssertTrue(animator.layers[0].finished)
        XCTAssertTrue(animator.endedLayers.isEmpty, "setFrame suppresses one completion check")
        XCTAssertTrue(animator.controlLayer(at: 0, action: .stop))
        XCTAssertFalse(animator.layers[0].finished)
        XCTAssertTrue(animator.layers[0].paused)
        XCTAssertEqual(animator.layers[0].frame, 0)
        animator.advance(dt: 0)
        assertEqual(animator.palette[1], matrix_identity_float4x4)
        XCTAssertFalse(animator.controlLayer(at: 99, action: .play))
    }

    func testHostLayerFieldsDeferEvaluationAndKeepPlaybackIndependentOfVisibility() {
        var animator = WPEParityPuppetAnimator(model: rotatingChild(frames: 2), layers: [layer(7)])
        XCTAssertTrue(animator.updateLayer(at: 0, enabled: false, name: "hidden", additive: true,
                                           blendIn: true, blendOut: true, blendTime: 0.25))
        XCTAssertTrue(animator.layers[0].isPlaying, "native isPlaying ignores the visible descriptor")
        animator.advance(dt: 0.25)
        XCTAssertEqual(animator.layers[0].time, 0)
        XCTAssertTrue(animator.updateLayer(at: 0, enabled: true, rate: 0, blend: 0.5,
                                           additive: false, blendIn: false, blendOut: false))
        XCTAssertTrue(animator.controlLayer(at: 0, action: .setFrame(1)))
        animator.advance(dt: 0)
        XCTAssertEqual(animator.layers[0].name, "hidden")
        XCTAssertEqual(animator.layers[0].weight, 0.5)
        let expected = translation(SIMD3(1, 2, 0)) * simd_float4x4(rotationZ(.pi / 4))
            * translation(SIMD3(-1, -2, 0))
        assertEqual(animator.palette[1], expected)
    }

    func testChildPaletteFollowsNlerpBetweenKeys() {
        var animator = WPEParityPuppetAnimator(model: rotatingChild(), layers: [layer(7)])
        animator.advance(dt: 0.0625)
        // t = 0.25 of identity → 90° about Z, nlerp (not slerp) with the parent's (1, 2, 0) pivot.
        let rotation = simd_normalize(rotationZ(0) * 0.75 + rotationZ(.pi / 2) * 0.25)
        let expected = translation(SIMD3(1, 2, 0)) * simd_float4x4(rotation) * translation(SIMD3(-1, -2, 0))
        assertEqual(animator.palette[1], expected)
        assertEqual(animator.palette[0], matrix_identity_float4x4)
        let slerp = translation(SIMD3(1, 2, 0)) * simd_float4x4(rotationZ(.pi / 8)) * translation(SIMD3(-1, -2, 0))
        XCTAssertFalse(simd_almost_equal_elements(animator.palette[1], slerp, 1e-4))
    }

    func testLoopWrapsTime() {
        var animator = WPEParityPuppetAnimator(model: rotatingChild(frames: 2), layers: [layer(7)])
        animator.advance(dt: 0.625)
        XCTAssertEqual(animator.layers[0].time, 0.125, accuracy: 1e-6)
        XCTAssertFalse(animator.layers[0].reversing)
    }

    func testMirrorReversesAtTheEnd() {
        var animator = WPEParityPuppetAnimator(model: rotatingChild(mode: "mirror", frames: 2), layers: [layer(7)])
        animator.advance(dt: 0.625)
        XCTAssertEqual(animator.layers[0].time, 0.375, accuracy: 1e-6)
        XCTAssertTrue(animator.layers[0].reversing)
        animator.advance(dt: 0.125)
        XCTAssertEqual(animator.layers[0].time, 0.25, accuracy: 1e-6)
        animator.advance(dt: 0.375)
        XCTAssertEqual(animator.layers[0].time, 0.125, accuracy: 1e-6)
        XCTAssertFalse(animator.layers[0].reversing)
    }

    func testSingleClampsAtTheLastFrame() {
        var animator = WPEParityPuppetAnimator(model: rotatingChild(mode: "single", frames: 2), layers: [layer(7)])
        animator.advance(dt: 0.625)
        XCTAssertEqual(animator.layers[0].time, 0.5)
        XCTAssertTrue(animator.layers[0].finished)
        animator.advance(dt: 0.25)
        XCTAssertEqual(animator.layers[0].time, 0.5)
        let frame = WPEParityPuppetAnimator.frame(time: 0.5, frameDuration: 0.25, frameCount: 2)
        XCTAssertEqual([frame.a, frame.b], [1, 2])
    }

    func testFrameIndicesFollowWPE() {
        let mid = WPEParityPuppetAnimator.frame(time: 0.3125, frameDuration: 0.25, frameCount: 4)
        XCTAssertEqual([mid.a, mid.b], [1, 2])
        XCTAssertEqual(mid.t, 0.25, accuracy: 1e-6)
        let start = WPEParityPuppetAnimator.frame(time: 0, frameDuration: 0.25, frameCount: 4)
        XCTAssertEqual([start.a, start.b], [0, 1])
    }

    func testNativeInt32FrameConversionHandlesInvalidAndBoundaryQuotients() {
        // 1401705be is CVTTSS2SI ecx: invalid returns 0x80000000, then 1401705cb..5d8 selects A=0.
        // Float immediately below +2^31 is valid; +2^31 itself is invalid, rather than clamped to the last frame.
        let cases: [(time: Float, duration: Float, indices: [Int])] = [
            (33.25, 1, [3, 4]), (-0.75, 1, [0, 1]),
            (Float(bitPattern: 0x4EFF_FFFF), 1, [3, 4]),
            (Float(bitPattern: 0x4F00_0000), 1, [0, 1]),
            (Float(bitPattern: 0x4F00_0001), 1, [0, 1]),
            (Float(bitPattern: 0xCEFF_FFFF), 1, [0, 1]),
            (Float(bitPattern: 0xCF00_0000), 1, [0, 1]),
            (Float(bitPattern: 0xCF00_0001), 1, [0, 1]),
            (.greatestFiniteMagnitude, 1, [0, 1]), (-.greatestFiniteMagnitude, 1, [0, 1]),
            (1_073_741_824, 0.5, [0, 1]), (100, .leastNormalMagnitude, [0, 1]),
            (.nan, 1, [0, 1]), (.infinity, 1, [0, 1]), (-.infinity, 1, [0, 1]),
        ]
        for value in cases {
            let frame = WPEParityPuppetAnimator.frame(time: value.time, frameDuration: value.duration, frameCount: 4)
            XCTAssertEqual([frame.a, frame.b], value.indices, "time=\(value.time), duration=\(value.duration)")
            if !value.time.isFinite {
                XCTAssertTrue(frame.t.isNaN, "the native remainder stays NaN")
            }
        }
        let negative = WPEParityPuppetAnimator.frame(time: -0.75, frameDuration: 1, frameCount: 4)
        XCTAssertEqual(negative.t, -0.75, "index qualification does not clamp the native interpolation factor")

        // Drive the same conversion through the newly exposed host control and the real pose evaluation.
        var animator = WPEParityPuppetAnimator(model: rotatingChild(frames: 2), layers: [layer(7)])
        XCTAssertTrue(animator.controlLayer(at: 0, action: .pause))
        XCTAssertTrue(animator.controlLayer(at: 0, action: .setFrame(Float(bitPattern: 0x4EFF_FFFF))))
        animator.advance(dt: 0)
        let last = translation(SIMD3(1, 2, 0)) * simd_float4x4(rotationZ(.pi / 2))
            * translation(SIMD3(-1, -2, 0))
        assertEqual(animator.palette[1], last)
        XCTAssertTrue(animator.controlLayer(at: 0, action: .setFrame(Float(bitPattern: 0x4F00_0000))))
        animator.advance(dt: 0)
        assertEqual(animator.palette[1], matrix_identity_float4x4)
        for frame: Float in [.nan, .infinity, -.infinity] {
            XCTAssertTrue(animator.controlLayer(at: 0, action: .setFrame(frame)))
            animator.advance(dt: 0)
            XCTAssertTrue(animator.palette[1].columns.0.x.isNaN,
                          "the native nonfinite sample remains nonfinite without an integer-conversion trap")
        }
    }

    func testRateScalesAdvance() {
        var animator = WPEParityPuppetAnimator(model: rotatingChild(frames: 2), layers: [layer(7, rate: 2)])
        animator.advance(dt: 0.0625)
        XCTAssertEqual(animator.layers[0].time, 0.125, accuracy: 1e-6)
    }

    func testSecondLayerAtHalfBlendMixesFiftyFifty() {
        let rootKeys = (0 ... 1).map { key($0, SIMD3(1, 0, 0)) }
        let first = animation(id: 1, channels: [rootKeys, (0 ... 1).map { key($0, SIMD3(4, 0, 0)) }])
        let second = animation(id: 2, channels: [rootKeys, (0 ... 1).map { key($0, SIMD3(0, 4, 0), rotationZ: .pi / 2) }])
        let animator = WPEParityPuppetAnimator(model: chain([first, second]),
                                               layers: [layer(1), layer(2, id: 2, blend: 0.5)])
        let rotation = simd_normalize(rotationZ(0) * 0.5 + rotationZ(.pi / 2) * 0.5)
        let world = translation(SIMD3(1, 0, 0)) * translation(SIMD3(2, 2, 0)) * simd_float4x4(rotation)
        let bind = translation(SIMD3(1, 2, 0))
        assertEqual(animator.palette[1], world * bind.inverse)
    }

    func testBlendInRampsOverHalfTheDurationAtMost() {
        let model = rotatingChild(frames: 2)
        let scene = WPESceneAnimationLayer(id: 1, rate: 1, visible: true, blend: 1, animation: 7,
                                           blendIn: true, blendTime: 1)
        var animator = WPEParityPuppetAnimator(model: model, layers: [scene])
        animator.advance(dt: 0.125)
        XCTAssertEqual(animator.layers[0].weight, 0.5, accuracy: 1e-6)
        animator.advance(dt: 0.125)
        XCTAssertEqual(animator.layers[0].weight, 1)
        XCTAssertFalse(animator.layers[0].blendIn)
    }

    func testRowsPackMathRowsWithTranslationInW() {
        let palette = simd_float4x4(rows: [
            SIMD4(1, 2, 3, 4), SIMD4(5, 6, 7, 8), SIMD4(9, 10, 11, 12), SIMD4(0, 0, 0, 1),
        ])
        let rows = WPEParityPuppetAnimator.packedRows([palette])
        XCTAssertEqual(rows, [SIMD4(1, 2, 3, 4), SIMD4(5, 6, 7, 8), SIMD4(9, 10, 11, 12)])
        let columnMajor = [palette.columns.0, palette.columns.1, palette.columns.2]
        XCTAssertNotEqual(rows, columnMajor)
    }

    func testBonesPackIntoFloat4x3ArrayAtFortyEightByteStride() throws {
        var animator = WPEParityPuppetAnimator(model: rotatingChild(), layers: [layer(7)])
        animator.advance(dt: 0.0625)
        let variable = WPEStageReflection.CBuffer.Variable(
            name: "g_Bones", offset: 0, size: 96, baseType: .float, class: .matrix_columns,
            rows: 4, columns: 3, elements: 2, used: true
        )
        let layout = try WPECBufferLayout(.init(name: "g_bufAnimation", register: 2, space: 0, size: 96,
                                                variables: [variable]))
        var packer = WPECBufferPacker(layout: layout)
        try packer.write(XCTUnwrap(animator.values["g_Bones"]), to: "g_Bones")
        let words = stride(from: 0, to: 96, by: 4).map { offset in
            (0 ..< 4).reduce(UInt32(0)) { $0 | UInt32(packer.bytes[offset + $1]) << ($1 * 8) }
        }
        XCTAssertEqual(words, animator.bones.flatMap { [$0.x, $0.y, $0.z, $0.w] }.map(\.bitPattern))
    }

    /// FUN_1401a8c10: case-insensitive "mirror" sets bit0, "single" bit1, anything else loops.
    func testModeStringsCompareWithoutCaseOrTrimming() {
        XCTAssertEqual(WPEParityPuppetAnimator.Mode("Mirror"), .mirror)
        XCTAssertEqual(WPEParityPuppetAnimator.Mode("SINGLE"), .single)
        XCTAssertEqual(WPEParityPuppetAnimator.Mode(" single"), .loop)
        XCTAssertEqual(WPEParityPuppetAnimator.Mode(""), .loop)
    }

    /// FUN_1401f9820 over a base layer, against the decompiled formula written out per component.
    func testAdditiveLayerMatchesTheDecompiledFormula() {
        typealias Q = SIMD4<Float> // (w, x, y, z)
        func euler(_ e: SIMD3<Float>) -> Q { // 140261880.c:2212-2234
            let (cx, cy, cz) = (cos(e.x * 0.5), cos(e.y * 0.5), cos(e.z * 0.5))
            let (sx, sy, sz) = (sin(e.x * 0.5), sin(e.y * 0.5), sin(e.z * 0.5))
            return Q(sx * sy * sz + cx * cy * cz, sx * cy * cz - cx * sy * sz,
                     sx * cy * sz + cx * sy * cz, cx * cy * sz - sx * sy * cz)
        }
        func mul(_ a: Q, _ b: Q) -> Q {
            Q(a.x * b.x - a.y * b.y - a.z * b.z - a.w * b.w, a.x * b.y + a.y * b.x + a.z * b.w - a.w * b.z,
              a.x * b.z - a.y * b.w + a.z * b.x + a.w * b.y, a.x * b.w + a.y * b.z - a.z * b.y + a.w * b.x)
        }
        func matrix(_ t: SIMD3<Float>, _ q: Q, _ s: SIMD3<Float>) -> simd_float4x4 {
            var m = simd_float4x4(simd_quatf(ix: q.y, iy: q.z, iz: q.w, r: q.x))
            m.columns.0 *= s.x
            m.columns.1 *= s.y
            m.columns.2 *= s.z
            m.columns.3 = SIMD4(t, 1)
            return m
        }
        let restT = SIMD3<Float>(1, 0, 0), restQ = euler(SIMD3(0, 0, 0.4)), restS = SIMD3<Float>(2, 2, 2)
        let rest = matrix(restT, restQ, restS)
        let base = [(SIMD3<Float>(0, 0, 0), SIMD3<Float>(0.2, 0, 0), SIMD3<Float>(1, 1, 1)),
                    (SIMD3<Float>(0, 4, 0), SIMD3<Float>(0.2, 0.3, 0.6), SIMD3<Float>(1, 2, 1))]
        let added = [(SIMD3<Float>(1, 0, 0), SIMD3<Float>(0, 0, 0.4), SIMD3<Float>(2, 2, 2)),
                     (SIMD3<Float>(1, 2, 0), SIMD3<Float>(0.5, 0, 1.2), SIMD3<Float>(3, 2, 2))]
        func keys(_ list: [(SIMD3<Float>, SIMD3<Float>, SIMD3<Float>)]) -> [WPEPuppetAnimKey] {
            list.enumerated().map { WPEPuppetAnimKey(frame: $0, translation: $1.0, euler: $1.1, scale: $1.2) }
        }
        let model = WPEPuppetModel(version: 23, meshes: [], bones: [
            WPEPuppetBone(index: 0, parentIndex: nil, rawMatrix: floats(rest)),
        ], animations: [
            WPEPuppetAnimation(id: 1, name: "base", mode: "loop", fps: 4, frameCount: 1,
                               channels: [WPEPuppetAnimChannel(boneIndex: 0, keyframes: keys(base))]),
            WPEPuppetAnimation(id: 2, name: "add", mode: "single", fps: 4, frameCount: 1,
                               channels: [WPEPuppetAnimChannel(boneIndex: 0, keyframes: keys(added))]),
        ])
        var animator = WPEParityPuppetAnimator(model: model, layers: [
            layer(1), layer(2, id: 2, blend: 0.5, additive: true),
        ])
        func sample(_ list: [(SIMD3<Float>, SIMD3<Float>, SIMD3<Float>)], _ t: Float)
            -> (SIMD3<Float>, Q, SIMD3<Float>) {
            let qa = euler(list[0].1), qb = euler(list[1].1)
            let tb = simd_dot(qa, qb) < 0 ? -t : t
            return (list[0].0 * (1 - t) + list[1].0 * t, simd_normalize(qa * (1 - t) + qb * tb),
                    list[0].2 * (1 - t) + list[1].2 * t)
        }
        for dt in [0.05, 0.05, 0.1] {
            animator.advance(dt: dt)
            let t = animator.layers.map { $0.time.truncatingRemainder(dividingBy: 0.25) / 0.25 }
            let w = animator.layers[1].weight
            XCTAssertEqual(w, 0.5)
            let (bt, bq, bs) = sample(base, t[0])
            let (at, aq, as_) = sample(added, t[1])
            let delta = mul(Q(restQ.x, -restQ.y, -restQ.z, -restQ.w), aq)
            let signed = delta.x.sign == .minus ? -w : w
            let ramp = simd_normalize(Q(signed * delta.x + (1 - w), signed * delta.y, signed * delta.z,
                                        signed * delta.w))
            let local = matrix(bt + (at - restT) * w, mul(bq, ramp), bs + (as_ - restS) * w)
            assertEqual(animator.palette[0], local * rest.inverse, accuracy: 1e-4)
            assertEqual(animator.boneWorld[0], local, accuracy: 1e-4)
        }
    }

    /// 1401fdf90.c:583-593, 1050-1052 and 1401fbae0.c:356-464: extras are the rest pose, the bind stays raw.
    private func sheetBone(_ animations: [WPEPuppetAnimation]) -> WPEPuppetModel {
        WPEPuppetModel(version: 23, meshes: [], bones: [
            WPEPuppetBone(index: 0, parentIndex: nil, rawMatrix: floats(translation(SIMD3(100, 0, 0))),
                          restMatrix: floats(translation(SIMD3(0, 50, 0)))),
        ], animations: animations)
    }

    func testExtrasRestIsTheAdditiveReferenceWhileTheBindStaysRaw() {
        let assembled = animation(id: 1, channels: [(0 ... 1).map { key($0, SIMD3(0, 50, 0)) }])
        let animator = WPEParityPuppetAnimator(model: sheetBone([assembled]), layers: [
            layer(1, additive: true), layer(1, id: 2, additive: true),
        ])
        assertEqual(animator.boneWorld[0], translation(SIMD3(0, 50, 0)))
        assertEqual(animator.palette[0], translation(SIMD3(-100, 50, 0)))
    }

    func testExtrasRestPosesABoneWithoutLayers() {
        let animator = WPEParityPuppetAnimator(model: sheetBone([]), layers: [])
        assertEqual(animator.boneWorld[0], translation(SIMD3(0, 50, 0)))
        assertEqual(animator.palette[0], translation(SIMD3(-100, 50, 0)))
    }

    func testBoneWorldComposesAlongParents() {
        var animator = WPEParityPuppetAnimator(model: rotatingChild(), layers: [layer(7)])
        animator.advance(dt: 0.1)
        assertEqual(animator.boneWorld[0], translation(SIMD3(1, 0, 0)))
        // nlerp at t = 0.4 between 0 and a quarter turn.
        let root = Float(0.5).squareRoot()
        let half = SIMD2<Float>(0.6 + 0.4 * root, 0.4 * root)
        let child = translation(SIMD3(0, 2, 0)) * simd_float4x4(rotationZ(2 * atan2(half.y, half.x)))
        XCTAssertEqual(animator.boneWorld.count, 2)
        assertEqual(animator.boneWorld[1], animator.boneWorld[0] * child)
        assertEqual(animator.palette[1], animator.boneWorld[1] * translation(SIMD3(1, 2, 0)).inverse)
    }

    func testWorkshop2370640409PuppetStaysFinite() throws {
        let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(
            "Library/Application Support/Steam/steamapps/workshop/content/431960/2370640409/scene.pkg"
        )
        guard let package = try? Data(contentsOf: url) else {
            throw XCTSkip("Workshop 2370640409 is not installed")
        }
        let files = try PackageFixture.entries(package)
        let sceneJSON = try XCTUnwrap(files["scene.json"].flatMap { String(bytes: $0, encoding: .utf8) })
        let document = try ParityCameraFixture.document(json: sceneJSON)
        let image = try XCTUnwrap(document.imageObjects.first { !$0.animationLayers.isEmpty })
        let modelJSON = try XCTUnwrap(JSONSerialization.jsonObject(
            with: XCTUnwrap(files[image.imageRelativePath])
        ) as? [String: Any])
        let puppetPath = try XCTUnwrap(modelJSON["puppet"] as? String)
        let model = try WPEMdlParser.parse(data: XCTUnwrap(files[puppetPath]))
        XCTAssertFalse(model.bones.isEmpty)
        var animator = WPEParityPuppetAnimator(model: model, layers: image.animationLayers)
        XCTAssertEqual(animator.layers.count, image.animationLayers.count)
        for _ in 0 ..< 60 {
            animator.advance(dt: 1.0 / 60)
        }
        XCTAssertEqual(animator.bones.count, model.bones.count * 3)
        XCTAssertTrue(animator.bones.allSatisfy { [$0.x, $0.y, $0.z, $0.w].allSatisfy(\.isFinite) })
        XCTAssertGreaterThan(animator.layers[0].time, 0)
    }

    /// Workshop 3647999330's single morph target over one vertex.
    private func morphMesh(flags: UInt32 = 0x1000) -> WPEPuppetMesh {
        let target = WPEPuppetMorph.Target(name: "Shape 1706", positions: [-28174, 16728, 0], normals: nil,
                                           alpha: flags & 0x1000 != 0 ? [32767] : nil)
        return WPEPuppetMesh(materialPath: "", vertices: [], indices: [], parts: [], flags: flags,
                             morph: WPEPuppetMorph(scale: 10.269853, vertexCount: 1, targets: [target]))
    }

    private func morphAnimator(track: [Float], blend: Double, additive: Bool) -> WPEParityPuppetAnimator {
        let tail = WPEPuppetAnimationTail(mdlaVersion: 6, sourceRange: 0 ..< 0, blendCurves: nil, scalarCurves: nil,
                                          unknownSegments: [],
                                          morphTracks: [[WPEPuppetMorphTrack(targetIndex: 0, values: track)]])
        let clip = WPEPuppetAnimation(id: 749, name: "LogoShake", mode: "loop", fps: 4, frameCount: 1, channels: [],
                                      tail: tail)
        let model = WPEPuppetModel(version: 23, meshes: [morphMesh()], animations: [clip])
        var animator = WPEParityPuppetAnimator(model: model, layers: [layer(749, blend: blend, additive: additive)])
        animator.advance(dt: 0.125)
        return animator
    }

    private func lanes(_ value: WPECBufferValue?) -> [[Float]] {
        guard case let .array(groups)? = value else { return [] }
        return groups.map { group in
            switch group {
            case let .vector(lanes): lanes
            case let .uintVector(lanes): lanes.map { Float($0) }
            default: []
            }
        }
    }

    /// 1401fdf90.c:1087-1155 and 14020cff0.c:50-160: the set target lands in g_MorphOffsets[1] at index · vc.
    func testAdditiveMorphTrackFillsTheMorphUniforms() {
        let values = morphAnimator(track: [0, 1], blend: 1, additive: true).values
        guard case let .array(offsets)? = values["g_MorphOffsets"], case .uintVector = offsets.first else {
            return XCTFail("g_MorphOffsets must be uint4 groups")
        }
        XCTAssertEqual(lanes(values["g_MorphOffsets"]), [[1, 0, 0, 0], [0, 0, 0, 0], [0, 0, 0, 0]])
        XCTAssertEqual(lanes(values["g_MorphWeights"]), [[10.269853, 0.5, 0, 0], [0, 0, 0, 0], [0, 0, 0, 0]])
    }

    /// 1401fdf90.c:988-1006: a blended layer lerps from the previous weight by the layer weight.
    func testBlendedMorphTrackLerpsByTheLayerWeight() {
        let values = morphAnimator(track: [0, 1], blend: 0.5, additive: false).values
        XCTAssertEqual(lanes(values["g_MorphOffsets"]).first, [1, 0, 0, 0])
        XCTAssertEqual(lanes(values["g_MorphWeights"]).first, [10.269853, 0.25, 0, 0])
    }

    func testZeroMorphTrackSetsNoTarget() {
        let values = morphAnimator(track: [0, 0], blend: 1, additive: false).values
        XCTAssertEqual(lanes(values["g_MorphOffsets"]).first, [0, 0, 0, 0])
        XCTAssertEqual(lanes(values["g_MorphWeights"]).first, [10.269853, 0, 0, 0])
    }

    /// 1401fbae0.c:246-321: texel 0 is (0, 0, 0, 0x7fff), then one texel per target vertex.
    func testMorphTexelsLayOutTargetsAfterTheRestTexel() throws {
        let texture = try XCTUnwrap(WPEParityPuppetAnimator.morphTexels(morphMesh()))
        XCTAssertEqual(texture.side, 2)
        XCTAssertEqual(texture.texels, [0, 0, 0, 32767, -28174, 16728, 0, 32767] + [Int16](repeating: 0, count: 8))
        let plain = try XCTUnwrap(WPEParityPuppetAnimator.morphTexels(morphMesh(flags: 0)))
        XCTAssertEqual(plain.side, 2)
        XCTAssertEqual(plain.texels, [0, 0, 0, 32767] + [Int16](repeating: 0, count: 12))
    }
}

/// `PKGV` archive: header string, entry count, then (name, offset, size) records before the data block.
private enum PackageFixture {
    static func entries(_ data: Data) throws -> [String: Data] {
        let bytes = [UInt8](data)
        var cursor = 0
        func u32() throws -> Int {
            guard cursor + 4 <= bytes.count else { throw CocoaError(.fileReadCorruptFile) }
            defer { cursor += 4 }
            return (0 ..< 4).reduce(0) { $0 | Int(bytes[cursor + $1]) << ($1 * 8) }
        }
        func string() throws -> String {
            let count = try u32()
            guard cursor + count <= bytes.count,
                  let value = String(bytes: bytes[cursor ..< cursor + count], encoding: .utf8) else {
                throw CocoaError(.fileReadCorruptFile)
            }
            cursor += count
            return value
        }
        _ = try string()
        let records = try (0 ..< u32()).map { _ in try (string(), u32(), u32()) }
        return Dictionary(records.map { name, offset, size in
            (name, Data(bytes[(cursor + offset) ..< (cursor + offset + size)]))
        }, uniquingKeysWith: { first, _ in first })
    }
}
