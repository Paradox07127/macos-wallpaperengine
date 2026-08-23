import AppKit
import LiveWallpaperCore
import LiveWallpaperProWPE
import QuartzCore
import Testing
@testable import LiveWallpaper

@MainActor
@Suite("WPE Metal runtime uniforms")
struct WPEMetalRuntimeUniformsTests {

    @Test("Frame clock computes time daytime brightness and pointer uniforms")
    func frameClockComputesRuntimeUniforms() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!

        let date = try #require(DateComponents(
            calendar: calendar,
            timeZone: calendar.timeZone,
            year: 2026,
            month: 5,
            day: 5,
            hour: 6,
            minute: 30,
            second: 0
        ).date)

        let clock = WPEMetalFrameClock(
            loadTime: 10,
            currentMediaTime: { 12.5 },
            currentDate: { date },
            calendar: calendar
        )

        let uniforms = clock.runtimeUniforms(
            profile: .quality,
            pointerPosition: SIMD2<Double>(0.25, 0.75)
        )

        #expect(abs(uniforms.time - 2.5) < 0.0001)
        #expect(abs(uniforms.daytime - 0.2708333333) < 0.0001)
        #expect(uniforms.brightness == 1)
        #expect(uniforms.pointerPosition == SIMD2<Double>(0.25, 0.75))
        #expect(uniforms.uniformValues["g_Time"]?.numberValue == 2.5)
        #expect(uniforms.uniformValues["g_Brightness"]?.numberValue == 1)
        #expect(uniforms.uniformValues["g_PointerPosition"]?.vectorValue == [0.25, 0.75])
    }

    @Test("Suspended profile keeps brightness uniform at one")
    func suspendedProfileKeepsBrightnessAtOne() {
        let uniforms = WPEMetalRuntimeUniforms(
            time: 4,
            daytime: 0.5,
            brightness: WallpaperPerformanceProfile.suspended.metalBrightnessUniformValue,
            pointerPosition: SIMD2<Double>(0.5, 0.5)
        )

        #expect(uniforms.brightness == 1)
        #expect(uniforms.uniformValues["g_Brightness"]?.numberValue == 1)
    }

    @Test("WPE 2.8 neutral frame defaults disable optional effects and pass through SDR")
    func provides28NeutralFrameDefaults() {
        let uniforms = WPEMetalRuntimeUniforms(
            time: 0,
            daytime: 0,
            brightness: 1,
            pointerPosition: SIMD2<Double>(0.5, 0.5)
        )
        let values = uniforms.uniformValues

        for name in ["g_RenderVar0", "g_RenderVar1", "g_RenderVar2", "g_RenderVar3"] {
            #expect(values[name]?.vectorValue == [0, 0, 0, 0])
        }

        #expect(values["g_HDRParams"]?.vectorValue == [1, 0.5])
    }

    @Test("Center present mode preserves source pixel size and centers")
    func centerPresentModePreservesSourcePixelSizeAndCenters() {
        let smaller = WPEPresentUniforms.make(
            fitMode: .center,
            sourceWidth: 960,
            sourceHeight: 540,
            targetWidth: 1920,
            targetHeight: 1080
        )

        #expect(smaller.ndcScale == SIMD2<Float>(0.5, 0.5))
        #expect(smaller.uvScale == SIMD2<Float>(1, 1))
        #expect(smaller.uvOffset == SIMD2<Float>(0, 0))

        let larger = WPEPresentUniforms.make(
            fitMode: .center,
            sourceWidth: 3840,
            sourceHeight: 2160,
            targetWidth: 1920,
            targetHeight: 1080
        )

        #expect(larger.ndcScale == SIMD2<Float>(2, 2))
        #expect(larger.uvScale == SIMD2<Float>(1, 1))
        #expect(larger.uvOffset == SIMD2<Float>(0, 0))
    }

    @Test("Pointer sampler normalizes global mouse position to top-left scene UV")
    func pointerSamplerNormalizesGlobalMousePosition() throws {
        let window = NSWindow(
            contentRect: CGRect(x: 100, y: 100, width: 200, height: 100),
            styleMask: [],
            backing: .buffered,
            defer: false
        )
        let view = NSView(frame: CGRect(x: 0, y: 0, width: 200, height: 100))
        window.contentView = view

        let uv = WPEMetalPointerSampler.normalizedSceneUV(
            mouseLocation: CGPoint(x: 200, y: 125),
            in: view
        )

        #expect(abs(uv.x - 0.5) < 0.0001)
        #expect(abs(uv.y - 0.75) < 0.0001)
    }

    @Test("Pointer sampler marks locations outside the renderer view inactive")
    func pointerSamplerMarksLocationsOutsideRendererViewInactive() throws {
        let window = NSWindow(
            contentRect: CGRect(x: 100, y: 100, width: 200, height: 100),
            styleMask: [],
            backing: .buffered,
            defer: false
        )
        let view = NSView(frame: CGRect(x: 0, y: 0, width: 200, height: 100))
        window.contentView = view

        let uv = WPEMetalPointerSampler.normalizedSceneUV(
            mouseLocation: CGPoint(x: 450, y: 125),
            in: view
        )

        #expect(uv == SIMD2<Double>(0.5, 0.5))
    }

    @Test("Orthographic camera uses scene projection dimensions")
    func orthographicCameraUsesSceneProjectionDimensions() {
        let projection = WPESceneOrthogonalProjection(width: 200, height: 100, auto: true)
        let camera = WPEMetalCameraUniforms(
            orthogonalProjection: projection,
            sceneCamera: .defaultCamera
        )

        #expect(camera.renderSize == CGSize(width: 200, height: 100))
        #expect(camera.viewProjectionMatrix.count == 16)
        #expect(abs(camera.viewProjectionMatrix[0] - 0.01) < 0.0001)
        #expect(abs(camera.viewProjectionMatrix[5] + 0.02) < 0.0001)
        #expect(abs(camera.viewProjectionMatrix[12] + 1.0) < 0.0001)
        #expect(abs(camera.viewProjectionMatrix[13] - 1.0) < 0.0001)
    }

    @Test("Perspective projection maps world text/image origins to scene-centered pixels")
    func projectedCenterInScenePixelsMatchesObjectQuadCamera() throws {
        let camera = WPEMetalCameraUniforms(
            orthogonalProjection: WPESceneOrthogonalProjection(width: 100, height: 100, auto: true),
            sceneCamera: WPESceneCamera(
                center: SIMD3<Double>(0, 0, 0),
                eye: SIMD3<Double>(0, 0, 10),
                up: SIMD3<Double>(0, 1, 0),
                nearZ: 0.1,
                farZ: 100,
                fov: 90
            ),
            usesPerspectiveProjection: true
        )
        let sceneSize = CGSize(width: 100, height: 100)

        let onAxis = try #require(camera.projectedCenterInScenePixels(
            worldPoint: SIMD3<Double>(0, 0, 0), sceneSize: sceneSize
        ))
        #expect(abs(onAxis.center.x) < 0.01)
        #expect(abs(onAxis.center.y) < 0.01)
        #expect(abs(onAxis.depthScale - 5) < 0.01)

        let offAxis = try #require(camera.projectedCenterInScenePixels(
            worldPoint: SIMD3<Double>(2, 3, 0), sceneSize: sceneSize
        ))
        #expect(abs(offAxis.center.x - 10) < 0.01)
        #expect(abs(offAxis.center.y - 15) < 0.01)

        let label = try #require(camera.projectedCenterInScenePixels(
            worldPoint: SIMD3<Double>(0, -0.54, 4), sceneSize: sceneSize
        ))
        #expect(abs(label.center.x) < 50)
        #expect(abs(label.center.y) < 50)

        #expect(camera.projectedCenterInScenePixels(
            worldPoint: SIMD3<Double>(0, 0, 20), sceneSize: sceneSize
        ) == nil)
    }

    @Test("Perspective projection uses reversed Z and Wallpaper Engine defaults")
    func perspectiveProjectionUsesReversedZAndWPEDefaults() {
        #expect(WPESceneCamera.defaultCamera.nearZ == 0.01)
        #expect(WPESceneCamera.defaultCamera.farZ == 10000)
        #expect(WPESceneCamera.defaultCamera.fov == 50)

        let camera = WPEMetalCameraUniforms(
            orthogonalProjection: WPESceneOrthogonalProjection(width: 1920, height: 1080, auto: true),
            sceneCamera: WPESceneCamera(
                center: .zero,
                eye: .zero,
                up: SIMD3<Double>(0, 1, 0),
                nearZ: 0.01,
                farZ: 10000,
                fov: 50
            ),
            usesPerspectiveProjection: true
        )
        let matrix = camera.viewProjectionMatrix
        func projectedDepth(distance: Double) -> Double {
            let z = -distance
            return (matrix[10] * z + matrix[14]) / (matrix[11] * z + matrix[15])
        }

        #expect(abs(projectedDepth(distance: 0.01) - 1) < 0.000_001)
        #expect(abs(projectedDepth(distance: 10000)) < 0.000_001)
        #expect(projectedDepth(distance: 1) > projectedDepth(distance: 100))
    }

    @Test("Prepared pipeline receives runtime and camera uniforms without losing material uniforms")
    func preparedPipelineReceivesRuntimeAndCameraUniforms() {
        let pass = WPERenderPass(
            id: "solid.0",
            phase: .material,
            shader: "solidcolor",
            source: .previous,
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
        let layer = WPERenderLayer(
            objectID: "layer",
            objectName: "Layer",
            imagePath: "materials/base.png",
            materialPath: nil,
            geometry: .identity,
            compositeA: "a",
            compositeB: "b",
            localFBOs: [],
            passes: [pass]
        )
        let pipeline = WPEPreparedRenderPipeline(layers: [
            WPEPreparedRenderLayer(
                graphLayer: layer,
                passes: [
                    WPEPreparedRenderPass(
                        pass: pass,
                        shader: WPEShaderProgram(
                            name: "solidcolor",
                            vertexSource: "",
                            fragmentSource: "",
                            isBuiltin: true
                        ),
                        textureBindings: [:],
                        comboValues: [:],
                        uniformValues: ["g_Color": .vector([1, 0, 0, 1])]
                    )
                ]
            )
        ])

        let runtime = WPEMetalRuntimeUniforms(
            time: 1,
            daytime: 0.25,
            brightness: 1,
            pointerPosition: SIMD2<Double>(0.2, 0.8)
        )
        let camera = WPEMetalCameraUniforms(
            orthogonalProjection: WPESceneOrthogonalProjection(width: 64, height: 32, auto: true),
            sceneCamera: .defaultCamera
        )

        let (prepared, frameUniforms) = pipeline.addingMetalRuntimeUniforms(runtime, camera: camera)
        let values = prepared.layers[0].passes[0].uniformValues

        #expect(values["g_Color"]?.vectorValue == [1, 0, 0, 1])
        // Frame-global uniforms live in the frame context now, not the pass dict.
        func frame(_ name: String) -> WPESceneShaderConstantValue? {
            frameUniforms.value(named: name, passID: "solid.0")
        }
        #expect(frame("g_Time")?.numberValue == 1)
        #expect(frame("g_Daytime")?.numberValue == 0.25)
        #expect(frame("g_Brightness")?.numberValue == 1)
        #expect(frame("g_PointerPosition")?.vectorValue == [0.2, 0.8])
        #expect(frame("g_ViewProjectionMatrix")?.vectorValue?.count == 16)
        #expect(frame("g_ModelMatrix")?.vectorValue == [1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1])
        #expect(frame("g_NormalModelMatrix")?.vectorValue == [1, 0, 0, 0, 1, 0, 0, 0, 1])
    }

    @Test("Prepared pipeline applies dynamic origin overrides before object uniforms")
    func preparedPipelineAppliesDynamicOriginOverrides() {
        let pass = WPERenderPass(
            id: "image.0",
            phase: .material,
            shader: "genericimage",
            source: .previous,
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
        let layer = WPERenderLayer(
            objectID: "154",
            objectName: "苍月草1/Nemophila1",
            imagePath: "models/nemophila.json",
            materialPath: nil,
            geometry: WPERenderLayerGeometry(
                origin: SIMD3<Double>(860, 133, 0),
                scale: SIMD3<Double>(1, 1, 1),
                angles: SIMD3<Double>(0, 0, 0),
                alignment: .center,
                size: CGSize(width: 360, height: 248),
                alpha: 1,
                color: SIMD3<Double>(1, 1, 1),
                brightness: 1
            ),
            compositeA: "a",
            compositeB: "b",
            localFBOs: [],
            passes: [pass]
        )
        let pipeline = WPEPreparedRenderPipeline(layers: [
            WPEPreparedRenderLayer(
                graphLayer: layer,
                passes: [
                    WPEPreparedRenderPass(
                        pass: pass,
                        shader: nil,
                        textureBindings: [:],
                        comboValues: [:],
                        uniformValues: [:]
                    )
                ]
            )
        ])

        let runtime = WPEMetalRuntimeUniforms(
            time: 1,
            daytime: 0,
            brightness: 1,
            pointerPosition: SIMD2<Double>(0.25, 0.75)
        )
        let (_, frameUniforms) = pipeline
            .applyingLayerTransforms(
                origins: ["154": SIMD3<Double>(960, 1620, 0)],
                scales: [:],
                angles: [:]
            )
            .addingMetalRuntimeUniforms(
                runtime,
                camera: WPEMetalCameraUniforms(
                    orthogonalProjection: WPESceneOrthogonalProjection(width: 3840, height: 2160, auto: true),
                    sceneCamera: .defaultCamera
                )
            )

        let model = frameUniforms.value(named: "g_ModelMatrix", passID: "image.0")?.vectorValue
        #expect(model?[12] == 960)
        #expect(model?[13] == 1620)
    }

    @Test("Animated single shader constants clamp to final keyframe after their duration")
    func animatedSingleShaderConstantsClampToFinalKeyframe() throws {
        let animatedAlpha = try #require(Self.animatedScalarConstant(
            mode: "single",
            wrapLoop: nil,
            length: 90,
            keys: [
                (0, 1),
                (60, 1),
                (90, 0)
            ]
        ))
        let pipeline = Self.pipelineWithUniform("alpha", value: animatedAlpha)

        let prepared = pipeline.addingMetalRuntimeUniforms(
            WPEMetalRuntimeUniforms(
                time: 4,
                daytime: 0,
                brightness: 1,
                pointerPosition: SIMD2<Double>(0.5, 0.5)
            ),
            camera: .identity
        ).pipeline

        #expect(prepared.layers[0].passes[0].uniformValues["alpha"]?.numberValue == 0)
    }

    @Test("Animated loop shader constants wrap by authored animation length")
    func animatedLoopShaderConstantsWrapByLength() throws {
        let animatedAlpha = try #require(Self.animatedScalarConstant(
            mode: "loop",
            wrapLoop: true,
            length: 90,
            keys: [
                (0, 0),
                (30, 1),
                (90, 0)
            ]
        ))
        let pipeline = Self.pipelineWithUniform("alpha", value: animatedAlpha)

        let prepared = pipeline.addingMetalRuntimeUniforms(
            WPEMetalRuntimeUniforms(
                time: 4,
                daytime: 0,
                brightness: 1,
                pointerPosition: SIMD2<Double>(0.5, 0.5)
            ),
            camera: .identity
        ).pipeline

        #expect(prepared.layers[0].passes[0].uniformValues["alpha"]?.numberValue == 1)
    }

    private static func animatedScalarConstant(
        mode: String,
        wrapLoop: Bool?,
        length: Int,
        keys: [(frame: Int, value: Double)]
    ) -> WPESceneShaderConstantValue? {
        var options: [String: Any] = [
            "fps": 30,
            "length": length,
            "mode": mode
        ]
        options["wraploop"] = wrapLoop as Any
        return WPEValueParser.shaderConstant([
            "value": keys.first?.value ?? 0,
            "animation": [
                "c0": keys.map { key in
                    [
                        "frame": key.frame,
                        "value": key.value
                    ]
                },
                "options": options
            ]
        ])
    }

    private static func pipelineWithUniform(
        _ name: String,
        value: WPESceneShaderConstantValue,
        materialUniformNames: [String: String] = [:]
    ) -> WPEPreparedRenderPipeline {
        let pass = WPERenderPass(
            id: "opacity.0",
            phase: .effect(file: "effects/opacity/effect.json"),
            shader: "effects/opacity",
            source: .previous,
            target: .scene,
            textures: [:],
            binds: [:],
            constants: [name: value],
            combos: [:],
            blending: "normal",
            cullMode: "nocull",
            depthTest: "disabled",
            depthWrite: "disabled"
        )
        let layer = WPERenderLayer(
            objectID: "layer",
            objectName: "Layer",
            imagePath: "models/layer.json",
            materialPath: nil,
            geometry: .identity,
            compositeA: "a",
            compositeB: "b",
            localFBOs: [],
            passes: [pass]
        )
        return WPEPreparedRenderPipeline(layers: [
            WPEPreparedRenderLayer(
                graphLayer: layer,
                passes: [
                    WPEPreparedRenderPass(
                        pass: pass,
                        shader: WPEShaderProgram(
                            name: "effects/opacity",
                            vertexSource: "",
                            fragmentSource: "",
                            isBuiltin: true
                        ),
                        textureBindings: [:],
                        comboValues: [:],
                        uniformValues: [name: value],
                        materialUniformNames: materialUniformNames
                    )
                ]
            )
        ])
    }

    /// Solid passes bind `g_Color` from `uniformValues`, never from geometry.
    /// Script overrides clear the authored animation, so without a write-through
    /// (or the alphaAnimation rebuild trigger) the layer freezes at load color.
    private static func solidPipeline(
        seedColor: [Double] = [1, 1, 1, 1],
        geometry: WPERenderLayerGeometry = .identity
    ) -> WPEPreparedRenderPipeline {
        let seed = WPESceneShaderConstantValue.vector(seedColor)
        let pass = WPERenderPass(
            id: "solid.0",
            phase: .material,
            shader: WPEBuiltinShaderKind.solidLayer.rawValue,
            source: .image("models/solid.json"),
            target: .scene,
            textures: [:],
            binds: [:],
            constants: ["g_Color": seed],
            combos: [:],
            blending: "normal",
            cullMode: "nocull",
            depthTest: "disabled",
            depthWrite: "disabled"
        )
        let layer = WPERenderLayer(
            objectID: "layer",
            objectName: "Solid",
            imagePath: "models/solid.json",
            materialPath: nil,
            geometry: geometry,
            compositeA: "a",
            compositeB: "b",
            localFBOs: [],
            passes: [pass]
        )
        return WPEPreparedRenderPipeline(layers: [
            WPEPreparedRenderLayer(
                graphLayer: layer,
                passes: [
                    WPEPreparedRenderPass(
                        pass: pass,
                        shader: nil,
                        textureBindings: [:],
                        comboValues: [:],
                        uniformValues: ["g_Color": seed],
                        materialUniformNames: [:]
                    )
                ]
            )
        ])
    }

    private static func preparedSolidValues(
        _ pipeline: WPEPreparedRenderPipeline,
        scriptedConstants: [String: [String: WPESceneShaderConstantValue]] = [:]
    ) -> [String: WPESceneShaderConstantValue]? {
        pipeline.addingMetalRuntimeUniforms(
            WPEMetalRuntimeUniforms(
                time: 4,
                daytime: 0,
                brightness: 1,
                pointerPosition: SIMD2<Double>(0.5, 0.5)
            ),
            camera: .identity,
            scriptedConstants: scriptedConstants
        ).pipeline.layers.first?.passes.first?.uniformValues
    }

    @Test("Script color override survives through the per-frame prepare")
    func scriptColorOverrideUpdatesSolidUniform() throws {
        let tinted = Self.solidPipeline()
            .applyingLayerColor(["layer": SIMD3<Double>(0.2, 0.4, 0.6)])
        let values = try #require(Self.preparedSolidValues(tinted))
        #expect(values["g_Color"]?.vectorValue == [0.2, 0.4, 0.6, 1])
    }

    @Test("Script alpha override writes g_Color.w and survives the prepare")
    func scriptAlphaOverrideUpdatesSolidUniform() throws {
        let faded = Self.solidPipeline()
            .applyingLayerAlpha(["layer": 0.25])
        let values = try #require(Self.preparedSolidValues(faded))
        #expect(values["g_Color"]?.vectorValue == [1, 1, 1, 0.25])
    }

    @Test("Alpha override keeps an authored rgb that differs from the layer tint")
    func alphaOverridePreservesAuthoredColor() throws {
        let faded = Self.solidPipeline(seedColor: [1, 0, 0, 1])
            .applyingLayerAlpha(["layer": 0.25])
        let values = try #require(Self.preparedSolidValues(faded))
        #expect(values["g_Color"]?.vectorValue == [1, 0, 0, 0.25])
    }

    @Test("Alpha-only animation rebuilds solid g_Color each frame")
    func alphaOnlyAnimationRebuildsSolidColor() throws {
        let animatedAlpha = WPESceneAnimatedValue(
            animation: WPESceneNumericAnimation(
                tracks: [[
                    .init(frame: 0, value: 1),
                    .init(frame: 60, value: 1),
                    .init(frame: 90, value: 0)
                ]],
                fps: 30, length: 90, mode: "single", wrapLoop: false
            ),
            scalarFallback: 1,
            vectorFallback: nil
        )
        let geometry = WPERenderLayerGeometry(
            origin: .zero,
            scale: SIMD3<Double>(1, 1, 1),
            angles: .zero,
            alignment: .center,
            size: CGSize(width: 10, height: 10),
            alpha: 1,
            alphaAnimation: animatedAlpha,
            color: SIMD3<Double>(1, 1, 1),
            colorAnimation: nil,
            brightness: 1
        )
        let values = try #require(Self.preparedSolidValues(Self.solidPipeline(geometry: geometry)))
        #expect(values["g_Color"]?.vectorValue == [1, 1, 1, 0])
    }

    @Test("A scripted g_Color beats the animated layer tint")
    func scriptedColorBeatsAnimatedTint() throws {
        let animatedAlpha = WPESceneAnimatedValue(
            animation: WPESceneNumericAnimation(
                tracks: [[
                    .init(frame: 0, value: 1),
                    .init(frame: 90, value: 0)
                ]],
                fps: 30, length: 90, mode: "single", wrapLoop: false
            ),
            scalarFallback: 1,
            vectorFallback: nil
        )
        let geometry = WPERenderLayerGeometry(
            origin: .zero,
            scale: SIMD3<Double>(1, 1, 1),
            angles: .zero,
            alignment: .center,
            size: CGSize(width: 10, height: 10),
            alpha: 1,
            alphaAnimation: animatedAlpha,
            color: SIMD3<Double>(1, 1, 1),
            colorAnimation: nil,
            brightness: 1
        )
        let values = try #require(Self.preparedSolidValues(
            Self.solidPipeline(geometry: geometry),
            scriptedConstants: ["solid.0": ["g_Color": .vector([1, 0, 0, 1])]]
        ))
        #expect(values["g_Color"]?.vectorValue == [1, 0, 0, 1])
    }

    /// Scripts address a constant by its AUTHORED name while the pass is keyed by
    /// the SHADER name, so an untranslated merge writes to a slot no shader reads
    /// and the seeded value silently keeps winning.
    @Test("Scripted constants merge under the shader uniform name, not the authored one")
    func scriptedConstantsTranslateAuthoredNameToShaderUniform() {
        let pipeline = Self.pipelineWithUniform(
            "g_Multiply",
            value: .number(1),
            materialUniformNames: ["multiply1": "g_Multiply"]
        )

        let prepared = pipeline.addingMetalRuntimeUniforms(
            WPEMetalRuntimeUniforms(
                time: 0,
                daytime: 0,
                brightness: 1,
                pointerPosition: SIMD2<Double>(0.5, 0.5)
            ),
            camera: .identity,
            scriptedConstants: ["opacity.0": ["multiply1": .number(0.25)]]
        ).pipeline

        let values = prepared.layers[0].passes[0].uniformValues
        #expect(values["g_Multiply"]?.numberValue == 0.25)
        #expect(values["multiply1"] == nil)
    }

    @Test("Scripted constants with no material mapping keep their own name")
    func scriptedConstantsWithoutMappingKeepAuthoredName() {
        let pipeline = Self.pipelineWithUniform("alpha", value: .number(1))

        let prepared = pipeline.addingMetalRuntimeUniforms(
            WPEMetalRuntimeUniforms(
                time: 0,
                daytime: 0,
                brightness: 1,
                pointerPosition: SIMD2<Double>(0.5, 0.5)
            ),
            camera: .identity,
            scriptedConstants: ["opacity.0": ["alpha": .number(0.5)]]
        ).pipeline

        #expect(prepared.layers[0].passes[0].uniformValues["alpha"]?.numberValue == 0.5)
    }

    // Windows RenderDoc capture 3448877775: same-frame g_AudioSpectrum32Left and
    // g_AudioSpectrum16Left. WPE derives 16 bands from 32 by MAX over adjacent
    // pairs — max-pool reproduces the captured 16-band array exactly (error 0.0)
    // across 9 captures / 18 array pairs, mean-pool is off by 0.10–0.43.
    private static let windows32Left: [Double] = [
        0.2914999723434448, 0.16796553134918213, 0.500199556350708, 0.49108681082725525,
        0.16706208884716034, 0.320111483335495, 0.9157431721687317, 0.4100834131240845,
        0.21221551299095154, 0.14724524319171906, 0.6814256310462952, 0.3106551766395569,
        0.3115047216415405, 0.8946790099143982, 0.5414815545082092, 0.23364144563674927,
        0.9521645307540894, 0.43884873390197754, 0.5466235876083374, 0.36862146854400635,
        0.3437141180038452, 0.876319169998169, 0.24152739346027374, 0.26156309247016907,
        0.1979193538427353, 0.5026334524154663, 0.2063640058040619, 0.2777906060218811,
        0.3293505311012268, 0.1483396738767624, 0.13266953825950623, 0.18672189116477966
    ]
    private static let windows16Left: [Double] = [
        0.2914999723434448, 0.500199556350708, 0.320111483335495, 0.9157431721687317,
        0.21221551299095154, 0.6814256310462952, 0.8946790099143982, 0.5414815545082092,
        0.9521645307540894, 0.5466235876083374, 0.876319169998169, 0.26156309247016907,
        0.5026334524154663, 0.2777906060218811, 0.3293505311012268, 0.18672189116477966
    ]

    @Test("Audio 32→16 max-pool reproduces the Windows capture bit-for-bit")
    func audioBandsMaxPoolMatchesWindowsCapture() throws {
        // Duplicating each 32-band value into an adjacent pair makes the 64→32
        // stage operator-neutral (mean and max agree on equal pairs), so the
        // 32→16 stage alone discriminates against the L1 expectation.
        var spectrum64 = [Double]()
        for value in Self.windows32Left {
            spectrum64.append(value)
            spectrum64.append(value)
        }
        let uniforms = WPEMetalRuntimeUniforms(
            time: 0,
            daytime: 0,
            brightness: 1,
            pointerPosition: SIMD2<Double>(0.5, 0.5),
            audioSpectrum: spectrum64
        )
        guard case let .vector(s32)? = uniforms.uniformValues["g_AudioSpectrum32Left"],
              case let .vector(s16)? = uniforms.uniformValues["g_AudioSpectrum16Left"],
              case let .vector(s16R)? = uniforms.uniformValues["g_AudioSpectrum16Right"]
        else {
            Issue.record("audio spectrum uniforms missing")
            return
        }
        // Max is a pure selection, so equality is exact — no tolerance needed.
        #expect(s32 == Self.windows32Left)
        #expect(s16 == Self.windows16Left)
        #expect(s16R == Self.windows16Left)
    }

    @Test("Audio band halving keeps the larger neighbour, not the average")
    func audioBandHalvingIsMaxNotMean() throws {
        var spectrum64 = [Double](repeating: 0, count: 64)
        for index in spectrum64.indices { spectrum64[index] = Double(index + 1) }
        let uniforms = WPEMetalRuntimeUniforms(
            time: 0,
            daytime: 0,
            brightness: 1,
            pointerPosition: SIMD2<Double>(0.5, 0.5),
            audioSpectrum: spectrum64
        )
        guard case let .vector(s32)? = uniforms.uniformValues["g_AudioSpectrum32Left"],
              case let .vector(s16)? = uniforms.uniformValues["g_AudioSpectrum16Left"]
        else {
            Issue.record("audio spectrum uniforms missing")
            return
        }
        // Hoisted out of `#expect`: inside the macro's generic
        // `__checkBinaryOperation` expansion these two `.map` closures take the
        // 6.3.3 type checker past its 300ms limit and fail the release build.
        let expected32: [Double] = (0..<32).map { Double(2 * $0 + 2) }
        let expected16: [Double] = (0..<16).map { Double(4 * $0 + 4) }
        #expect(s32 == expected32)
        #expect(s16 == expected16)
    }
}
