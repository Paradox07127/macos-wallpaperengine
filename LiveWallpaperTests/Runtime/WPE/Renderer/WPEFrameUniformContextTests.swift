#if !LITE_BUILD
import Foundation
import LiveWallpaperProWPE
import Metal
import Testing

@testable import LiveWallpaper

/// Frame-global uniforms via `WPEFrameUniformContext` must match the old merge.
@Suite("WPE frame uniform context")
struct WPEFrameUniformContextTests {

    // MARK: - Fixtures

    private static func makePass(
        id: String,
        constants: [String: WPESceneShaderConstantValue] = [:],
        uniformValues: [String: WPESceneShaderConstantValue],
        materialUniformNames: [String: String] = [:]
    ) -> (WPERenderPass, WPEPreparedRenderPass) {
        let pass = WPERenderPass(
            id: id,
            phase: .effect(file: "effects/test/effect.json"),
            shader: "effects/test",
            source: .previous,
            target: .scene,
            textures: [:],
            binds: [:],
            constants: constants,
            combos: [:],
            blending: "normal",
            cullMode: "nocull",
            depthTest: "disabled",
            depthWrite: "disabled"
        )
        let prepared = WPEPreparedRenderPass(
            pass: pass,
            shader: WPEShaderProgram(
                name: "effects/test",
                vertexSource: "",
                fragmentSource: "",
                isBuiltin: false
            ),
            textureBindings: [:],
            comboValues: [:],
            uniformValues: uniformValues,
            materialUniformNames: materialUniformNames
        )
        return (pass, prepared)
    }

    private static func makeLayer(
        objectID: String,
        origin: SIMD3<Double> = SIMD3<Double>(0, 0, 0),
        passes: [WPERenderPass]
    ) -> WPERenderLayer {
        WPERenderLayer(
            objectID: objectID,
            objectName: "Layer \(objectID)",
            imagePath: "materials/base.png",
            materialPath: nil,
            geometry: WPERenderLayerGeometry(
                origin: origin,
                scale: SIMD3<Double>(1, 1, 1),
                angles: SIMD3<Double>(0, 0, 0),
                alignment: .center,
                size: CGSize(width: 64, height: 64),
                alpha: 1,
                color: SIMD3<Double>(1, 1, 1),
                brightness: 1
            ),
            compositeA: "a",
            compositeB: "b",
            localFBOs: [],
            passes: passes
        )
    }

    private static let runtime = WPEMetalRuntimeUniforms(
        time: 1.5,
        daytime: 0.25,
        brightness: 0.8,
        pointerPosition: SIMD2<Double>(0.2, 0.8)
    )

    private static let camera = WPEMetalCameraUniforms(
        orthogonalProjection: WPESceneOrthogonalProjection(width: 64, height: 32, auto: true),
        sceneCamera: .defaultCamera
    )

    /// The OLD `addingMetalRuntimeUniforms` per-pass merge, replicated verbatim
    /// as the semantic reference: resolve authored → scripted (translated) →
    /// runtime → camera → object, later inserts winning.
    private static func legacyMergedValues(
        pass: WPEPreparedRenderPass,
        layer: WPERenderLayer,
        scripted: [String: WPESceneShaderConstantValue]?
    ) -> [String: WPESceneShaderConstantValue] {
        var values = pass.uniformValues.mapValues { $0.resolved(at: runtime.time) }
        if let scripted {
            for (key, value) in scripted {
                values[pass.materialUniformNames[key] ?? key] = value
            }
        }
        for (key, value) in runtime.uniformValues { values[key] = value }
        for (key, value) in camera.uniformValues { values[key] = value }
        let geometry = layer.geometry
        let objectUniforms = WPEMetalObjectUniforms.uniformValues(
            origin: geometry.origin,
            scale: geometry.scale,
            angles: geometry.angles
        )
        for (key, value) in objectUniforms { values[key] = value }
        return values
    }

    private static func slot(_ name: String, _ index: Int, type: String = "float", slotCount: Int = 1) -> WPEUniformSlot {
        WPEUniformSlot(name: name, glslType: type, slot: index, slotCount: slotCount)
    }

    /// A 0→1 scalar keyframe animation (60 frames @ 30 fps, single-shot).
    private static func makeAnimatedConstant() -> WPESceneShaderConstantValue? {
        let raw: [String: Any] = [
            "value": 0.0,
            "animation": [
                "c0": [
                    ["frame": 0, "value": 0.0],
                    ["frame": 60, "value": 1.0]
                ],
                "options": ["fps": 30, "length": 60, "mode": "single"]
            ] as [String: Any]
        ]
        return WPEValueParser.shaderConstant(raw)
    }

    // MARK: - Slot-for-slot parity against the legacy merge

    @Test("Four pass classes pack identical slots to the legacy merged-dict reference")
    func packedSlotsMatchLegacyMergeReference() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let executor = try WPEMetalRenderExecutor(device: device)

        let animatedValue = try #require(Self.makeAnimatedConstant())

        // 1. Pure static; 2. animated value; 3. scripted override;
        // 4. authored key colliding with a runtime key (g_Time).
        let (staticRaw, staticPass) = Self.makePass(
            id: "static.0",
            uniformValues: ["u_Static": .number(3.25), "g_Color": .vector([0.5, 0.25, 1, 1])]
        )
        let (animatedRaw, animatedPass) = Self.makePass(
            id: "animated.0",
            uniformValues: ["u_Anim": animatedValue, "u_Static": .number(7)]
        )
        let (scriptedRaw, scriptedPass) = Self.makePass(
            id: "scripted.0",
            uniformValues: ["g_Multiply": .number(1)],
            materialUniformNames: ["multiply1": "g_Multiply"]
        )
        let (collidingRaw, collidingPass) = Self.makePass(
            id: "colliding.0",
            uniformValues: ["g_Time": .number(999), "u_Own": .number(2)]
        )
        let scriptedConstants: [String: [String: WPESceneShaderConstantValue]] = [
            "scripted.0": ["multiply1": .number(0.25)]
        ]

        let layers = [
            Self.makeLayer(objectID: "L1", passes: [staticRaw, animatedRaw]),
            Self.makeLayer(objectID: "L2", origin: SIMD3<Double>(100, 50, 0), passes: [scriptedRaw, collidingRaw])
        ]
        let pipeline = WPEPreparedRenderPipeline(layers: [
            WPEPreparedRenderLayer(graphLayer: layers[0], passes: [staticPass, animatedPass]),
            WPEPreparedRenderLayer(graphLayer: layers[1], passes: [scriptedPass, collidingPass])
        ])

        let (prepared, frameUniforms) = pipeline.addingMetalRuntimeUniforms(
            Self.runtime,
            camera: Self.camera,
            scriptedConstants: scriptedConstants
        )
        executor.frameUniformContext = frameUniforms
        defer { executor.frameUniformContext = .empty }

        let layout = [
            Self.slot("g_Time", 0),
            Self.slot("u_Static", 1),
            Self.slot("u_Anim", 2),
            Self.slot("g_Multiply", 3),
            Self.slot("u_Own", 4),
            Self.slot("g_Color", 5, type: "vec4"),
            Self.slot("g_ViewProjectionMatrix", 6, type: "mat4", slotCount: 4),
            Self.slot("g_ModelMatrix", 10, type: "mat4", slotCount: 4),
            Self.slot("g_Daytime", 14),
            Self.slot("g_time", 15) // lowercased spelling → case-insensitive fallback
        ]

        var newSlotsByPassID: [String: [SIMD4<Float>]] = [:]
        for layer in prepared.layers {
            for pass in layer.passes {
                newSlotsByPassID[pass.id] = executor.packTranslatedUniforms(for: pass, layout: layout)
            }
        }

        // Reference: a pass whose dict IS the legacy merge, packed by the SAME
        // per-pass packer with no frame context — identical packing logic, old
        // merge precedence.
        executor.frameUniformContext = .empty
        let originals: [(WPEPreparedRenderPass, Int)] = [
            (staticPass, 0), (animatedPass, 0), (scriptedPass, 1), (collidingPass, 1)
        ]
        for (original, layerIndex) in originals {
            let legacy = Self.legacyMergedValues(
                pass: original,
                layer: layers[layerIndex],
                scripted: scriptedConstants[original.id]
            )
            let referencePass = WPEPreparedRenderPass(
                pass: WPERenderPass(
                    id: original.id + ".ref",
                    phase: original.pass.phase,
                    shader: original.pass.shader,
                    source: original.pass.source,
                    target: original.pass.target,
                    textures: original.pass.textures,
                    binds: original.pass.binds,
                    constants: original.pass.constants,
                    combos: original.pass.combos,
                    blending: original.pass.blending,
                    cullMode: original.pass.cullMode,
                    depthTest: original.pass.depthTest,
                    depthWrite: original.pass.depthWrite
                ),
                shader: original.shader,
                textureBindings: original.textureBindings,
                comboValues: original.comboValues,
                uniformValues: legacy,
                materialUniformNames: original.materialUniformNames
            )
            let referenceSlots = executor.packTranslatedUniforms(for: referencePass, layout: layout)
            let newSlots = try #require(newSlotsByPassID[original.id])
            #expect(
                newSlots == referenceSlots,
                "slot mismatch for pass \(original.id): \(newSlots) vs \(referenceSlots)"
            )
        }
    }

    @Test("Runtime g_Time beats an authored g_Time=999 and a scripted g_Time")
    func runtimeTimeWinsOverAuthoredAndScripted() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let executor = try WPEMetalRenderExecutor(device: device)

        let (raw, pass) = Self.makePass(
            id: "priority.0",
            uniformValues: ["g_Time": .number(999)]
        )
        let layer = Self.makeLayer(objectID: "P", passes: [raw])
        let pipeline = WPEPreparedRenderPipeline(layers: [
            WPEPreparedRenderLayer(graphLayer: layer, passes: [pass])
        ])

        let (prepared, frameUniforms) = pipeline.addingMetalRuntimeUniforms(
            Self.runtime,
            camera: Self.camera,
            scriptedConstants: ["priority.0": ["g_Time": .number(777)]]
        )
        executor.frameUniformContext = frameUniforms
        defer { executor.frameUniformContext = .empty }

        let slots = executor.packTranslatedUniforms(
            for: prepared.layers[0].passes[0],
            layout: [Self.slot("g_Time", 0)]
        )
        // Old merge inserted runtime last → runtime time (1.5) always won.
        #expect(slots[0].x == 1.5)
    }

    @Test("Camera view globals beat authored sentinels through translated uniform binding")
    func cameraViewGlobalsBeatAuthoredValues() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let executor = try WPEMetalRenderExecutor(device: device)
        let names = ["g_EyePosition", "g_ViewForward", "g_ViewRight", "g_ViewUp"]
        let (_, pass) = Self.makePass(
            id: "camera.priority",
            uniformValues: Dictionary(
                uniqueKeysWithValues: names.map { ($0, WPESceneShaderConstantValue.vector([-9, -9, -9])) }
            )
        )
        let camera = WPEMetalCameraUniforms(
            orthogonalProjection: WPESceneOrthogonalProjection(width: 64, height: 32, auto: true),
            sceneCamera: WPESceneCamera(
                center: SIMD3<Double>(7, 8, 8),
                eye: SIMD3<Double>(7, 8, 9),
                up: SIMD3<Double>(0, 1, 0),
                nearZ: 0.01,
                farZ: 10_000,
                fov: 50
            ),
            usesPerspectiveProjection: true
        )
        executor.frameUniformContext = WPEFrameUniformContext(
            runtimeUniformValues: [:],
            cameraUniformValues: camera.uniformValues,
            objectUniformValuesByPassID: [:]
        )
        defer { executor.frameUniformContext = .empty }

        let slots = executor.packTranslatedUniforms(
            for: pass,
            layout: names.enumerated().map { index, name in
                Self.slot(name, index, type: "vec3")
            }
        )
        #expect(slots[0] == SIMD4<Float>(7, 8, 9, 0))
        #expect(slots[1] == SIMD4<Float>(0, 0, -1, 0))
        #expect(slots[2] == SIMD4<Float>(1, 0, 0, 0))
        #expect(slots[3] == SIMD4<Float>(0, 1, 0, 0))
    }

    @Test("Official matrix counterparts bind per pass, beat authored values, and follow the camera")
    func officialMatrixCounterpartsAreBoundAtObjectScope() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let executor = try WPEMetalRenderExecutor(device: device)
        let names = [
            "g_ModelMatrixInverse",
            "g_ModelViewProjectionMatrix",
            "g_ModelViewProjectionMatrixInverse",
            "g_LayerModelMatrix"
        ]
        let sentinel = WPESceneShaderConstantValue.vector([Double](repeating: -9, count: 16))
        let (_, passA) = Self.makePass(
            id: "matrix.a",
            uniformValues: Dictionary(uniqueKeysWithValues: names.map { ($0, sentinel) })
        )
        let (_, passB) = Self.makePass(
            id: "matrix.b",
            uniformValues: Dictionary(uniqueKeysWithValues: names.map { ($0, sentinel) })
        )
        let objectA = WPEMetalObjectUniforms.uniformValues(
            origin: SIMD3<Double>(2, 3, 4), scale: SIMD3<Double>(2, 1, 1), angles: .zero
        )
        let objectB = WPEMetalObjectUniforms.uniformValues(
            origin: SIMD3<Double>(9, 8, 7), scale: SIMD3<Double>(1, 3, 1), angles: .zero
        )
        let cameraA = WPEMetalCameraUniforms(
            orthogonalProjection: WPESceneOrthogonalProjection(width: 64, height: 32, auto: true),
            sceneCamera: .defaultCamera
        )
        let frameA = WPEFrameUniformContext(
            runtimeUniformValues: [:],
            cameraUniformValues: cameraA.uniformValues,
            objectUniformValuesByPassID: ["matrix.a": objectA, "matrix.b": objectB]
        )
        let layout = names.enumerated().map { index, name in
            Self.slot(name, index * 4, type: "mat4", slotCount: 4)
        }

        executor.frameUniformContext = frameA
        let packedA = executor.packTranslatedUniforms(for: passA, layout: layout)
        let packedB = executor.packTranslatedUniforms(for: passB, layout: layout)
        #expect(packedA != packedB, "each prepared pass must use its own layer/object matrices")
        #expect(packedA.allSatisfy { $0 != SIMD4<Float>(repeating: -9) })
        #expect(frameA.value(named: "g_ModelViewProjectionMatrix", passID: "missing") == nil)

        let cameraB = WPEMetalCameraUniforms(
            orthogonalProjection: WPESceneOrthogonalProjection(width: 128, height: 64, auto: true),
            sceneCamera: .defaultCamera
        )
        executor.frameUniformContext = WPEFrameUniformContext(
            runtimeUniformValues: [:],
            cameraUniformValues: cameraB.uniformValues,
            objectUniformValuesByPassID: ["matrix.a": objectA]
        )
        let packedAfterCameraChange = executor.packTranslatedUniforms(for: passA, layout: layout)
        #expect(
            Array(packedAfterCameraChange[4..<8]) != Array(packedA[4..<8]),
            "MVP must be composed from the current camera, not cached with the object"
        )
        // Direct object-only counterparts do not move with the camera.
        #expect(Array(packedAfterCameraChange[0..<4]) == Array(packedA[0..<4]))
        #expect(Array(packedAfterCameraChange[12..<16]) == Array(packedA[12..<16]))
        executor.frameUniformContext = .empty
    }

    // MARK: - Static-pass structure reuse

    @Test("A fully static pass is reused without cloning; animated/scripted passes are re-resolved")
    func staticPassStructureIsReused() throws {
        let animatedValue = try #require(Self.makeAnimatedConstant())
        let (staticRaw, staticPass) = Self.makePass(
            id: "static.0",
            uniformValues: ["u_Static": .number(3.25)]
        )
        let (animatedRaw, animatedPass) = Self.makePass(
            id: "animated.0",
            uniformValues: ["u_Anim": animatedValue]
        )
        #expect(staticPass.hasAnimatedUniformValues == false)
        #expect(animatedPass.hasAnimatedUniformValues == true)

        let layer = Self.makeLayer(objectID: "S", passes: [staticRaw, animatedRaw])
        let pipeline = WPEPreparedRenderPipeline(layers: [
            WPEPreparedRenderLayer(graphLayer: layer, passes: [staticPass, animatedPass])
        ])
        let (prepared, _) = pipeline.addingMetalRuntimeUniforms(Self.runtime, camera: Self.camera)

        // Static pass: identical structure, no frame-global keys leaked in.
        #expect(prepared.layers[0].passes[0] == staticPass)
        #expect(prepared.layers[0].passes[0].uniformValues["g_Time"] == nil)
        // Animated pass: value re-resolved at the frame time (not the seed).
        #expect(
            prepared.layers[0].passes[1].uniformValues["u_Anim"]
                == animatedValue.resolved(at: Self.runtime.time)
        )
        #expect(prepared.layers[0].passes[1].uniformValues["u_Anim"]?.numberValue != 0)
    }

    // MARK: - Frame-global reads outside the transpiled path

    @Test("floatScalar frame overload: runtime g_Brightness beats authored brightness")
    func frameAwareFloatScalarPrefersRuntimeBrightness() {
        let (_, pass) = Self.makePass(
            id: "bright.0",
            constants: ["brightness": .number(0.3)],
            uniformValues: ["brightness": .number(0.3)]
        )
        let frame = WPEFrameUniformContext(
            runtimeUniformValues: Self.runtime.uniformValues,
            cameraUniformValues: Self.camera.uniformValues,
            objectUniformValuesByPassID: [:]
        )
        let value = WPEMetalShaderInputs.floatScalar(
            named: ["g_Brightness", "u_Brightness", "brightness"],
            in: pass,
            frame: frame,
            default: 1
        )
        // Old merge: runtime g_Brightness (0.8) was always present and won.
        #expect(value == 0.8)
        // Control: without the frame context the authored value wins — proving
        // the frame parameter is what carries the precedence.
        let bare = WPEMetalShaderInputs.floatScalar(
            named: ["g_Brightness", "u_Brightness", "brightness"],
            in: pass,
            default: 1
        )
        #expect(bare == Float(0.3))
    }

    @Test("Lowercased frame-global index resolves case-variant spellings to canonical names")
    func lowercasedIndexCoversFrameGlobalNames() {
        let index = WPEFrameUniformContext.canonicalNameByLowercased
        #expect(index["g_time"] == "g_Time")
        #expect(index["g_viewprojectionmatrix"] == "g_ViewProjectionMatrix")
        #expect(index["g_modelmatrix"] == "g_ModelMatrix")
        #expect(index["g_modelmatrixinverse"] == "g_ModelMatrixInverse")
        #expect(index["g_modelviewprojectionmatrix"] == "g_ModelViewProjectionMatrix")
        #expect(index["g_modelviewprojectionmatrixinverse"] == "g_ModelViewProjectionMatrixInverse")
        #expect(index["g_layermodelmatrix"] == "g_LayerModelMatrix")
        #expect(index["g_audiospectrum64left"] == "g_AudioSpectrum64Left")
        #expect(index["u_notaframeglobal"] == nil)
    }
}
#endif
