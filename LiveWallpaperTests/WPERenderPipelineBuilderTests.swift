import Foundation
import LiveWallpaperProWPE
import Metal
import Testing
@testable import LiveWallpaper

@Suite("WPE render pipeline builder")
struct WPERenderPipelineBuilderTests {

    @Test("Official TEXnFORMAT ABI values stay independent from decoder raw values")
    func officialTextureFormatABIValues() {
        #expect(WPEOfficialTextureFormatABI.rgba8888 == 0)
        #expect(WPEOfficialTextureFormatABI.rgb888 == 1)
        #expect(WPEOfficialTextureFormatABI.rgb565 == 2)
        #expect(WPEOfficialTextureFormatABI.etc1RGB8 == 3)
        #expect(WPEOfficialTextureFormatABI.dxt5 == 4)
        #expect(WPEOfficialTextureFormatABI.etc2RGBA8 == 5)
        #expect(WPEOfficialTextureFormatABI.dxt3 == 6)
        #expect(WPEOfficialTextureFormatABI.dxt1 == 7)
        #expect(WPEOfficialTextureFormatABI.rg88 == 8)
        #expect(WPEOfficialTextureFormatABI.r8 == 9)
        #expect(WPEOfficialTextureFormatABI.rg1616F == 10)
        #expect(WPEOfficialTextureFormatABI.r16F == 11)
        #expect(WPEOfficialTextureFormatABI.bc7 == 12)
        #expect(WPEOfficialTextureFormatABI.shaderValue(forTextureFormatCode: 3) == 3)
        #expect(WPEOfficialTextureFormatABI.shaderValue(forTextureFormatCode: 12) == 12)
        #expect(WPEOfficialTextureFormatABI.shaderValue(forTextureFormatCode: 13) == nil)
    }

    @Test("TEXnFORMAT comes from bound TEXI headers and participates in compile identity")
    func textureFormatsComeFromBoundHeadersAndCompileIdentity() throws {
        func makeGraph() -> WPERenderGraph {
            WPERenderGraph(layers: [
                WPERenderLayer(
                    objectID: "format",
                    objectName: "Format probe",
                    imagePath: "normal",
                    materialPath: nil,
                    geometry: .identity,
                    compositeA: "a",
                    compositeB: "b",
                    localFBOs: [],
                    passes: [
                        WPERenderPass(
                            id: "format.0",
                            phase: .effect(file: "effects/format_probe/effect.json"),
                            shader: "effects/format_probe",
                            source: .image("normal"),
                            target: .scene,
                            textures: [
                                1: .image("mask"),
                                2: .image("native.png"),
                                3: .fbo("_rt_NormalScratch"),
                                5: .image("broken.tex"),
                                6: .image("missing.tex")
                            ],
                            binds: [:],
                            constants: [:],
                            // A material-authored value must not override runtime TEXI.
                            combos: ["TEX1FORMAT": 999],
                            blending: "normal",
                            cullMode: "nocull",
                            depthTest: "disabled",
                            depthWrite: "disabled"
                        )
                    ]
                )
            ])
        }

        let shaderFiles = [
            "shaders/effects/format_probe.vert": """
            attribute vec3 a_Position;
            void main() { gl_Position = vec4(a_Position, 1.0); }
            """,
            "shaders/effects/format_probe.frag": """
            #include "common_fragment.h"
            uniform sampler2D g_Texture0;
            uniform sampler2D g_Texture1;
            void main() {
            #if TEX0FORMAT == FORMAT_DXT5
                gl_FragColor = DecompressNormal(texSample2D(g_Texture1, vec2(0.5))).xyzz;
            #else
                gl_FragColor = texSample2D(g_Texture0, vec2(0.5));
            #endif
            }
            """
        ]
        let first = try makeFixture(
            files: shaderFiles.merging(["native.png": "not decoded by the header probe"]) { lhs, _ in lhs },
            dataFiles: [
                "materials/normal.tex": makeHeaderOnlyTex(formatCode: 4),
                "materials/mask.tex": makeHeaderOnlyTex(formatCode: 8),
                "broken.tex": Data("not-a-tex".utf8)
            ]
        )
        defer { first.cleanup() }

        let firstPass = try #require(
            WPERenderPipelineBuilder(cacheRootURL: first.root)
                .build(graph: makeGraph()).layers.first?.passes.first
        )
        #expect(firstPass.comboValues["TEX0FORMAT"] == WPEOfficialTextureFormatABI.dxt5)
        #expect(firstPass.comboValues["TEX1FORMAT"] == WPEOfficialTextureFormatABI.rg88)
        #expect(firstPass.comboValues["TEX2FORMAT"] == WPEOfficialTextureFormatABI.rgba8888)
        #expect(firstPass.comboValues["TEX3FORMAT"] == WPEOfficialTextureFormatABI.rgba8888)
        #expect(firstPass.comboValues["TEX4FORMAT"] == WPEOfficialTextureFormatABI.rgba8888)
        #expect(firstPass.comboValues["TEX5FORMAT"] == WPEOfficialTextureFormatABI.rgba8888)
        #expect(firstPass.comboValues["TEX6FORMAT"] == WPEOfficialTextureFormatABI.rgba8888)
        #expect(firstPass.comboValues["TEX7FORMAT"] == WPEOfficialTextureFormatABI.rgba8888)
        #expect(firstPass.shader?.fragmentSource.contains("#define TEX0FORMAT 4") == true)
        #expect(firstPass.shader?.fragmentSource.contains("#define TEX1FORMAT 8") == true)

        let second = try makeFixture(
            files: shaderFiles,
            dataFiles: [
                "materials/normal.tex": makeHeaderOnlyTex(formatCode: 12),
                "materials/mask.tex": makeHeaderOnlyTex(formatCode: 8)
            ]
        )
        defer { second.cleanup() }
        let secondPass = try #require(
            WPERenderPipelineBuilder(cacheRootURL: second.root)
                .build(graph: makeGraph()).layers.first?.passes.first
        )
        let firstRequest = try #require(
            try WPEMetalRenderExecutor.makeCompileRequest(for: firstPass, recordFailure: false)
        )
        let secondRequest = try #require(
            try WPEMetalRenderExecutor.makeCompileRequest(for: secondPass, recordFailure: false)
        )
        #expect(secondPass.comboValues["TEX0FORMAT"] == WPEOfficialTextureFormatABI.bc7)
        #expect(firstRequest.sourceHash != secondRequest.sourceHash)
        #expect(firstRequest.translationCacheKey != secondRequest.translationCacheKey)
    }

    @Test("TEXnFORMAT for an FBO slot comes from the layer's authored FBO format")
    func textureFormatsForFBOSlotsComeFromTheGraph() throws {
        // Corpus shape: `bokeh_blur/effect.json` declares an `rg88` target and
        // `glitter/effect.json` an `r8` one. Reporting RGBA8888 for those would
        // send a branch-on-format shader down the wrong channel swizzle.
        func makeGraph(scratchFormat: String) -> WPERenderGraph {
            WPERenderGraph(layers: [
                WPERenderLayer(
                    objectID: "fboformat",
                    objectName: "FBO format probe",
                    imagePath: "normal",
                    materialPath: nil,
                    geometry: .identity,
                    compositeA: "a",
                    compositeB: "b",
                    localFBOs: [
                        WPERenderFBO(name: "_rt_Scratch", scale: 1, format: scratchFormat),
                        WPERenderFBO(name: "_rt_Mask", scale: 1, format: "r8")
                    ],
                    passes: [
                        WPERenderPass(
                            id: "fboformat.0",
                            phase: .effect(file: "effects/format_probe/effect.json"),
                            shader: "effects/format_probe",
                            source: .image("normal"),
                            target: .scene,
                            textures: [
                                1: .fbo("_rt_Scratch"),
                                2: .fbo("_rt_Mask"),
                                3: .fbo("_rt_FullFrameBuffer"),
                                4: .previous
                            ],
                            binds: [:],
                            constants: [:],
                            combos: [:],
                            blending: "normal",
                            cullMode: "nocull",
                            depthTest: "disabled",
                            depthWrite: "disabled"
                        )
                    ]
                )
            ])
        }

        let shaderFiles = [
            "shaders/effects/format_probe.vert": """
            attribute vec3 a_Position;
            void main() { gl_Position = vec4(a_Position, 1.0); }
            """,
            "shaders/effects/format_probe.frag": """
            #include "common_fragment.h"
            void main() { gl_FragColor = vec4(1.0); }
            """
        ]

        let fixture = try makeFixture(files: shaderFiles, dataFiles: [:])
        defer { fixture.cleanup() }
        let builder = WPERenderPipelineBuilder(cacheRootURL: fixture.root)

        let rg88Pass = try #require(
            builder.build(graph: makeGraph(scratchFormat: "rg88")).layers.first?.passes.first
        )
        #expect(rg88Pass.comboValues["TEX1FORMAT"] == WPEOfficialTextureFormatABI.rg88)
        #expect(rg88Pass.comboValues["TEX2FORMAT"] == WPEOfficialTextureFormatABI.r8)
        // A scene alias is not a layer-local FBO; it resolves to the RGBA scene target.
        #expect(rg88Pass.comboValues["TEX3FORMAT"] == WPEOfficialTextureFormatABI.rgba8888)
        #expect(rg88Pass.comboValues["TEX4FORMAT"] == WPEOfficialTextureFormatABI.rgba8888)
        #expect(rg88Pass.shader?.fragmentSource.contains("#define TEX1FORMAT 8") == true)

        // Same shader, different authored target format ⇒ different compile identity,
        // or the two variants would share one cached MSL translation.
        let r16fPass = try #require(
            builder.build(graph: makeGraph(scratchFormat: "r16f")).layers.first?.passes.first
        )
        #expect(r16fPass.comboValues["TEX1FORMAT"] == WPEOfficialTextureFormatABI.r16F)
        let rg88Request = try #require(
            try WPEMetalRenderExecutor.makeCompileRequest(for: rg88Pass, recordFailure: false)
        )
        let r16fRequest = try #require(
            try WPEMetalRenderExecutor.makeCompileRequest(for: r16fPass, recordFailure: false)
        )
        #expect(rg88Request.sourceHash != r16fRequest.sourceHash)
        #expect(rg88Request.translationCacheKey != r16fRequest.translationCacheKey)
    }

    @Test("TEXnFORMAT for a `.previous` slot inherits the pass target's authored FBO format")
    func textureFormatsForPreviousSlotsInheritThePassTargetFormat() throws {
        /// `.previous` samples the prior frame of the pass's OWN target (the
        /// executor rebinds the target's history texture 1:1), so a feedback
        /// pass into an rg1616f FBO must compile with that format, not RGBA.
        func makeGraph(targetFormat: String) -> WPERenderGraph {
            WPERenderGraph(layers: [
                WPERenderLayer(
                    objectID: "prevformat",
                    objectName: "Previous format probe",
                    imagePath: "normal",
                    materialPath: nil,
                    geometry: .identity,
                    compositeA: "a",
                    compositeB: "b",
                    localFBOs: [
                        WPERenderFBO(name: "_rt_Feedback", scale: 1, format: targetFormat),
                        WPERenderFBO(name: "_rt_Aux", scale: 1, format: "r8"),
                    ],
                    passes: [
                        WPERenderPass(
                            id: "prevformat.0",
                            phase: .effect(file: "effects/format_probe/effect.json"),
                            shader: "effects/format_probe",
                            source: .image("normal"),
                            target: .fbo(name: "_rt_Feedback"),
                            textures: [
                                1: .previous,
                                2: .fbo("_rt_Aux"),
                                3: .image("mask"),
                            ],
                            binds: [:],
                            constants: [:],
                            combos: [:],
                            blending: "normal",
                            cullMode: "nocull",
                            depthTest: "disabled",
                            depthWrite: "disabled"
                        ),
                    ]
                ),
            ])
        }

        let shaderFiles = [
            "shaders/effects/format_probe.vert": """
            attribute vec3 a_Position;
            void main() { gl_Position = vec4(a_Position, 1.0); }
            """,
            "shaders/effects/format_probe.frag": """
            #include "common_fragment.h"
            void main() { gl_FragColor = vec4(1.0); }
            """,
        ]

        let fixture = try makeFixture(
            files: shaderFiles,
            dataFiles: ["materials/mask.tex": makeHeaderOnlyTex(formatCode: 8)]
        )
        defer { fixture.cleanup() }
        let builder = WPERenderPipelineBuilder(cacheRootURL: fixture.root)

        let rg1616fPass = try #require(
            builder.build(graph: makeGraph(targetFormat: "rg1616f")).layers.first?.passes.first
        )
        #expect(rg1616fPass.comboValues["TEX1FORMAT"] == WPEOfficialTextureFormatABI.rg1616F)
        // Sibling slots keep their own resolutions alongside the target inheritance.
        #expect(rg1616fPass.comboValues["TEX2FORMAT"] == WPEOfficialTextureFormatABI.r8)
        #expect(rg1616fPass.comboValues["TEX3FORMAT"] == WPEOfficialTextureFormatABI.rg88)

        // Same graph, different authored target format ⇒ different compile identity.
        let r16fPass = try #require(
            builder.build(graph: makeGraph(targetFormat: "r16f")).layers.first?.passes.first
        )
        #expect(r16fPass.comboValues["TEX1FORMAT"] == WPEOfficialTextureFormatABI.r16F)
        let rg1616fRequest = try #require(
            try WPEMetalRenderExecutor.makeCompileRequest(for: rg1616fPass, recordFailure: false)
        )
        let r16fRequest = try #require(
            try WPEMetalRenderExecutor.makeCompileRequest(for: r16fPass, recordFailure: false)
        )
        #expect(rg1616fRequest.sourceHash != r16fRequest.sourceHash)
        #expect(rg1616fRequest.translationCacheKey != r16fRequest.translationCacheKey)

        // A pass whose target has no non-RGBA authored format stays RGBA,
        // matching the pre-existing `.previous` fallback for scene targets.
        let rgbaPass = try #require(
            builder.build(graph: makeGraph(targetFormat: "rgba8888")).layers.first?.passes.first
        )
        #expect(rgbaPass.comboValues["TEX1FORMAT"] == WPEOfficialTextureFormatABI.rgba8888)

        // Regression guard: the target format may influence ONLY the `.previous`
        // slot — every .tex/FBO/sparse slot must resolve identically across
        // target formats, or target plumbing leaked into unrelated compile keys.
        for slot in 0 ..< WPEShaderTranspiler.customTextureSlotCount where slot != 1 {
            let macro = "TEX\(slot)FORMAT"
            #expect(rg1616fPass.comboValues[macro] == rgbaPass.comboValues[macro])
        }
    }

    @Test("SceneScript transform journal overlays current-generation assignments before geometry preparation")
    func sceneScriptTransformJournalGeometryMerge() throws {
        let layer = WPERenderLayer(
            objectID: "mover",
            objectName: "Mover",
            imagePath: "materials/base.png",
            materialPath: nil,
            geometry: WPERenderLayerGeometry(
                origin: SIMD3<Double>(10, 20, 30),
                scale: SIMD3<Double>(1, 1, 1),
                angles: SIMD3<Double>(0, 0, 0),
                alignment: .center,
                size: CGSize(width: 100, height: 50),
                alpha: 1,
                color: SIMD3<Double>(1, 1, 1),
                brightness: 1
            ),
            compositeA: "a",
            compositeB: "b",
            localFBOs: [],
            passes: []
        )
        let pipeline = WPEPreparedRenderPipeline(layers: [
            WPEPreparedRenderLayer(graphLayer: layer, passes: [])
        ])
        var animated = WPEMetalSceneRenderer.LiveScriptTransforms()
        animated.origins["mover"] = SIMD3<Double>(11, 22, 33)
        animated.scales["mover"] = SIMD3<Double>(1.25, 1.5, 1.75)
        animated.angles["mover"] = SIMD3<Double>(0.1, 0.2, 0.3)

        var journal = WPESceneScriptTransformMutationJournal()
        journal.record(
            WPELayerScriptTransformMutation(origin: SIMD3<Double>(100, 200, 300)),
            objectID: "mover",
            generation: 7
        )
        // Same objectID from a retired load must not affect generation 7.
        journal.record(
            WPELayerScriptTransformMutation(scale: SIMD3<Double>(9, 9, 9)),
            objectID: "mover",
            generation: 6
        )
        let merged = journal.applying(to: animated, generation: 7)
        let geometry = try #require(pipeline.applyingLayerTransforms(
            origins: merged.origins,
            scales: merged.scales,
            angles: merged.angles
        ).layers.first).graphLayer.geometry

        #expect(geometry.origin == SIMD3<Double>(100, 200, 300))
        #expect(geometry.scale == SIMD3<Double>(1.25, 1.5, 1.75))
        #expect(geometry.angles == SIMD3<Double>(0.1, 0.2, 0.3))

        journal.record(
            WPELayerScriptTransformMutation(angles: SIMD3<Double>(0, 0, 90)),
            objectID: "mover",
            generation: 7
        )
        let angleMerged = journal.applying(to: animated, generation: 7)
        #expect(abs((angleMerged.angles["mover"]?.z ?? 0) - .pi / 2) < 0.000_001)
    }

    @Test("Normalizes built-in shader aliases consistently")
    func normalizesBuiltinShaderAliasesConsistently() {
        #expect(WPEBuiltinShaderName.normalized("materials/util/solidlayer.json") == "solidlayer")
        #expect(WPEBuiltinShaderName.normalized("materials/effects/blur/blur.json") == "effect_blur")
        #expect(WPEBuiltinShaderName.normalized("composelayer") == "compose")
        #expect(WPEBuiltinShaderName.normalized("materials/util/composelayer.json") == "compose")
        #expect(WPEBuiltinShaderName.normalized("effects/distort/distort") == "effect_water")
        #expect(WPEBuiltinShaderName.normalized("genericimage2") == "genericimage2")
        #expect(WPEBuiltinShaderName.normalized("generic4") == "genericimage4")
        #expect(WPEBuiltinShaderName.normalized("genericimage2", genericImageAsCopy: true) == "copy")
        #expect(WPEBuiltinShaderName.normalized("genericimage_custom", genericImageAsCopy: true) == "genericimage_custom")
    }

    @Test("Script-driven alpha/transform rewrites keep shape:quad points")
    func scriptAlphaAndTransformRewritesKeepShapeQuadPoints() throws {
        let points = [
            SIMD2<Double>(0.4, 0.25),
            SIMD2<Double>(0.6, 0.25),
            SIMD2<Double>(0.94451, 0.83623),
            SIMD2<Double>(0.09498, 0.88795)
        ]
        let layer = WPERenderLayer(
            objectID: "96",
            objectName: "beam",
            imagePath: "materials/base.png",
            materialPath: nil,
            geometry: WPERenderLayerGeometry(
                origin: SIMD3<Double>(100, 200, 0),
                scale: SIMD3<Double>(1, 1, 1),
                angles: SIMD3<Double>(0, 0, 0),
                alignment: .center,
                size: CGSize(width: 200, height: 100),
                alpha: 1,
                color: SIMD3<Double>(1, 1, 1),
                brightness: 1,
                shapePoints: points
            ),
            compositeA: "_rt_imageLayerComposite_96_a",
            compositeB: "_rt_imageLayerComposite_96_b",
            localFBOs: [],
            passes: []
        )

        let pipeline = WPEPreparedRenderPipeline(layers: [
            WPEPreparedRenderLayer(graphLayer: layer, passes: [])
        ])

        let faded = try #require(pipeline.applyingLayerAlpha(["96": 0.5]).layers.first).graphLayer
        #expect(faded.geometry.alpha == 0.5)
        #expect(faded.geometry.shapePoints == points)

        let animatedColor = WPESceneAnimatedValue(
            animation: WPESceneNumericAnimation(
                tracks: [[.init(frame: 0, value: 0)], [.init(frame: 0, value: 1)], [.init(frame: 0, value: 0)]],
                fps: 30, length: 30, mode: "loop", wrapLoop: true
            ),
            scalarFallback: nil,
            vectorFallback: [0, 1, 0]
        )
        let animatedLayer = WPERenderLayer(
            objectID: "96",
            objectName: "beam",
            imagePath: "materials/base.png",
            materialPath: nil,
            geometry: WPERenderLayerGeometry(
                origin: SIMD3<Double>(100, 200, 0),
                scale: SIMD3<Double>(1, 1, 1),
                angles: SIMD3<Double>(0, 0, 0),
                alignment: .center,
                size: CGSize(width: 200, height: 100),
                alpha: 1,
                color: SIMD3<Double>(1, 1, 1),
                colorAnimation: animatedColor,
                brightness: 1
            ),
            compositeA: "_rt_imageLayerComposite_96_a",
            compositeB: "_rt_imageLayerComposite_96_b",
            localFBOs: [],
            passes: []
        )
        let animatedPipeline = WPEPreparedRenderPipeline(layers: [
            WPEPreparedRenderLayer(graphLayer: animatedLayer, passes: [])
        ])
        let movedAnimated = try #require(animatedPipeline.applyingLayerTransforms(
            origins: ["96": SIMD3<Double>(150, 250, 0)],
            scales: [:],
            angles: [:]
        ).layers.first).graphLayer
        #expect(
            movedAnimated.geometry.colorAnimation != nil,
            "a live transform must not discard the layer's authored color animation"
        )

        let tinted = try #require(
            pipeline.applyingLayerColor(["96": SIMD3<Double>(0.2, 0.4, 0.6)]).layers.first
        ).graphLayer
        #expect(tinted.geometry.color == SIMD3<Double>(0.2, 0.4, 0.6))
        #expect(tinted.geometry.colorAnimation == nil, "the override must not be re-collapsed per frame")
        #expect(tinted.geometry.alpha == 1, "color override must not disturb alpha")

        let moved = try #require(pipeline.applyingLayerTransforms(
            origins: ["96": SIMD3<Double>(150, 250, 0)],
            scales: [:],
            angles: [:]
        ).layers.first).graphLayer
        #expect(moved.geometry.origin == SIMD3<Double>(150, 250, 0))
        #expect(moved.geometry.shapePoints == points)
    }

    @Test("Builds prepared shader programs from render graph passes")
    func buildsPreparedShaderProgramsFromGraphPasses() throws {
        let fixture = try makeFixture(files: [
            "shaders/effects/custom.vert": """
            // [COMBO] {"combo":"KERNEL","default":1}
            #include "common.h"
            void main() { gl_Position = vec4(0.0); }
            """,
            "shaders/effects/custom.frag": """
            uniform sampler2D g_Texture0;
            void main() { gl_FragColor = texSample2D(g_Texture0, vec2(0.5)); }
            """
        ])
        defer { fixture.cleanup() }

        let graph = WPERenderGraph(layers: [
            WPERenderLayer(
                objectID: "7",
                objectName: "Layer",
                imagePath: "materials/base.png",
                materialPath: "materials/base.json",
                geometry: .identity,
                compositeA: "_rt_imageLayerComposite_7_a",
                compositeB: "_rt_imageLayerComposite_7_b",
                localFBOs: [],
                passes: [
                    WPERenderPass(
                        id: "7.0",
                        phase: .material,
                        shader: "genericimage2",
                        source: .image("materials/base.png"),
                        target: .layerComposite(name: "_rt_imageLayerComposite_7_a"),
                        textures: [:],
                        binds: [:],
                        constants: [:],
                        combos: [:],
                        blending: "normal",
                        cullMode: "nocull",
                        depthTest: "disabled",
                        depthWrite: "disabled"
                    ),
                    WPERenderPass(
                        id: "7.1",
                        phase: .effect(file: "effects/custom/effect.json"),
                        shader: "effects/custom",
                        source: .fbo("_rt_imageLayerComposite_7_a"),
                        target: .scene,
                        textures: [:],
                        binds: [0: .previous],
                        constants: [:],
                        combos: ["KERNEL": 2],
                        blending: "normal",
                        cullMode: "nocull",
                        depthTest: "disabled",
                        depthWrite: "disabled"
                    )
                ]
            )
        ])

        let pipeline = try WPERenderPipelineBuilder(cacheRootURL: fixture.root).build(graph: graph)
        let layer = try #require(pipeline.layers.first)

        #expect(layer.passes.map(\.pass.shader) == ["genericimage2", "effects/custom"])
        #expect(layer.passes[0].shader?.isBuiltin == true)
        #expect(layer.passes[1].shader?.vertexSource.contains("#define KERNEL 2") == true)
        #expect(layer.passes[1].shader?.vertexSource.contains("wpe_common_included") == true)
        #expect(layer.passes[1].shader?.vertexSource.contains("#include") == false)
        #expect(layer.passes[1].shader?.fragmentSource.contains("#define texSample2D") == true)
    }

    @Test("Texture-declared combo (MASK) auto-enables when its sampler slot is bound")
    func textureDeclaredComboEnablesWhenSamplerSlotBound() throws {
        let fixture = try makeFixture(files: [
            "shaders/effects/masked.vert": """
            attribute vec3 a_Position;
            void main() { gl_Position = vec4(a_Position, 1.0); }
            """,
            "shaders/effects/masked.frag": """
            uniform sampler2D g_Texture0; // {"hidden":true}
            uniform sampler2D g_Texture1; // {"mode":"opacitymask","combo":"MASK"}
            void main() {
            #if MASK
                float mask = texSample2D(g_Texture1, vec2(0.5)).r;
            #else
                float mask = 1.0;
            #endif
                gl_FragColor = texSample2D(g_Texture0, vec2(0.5)) * mask;
            }
            """
        ])
        defer { fixture.cleanup() }

        let graph = WPERenderGraph(layers: [
            WPERenderLayer(
                objectID: "9",
                objectName: "Layer",
                imagePath: "materials/base.png",
                materialPath: "materials/base.json",
                geometry: .identity,
                compositeA: "_rt_imageLayerComposite_9_a",
                compositeB: "_rt_imageLayerComposite_9_b",
                localFBOs: [],
                passes: [
                    WPERenderPass(
                        id: "9.0",
                        phase: .material,
                        shader: "genericimage2",
                        source: .image("materials/base.png"),
                        target: .layerComposite(name: "_rt_imageLayerComposite_9_a"),
                        textures: [:],
                        binds: [:],
                        constants: [:],
                        combos: [:],
                        blending: "normal",
                        cullMode: "nocull",
                        depthTest: "disabled",
                        depthWrite: "disabled"
                    ),
                    WPERenderPass(
                        id: "9.1",
                        phase: .effect(file: "effects/masked/effect.json"),
                        shader: "effects/masked",
                        source: .fbo("_rt_imageLayerComposite_9_a"),
                        target: .scene,
                        textures: [1: .asset("masks/waterwaves_mask")],
                        binds: [:],
                        constants: [:],
                        combos: [:],
                        blending: "normal",
                        cullMode: "nocull",
                        depthTest: "disabled",
                        depthWrite: "disabled"
                    )
                ]
            )
        ])

        let pipeline = try WPERenderPipelineBuilder(cacheRootURL: fixture.root).build(graph: graph)
        let effect = try #require(pipeline.layers.first?.passes.last?.shader)
        #expect(effect.fragmentSource.contains("#define MASK 1"))
    }

    @Test("Loads puppet model from render graph layer path")
    func loadsPuppetModelFromRenderGraphLayerPath() throws {
        let fixture = try makeFixture(dataFiles: [
            "models/layer_puppet.mdl": makeSingleTrianglePuppetMDL()
        ])
        defer { fixture.cleanup() }

        let graph = WPERenderGraph(layers: [
            WPERenderLayer(
                objectID: "7",
                objectName: "Layer",
                imagePath: "models/layer.json",
                materialPath: "materials/layer.json",
                puppetPath: "models/layer_puppet.mdl",
                geometry: .identity,
                compositeA: "_rt_imageLayerComposite_7_a",
                compositeB: "_rt_imageLayerComposite_7_b",
                localFBOs: [],
                passes: [
                    WPERenderPass(
                        id: "7.0",
                        phase: .material,
                        shader: "generic4",
                        source: .image("materials/layer.png"),
                        target: .layerComposite(name: "_rt_imageLayerComposite_7_a"),
                        textures: [:],
                        binds: [:],
                        constants: [:],
                        combos: [:],
                        blending: "normal",
                        cullMode: "nocull",
                        depthTest: "disabled",
                        depthWrite: "disabled"
                    )
                ]
            )
        ])

        let pipeline = try WPERenderPipelineBuilder(cacheRootURL: fixture.root).build(graph: graph)
        let mesh = try #require(pipeline.layers.first?.puppetModel?.meshes.first)

        #expect(mesh.vertices.count == 3)
        #expect(mesh.indices == [0, 1, 2])
        #expect(mesh.parts == [WPEPuppetMeshPart(id: 7, start: 0, count: 3)])
    }

    @Test("A pre-v19 puppet generation refuses the whole scene instead of rendering it misaligned")
    func legacyPuppetGenerationRefusesScene() throws {
        let fixture = try makeFixture(dataFiles: [
            "models/layer_puppet.mdl": makeLegacyPuppetMDLBelow19()
        ])
        defer { fixture.cleanup() }

        let graph = WPERenderGraph(layers: [puppetLayer()])

        #expect {
            _ = try WPERenderPipelineBuilder(cacheRootURL: fixture.root).build(graph: graph)
        } throws: { error in
            guard case SceneRenderingError.metalRendererUnsupported(let reason) = error else { return false }
            return reason.contains("MDLV0017")
        }
    }

    @Test("An MDLV0019 character-sheet puppet loads (it is assembled by skinning, not refused)")
    func mdlv19PuppetLoadsInsteadOfRefusing() throws {
        var mdl = makeSingleTrianglePuppetMDL()
        mdl.replaceSubrange(0..<8, with: "MDLV0019".utf8)
        let fixture = try makeFixture(dataFiles: [
            "models/layer_puppet.mdl": mdl
        ])
        defer { fixture.cleanup() }

        let graph = WPERenderGraph(layers: [puppetLayer()])
        let pipeline = try WPERenderPipelineBuilder(cacheRootURL: fixture.root).build(graph: graph)
        let model = try #require(pipeline.layers.first?.puppetModel)
        #expect(model.version == 19)
    }

    private func puppetLayer() -> WPERenderLayer {
        WPERenderLayer(
            objectID: "7",
            objectName: "Layer",
            imagePath: "models/layer.json",
            materialPath: "materials/layer.json",
            puppetPath: "models/layer_puppet.mdl",
            geometry: .identity,
            compositeA: "_rt_imageLayerComposite_7_a",
            compositeB: "_rt_imageLayerComposite_7_b",
            localFBOs: [],
            passes: [
                WPERenderPass(
                    id: "7.0",
                    phase: .material,
                    shader: "generic4",
                    source: .image("materials/layer.png"),
                    target: .layerComposite(name: "_rt_imageLayerComposite_7_a"),
                    textures: [:],
                    binds: [:],
                    constants: [:],
                    combos: [:],
                    blending: "normal",
                    cullMode: "nocull",
                    depthTest: "disabled",
                    depthWrite: "disabled"
                )
            ]
        )
    }

    @Test("MDLV16 direct scene model loads as static mesh instead of legacy puppet")
    func mdlv16DirectSceneModelLoadsAsStaticMesh() throws {
        let fixture = try makeFixture(dataFiles: [
            "models/ring.mdl": makeSingleTriangleMDLV16SceneModel()
        ])
        defer { fixture.cleanup() }

        let graph = WPERenderGraph(layers: [
            WPERenderLayer(
                objectID: "ring",
                objectName: "Ring",
                imagePath: "models/ring.mdl",
                materialPath: "materials/ring.json",
                puppetPath: "models/ring.mdl",
                geometry: .identity,
                compositeA: "_rt_imageLayerComposite_ring_a",
                compositeB: "_rt_imageLayerComposite_ring_b",
                localFBOs: [],
                passes: [
                    WPERenderPass(
                        id: "ring.0",
                        phase: .material,
                        shader: "generic4",
                        source: .image("models/ring.mdl"),
                        target: .scene,
                        textures: [:],
                        binds: [:],
                        constants: [:],
                        combos: [:],
                        blending: "normal",
                        cullMode: "nocull",
                        depthTest: "enabled",
                        depthWrite: "enabled"
                    )
                ]
            )
        ])

        let pipeline = try WPERenderPipelineBuilder(cacheRootURL: fixture.root).build(graph: graph)
        let model = try #require(pipeline.layers.first?.puppetModel)

        #expect(model.version == 16)
        #expect(model.meshes.first?.materialPath == "materials/models/Hollow Cylinder/diffuse_0.json")
    }

    @Test("Loads puppet model through dependency mounts")
    func loadsPuppetModelThroughDependencyMounts() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let dependencyRoot = fixture.root.appendingPathComponent("dependency-123", isDirectory: true)
        let modelURL = dependencyRoot.appendingPathComponent("models/layer_puppet.mdl")
        try FileManager.default.createDirectory(
            at: modelURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try makeSingleTrianglePuppetMDL().write(to: modelURL)

        let graph = WPERenderGraph(layers: [
            WPERenderLayer(
                objectID: "7",
                objectName: "Layer",
                imagePath: "models/layer.json",
                materialPath: "materials/layer.json",
                puppetPath: "../123/models/layer_puppet.mdl",
                geometry: .identity,
                compositeA: "_rt_imageLayerComposite_7_a",
                compositeB: "_rt_imageLayerComposite_7_b",
                localFBOs: [],
                passes: [
                    WPERenderPass(
                        id: "7.0",
                        phase: .material,
                        shader: "generic4",
                        source: .image("materials/layer.png"),
                        target: .layerComposite(name: "_rt_imageLayerComposite_7_a"),
                        textures: [:],
                        binds: [:],
                        constants: [:],
                        combos: [:],
                        blending: "normal",
                        cullMode: "nocull",
                        depthTest: "disabled",
                        depthWrite: "disabled"
                    )
                ]
            )
        ])

        let pipeline = try WPERenderPipelineBuilder(
            cacheRootURL: fixture.root,
            dependencyMounts: [WPEAssetMount(workshopID: "123", rootURL: dependencyRoot)]
        ).build(graph: graph)
        let mesh = try #require(pipeline.layers.first?.puppetModel?.meshes.first)

        #expect(mesh.vertices.count == 3)
        #expect(mesh.indices == [0, 1, 2])
    }

    @Test("Shader annotation numeric defaults stay numeric")
    func shaderAnnotationNumericDefaultsStayNumeric() throws {
        let fixture = try makeFixture(files: [
            "shaders/effects/custom.vert": """
            void main() { gl_Position = vec4(0.0); }
            """,
            "shaders/effects/custom.frag": """
            uniform sampler2D g_Texture0;
            uniform float u_alpha; // {"material":"Opacity","default":1,"range":[0,1]}
            void main() { gl_FragColor = texSample2D(g_Texture0, vec2(0.5)) * u_alpha; }
            """
        ])
        defer { fixture.cleanup() }

        let graph = WPERenderGraph(layers: [
            WPERenderLayer(
                objectID: "7",
                objectName: "Layer",
                imagePath: "materials/base.png",
                materialPath: "materials/base.json",
                geometry: .identity,
                compositeA: "_rt_imageLayerComposite_7_a",
                compositeB: "_rt_imageLayerComposite_7_b",
                localFBOs: [],
                passes: [
                    WPERenderPass(
                        id: "7.0",
                        phase: .effect(file: "effects/custom/effect.json"),
                        shader: "effects/custom",
                        source: .image("materials/base.png"),
                        target: .scene,
                        textures: [:],
                        binds: [:],
                        constants: [:],
                        combos: [:],
                        blending: "normal",
                        cullMode: "nocull",
                        depthTest: "disabled",
                        depthWrite: "disabled"
                    )
                ]
            )
        ])

        let pipeline = try WPERenderPipelineBuilder(cacheRootURL: fixture.root).build(graph: graph)
        let alpha = try #require(pipeline.layers.first?.passes.first?.uniformValues["u_alpha"])

        #expect(alpha.numberValue == 1)
    }

    @Test("WPE shader prelude defines M_PI_2 as full turn")
    func shaderPreludeDefinesMPI2AsFullTurn() throws {
        let fixture = try makeFixture(files: [
            "shaders/effects/shake.vert": """
            void main() { gl_Position = vec4(0.0); }
            """,
            "shaders/effects/shake.frag": """
            #include "common.h"
            uniform float g_Time;
            void main() {
                float offset = sin(frac(g_Time / M_PI_2) * M_PI_2);
                gl_FragColor = vec4(offset);
            }
            """
        ])
        defer { fixture.cleanup() }

        let graph = WPERenderGraph(layers: [
            WPERenderLayer(
                objectID: "1",
                objectName: "Layer",
                imagePath: "materials/base.png",
                materialPath: nil,
                geometry: .identity,
                compositeA: "a",
                compositeB: "b",
                localFBOs: [],
                passes: [
                    WPERenderPass(
                        id: "1.0",
                        phase: .effect(file: "effects/shake/effect.json"),
                        shader: "effects/shake",
                        source: .image("materials/base.png"),
                        target: .scene,
                        textures: [:],
                        binds: [:],
                        constants: [:],
                        combos: [:],
                        blending: "normal",
                        cullMode: "nocull",
                        depthTest: "disabled",
                        depthWrite: "disabled"
                    )
                ]
            )
        ])

        let pipeline = try WPERenderPipelineBuilder(cacheRootURL: fixture.root).build(graph: graph)
        let fragment = try #require(pipeline.layers.first?.passes.first?.shader?.fragmentSource)

        #expect(fragment.contains("#define M_PI_2 6.28318530717958647692"))
    }

    @Test("Missing shader source is reported with the pass shader name")
    func missingShaderSourceReportsName() throws {
        let fixture = try makeFixture(files: [:])
        defer { fixture.cleanup() }

        let pass = WPERenderPass(
            id: "1.0",
            phase: .effect(file: "effects/missing/effect.json"),
            shader: "effects/missing",
            source: .image("materials/base.png"),
            target: .scene,
            textures: [:],
            binds: [:],
            constants: [:],
            combos: [:],
            blending: "normal",
            cullMode: "nocull",
            depthTest: "disabled",
            depthWrite: "disabled"
        )
        let graph = WPERenderGraph(layers: [
            WPERenderLayer(
                objectID: "1",
                objectName: "Layer",
                imagePath: "materials/base.png",
                materialPath: nil,
                geometry: .identity,
                compositeA: "a",
                compositeB: "b",
                localFBOs: [],
                passes: [pass]
            )
        ])

        #expect(throws: WPERenderPipelineError.self) {
            _ = try WPERenderPipelineBuilder(cacheRootURL: fixture.root).build(graph: graph)
        }
    }

    @Test("Expands WPE composite helper include used by blur combine shaders")
    func expandsCompositeHelperInclude() throws {
        let fixture = try makeFixture(files: [
            "shaders/effects/blur_combine.vert": """
            void main() { gl_Position = vec4(0.0); }
            """,
            "shaders/effects/blur_combine.frag": """
            // [COMBO] {"combo":"COMPOSITE","default":0}
            #include "common_composite.h"
            uniform sampler2D g_Texture0;
            uniform vec4 g_Texture0Resolution;
            void main() {
                vec2 uv = ApplyCompositeOffset(vec2(0.5), g_Texture0Resolution.xy);
                gl_FragColor = ApplyComposite(vec4(0.0), texSample2D(g_Texture0, uv));
            }
            """
        ])
        defer { fixture.cleanup() }

        let graph = WPERenderGraph(layers: [
            WPERenderLayer(
                objectID: "1",
                objectName: "Layer",
                imagePath: "materials/base.png",
                materialPath: nil,
                geometry: .identity,
                compositeA: "a",
                compositeB: "b",
                localFBOs: [],
                passes: [
                    WPERenderPass(
                        id: "1.0",
                        phase: .effect(file: "effects/blur/effect.json"),
                        shader: "effects/blur_combine",
                        source: .image("materials/base.png"),
                        target: .scene,
                        textures: [:],
                        binds: [:],
                        constants: [:],
                        combos: [:],
                        blending: "normal",
                        cullMode: "nocull",
                        depthTest: "disabled",
                        depthWrite: "disabled"
                    )
                ]
            )
        ])

        let pipeline = try WPERenderPipelineBuilder(cacheRootURL: fixture.root).build(graph: graph)
        let fragmentSource = try #require(pipeline.layers.first?.passes.first?.shader?.fragmentSource)

        #expect(fragmentSource.contains("wpe_common_composite_included"))
        #expect(fragmentSource.contains("vec2 ApplyCompositeOffset"))
        #expect(fragmentSource.contains("vec4 ApplyComposite"))
        #expect(fragmentSource.contains("#include") == false)
    }

    @Test("common_blur.h provides radial blur helpers used by blur_radial_gaussian")
    func commonBlurProvidesRadialBlurHelpers() throws {
        let fixture = try makeFixture(files: [
            "shaders/effects/blur_radial_gaussian.vert": """
            void main() { gl_Position = vec4(0.0); }
            """,
            "shaders/effects/blur_radial_gaussian.frag": """
            // [COMBO] {"combo":"KERNEL","default":0}
            #include "common_blur.h"
            varying vec2 v_TexCoord;
            uniform sampler2D g_Texture0;
            uniform float u_Scale;
            uniform vec2 u_Center;
            void main() {
            #if KERNEL == 0
                vec4 albedo = blurRadial13a(v_TexCoord.xy, u_Center, u_Scale);
            #endif
                gl_FragColor = albedo;
            }
            """
        ])
        defer { fixture.cleanup() }

        let graph = WPERenderGraph(layers: [
            WPERenderLayer(
                objectID: "1",
                objectName: "Layer",
                imagePath: "materials/base.png",
                materialPath: nil,
                geometry: .identity,
                compositeA: "a",
                compositeB: "b",
                localFBOs: [],
                passes: [
                    WPERenderPass(
                        id: "1.0",
                        phase: .effect(file: "effects/blur_radial/effect.json"),
                        shader: "effects/blur_radial_gaussian",
                        source: .image("materials/base.png"),
                        target: .scene,
                        textures: [:],
                        binds: [:],
                        constants: [:],
                        combos: [:],
                        blending: "normal",
                        cullMode: "nocull",
                        depthTest: "disabled",
                        depthWrite: "disabled"
                    )
                ]
            )
        ])

        let pipeline = try WPERenderPipelineBuilder(cacheRootURL: fixture.root).build(graph: graph)
        let pass = try #require(pipeline.layers.first?.passes.first)
        let shader = try #require(pass.shader)
        let result = try WPEShaderTranspiler.translateFragment(
            shaderName: shader.name,
            preprocessedSource: shader.fragmentSource,
            comboValues: pass.comboValues
        )

        #expect(result.mslSource.contains("blurRadial13a"))
        let device = try #require(MTLCreateSystemDefaultDevice())
        let opts = MTLCompileOptions()
        opts.languageVersion = .version3_0
        _ = try device.makeLibrary(source: result.mslSource, options: opts)
    }

    @Test("Staged official headers take precedence over builtin fallbacks")
    func stagedOfficialHeadersPrecedeBuiltinFallbacks() throws {
        let fixture = try makeFixture(files: [
            "shaders/common_vertex.h": "#define OFFICIAL_COMMON_VERTEX 1",
            "shaders/common_perspective.h": "#define OFFICIAL_COMMON_PERSPECTIVE 1",
            "shaders/common_blur.h": "#define OFFICIAL_COMMON_BLUR 1",
            "shaders/common_fragment.h": "#define OFFICIAL_COMMON_FRAGMENT 1",
            "shaders/common_blending.h": "#define OFFICIAL_COMMON_BLENDING 1",
            "shaders/effects/header_probe.vert": """
            #include "common_vertex.h"
            #include "common_perspective.h"
            void main() { gl_Position = vec4(0.0); }
            """,
            "shaders/effects/header_probe.frag": """
            #include "common_blur.h"
            #include "common_fragment.h"
            #include "common_blending.h"
            void main() { gl_FragColor = vec4(1.0); }
            """
        ])
        defer { fixture.cleanup() }

        let graph = WPERenderGraph(layers: [
            WPERenderLayer(
                objectID: "1",
                objectName: "Layer",
                imagePath: "materials/base.png",
                materialPath: nil,
                geometry: .identity,
                compositeA: "a",
                compositeB: "b",
                localFBOs: [],
                passes: [WPERenderPass(
                    id: "1.0",
                    phase: .effect(file: "effects/header_probe/effect.json"),
                    shader: "effects/header_probe",
                    source: .image("materials/base.png"),
                    target: .scene,
                    textures: [:],
                    binds: [:],
                    constants: [:],
                    combos: [:],
                    blending: "normal",
                    cullMode: "nocull",
                    depthTest: "disabled",
                    depthWrite: "disabled"
                )]
            )
        ])

        let pipeline = try WPERenderPipelineBuilder(cacheRootURL: fixture.root).build(graph: graph)
        let shader = try #require(pipeline.layers.first?.passes.first?.shader)
        #expect(shader.vertexSource.contains("OFFICIAL_COMMON_VERTEX"))
        #expect(shader.vertexSource.contains("OFFICIAL_COMMON_PERSPECTIVE"))
        #expect(shader.fragmentSource.contains("OFFICIAL_COMMON_BLUR"))
        #expect(shader.fragmentSource.contains("OFFICIAL_COMMON_FRAGMENT"))
        #expect(shader.fragmentSource.contains("OFFICIAL_COMMON_BLENDING"))
        #expect(!shader.vertexSource.contains("wpe_common_vertex_included"))
        #expect(!shader.vertexSource.contains("wpe_common_perspective_included"))
        #expect(!shader.fragmentSource.contains("wpe_common_blur_included"))
        #expect(!shader.fragmentSource.contains("wpe_common_fragment_included"))
        #expect(!shader.fragmentSource.contains("wpe_common_blending_included"))
    }

    @Test("Builtin composite resolves the canonical compile-time blending ABI")
    func builtinCompositeUsesResolvedBlendingHeader() throws {
        let fixture = try makeFixture(files: [
            "shaders/common_blending.h": """
            #define OFFICIAL_BLEND_ABI 1
            vec3 ApplyBlending(const int ignoredMode, in vec3 base, in vec3 blend, in float opacity) {
            #if BLENDMODE == 31
                return base + blend * opacity;
            #else
                return mix(base, blend, opacity);
            #endif
            }
            """,
            "shaders/effects/composite_probe.vert": "void main() { gl_Position = vec4(0.0); }",
            "shaders/effects/composite_probe.frag": """
            // [COMBO] {"combo":"COMPOSITE","default":1}
            // [COMBO] {"combo":"BLENDMODE","default":31}
            #include "common_composite.h"
            void main() { gl_FragColor = ApplyComposite(vec4(0.1), vec4(0.2)); }
            """,
        ])
        defer { fixture.cleanup() }

        let graph = WPERenderGraph(layers: [WPERenderLayer(
            objectID: "1", objectName: "Layer", imagePath: "materials/base.png",
            materialPath: nil, geometry: .identity, compositeA: "a", compositeB: "b",
            localFBOs: [], passes: [WPERenderPass(
                id: "1.0", phase: .effect(file: "effects/composite_probe/effect.json"),
                shader: "effects/composite_probe", source: .image("materials/base.png"),
                target: .scene, textures: [:], binds: [:], constants: [:], combos: [:],
                blending: "normal", cullMode: "nocull", depthTest: "disabled", depthWrite: "disabled"
            )]
        )])

        let pipeline = try WPERenderPipelineBuilder(cacheRootURL: fixture.root).build(graph: graph)
        let pass = try #require(pipeline.layers.first?.passes.first)
        let shader = try #require(pass.shader)
        #expect(shader.fragmentSource.contains("OFFICIAL_BLEND_ABI"))
        #expect(!shader.fragmentSource.contains("wpe_common_blending_included"))
        #expect(shader.fragmentSource.contains("#include") == false)

        let result = try WPEShaderTranspiler.translateFragment(
            shaderName: shader.name,
            preprocessedSource: shader.fragmentSource,
            comboValues: pass.comboValues
        )
        let device = try #require(MTLCreateSystemDefaultDevice())
        let options = MTLCompileOptions()
        options.languageVersion = .version3_0
        _ = try device.makeLibrary(source: result.mslSource, options: options)
    }

    @Test("Resolved headers expand once per shader stage even without include guards")
    func resolvedHeadersAreIncludeOnce() throws {
        let fixture = try makeFixture(files: [
            "shaders/common_blur.h": "float official_once_marker = 1.0;",
            "shaders/effects/nested.h": "#include \"common_blur.h\"",
            "shaders/effects/include_once.vert": "void main() { gl_Position = vec4(0.0); }",
            "shaders/effects/include_once.frag": """
            #include "nested.h"
            #include "common_blur.h"
            void main() { gl_FragColor = vec4(official_once_marker); }
            """
        ])
        defer { fixture.cleanup() }

        let graph = WPERenderGraph(layers: [
            WPERenderLayer(
                objectID: "1",
                objectName: "Layer",
                imagePath: "materials/base.png",
                materialPath: nil,
                geometry: .identity,
                compositeA: "a",
                compositeB: "b",
                localFBOs: [],
                passes: [WPERenderPass(
                    id: "1.0",
                    phase: .effect(file: "effects/include_once/effect.json"),
                    shader: "effects/include_once",
                    source: .image("materials/base.png"),
                    target: .scene,
                    textures: [:],
                    binds: [:],
                    constants: [:],
                    combos: [:],
                    blending: "normal",
                    cullMode: "nocull",
                    depthTest: "disabled",
                    depthWrite: "disabled"
                )]
            )
        ])

        let pipeline = try WPERenderPipelineBuilder(cacheRootURL: fixture.root).build(graph: graph)
        let source = try #require(pipeline.layers.first?.passes.first?.shader?.fragmentSource)
        #expect(source.components(separatedBy: "official_once_marker = 1.0").count - 1 == 1)
        #expect(source.contains("include-once: shaders/common_blur.h"))
    }

    @Test("Expands common_fragment.h ConvertSampleR8 used by WPE 2.8 font.frag")
    func expandsCommonFragmentConvertSampleR8() throws {
        let fixture = try makeFixture(files: [
            "shaders/effects/font_like.vert": """
            void main() { gl_Position = vec4(0.0); }
            """,
            "shaders/effects/font_like.frag": """
            #include "common_fragment.h"
            uniform sampler2D g_Texture0;
            uniform vec4 g_Color4;
            void main() {
                float a = ConvertSampleR8(texSample2D(g_Texture0, vec2(0.5)));
                gl_FragColor = vec4(g_Color4.rgb, a * g_Color4.a);
            }
            """
        ])
        defer { fixture.cleanup() }

        let graph = WPERenderGraph(layers: [
            WPERenderLayer(
                objectID: "1",
                objectName: "Layer",
                imagePath: "materials/base.png",
                materialPath: nil,
                geometry: .identity,
                compositeA: "a",
                compositeB: "b",
                localFBOs: [],
                passes: [
                    WPERenderPass(
                        id: "1.0",
                        phase: .effect(file: "effects/font/effect.json"),
                        shader: "effects/font_like",
                        source: .image("materials/base.png"),
                        target: .scene,
                        textures: [:],
                        binds: [:],
                        constants: [:],
                        combos: [:],
                        blending: "normal",
                        cullMode: "nocull",
                        depthTest: "disabled",
                        depthWrite: "disabled"
                    )
                ]
            )
        ])

        let pipeline = try WPERenderPipelineBuilder(cacheRootURL: fixture.root).build(graph: graph)
        let fragmentSource = try #require(pipeline.layers.first?.passes.first?.shader?.fragmentSource)

        #expect(fragmentSource.contains("wpe_common_fragment_included"))
        #expect(fragmentSource.contains("float ConvertSampleR8"))
        #expect(fragmentSource.contains("#include") == false)
    }

    @Test("common_fragment.h FORMAT_* constants keep formatcombo branches off the R8 path")
    func commonFragmentFormatConstantsKeepFormatcomboBranchesOffR8() throws {
        let fixture = try makeFixture(files: [
            "shaders/effects/shafts_like.vert": """
            attribute vec3 a_Position;
            void main() { gl_Position = vec4(a_Position, 1.0); }
            """,
            "shaders/effects/shafts_like.frag": """
            #include "common_fragment.h"
            uniform sampler2D g_Texture2; // {"default":"gradient/gradient_iridescent","formatcombo":true}
            void main() {
            #if TEX2FORMAT == FORMAT_R8 || TEX2FORMAT == FORMAT_RG88
                vec3 gradColor = texSample2D(g_Texture2, vec2(0.5)).rrr;
            #else
                vec3 gradColor = texSample2D(g_Texture2, vec2(0.5)).rgb;
            #endif
                gl_FragColor = vec4(gradColor, 1.0);
            }
            """
        ])
        defer { fixture.cleanup() }

        let graph = WPERenderGraph(layers: [
            WPERenderLayer(
                objectID: "1",
                objectName: "Layer",
                imagePath: "materials/base.png",
                materialPath: nil,
                geometry: .identity,
                compositeA: "a",
                compositeB: "b",
                localFBOs: [],
                passes: [
                    WPERenderPass(
                        id: "1.0",
                        phase: .effect(file: "effects/shafts/effect.json"),
                        shader: "effects/shafts_like",
                        source: .image("materials/base.png"),
                        target: .scene,
                        textures: [:],
                        binds: [:],
                        constants: [:],
                        combos: [:],
                        blending: "normal",
                        cullMode: "nocull",
                        depthTest: "disabled",
                        depthWrite: "disabled"
                    )
                ]
            )
        ])

        let pipeline = try WPERenderPipelineBuilder(cacheRootURL: fixture.root).build(graph: graph)
        let pass = try #require(pipeline.layers.first?.passes.first)
        let fragmentSource = try #require(pass.shader?.fragmentSource)

        #expect(fragmentSource.contains("#define FORMAT_R8 9"))
        #expect(fragmentSource.contains("#define FORMAT_RG88 8"))
        #expect(fragmentSource.contains("#define FORMAT_R8 0") == false)
        #expect(fragmentSource.contains("#define FORMAT_RG88 0") == false)
        #expect(fragmentSource.contains("#define TEX2FORMAT 0"))
        #expect(pass.textureBindings[2] == WPETextureReference.asset("gradient/gradient_iridescent"))
    }

    @Test("Treats generic image shader variants as builtins")
    func treatsGenericImageShaderVariantsAsBuiltins() throws {
        let fixture = try makeFixture(files: [:])
        defer { fixture.cleanup() }

        let graph = WPERenderGraph(layers: [
            WPERenderLayer(
                objectID: "1",
                objectName: "Layer",
                imagePath: "materials/base.png",
                materialPath: nil,
                geometry: .identity,
                compositeA: "a",
                compositeB: "b",
                localFBOs: [],
                passes: [
                    WPERenderPass(
                        id: "1.0",
                        phase: .material,
                        shader: "generic4",
                        source: .image("materials/base.png"),
                        target: .scene,
                        textures: [:],
                        binds: [:],
                        constants: [:],
                        combos: [:],
                        blending: "normal",
                        cullMode: "nocull",
                        depthTest: "disabled",
                        depthWrite: "disabled"
                    )
                ]
            )
        ])

        let pipeline = try WPERenderPipelineBuilder(cacheRootURL: fixture.root).build(graph: graph)
        let shader = try #require(pipeline.layers.first?.passes.first?.shader)

        #expect(shader.name == "generic4")
        #expect(shader.isBuiltin)
    }

    @Test("Dynamic transform on a non-rendered parent propagates to child geometry")
    func dynamicParentTransformPropagatesToChildGeometry() {
        let childGeometry = WPERenderLayerGeometry(
            origin: SIMD3<Double>(10, 0, 0),
            scale: SIMD3<Double>(1, 1, 1),
            angles: SIMD3<Double>(0, 0, 0),
            alignment: .center,
            size: CGSize(width: 10, height: 10),
            alpha: 1,
            color: SIMD3<Double>(1, 1, 1),
            brightness: 1
        )
        let graphLayer = WPERenderLayer(
            objectID: "child",
            objectName: "Child",
            imagePath: "materials/base.png",
            materialPath: nil,
            parentObjectID: "group",
            geometry: childGeometry,
            localGeometry: childGeometry,
            compositeA: "a",
            compositeB: "b",
            localFBOs: [],
            passes: []
        )
        let pipeline = WPEPreparedRenderPipeline(layers: [
            WPEPreparedRenderLayer(graphLayer: graphLayer, passes: [])
        ])

        let transformed = pipeline.applyingLayerTransforms(
            origins: [:],
            scales: [:],
            angles: ["group": SIMD3<Double>(0, 0, Double.pi / 2)],
            parentByID: ["child": "group"],
            hostTransforms: [
                "group": WPERenderObjectTransform(
                    origin: SIMD3<Double>(0, 0, 0),
                    scale: SIMD3<Double>(1, 1, 1),
                    angles: SIMD3<Double>(0, 0, 0)
                )
            ]
        )
        let geometry = transformed.layers[0].graphLayer.geometry

        #expect(abs(geometry.origin.x) < 0.0001)
        #expect(abs(geometry.origin.y - 10) < 0.0001)
        #expect(abs(geometry.angles.z - Double.pi / 2) < 0.0001)
    }

    @Test("Dynamic parent transform rotates child origin around X and Y")
    func dynamicParentTransformRotatesChildOriginAroundXAndY() {
        func makePipeline(childOrigin: SIMD3<Double>) -> WPEPreparedRenderPipeline {
            let childGeometry = WPERenderLayerGeometry(
                origin: childOrigin,
                scale: SIMD3<Double>(1, 1, 1),
                angles: SIMD3<Double>(0, 0, 0),
                alignment: .center,
                size: CGSize(width: 10, height: 10),
                alpha: 1,
                color: SIMD3<Double>(1, 1, 1),
                brightness: 1
            )
            let graphLayer = WPERenderLayer(
                objectID: "child",
                objectName: "Child",
                imagePath: "materials/base.png",
                materialPath: nil,
                parentObjectID: "group",
                geometry: childGeometry,
                localGeometry: childGeometry,
                compositeA: "a",
                compositeB: "b",
                localFBOs: [],
                passes: []
            )
            return WPEPreparedRenderPipeline(layers: [
                WPEPreparedRenderLayer(graphLayer: graphLayer, passes: [])
            ])
        }

        let xRotated = makePipeline(childOrigin: SIMD3<Double>(0, 1, 0)).applyingLayerTransforms(
            origins: [:],
            scales: [:],
            angles: ["group": SIMD3<Double>(Double.pi / 2, 0, 0)],
            parentByID: ["child": "group"],
            hostTransforms: [
                "group": WPERenderObjectTransform(
                    origin: SIMD3<Double>(1, 2, 3),
                    scale: SIMD3<Double>(2, 3, 4),
                    angles: SIMD3<Double>(0, 0, 0)
                )
            ]
        ).layers[0].graphLayer.geometry

        #expect(abs(xRotated.origin.x - 1) < 0.0001)
        #expect(abs(xRotated.origin.y - 2) < 0.0001)
        #expect(abs(xRotated.origin.z - 6) < 0.0001)
        #expect(abs(xRotated.angles.x - Double.pi / 2) < 0.0001)

        let yRotated = makePipeline(childOrigin: SIMD3<Double>(0, 0, 1)).applyingLayerTransforms(
            origins: [:],
            scales: [:],
            angles: ["group": SIMD3<Double>(0, Double.pi / 2, 0)],
            parentByID: ["child": "group"],
            hostTransforms: [
                "group": WPERenderObjectTransform(
                    origin: SIMD3<Double>(1, 2, 3),
                    scale: SIMD3<Double>(2, 3, 4),
                    angles: SIMD3<Double>(0, 0, 0)
                )
            ]
        ).layers[0].graphLayer.geometry

        #expect(abs(yRotated.origin.x - 5) < 0.0001)
        #expect(abs(yRotated.origin.y - 2) < 0.0001)
        #expect(abs(yRotated.origin.z - 3) < 0.0001)
        #expect(abs(yRotated.angles.y - Double.pi / 2) < 0.0001)
    }

    @Test("Live alpha override also updates a composelayer-group child's group-local alpha")
    func liveAlphaOverrideUpdatesGroupLocalGeometry() {
        func geometry(alpha: Double) -> WPERenderLayerGeometry {
            WPERenderLayerGeometry(
                origin: SIMD3<Double>(5, 7, 0),
                scale: SIMD3<Double>(1, 1, 1),
                angles: SIMD3<Double>(0, 0, 0),
                alignment: .center,
                size: CGSize(width: 40, height: 30),
                alpha: alpha,
                color: SIMD3<Double>(1, 1, 1),
                brightness: 1
            )
        }
        let child = WPERenderLayer(
            objectID: "child",
            objectName: "Child",
            imagePath: "materials/base.png",
            materialPath: nil,
            parentObjectID: "group",
            geometry: geometry(alpha: 1),
            localGeometry: geometry(alpha: 1),
            compositeA: "a",
            compositeB: "b",
            localFBOs: [],
            passes: [],
            groupRenderTarget: "_rt_layerGroup_group",
            groupLocalGeometry: geometry(alpha: 1)
        )
        let pipeline = WPEPreparedRenderPipeline(layers: [
            WPEPreparedRenderLayer(graphLayer: child, passes: [])
        ])

        let faded = pipeline.applyingLayerAlpha(["child": 0.25]).layers[0].graphLayer
        #expect(abs(faded.geometry.alpha - 0.25) < 0.0001)
        #expect(abs((faded.groupLocalGeometry?.alpha ?? -1) - 0.25) < 0.0001)
        #expect(faded.groupLocalGeometry?.alphaAnimation == nil)
        #expect(faded.groupLocalGeometry?.origin == SIMD3<Double>(5, 7, 0))
    }

    @Test("Prefers scene-provided source for WPE effect aliases")
    func prefersSceneProvidedSourceForWPEEffectAliases() throws {
        let fixture = try makeFixture(files: [
            "shaders/effects/shake.vert": """
            attribute vec3 a_Position;
            void main() { gl_Position = vec4(a_Position, 1.0); }
            """,
            "shaders/effects/shake.frag": """
            uniform sampler2D g_Texture0;
            void main() {
                vec4 sampled = texSample2D(g_Texture0, vec2(0.5));
                gl_FragColor = sampled + vec4(0.123, 0.0, 0.0, 0.0);
            }
            """
        ])
        defer { fixture.cleanup() }

        let graph = WPERenderGraph(layers: [
            WPERenderLayer(
                objectID: "1",
                objectName: "Layer",
                imagePath: "materials/base.png",
                materialPath: nil,
                geometry: .identity,
                compositeA: "a",
                compositeB: "b",
                localFBOs: [],
                passes: [
                    WPERenderPass(
                        id: "1.0",
                        phase: .effect(file: "effects/shake/effect.json"),
                        shader: "effects/shake",
                        source: .image("materials/base.png"),
                        target: .scene,
                        textures: [:],
                        binds: [:],
                        constants: [:],
                        combos: [:],
                        blending: "normal",
                        cullMode: "nocull",
                        depthTest: "disabled",
                        depthWrite: "disabled"
                    )
                ]
            )
        ])

        let pipeline = try WPERenderPipelineBuilder(cacheRootURL: fixture.root).build(graph: graph)
        let shader = try #require(pipeline.layers.first?.passes.first?.shader)

        #expect(shader.isBuiltin == false)
        #expect(shader.fragmentSource.contains("0.123"))
    }

    @Test("Expands WPE imageblending mode 31 as additive blending")
    func expandsWPEImageBlendingMode31AsAdditiveBlending() throws {
        let fixture = try makeFixture(files: [
            "shaders/effects/lightblend.vert": """
            attribute vec3 a_Position;
            void main() { gl_Position = vec4(a_Position, 1.0); }
            """,
            "shaders/effects/lightblend.frag": """
            // [COMBO] {"material":"ui_editor_properties_blend_mode","combo":"BLENDMODE","type":"imageblending","default":31}
            #include "common_blending.h"
            uniform sampler2D g_Texture0;
            void main() {
                vec4 albedo = texSample2D(g_Texture0, vec2(0.5));
                gl_FragColor = vec4(ApplyBlending(BLENDMODE, albedo.rgb, vec3(0.25), 1.0), albedo.a);
            }
            """
        ])
        defer { fixture.cleanup() }

        let graph = WPERenderGraph(layers: [
            WPERenderLayer(
                objectID: "1",
                objectName: "Layer",
                imagePath: "materials/base.png",
                materialPath: nil,
                geometry: .identity,
                compositeA: "a",
                compositeB: "b",
                localFBOs: [],
                passes: [
                    WPERenderPass(
                        id: "1.0",
                        phase: .effect(file: "effects/lightblend/effect.json"),
                        shader: "effects/lightblend",
                        source: .image("materials/base.png"),
                        target: .scene,
                        textures: [:],
                        binds: [:],
                        constants: [:],
                        combos: [:],
                        blending: "normal",
                        cullMode: "nocull",
                        depthTest: "disabled",
                        depthWrite: "disabled"
                    )
                ]
            )
        ])

        let pipeline = try WPERenderPipelineBuilder(cacheRootURL: fixture.root).build(graph: graph)
        let pass = try #require(pipeline.layers.first?.passes.first)
        let shader = try #require(pass.shader)

        #expect(pass.comboValues["BLENDMODE"] == 31)
        #expect(shader.fragmentSource.contains("#define BLENDMODE 31"))
        #expect(shader.fragmentSource.contains("blendMode == 31"))
        #expect(shader.fragmentSource.contains("vec3 ApplyBlending(int blendMode, vec3 A, vec3 B, vec3 opacity)"))
        #expect(shader.fragmentSource.contains("#include") == false)
    }

    @Test("Builds built-in solid color shader")
    func buildsBuiltinSolidColorShader() throws {
        let fixture = try makeFixture(files: [:])
        defer { fixture.cleanup() }

        let graph = WPERenderGraph(layers: [
            WPERenderLayer(
                objectID: "1",
                objectName: "Solid",
                imagePath: "models/util/solidlayer.json",
                materialPath: "models/util/solidlayer.json",
                geometry: .identity,
                compositeA: "a",
                compositeB: "b",
                localFBOs: [],
                passes: [
                    WPERenderPass(
                        id: "1.0",
                        phase: .material,
                        shader: "solidcolor",
                        source: .image("models/util/solidlayer.json"),
                        target: .scene,
                        textures: [:],
                        binds: [:],
                        constants: ["g_Color": .vector([1, 0, 0, 1])],
                        combos: [:],
                        blending: "normal",
                        cullMode: "nocull",
                        depthTest: "disabled",
                        depthWrite: "disabled"
                    )
                ]
            )
        ])

        let pipeline = try WPERenderPipelineBuilder(cacheRootURL: fixture.root).build(graph: graph)
        let shader = try #require(pipeline.layers.first?.passes.first?.shader)

        #expect(shader.name == "solidcolor")
        #expect(shader.isBuiltin)
        #expect(shader.fragmentSource.contains("uniform vec4 g_Color"))
    }

    @Test("Builds executable copy command passes")
    func buildsExecutableCopyCommandPasses() throws {
        let fixture = try makeFixture(files: [:])
        defer { fixture.cleanup() }

        let graph = WPERenderGraph(layers: [
            WPERenderLayer(
                objectID: "1",
                objectName: "Layer",
                imagePath: "materials/base.png",
                materialPath: nil,
                geometry: .identity,
                compositeA: "a",
                compositeB: "b",
                localFBOs: [],
                passes: [
                    WPERenderPass(
                        id: "1.0",
                        phase: .command(file: "effects/copy/effect.json"),
                        shader: "commands/copy",
                        source: .fbo("_rt_Previous"),
                        target: .fbo(name: "_rt_Target"),
                        textures: [0: .fbo("_rt_Source")],
                        binds: [:],
                        constants: [:],
                        combos: [:],
                        blending: "normal",
                        cullMode: "nocull",
                        depthTest: "disabled",
                        depthWrite: "disabled"
                    )
                ]
            )
        ])

        let pipeline = try WPERenderPipelineBuilder(cacheRootURL: fixture.root).build(graph: graph)
        let pass = try #require(pipeline.layers.first?.passes.first)

        #expect(pass.shader?.name == "commands/copy")
        #expect(pass.shader?.isBuiltin == true)
        #expect(pass.textureBindings[0] == .fbo("_rt_Source"))
    }

    @Test("Merges shader annotation defaults into prepared pass metadata")
    func mergesShaderAnnotationDefaultsIntoPreparedPassMetadata() throws {
        let fixture = try makeFixture(files: [
            "shaders/effects/annotated.vert": """
            // [COMBO] {"combo":"QUALITY","default":2}
            attribute vec3 a_Position;
            void main() { gl_Position = vec4(a_Position, 1.0); }
            """,
            "shaders/effects/annotated.frag": """
            uniform sampler2D g_Texture1; // {"material":"noise","default":"util/noise","hidden":true}
            uniform sampler2D g_Texture2; // {"material":"flow","combo":"FLOWMASK"}
            uniform float u_Strength; // {"material":"strength","default":0.2}
            void main() { gl_FragColor = texSample2D(g_Texture1, vec2(u_Strength)); }
            """
        ])
        defer { fixture.cleanup() }

        let graph = WPERenderGraph(layers: [
            WPERenderLayer(
                objectID: "1",
                objectName: "Layer",
                imagePath: "materials/base.png",
                materialPath: nil,
                geometry: .identity,
                compositeA: "a",
                compositeB: "b",
                localFBOs: [],
                passes: [
                    WPERenderPass(
                        id: "1.0",
                        phase: .effect(file: "effects/annotated/effect.json"),
                        shader: "effects/annotated",
                        source: .image("materials/base.png"),
                        target: .scene,
                        textures: [2: .asset("masks/flow")],
                        binds: [:],
                        constants: ["strength": .number(0.75)],
                        combos: [:],
                        blending: "normal",
                        cullMode: "nocull",
                        depthTest: "disabled",
                        depthWrite: "disabled"
                    )
                ]
            )
        ])

        let pipeline = try WPERenderPipelineBuilder(cacheRootURL: fixture.root).build(graph: graph)
        let pass = try #require(pipeline.layers.first?.passes.first)

        #expect(pass.comboValues["QUALITY"] == 2)
        #expect(pass.comboValues["FLOWMASK"] == 1)
        #expect(pass.textureBindings[0] == .image("materials/base.png"))
        #expect(pass.textureBindings[1] == .asset("util/noise"))
        #expect(pass.textureBindings[2] == .asset("masks/flow"))
        #expect(pass.uniformValues["u_Strength"]?.numberValue == 0.75)
    }

    @Test("Legacy generic2 reflection default binds only when REFLECTION is enabled")
    func legacyGeneric2ReflectionDefaultFollowsCombo() throws {
        let fixture = try makeFixture(files: [
            "shaders/generic2.vert": """
            attribute vec3 a_Position;
            void main() { gl_Position = vec4(a_Position, 1.0); }
            """,
            "shaders/generic2.frag": """
            uniform sampler2D g_Texture0; // {"default":"util/white"}
            uniform sampler2D g_Texture2; // {"default":"_rt_Reflection","hidden":true}
            void main() {
            #if REFLECTION
                gl_FragColor = texSample2D(g_Texture2, vec2(0.5));
            #else
                gl_FragColor = texSample2D(g_Texture0, vec2(0.5));
            #endif
            }
            """
        ])
        defer { fixture.cleanup() }

        func preparedPass(reflection: Int?) throws -> WPEPreparedRenderPass {
            let combos = reflection.map { ["REFLECTION": $0] } ?? [:]
            let graph = WPERenderGraph(layers: [
                WPERenderLayer(
                    objectID: "3470948192",
                    objectName: "generic2",
                    imagePath: "util/white",
                    materialPath: nil,
                    geometry: .identity,
                    compositeA: "a",
                    compositeB: "b",
                    localFBOs: [],
                    passes: [
                        WPERenderPass(
                            id: "3470948192.0",
                            phase: .material,
                            shader: "generic2",
                            source: .asset("util/white"),
                            target: .scene,
                            textures: [:],
                            binds: [:],
                            constants: [:],
                            combos: combos,
                            blending: "normal",
                            cullMode: "nocull",
                            depthTest: "enabled",
                            depthWrite: "enabled"
                        )
                    ]
                )
            ])
            return try #require(
                WPERenderPipelineBuilder(cacheRootURL: fixture.root)
                    .build(graph: graph)
                    .layers.first?.passes.first
            )
        }

        let implicitOff = try preparedPass(reflection: nil)
        let explicitOff = try preparedPass(reflection: 0)
        let enabled = try preparedPass(reflection: 1)

        #expect(implicitOff.textureBindings[2] == nil)
        #expect(explicitOff.textureBindings[2] == nil)
        #expect(enabled.textureBindings[2] == .fbo("_rt_Reflection"))
    }

    @Test("shake/pulse opacity mask slot 2 defaults to white unless explicitly bound")
    func effectOpacityMaskSlot2DefaultsToWhite() throws {
        let fixture = try makeFixture(files: [
            "shaders/effects/shake.vert": """
            attribute vec3 a_Position;
            void main() { gl_Position = vec4(a_Position, 1.0); }
            """,
            "shaders/effects/shake.frag": """
            uniform sampler2D g_Texture0;
            uniform sampler2D g_Texture2; // {"default":"util/black"}
            void main() { gl_FragColor = texSample2D(g_Texture0, vec2(0.5)); }
            """
        ])
        defer { fixture.cleanup() }

        func builtPass(textures: [Int: WPETextureReference]) throws -> WPEPreparedRenderPass {
            let graph = WPERenderGraph(layers: [
                WPERenderLayer(
                    objectID: "161",
                    objectName: "Layer",
                    imagePath: "materials/base.png",
                    materialPath: nil,
                    geometry: .identity,
                    compositeA: "a",
                    compositeB: "b",
                    localFBOs: [],
                    passes: [
                        WPERenderPass(
                            id: "161.1",
                            phase: .effect(file: "effects/shake/effect.json"),
                            shader: "effects/shake",
                            source: .image("materials/base.png"),
                            target: .scene,
                            textures: textures,
                            binds: [:],
                            constants: [:],
                            combos: [:],
                            blending: "normal",
                            cullMode: "nocull",
                            depthTest: "disabled",
                            depthWrite: "disabled"
                        )
                    ]
                )
            ])
            let pipeline = try WPERenderPipelineBuilder(cacheRootURL: fixture.root).build(graph: graph)
            return try #require(pipeline.layers.first?.passes.first)
        }

        let defaulted = try builtPass(textures: [:])
        #expect(defaulted.textureBindings[2] == .asset("util/white"))

        let explicit = try builtPass(textures: [2: .asset("masks/pulse__mask_9913c181")])
        #expect(explicit.textureBindings[2] == .asset("masks/pulse__mask_9913c181"))
    }

    @Test("Sampler defaults honor shader require conditions")
    func samplerDefaultsHonorShaderRequireConditions() throws {
        let fixture = try makeFixture(files: [
            "shaders/effects/conditional.vert": """
            attribute vec3 a_Position;
            void main() { gl_Position = vec4(a_Position, 1.0); }
            """,
            "shaders/effects/conditional.frag": """
            // [COMBO] {"combo":"RENDERING","default":0}
            uniform sampler2D g_Texture1; // {"default":"gradient/gradient_iridescent","require":{"RENDERING":1}}
            void main() { gl_FragColor = vec4(1.0); }
            """
        ])
        defer { fixture.cleanup() }

        func buildPass(combos: [String: Int]) throws -> WPEPreparedRenderPass {
            let graph = WPERenderGraph(layers: [
                WPERenderLayer(
                    objectID: "1",
                    objectName: "Layer",
                    imagePath: "materials/base.png",
                    materialPath: nil,
                    geometry: .identity,
                    compositeA: "a",
                    compositeB: "b",
                    localFBOs: [],
                    passes: [
                        WPERenderPass(
                            id: "1.0",
                            phase: .effect(file: "effects/conditional/effect.json"),
                            shader: "effects/conditional",
                            source: .image("materials/base.png"),
                            target: .scene,
                            textures: [:],
                            binds: [:],
                            constants: [:],
                            combos: combos,
                            blending: "normal",
                            cullMode: "nocull",
                            depthTest: "disabled",
                            depthWrite: "disabled"
                        )
                    ]
                )
            ])
            let pipeline = try WPERenderPipelineBuilder(cacheRootURL: fixture.root).build(graph: graph)
            return try #require(pipeline.layers.first?.passes.first)
        }

        let inactivePass = try buildPass(combos: [:])
        #expect(inactivePass.comboValues["RENDERING"] == 0)
        #expect(inactivePass.textureBindings[1] == nil)

        let activePass = try buildPass(combos: ["RENDERING": 1])
        #expect(activePass.comboValues["RENDERING"] == 1)
        #expect(activePass.textureBindings[1] == WPETextureReference.asset("gradient/gradient_iridescent"))
    }

    @Test("Comments require directives and emits WPE compatibility prelude")
    func commentsRequireDirectivesAndEmitsCompatibilityPrelude() throws {
        let fixture = try makeFixture(files: [
            "shaders/effects/compat.vert": """
            #require SOME_FEATURE
            attribute vec3 a_Position;
            varying vec2 v_TexCoord;
            void main() { gl_Position = vec4(a_Position, 1.0); }
            """,
            "shaders/effects/compat.frag": """
            varying vec2 v_TexCoord;
            void main() { gl_FragColor = lerp(vec4(0.0), vec4(1.0), 0.5); }
            """
        ])
        defer { fixture.cleanup() }

        let graph = WPERenderGraph(layers: [
            WPERenderLayer(
                objectID: "1",
                objectName: "Layer",
                imagePath: "materials/base.png",
                materialPath: nil,
                geometry: .identity,
                compositeA: "a",
                compositeB: "b",
                localFBOs: [],
                passes: [
                    WPERenderPass(
                        id: "1.0",
                        phase: .effect(file: "effects/compat/effect.json"),
                        shader: "effects/compat",
                        source: .image("materials/base.png"),
                        target: .scene,
                        textures: [:],
                        binds: [:],
                        constants: [:],
                        combos: [:],
                        blending: "normal",
                        cullMode: "nocull",
                        depthTest: "disabled",
                        depthWrite: "disabled"
                    )
                ]
            )
        ])

        let pipeline = try WPERenderPipelineBuilder(cacheRootURL: fixture.root).build(graph: graph)
        let shader = try #require(pipeline.layers.first?.passes.first?.shader)

        #expect(shader.vertexSource.contains("#require") == false)
        #expect(shader.vertexSource.contains("#define attribute in"))
        #expect(shader.fragmentSource.contains("out vec4 out_FragColor"))
        #expect(shader.fragmentSource.contains("gl_FragColor") == false)
        #expect(shader.fragmentSource.contains("#define texSample2DLod textureLod"))
        #expect(shader.fragmentSource.contains("#define lerp mix"))
    }

    @Test("Compatibility prelude keeps GLSL atan2 compiling through Metal")
    func compatibilityPreludeAtan2CompilesThroughMetal() throws {
        let fixture = try makeFixture(files: [
            "shaders/effects/atan.vert": """
            attribute vec3 a_Position;
            varying vec2 v_TexCoord;
            void main() {
                gl_Position = vec4(a_Position, 1.0);
                v_TexCoord = a_Position.xy;
            }
            """,
            "shaders/effects/atan.frag": """
            varying vec2 v_TexCoord;
            void main() {
                float angle = atan2(v_TexCoord.y - 0.5, v_TexCoord.x - 0.5);
                gl_FragColor = vec4(angle, 0.0, 0.0, 1.0);
            }
            """
        ])
        defer { fixture.cleanup() }

        let graph = WPERenderGraph(layers: [
            WPERenderLayer(
                objectID: "1",
                objectName: "Layer",
                imagePath: "materials/base.png",
                materialPath: nil,
                geometry: .identity,
                compositeA: "a",
                compositeB: "b",
                localFBOs: [],
                passes: [
                    WPERenderPass(
                        id: "1.0",
                        phase: .effect(file: "effects/atan/effect.json"),
                        shader: "effects/atan",
                        source: .image("materials/base.png"),
                        target: .scene,
                        textures: [:],
                        binds: [:],
                        constants: [:],
                        combos: [:],
                        blending: "normal",
                        cullMode: "nocull",
                        depthTest: "disabled",
                        depthWrite: "disabled"
                    )
                ]
            )
        ])

        let pipeline = try WPERenderPipelineBuilder(cacheRootURL: fixture.root).build(graph: graph)
        let fragmentSource = try #require(pipeline.layers.first?.passes.first?.shader?.fragmentSource)
        let result = try WPEShaderTranspiler.translateFragment(
            shaderName: "effects/atan",
            preprocessedSource: fragmentSource
        )

        let device = try #require(MTLCreateSystemDefaultDevice())
        let opts = MTLCompileOptions()
        opts.languageVersion = .version3_0

        #expect(result.mslSource.contains("atan2(v_TexCoord.y - 0.5, v_TexCoord.x - 0.5)"))
        _ = try device.makeLibrary(source: result.mslSource, options: opts)
    }

    @Test(
        "Recognises effect aliases under bare, effects/, and materials/ paths",
        arguments: [
            "blur",
            "effects/blur",
            "effects/blur/blur",
            "materials/effects/blur/blur",
            "materials/effects/blur/blur.json",
            "MATERIALS/Effects/Blur/Blur.JSON"
        ]
    )
    func recognisesEffectAliasesAcrossPathStyles(shaderName: String) throws {
        let fixture = try makeFixture(files: [:])
        defer { fixture.cleanup() }

        let graph = WPERenderGraph(layers: [
            WPERenderLayer(
                objectID: "1",
                objectName: "Layer",
                imagePath: "materials/base.png",
                materialPath: nil,
                geometry: .identity,
                compositeA: "a",
                compositeB: "b",
                localFBOs: [],
                passes: [
                    WPERenderPass(
                        id: "1.0",
                        phase: .effect(file: "effects/blur/effect.json"),
                        shader: shaderName,
                        source: .fbo("_rt_Source"),
                        target: .scene,
                        textures: [0: .fbo("_rt_Source")],
                        binds: [:],
                        constants: [:],
                        combos: [:],
                        blending: "normal",
                        cullMode: "nocull",
                        depthTest: "disabled",
                        depthWrite: "disabled"
                    )
                ]
            )
        ])

        let pipeline = try WPERenderPipelineBuilder(cacheRootURL: fixture.root).build(graph: graph)
        let shader = try #require(pipeline.layers.first?.passes.first?.shader)

        #expect(shader.isBuiltin)
        #expect(shader.name == shaderName)
    }

    private struct Fixture {
        let root: URL

        func cleanup() {
            try? FileManager.default.removeItem(at: root)
        }
    }

    private func makeFixture(
        files: [String: String] = [:],
        dataFiles: [String: Data] = [:]
    ) throws -> Fixture {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("WPERenderPipelineBuilderTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        for (relativePath, contents) in files {
            let fileURL = root.appendingPathComponent(relativePath)
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try Data(contents.utf8).write(to: fileURL)
        }
        for (relativePath, contents) in dataFiles {
            let fileURL = root.appendingPathComponent(relativePath)
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try contents.write(to: fileURL)
        }
        return Fixture(root: root)
    }

    private func makeHeaderOnlyTex(formatCode: Int32) -> Data {
        var data = Data()
        data.append(contentsOf: "TEXV0005".utf8)
        data.append(0)
        data.append(contentsOf: "TEXI0001".utf8)
        data.append(0)
        data.appendLE(UInt32(bitPattern: formatCode))
        data.appendLE(UInt32(0)) // flags
        data.appendLE(UInt32(4)) // texture width
        data.appendLE(UInt32(4)) // texture height
        data.appendLE(UInt32(4)) // image width
        data.appendLE(UInt32(4)) // image height
        data.appendLE(UInt32(0)) // unknownInt0
        return data
    }

    private func makeSingleTrianglePuppetMDL() -> Data {
        var data = Data()
        data.append(contentsOf: Array("MDLV0023".utf8))
        data.appendLE(UInt32(0x80000900))
        data.append(UInt8(1))
        data.appendLE(UInt32(1))
        data.appendLE(UInt32(1))

        data.appendCString("materials/layer.json")
        data.appendLE(UInt32(0))
        data.appendLE(Float(-10))
        data.appendLE(Float(-20))
        data.appendLE(Float(0))
        data.appendLE(Float(10))
        data.appendLE(Float(20))
        data.appendLE(Float(0))
        data.appendLE(UInt32(0x180000f))
        let vertexData = Data.puppetVertices([
            (SIMD3<Float>(-10, -20, 0), SIMD2<Float>(0, 1)),
            (SIMD3<Float>(10, -20, 0), SIMD2<Float>(1, 1)),
            (SIMD3<Float>(0, 20, 0), SIMD2<Float>(0.5, 0))
        ])
        data.appendLE(UInt32(vertexData.count))
        data.append(vertexData)
        data.appendLE(UInt32(3 * MemoryLayout<UInt16>.size))
        data.appendLE(UInt16(0))
        data.appendLE(UInt16(1))
        data.appendLE(UInt16(2))

        data.append(UInt8(0))
        data.append(UInt8(1))
        data.appendLE(UInt32(16))
        data.appendLE(UInt32(7))
        data.appendLE(UInt32(0))
        data.appendLE(UInt32(0))
        data.appendLE(UInt32(3))

        return data
    }

    private func makeLegacyPuppetMDLBelow19() -> Data {
        // Real MDLV0017 header layout (9-byte NUL-terminated tag + flags +
        // skin count + mesh count) so the parser accepts it and the version
        // guard — not a parse failure — is what refuses the scene.
        var data = Data()
        data.append(contentsOf: Array("MDLV0017".utf8))
        data.append(UInt8(0))
        data.appendLE(UInt32(0x180000f))
        data.appendLE(UInt32(1))
        data.appendLE(UInt32(1))

        data.appendCString("materials/layer.json")
        data.appendLE(UInt32(0))
        for _ in 0..<6 { data.appendLE(Float(0)) }
        data.appendLE(UInt32(0x180000f))
        let vertexData = Data.puppetVertices([
            (SIMD3<Float>(0, 0, 0), SIMD2<Float>(0.5, 0.5))
        ])
        data.appendLE(UInt32(vertexData.count))
        data.append(vertexData)
        data.appendLE(UInt32(0))

        return data
    }

    private func makeSingleTriangleMDLV16SceneModel() -> Data {
        var data = Data()
        data.append(contentsOf: Array("MDLV0016".utf8))
        data.appendLE(UInt32(0x00000f00))
        data.append(UInt8(0))
        data.appendLE(UInt32(1))
        data.appendLE(UInt32(1))

        data.appendCString("materials/models/Hollow Cylinder/diffuse_0.json")
        data.appendLE(UInt32(0))
        data.appendLE(UInt32(0x0000000f))

        var vertices = Data()
        vertices.appendSceneModelVertex(position: SIMD3<Float>(-1, -1, 0), uv: SIMD2<Float>(0, 1))
        vertices.appendSceneModelVertex(position: SIMD3<Float>(1, -1, 0), uv: SIMD2<Float>(1, 1))
        vertices.appendSceneModelVertex(position: SIMD3<Float>(0, 1, 0), uv: SIMD2<Float>(0.5, 0))
        data.appendLE(UInt32(vertices.count))
        data.append(vertices)

        data.appendLE(UInt32(3 * MemoryLayout<UInt16>.size))
        data.appendLE(UInt16(0))
        data.appendLE(UInt16(1))
        data.appendLE(UInt16(2))

        return data
    }
}

private extension Data {
    mutating func appendLE(_ value: UInt16) {
        var littleEndian = value.littleEndian
        Swift.withUnsafeBytes(of: &littleEndian) { append(contentsOf: $0) }
    }

    mutating func appendLE(_ value: UInt32) {
        var littleEndian = value.littleEndian
        Swift.withUnsafeBytes(of: &littleEndian) { append(contentsOf: $0) }
    }

    mutating func appendLE(_ value: Float) {
        appendLE(value.bitPattern)
    }

    mutating func appendCString(_ string: String) {
        append(contentsOf: Array(string.utf8))
        append(UInt8(0))
    }

    static func puppetVertices(_ vertices: [(position: SIMD3<Float>, uv: SIMD2<Float>)]) -> Data {
        var data = Data()
        for vertex in vertices {
            data.appendLE(vertex.position.x)
            data.appendLE(vertex.position.y)
            data.appendLE(vertex.position.z)
            data.appendLE(Float(0))
            data.appendLE(Float(0))
            data.appendLE(Float(1))
            data.appendLE(Float(1))
            data.appendLE(Float(0))
            data.appendLE(Float(0))
            data.appendLE(Float(1))
            data.appendLE(Float(0))
            data.appendLE(Float(0))
            data.appendLE(Float(0))
            data.appendLE(Float(0))
            data.appendLE(Float(1))
            data.appendLE(Float(0))
            data.appendLE(Float(0))
            data.appendLE(Float(0))
            data.appendLE(vertex.uv.x)
            data.appendLE(vertex.uv.y)
        }
        return data
    }

    mutating func appendSceneModelVertex(position: SIMD3<Float>, uv: SIMD2<Float>) {
        appendLE(position.x)
        appendLE(position.y)
        appendLE(position.z)
        appendLE(Float(0))
        appendLE(Float(0))
        appendLE(Float(1))
        appendLE(Float(1))
        appendLE(Float(0))
        appendLE(Float(0))
        appendLE(Float(1))
        appendLE(uv.x)
        appendLE(uv.y)
    }
}
