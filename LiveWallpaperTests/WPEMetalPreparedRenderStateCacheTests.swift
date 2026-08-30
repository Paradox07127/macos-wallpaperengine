#if !LITE_BUILD
import CoreGraphics
import Foundation
import LiveWallpaperProWPE
import Metal
import Testing
@testable import LiveWallpaper

/// Per-pass PSO cache, indexed texture slot table, and `utilityModelKind` on the layer.
@Suite("WPE Metal prepared render-state caches")
struct WPEMetalPreparedRenderStateCacheTests {

    // MARK: - A. Per-pass PSO cache

    @Test("Same pass in two color formats gets two states, each equal to the pipeline cache's")
    func colorPixelFormatIsPartOfThePassKey() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let executor = try WPEMetalRenderExecutor(device: device)

        let ldr = try executor.passPipelineState(
            passID: "pass.0",
            variant: .genericImage2,
            fragmentName: "wpe_genericimage2_fragment",
            blendMode: "normal",
            alphaWritePolicy: .all,
            colorPixelFormat: .bgra8Unorm,
            depthPixelFormat: .invalid
        )
        // HDR promotion swaps the destination format under the same pass.
        let hdr = try executor.passPipelineState(
            passID: "pass.0",
            variant: .genericImage2,
            fragmentName: "wpe_genericimage2_fragment",
            blendMode: "normal",
            alphaWritePolicy: .all,
            colorPixelFormat: .rgba16Float,
            depthPixelFormat: .invalid
        )

        #expect(ldr !== hdr)

        // Each must be exactly what the second-level cache builds for the same
        // dimensions — the first-level cache may only skip the lookup, never
        // change its answer.
        let referenceLDR = try executor.renderPipeline(
            fragmentName: "wpe_genericimage2_fragment",
            blendMode: "normal",
            alphaWritePolicy: .all,
            colorPixelFormat: .bgra8Unorm,
            depthPixelFormat: .invalid
        )
        let referenceHDR = try executor.renderPipeline(
            fragmentName: "wpe_genericimage2_fragment",
            blendMode: "normal",
            alphaWritePolicy: .all,
            colorPixelFormat: .rgba16Float,
            depthPixelFormat: .invalid
        )
        #expect(ldr === referenceLDR)
        #expect(hdr === referenceHDR)
    }

    @Test("A repeat lookup hits the pass cache instead of re-resolving")
    func repeatLookupHitsTheCache() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let executor = try WPEMetalRenderExecutor(device: device)

        func lookup() throws -> MTLRenderPipelineState {
            try executor.passPipelineState(
                passID: "pass.0",
                variant: .compose,
                fragmentName: "wpe_compose_fragment",
                blendMode: "normal",
                alphaWritePolicy: .all,
                colorPixelFormat: .bgra8Unorm,
                depthPixelFormat: .invalid
            )
        }

        let first = try lookup()
        let resolvesAfterFirst = executor.passPipelineResolveCount
        let second = try lookup()

        #expect(first === second)
        #expect(resolvesAfterFirst == 1)
        #expect(executor.passPipelineResolveCount == 1)
    }

    @Test("Each mutable key dimension selects a distinct pipeline state")
    func everyMutableDimensionIsKeyed() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let executor = try WPEMetalRenderExecutor(device: device)

        func state(
            passID: String = "pass.0",
            variant: WPEMetalRenderExecutor.PassPSOVariant = .genericImage2,
            objectQuad: Bool = false,
            fragmentName: String = "wpe_genericimage2_fragment",
            blendMode: String = "normal",
            colorPixelFormat: MTLPixelFormat = .bgra8Unorm,
            depthPixelFormat: MTLPixelFormat = .invalid
        ) throws -> MTLRenderPipelineState {
            try executor.passPipelineState(
                passID: passID,
                variant: variant,
                objectQuad: objectQuad,
                vertexName: objectQuad ? "wpe_object_quad_vertex" : "wpe_fullscreen_vertex",
                fragmentName: fragmentName,
                blendMode: blendMode,
                alphaWritePolicy: .all,
                colorPixelFormat: colorPixelFormat,
                depthPixelFormat: depthPixelFormat
            )
        }

        let baseline = try state()

        // objectQuad: the vertex function flips with live camera parallax.
        #expect(try state(objectQuad: true) !== baseline)
        // variant: one pass id drives several fragment functions.
        #expect(try state(variant: .copy, fragmentName: "wpe_copy_fragment") !== baseline)
        // passID: distinct passes may share a variant and differ in fragment.
        #expect(try state(passID: "pass.1", fragmentName: "wpe_compose_fragment") !== baseline)
        // blending: `replacingBlending` can re-blend a pass id.
        #expect(try state(blendMode: "additive") !== baseline)
        // depth format: follows the pass's depth plan.
        #expect(try state(depthPixelFormat: .depth32Float) !== baseline)
        // color format: HDR promotion / target choice.
        #expect(try state(colorPixelFormat: .rgba16Float) !== baseline)
    }

    @Test("Releasing transient resources drops the pass PSO cache")
    func reloadInvalidatesThePassCache() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let executor = try WPEMetalRenderExecutor(device: device)

        func lookup() throws -> MTLRenderPipelineState {
            try executor.passPipelineState(
                passID: "pass.0",
                variant: .effect,
                fragmentName: "wpe_effect_opacity_fragment",
                blendMode: "normal",
                alphaWritePolicy: .all,
                colorPixelFormat: .bgra8Unorm,
                depthPixelFormat: .invalid
            )
        }

        _ = try lookup()
        #expect(executor.passPipelineResolveCount == 1)
        // A reload can reuse a pass id for a different shader, so the entry must
        // not survive it.
        executor.releaseTransientResources()
        _ = try lookup()
        #expect(executor.passPipelineResolveCount == 2)
    }

    // MARK: - B. Indexed fragment-texture slots

    @Test("Slot table reproduces the dictionary path's bindings slot for slot")
    func slotTableMatchesDictionaryBindings() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let textures = try (0..<3).map { _ in try makeTexture(device: device, width: 4, height: 2) }

        let reference: [Int: MTLTexture] = [0: textures[0], 3: textures[1], 7: textures[2]]
        let table = WPEMetalTextureSlotTable()
        let samplingDescriptor = WPETexSpriteSamplingDescriptor(
            rotation: SIMD4<Float>(0.5, 0.1, -0.2, 0.5),
            translation: SIMD2<Float>(0.25, 0.75)
        )
        for (slot, texture) in reference {
            table.set(
                texture: texture,
                samplingDescriptor: slot == 3 ? samplingDescriptor : nil,
                at: slot
            )
        }

        // Probe well past the transpiler's ceiling: `g_Texture<N>Resolution`
        // parses N out of authored shader source, so out-of-range reads must
        // answer nil rather than trap.
        for slot in -2..<32 {
            #expect(table[slot] === reference[slot])
        }
        #expect(table.slotCount == WPEShaderTranspiler.customTextureSlotCount)
        #expect(table.samplingDescriptor(at: 3) == samplingDescriptor)
        #expect(table.samplingDescriptor(at: 0) == nil)

        table.reset()
        for slot in 0..<table.slotCount {
            #expect(table[slot] == nil)
            #expect(table.samplingDescriptor(at: slot) == nil)
        }
    }

    @Test("Texture-resolution uniforms read the same slot through the table")
    func textureResolutionUniformsReadTheTable() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let executor = try WPEMetalRenderExecutor(device: device)
        let slot0 = try makeTexture(device: device, width: 8, height: 4)
        let slot3 = try makeTexture(device: device, width: 16, height: 2)

        let table = WPEMetalTextureSlotTable()
        table[0] = slot0
        table[3] = slot3

        let slots = executor.packTranslatedUniforms(
            for: packingPass(values: [:]),
            layout: [
                WPEUniformSlot(name: "g_Texture0Resolution", glslType: "vec4", slot: 0, slotCount: 1),
                WPEUniformSlot(name: "g_Texture3Resolution", glslType: "vec4", slot: 1, slotCount: 1),
                // Unbound slot falls through to the uniform default, exactly as
                // the missing-dictionary-key path did.
                WPEUniformSlot(name: "g_Texture5Resolution", glslType: "vec4", slot: 2, slotCount: 1)
            ],
            texturesBySlot: table
        )

        #expect(slots[0] == SIMD4<Float>(8, 4, 8, 4))
        #expect(slots[1] == SIMD4<Float>(16, 2, 16, 2))
        #expect(slots[2] == SIMD4<Float>(0, 0, 0, 0))
    }

    @Test("Production packer is the only translated-uniform packer")
    func productionPackerIsTheOnlyTranslatedUniformPacker() throws {
        let source = try RepositoryRoot.source(
            "LiveWallpaper/Runtime/Metal/WPEMetalRenderExecutor.swift"
        )
        #expect(source.contains("func packTranslatedUniforms(\n        for pass: WPEPreparedRenderPass,"))
        #expect(!source.contains("func packTranslatedUniforms(\n        values: [String: WPESceneShaderConstantValue],"))
    }

    // MARK: - C. Utility-model classification carried on the layer

    /// Authored path shapes plus negatives the suffix reject must not swallow.
    private static let classificationCorpus = [
        "models/util/composelayer.json",
        "models/util/projectlayer.json",
        "models/util/fullscreenlayer.json",
        "../3479521040/models/util/composelayer.json",
        "models\\util\\composelayer.json",
        "models\\util\\ProjectLayer.json",
        "MODELS/UTIL/FULLSCREENLAYER.JSON",
        "../dep/models\\util\\ComposeLayer.JSON",
        "models/util/solidlayer.json",
        "models/util/solidlayer_depthtest.json",
        "materials/quadrants.png",
        "layer.json",
        "x.json",
        ""
    ]

    @Test("The layer's stored kind equals classify() for every authored path shape")
    func storedKindMatchesClassify() {
        for path in Self.classificationCorpus {
            let layer = makeLayer(imagePath: path)
            #expect(layer.utilityModelKind == WPEUtilityModelKind.classify(path))
            #expect(layer.isUtilityModelLayer == WPEUtilityModelKind.isUtilityModelPath(path))
        }
    }

    /// Suffix reject is a short-circuit; full classification must agree.
    @Test("The suffix fast path never changes classify's answer")
    func suffixRejectMatchesFullClassification() {
        let expected: [String: WPEUtilityModelKind?] = [
            "models/util/composelayer.json": .composeLayer,
            "models/util/projectlayer.json": .projectLayer,
            "models/util/fullscreenlayer.json": .fullScreenLayer,
            "../3479521040/models/util/composelayer.json": .composeLayer,
            "models\\util\\composelayer.json": .composeLayer,
            "models\\util\\ProjectLayer.json": .projectLayer,
            "MODELS/UTIL/FULLSCREENLAYER.JSON": .fullScreenLayer,
            "../dep/models\\util\\ComposeLayer.JSON": .composeLayer,
            "models/util/solidlayer.json": WPEUtilityModelKind?.none,
            "materials/quadrants.png": WPEUtilityModelKind?.none,
            "layer.json": WPEUtilityModelKind?.none,
            "x.json": WPEUtilityModelKind?.none,
            "": WPEUtilityModelKind?.none
        ]
        for (path, kind) in expected {
            #expect(WPEUtilityModelKind.classify(path) == kind, "path: \(path)")
        }
    }

    @Test("Every per-frame consumer agrees with classify()")
    func consumersAgreeWithClassify() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let executor = try WPEMetalRenderExecutor(device: device)
        let sceneSize = CGSize(width: 1024, height: 768)

        for path in Self.classificationCorpus {
            let expected = WPEUtilityModelKind.classify(path)
            // Sub-rect footprint so a composelayer resolves to `.subregion` and
            // the two geometry paths are not trivially equal.
            let geometry = makeGeometry(size: CGSize(width: 120, height: 80))
            let layer = makeLayer(imagePath: path, geometry: geometry)

            // Dispatcher (compose-family gate).
            #expect(layer.isUtilityModelLayer == (expected != nil), "path: \(path)")
            // Executor (object-quad routing + composite geometry).
            #expect(
                executor.sceneCaptureUtilityOutputGeometry(for: layer)
                    == WPEMetalSceneCaptureUtilityModels.outputGeometry(
                        // A freshly-built executor has not seen a frame, so its
                        // scene size is still zero — the point here is that the
                        // two routes agree, not which branch they take.
                        path: path, geometry: geometry, sceneSize: .zero
                    ),
                "path: \(path)"
            )
            // Target pool (layer-composite sizing) reaches the same rule through
            // the kind-taking overload.
            #expect(
                WPEMetalSceneCaptureUtilityModels.outputGeometry(
                    kind: layer.utilityModelKind, geometry: geometry, sceneSize: sceneSize
                ) == WPEMetalSceneCaptureUtilityModels.outputGeometry(
                    path: path, geometry: geometry, sceneSize: sceneSize
                ),
                "path: \(path)"
            )
        }
    }

    // MARK: - Fixtures

    private func makeTexture(device: MTLDevice, width: Int, height: Int) throws -> MTLTexture {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba8Unorm,
            width: width,
            height: height,
            mipmapped: false
        )
        descriptor.usage = [.shaderRead, .renderTarget]
        return try #require(device.makeTexture(descriptor: descriptor))
    }

    private func makeGeometry(size: CGSize?) -> WPERenderLayerGeometry {
        WPERenderLayerGeometry(
            origin: SIMD3<Double>(0, 0, 0),
            scale: SIMD3<Double>(1, 1, 1),
            angles: SIMD3<Double>(0, 0, 0),
            alignment: .center,
            size: size,
            alpha: 1,
            color: SIMD3<Double>(1, 1, 1),
            brightness: 1
        )
    }

    private func makeLayer(
        imagePath: String,
        geometry: WPERenderLayerGeometry? = nil
    ) -> WPERenderLayer {
        WPERenderLayer(
            objectID: "layer",
            objectName: "layer",
            imagePath: imagePath,
            materialPath: nil,
            geometry: geometry ?? makeGeometry(size: nil),
            compositeA: "_rt_imageLayerComposite_layer_a",
            compositeB: "_rt_imageLayerComposite_layer_b",
            localFBOs: [],
            passes: []
        )
    }
}

@Suite("WPE translated pipeline prewarm signatures")
struct WPETranslatedPipelinePrewarmPlanTests {
    @Test("Fullscreen identity stays nil; parallax adds the object quad")
    func vertexNamesCoverParallaxFlip() {
        #expect(
            WPETranslatedPipelinePrewarmPlan.vertexNames(
                target: .scene,
                shapePointCount: nil,
                objectQuadAtRest: false,
                parallaxMayEnableObjectQuad: false,
                skewVertex: false,
                usesPerspectiveProjection: false
            ) == [nil]
        )
        #expect(
            WPETranslatedPipelinePrewarmPlan.vertexNames(
                target: .scene,
                shapePointCount: nil,
                objectQuadAtRest: false,
                parallaxMayEnableObjectQuad: true,
                skewVertex: false,
                usesPerspectiveProjection: false
            ) == [nil, "wpe_object_quad_vertex"]
        )
    }

    @Test("Object-quad layers prewarm skew when MODE=1, not the fullscreen vertex")
    func vertexNamesCoverSkewAndSkipFullscreen() {
        #expect(
            WPETranslatedPipelinePrewarmPlan.vertexNames(
                target: .scene,
                shapePointCount: nil,
                objectQuadAtRest: true,
                parallaxMayEnableObjectQuad: false,
                skewVertex: true,
                usesPerspectiveProjection: false
            ) == ["wpe_skew_object_quad_vertex", "wpe_object_quad_vertex"]
        )
    }

    @Test("Shape quads prewarm the shape vertex and the object-quad fallback")
    func vertexNamesCoverShapeQuads() {
        #expect(
            WPETranslatedPipelinePrewarmPlan.vertexNames(
                target: .scene,
                shapePointCount: 4,
                objectQuadAtRest: true,
                parallaxMayEnableObjectQuad: false,
                skewVertex: false,
                usesPerspectiveProjection: false
            ) == ["wpe_shape_quad_vertex", "wpe_object_quad_vertex"]
        )
    }

    @Test("FBO color format follows the authored buffer; depth follows the pass")
    func colorAndDepthMatchEncode() {
        let fbos = [WPERenderFBO(name: "_rt_Mask", scale: 1, format: "r8")]
        #expect(
            WPETranslatedPipelinePrewarmPlan.colorPixelFormat(
                target: .fbo(name: "_rt_Mask"),
                localFBOs: fbos,
                sceneColorFormat: .bgra8Unorm,
                hdr: false
            ) == .r8Unorm
        )
        #expect(
            WPETranslatedPipelinePrewarmPlan.colorPixelFormat(
                target: .scene,
                localFBOs: fbos,
                sceneColorFormat: .rgba16Float,
                hdr: true
            ) == .rgba16Float
        )
        #expect(
            WPETranslatedPipelinePrewarmPlan.colorPixelFormat(
                target: .fbo(name: "_rt_Color"),
                localFBOs: [WPERenderFBO(name: "_rt_Color", scale: 1, format: "rgba8888")],
                sceneColorFormat: .bgra8Unorm,
                hdr: true
            ) == .rgba16Float,
            "HDR promotes 8-bit color FBOs the same way the target pool does"
        )
        #expect(WPETranslatedPipelinePrewarmPlan.depthPixelFormat(needsDepth: false) == .invalid)
        #expect(WPETranslatedPipelinePrewarmPlan.depthPixelFormat(needsDepth: true) == .depth32Float)
    }
}

private func packingPass(
    values: [String: WPESceneShaderConstantValue]
) -> WPEPreparedRenderPass {
    WPEPreparedRenderPass(
        pass: WPERenderPass(
            id: "pack.0",
            phase: .effect(file: "effects/pack/effect.json"),
            shader: "effects/pack",
            source: .image("materials/base.png"),
            target: .scene,
            textures: [:],
            binds: [:],
            constants: [:],
            combos: [:],
            blending: "disabled",
            cullMode: "nocull",
            depthTest: "disabled",
            depthWrite: "disabled"
        ),
        shader: nil,
        textureBindings: [:],
        comboValues: [:],
        uniformValues: values
    )
}
#endif
