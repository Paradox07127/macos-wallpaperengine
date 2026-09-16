#if !LITE_BUILD
import Foundation
@testable import LiveWallpaper
import LiveWallpaperProWPE
import Testing

@MainActor
@Suite("Frame presentation overlay")
struct WPEFrameOverlayTests {
    @Test("Fused traversal agrees with the independent original", arguments: 0 ..< 8, [false, true])
    func differential(mask: Int, animated: Bool) {
        let pipeline = Self.fixture(animated: animated)
        let overlay = WPEFrameOverlay(
            visibility: mask & 1 == 0 ? [:] : ["layer": false],
            alpha: mask & 2 == 0 ? [:] : ["layer": 0.25],
            colors: mask & 4 == 0 ? [:] : ["layer": SIMD3(0.2, 0.4, 0.6)]
        )
        #expect(pipeline.applyingFrameOverlay(overlay) == Self.legacy(pipeline, overlay))
    }

    @Test("Claims preserve unclaimed animated g_Color components and access metadata")
    func animatedClaims() throws {
        let pipeline = Self.fixture(animated: true)
        let alpha = pipeline.applyingFrameOverlay(WPEFrameOverlay(alpha: ["layer": 0.25]))
        #expect(alpha.layers[0].passes[0].access === pipeline.layers[0].passes[0].access)
        for time in [0.0, 4.0] {
            let values = Self.resolved(alpha, time: time)
            let color = try #require(values["g_Color"]?.vectorValue)
            #expect(color[0] == (time == 0 ? 0 : 1))
            #expect(color[2] == (time == 0 ? 1 : 0))
            #expect(color[3] == 0.25)
        }
        let both = alpha.applyingFrameOverlay(WPEFrameOverlay(colors: ["layer": SIMD3(0.2, 0.4, 0.6)]))
        let color = try #require(Self.resolved(both, time: 4)["g_Color"]?.vectorValue)
        #expect(color == [0.4, 0.8, 1.2, 0.25])
        let rgb = pipeline.applyingFrameOverlay(WPEFrameOverlay(colors: ["layer": SIMD3(0.2, 0.4, 0.6)]))
        #expect(Self.resolved(rgb, time: 0)["g_Color"]?.vectorValue == [0.4, 0.8, 1.2, 0.2])
        #expect(Self.resolved(rgb, time: 4)["g_Color"]?.vectorValue == [0.4, 0.8, 1.2, 0.8])
        // Foreign shaders can use g_Color for a different purpose.
        #expect(both.layers[0].passes[1].uniformValues == pipeline.layers[0].passes[1].uniformValues)
    }

    @Test("Matching authored values still claim animations and group-local tint")
    func animationClaimsAndGroupGeometry() {
        let pipeline = Self.fixture(animated: true, animatedGeometry: true)
        let original = pipeline.layers[0].graphLayer
        let overlay = WPEFrameOverlay(alpha: ["layer": original.geometry.alpha], colors: ["layer": original.geometry.color])
        let result = pipeline.applyingFrameOverlay(overlay)
        let graph = result.layers[0].graphLayer
        #expect(graph.geometry.alphaAnimation == nil)
        #expect(graph.geometry.colorAnimation == nil)
        #expect(graph.groupLocalGeometry?.alphaAnimation == nil)
        #expect(graph.groupLocalGeometry?.colorAnimation == nil)
        #expect(graph.groupLocalGeometry?.alpha == original.geometry.alpha)
        #expect(graph.groupLocalGeometry?.color == original.geometry.color)
        #expect(graph.localGeometry == original.localGeometry)
        #expect(graph.geometry.shapePoints == original.geometry.shapePoints)
        #expect(result == Self.legacy(pipeline, overlay))
    }

    @Test("No-op overlay keeps layer and pass storage; visibility keeps pass storage")
    func noOpStorage() {
        let pipeline = Self.fixture()
        for overlay in [WPEFrameOverlay(), WPEFrameOverlay(visibility: ["missing": false]),
                        WPEFrameOverlay(visibility: ["layer": true], alpha: ["layer": 1], colors: ["layer": SIMD3(repeating: 1)])] {
            let result = pipeline.applyingFrameOverlay(overlay)
            #expect(Self.sharesStorage(pipeline.layers, result.layers))
            #expect(Self.sharesStorage(pipeline.layers[0].passes, result.layers[0].passes))
        }
        let hidden = pipeline.applyingFrameOverlay(WPEFrameOverlay(visibility: ["layer": false]))
        #expect(!hidden.layers[0].graphLayer.visible)
        #expect(Self.sharesStorage(pipeline.layers[0].passes, hidden.layers[0].passes))
    }

    @Test("Presentation snapshots survive later script mutations")
    func snapshot() {
        var visibility = ["layer": true]
        var alpha = ["layer": 0.4]
        var overlay = WPEFrameOverlay(visibility: visibility, alpha: alpha)
        visibility["layer"] = false
        alpha["layer"] = 0.9
        overlay.colors = ["layer": SIMD3(0.2, 0.4, 0.6)]
        #expect(overlay.visibility["layer"] == true)
        #expect(overlay.alpha["layer"] == 0.4)
    }

    @Test("Parent transform resolution retains fused presentation and local geometry")
    func parentTransform() {
        let pipeline = Self.fixture()
        let overlay = WPEFrameOverlay(visibility: ["layer": false], alpha: ["layer": 0.25], colors: ["layer": SIMD3(0.2, 0.4, 0.6)])
        func transform(_ value: WPEPreparedRenderPipeline) -> WPEPreparedRenderPipeline {
            value.applyingLayerTransforms(
                origins: [:], scales: [:], angles: ["group": SIMD3(0, 0, .pi / 2)],
                parentByID: ["layer": "group"],
                hostTransforms: ["group": WPERenderObjectTransform(origin: .zero, scale: SIMD3(repeating: 1), angles: .zero)]
            )
        }
        let result = transform(pipeline.applyingFrameOverlay(overlay))
        #expect(result == transform(Self.legacy(pipeline, overlay)))
        #expect(abs(result.layers[0].graphLayer.geometry.origin.x) < 1e-10)
        #expect(abs(result.layers[0].graphLayer.geometry.origin.y - 10) < 1e-10)
        #expect(result.layers[0].graphLayer.geometry.alpha == 0.25)
    }

    @Test("Opt-in CPU overlay benchmark")
    func benchmark() {
        guard ProcessInfo.processInfo.environment["LOOMSCREEN_FRAME_OVERLAY_BENCHMARK"] == "1" else { return }
        let iterations = 100
        for count in [64, 256, 1024] {
            let source = Self.fixture()
            let pipeline = WPEPreparedRenderPipeline(layers: (0 ..< count).map { index in
                let original = source.layers[0]
                let graph = WPERenderLayer(
                    objectID: "layer\(index)", objectName: "Layer", imagePath: "models/solid.json", materialPath: nil,
                    geometry: original.graphLayer.geometry, compositeA: "a", compositeB: "b", localFBOs: [], passes: original.graphLayer.passes
                )
                return WPEPreparedRenderLayer(graphLayer: graph, passes: original.passes + original.passes)
            })
            for percent in [-1, 0, 1, 100] {
                // -1 is an empty overlay; 0 repeats existing values for every layer.
                let changed = percent < 0 ? 0 : (percent == 0 ? count : max(1, count * percent / 100))
                let overlay = WPEFrameOverlay(
                    visibility: Dictionary(uniqueKeysWithValues: (0 ..< changed).map { ("layer\($0)", percent == 0) }),
                    alpha: Dictionary(uniqueKeysWithValues: (0 ..< changed).map { ("layer\($0)", percent == 0 ? 1.0 : 0.25) }),
                    colors: Dictionary(uniqueKeysWithValues: (0 ..< changed).map { ("layer\($0)", SIMD3(repeating: percent == 0 ? 1.0 : 0.5)) })
                )
                let expectedChecksum = Self.checksum(Self.legacy(pipeline, overlay)) * Double(iterations)
                for _ in 0 ..< 10 {
                    _ = Self.legacy(pipeline, overlay); _ = pipeline.applyingFrameOverlay(overlay)
                }
                for round in 0 ..< 5 {
                    for fused in round.isMultiple(of: 2) ? [false, true] : [true, false] {
                        let start = ContinuousClock.now
                        var checksum = 0.0
                        for _ in 0 ..< iterations {
                            let result = fused ? pipeline.applyingFrameOverlay(overlay) : Self.legacy(pipeline, overlay)
                            checksum += Self.checksum(result)
                        }
                        let elapsed = start.duration(to: .now)
                        print("FRAME_OVERLAY_BENCH layers=\(count) passes=4 changedPercent=\(percent) warmup=10 iterations=\(iterations) round=\(round) fused=\(fused) elapsed=\(elapsed) checksum=\(checksum)")
                        #expect(checksum == expectedChecksum)
                    }
                }
            }
        }
    }

    private static func checksum(_ pipeline: WPEPreparedRenderPipeline) -> Double {
        pipeline.layers.reduce(0) { sum, layer in
            let graph = layer.graphLayer
            let passTint = layer.passes.reduce(0.0) { $0 + ($1.uniformValues["g_Color"]?.vectorValue?.reduce(0, +) ?? 0) }
            return sum + graph.geometry.alpha + (graph.visible ? 1 : 0) + graph.geometry.color.x + passTint
        }
    }

    private static func legacy(_ pipeline: WPEPreparedRenderPipeline, _ overlay: WPEFrameOverlay) -> WPEPreparedRenderPipeline {
        pipeline.legacyApplyingLayerVisibility(overlay.visibility)
            .legacyApplyingLayerAlpha(overlay.alpha).legacyApplyingLayerColor(overlay.colors)
    }

    private static func sharesStorage<T>(_ lhs: [T], _ rhs: [T]) -> Bool {
        lhs.withUnsafeBufferPointer { left in rhs.withUnsafeBufferPointer { right in left.baseAddress == right.baseAddress } }
    }

    private static func resolved(_ pipeline: WPEPreparedRenderPipeline, time: Double) -> [String: WPESceneShaderConstantValue] {
        pipeline.addingMetalRuntimeUniforms(
            WPEMetalRuntimeUniforms(time: time, daytime: 0, brightness: 1, pointerPosition: SIMD2(0.5, 0.5)), camera: .identity
        ).pipeline.layers[0].passes[0].uniformValues
    }

    private static var animation: WPESceneAnimatedValue {
        WPESceneAnimatedValue(animation: WPESceneNumericAnimation(
            tracks: [[.init(frame: 0, value: 0), .init(frame: 120, value: 1)],
                     [.init(frame: 0, value: 0), .init(frame: 120, value: 0)],
                     [.init(frame: 0, value: 1), .init(frame: 120, value: 0)],
                     [.init(frame: 0, value: 0.2), .init(frame: 120, value: 0.8)]],
            fps: 30, length: 120, mode: "single", wrapLoop: false
        ), scalarFallback: nil, vectorFallback: [0, 0, 1, 0.2])
    }

    private static func fixture(animated: Bool = false, animatedGeometry: Bool = false) -> WPEPreparedRenderPipeline {
        let seed: WPESceneShaderConstantValue = animated ? .animated(animation) : .vector([1, 1, 1, 1])
        let passes = [WPEBuiltinShaderKind.solidLayer.rawValue, "foreign"].map { shader in
            WPERenderPass(id: shader, phase: .material, shader: shader, source: .image("models/solid.json"), target: .scene,
                          textures: [:], binds: [:], constants: ["g_Color": seed], combos: [:], blending: "normal",
                          cullMode: "nocull", depthTest: "disabled", depthWrite: "disabled")
        }
        let geometry = WPERenderLayerGeometry(
            origin: SIMD3(10, 0, 0), scale: SIMD3(repeating: 1), angles: .zero, alignment: .center, size: CGSize(width: 64, height: 32),
            alpha: 1, alphaAnimation: animatedGeometry ? animation : nil,
            color: SIMD3(repeating: 1), colorAnimation: animatedGeometry ? animation : nil,
            brightness: 2, shapePoints: [SIMD2(0, 0), SIMD2(1, 0), SIMD2(1, 1), SIMD2(0, 1)]
        )
        let graph = WPERenderLayer(
            objectID: "layer", objectName: "Layer", imagePath: "models/solid.json", materialPath: nil,
            parentObjectID: "group", geometry: geometry, localGeometry: geometry,
            compositeA: "a", compositeB: "b", localFBOs: [], passes: passes,
            groupRenderTarget: "groupBuffer", groupLocalGeometry: geometry, groupCompositeSource: "groupSource",
            parallaxDepth: SIMD2(0.1, 0.2), sortIndex: 3
        )
        return WPEPreparedRenderPipeline(layers: [WPEPreparedRenderLayer(graphLayer: graph, passes: passes.map {
            WPEPreparedRenderPass(pass: $0, shader: nil, textureBindings: [:], comboValues: [:], uniformValues: ["g_Color": seed])
        })])
    }
}
#endif
