#if !LITE_BUILD
import CoreGraphics
import Foundation
import LiveWallpaperProWPE
import Metal
import Testing
@testable import LiveWallpaper

/// Characterization for W5.2b: the per-slot uniform SOURCE plan compiled once
/// per (pass, layout) must resolve every slot to the same value the old
/// per-frame candidate walk did.
///
/// `LegacyReference` below is that walk plus its packer, replicated verbatim
/// from the pre-plan `translatedUniformValue` / `packTranslatedUniforms`. It is
/// deliberately a COPY, not a call into production code: it is the only thing
/// that fails when the compiled plan reorders a priority, which is what the
/// mutation check in this file's header comment exercises.
@Suite("WPE uniform resolution plan")
struct WPEUniformResolutionPlanTests {

    // MARK: - Legacy reference (verbatim replica of the pre-plan resolution)

    private enum LegacyReference {
        static func candidates(for uniform: WPEUniformSlot) -> [String] {
            var names: [String] = [uniform.name]
            if let materialName = uniform.materialName, !materialName.isEmpty {
                names.append(materialName)
            }
            if uniform.name.hasPrefix("u_") {
                let base = String(uniform.name.dropFirst(2))
                if !base.isEmpty {
                    names.append(base)
                    names.append(base.prefix(1).uppercased() + String(base.dropFirst()))
                }
            }
            var seen = Set<String>()
            return names.filter { seen.insert($0).inserted }
        }

        static func lowercasedKeyMap(
            _ values: [String: WPESceneShaderConstantValue]
        ) -> [String: String] {
            var map: [String: String] = [:]
            for key in values.keys where map[key.lowercased()] == nil {
                map[key.lowercased()] = key
            }
            return map
        }

        static func value(
            uniform: WPEUniformSlot,
            pass: WPEPreparedRenderPass,
            frame: WPEFrameUniformContext,
            sceneSize: CGSize,
            texturesBySlot: WPEMetalTextureSlotTable?
        ) -> WPESceneShaderConstantValue? {
            if uniform.name == "g_TexelSize", sceneSize.width > 0, sceneSize.height > 0 {
                return .vector([1 / Double(sceneSize.width), 1 / Double(sceneSize.height)])
            }
            if uniform.name.hasPrefix("g_Texture"), uniform.name.hasSuffix("Resolution"),
               let slot = Int(uniform.name.dropFirst("g_Texture".count).dropLast("Resolution".count)),
               let texture = texturesBySlot?[slot] {
                return WPEMetalTextureMetadataRegistry.shared.resolution(for: texture).shaderValue
            }
            let names = candidates(for: uniform)
            let lowered = names.map { $0.lowercased() }
            for name in names {
                if let value = frame.value(named: name, passID: pass.id) ?? pass.uniformValues[name] {
                    return value
                }
            }
            let uniformKeys = lowercasedKeyMap(pass.uniformValues)
            for name in lowered {
                if let value = frame.value(lowercasedName: name, passID: pass.id) {
                    return value
                }
                if let canonical = uniformKeys[name], let value = pass.uniformValues[canonical] {
                    return value
                }
            }
            for name in names {
                if let value = pass.pass.constants[name] { return value }
            }
            let constantKeys = lowercasedKeyMap(pass.pass.constants)
            for name in lowered {
                if let canonical = constantKeys[name], let value = pass.pass.constants[canonical] {
                    return value
                }
            }
            return uniform.defaultValue
        }

        static func scalar(_ value: WPESceneShaderConstantValue?) -> Float {
            switch value {
            case .number(let n): return Float(n)
            case .vector(let v): return Float(v.first ?? 0)
            case .bool(let b): return b ? 1 : 0
            case .animated(let v): return Float(v.scalar(at: 0) ?? 0)
            case .string(let s): return Float(s) ?? 0
            case nil: return 0
            }
        }

        static func vector(_ value: WPESceneShaderConstantValue?, count: Int) -> [Float] {
            var out: [Float]
            switch value {
            case .vector(let v): out = v.map(Float.init)
            case .animated(let v): out = (v.vector(at: 0) ?? []).map(Float.init)
            case .number(let n):
                out = [Float](repeating: 0, count: count)
                out[0] = Float(n)
            default: out = [Float](repeating: 0, count: count)
            }
            while out.count < count { out.append(0) }
            return out
        }

        static func packed(
            layout: [WPEUniformSlot],
            pass: WPEPreparedRenderPass,
            frame: WPEFrameUniformContext,
            sceneSize: CGSize,
            texturesBySlot: WPEMetalTextureSlotTable?
        ) -> [SIMD4<Float>] {
            let count = max(layout.reduce(0) { Swift.max($0, $1.slot + $1.slotCount) }, 1)
            var slots = [SIMD4<Float>](repeating: SIMD4<Float>(0, 0, 0, 0), count: count)
            for u in layout {
                let value = value(
                    uniform: u,
                    pass: pass,
                    frame: frame,
                    sceneSize: sceneSize,
                    texturesBySlot: texturesBySlot
                )
                if let length = u.arrayLength {
                    let components: Int
                    switch u.glslType {
                    case "vec2": components = 2
                    case "vec3": components = 3
                    case "vec4": components = 4
                    default: components = 1
                    }
                    let flat = vector(value, count: length * components)
                    for i in 0..<length where u.slot + i < slots.count {
                        let base = i * components
                        slots[u.slot + i] = SIMD4<Float>(
                            base < flat.count ? flat[base] : 0,
                            components > 1 && base + 1 < flat.count ? flat[base + 1] : 0,
                            components > 2 && base + 2 < flat.count ? flat[base + 2] : 0,
                            components > 3 && base + 3 < flat.count ? flat[base + 3] : 0
                        )
                    }
                    continue
                }
                switch u.glslType {
                case "float", "int", "bool":
                    slots[u.slot].x = scalar(value)
                case "vec2", "ivec2", "bvec2":
                    let v = vector(value, count: 2)
                    slots[u.slot] = SIMD4<Float>(v[0], v[1], 0, 0)
                case "vec3", "ivec3", "bvec3":
                    let v = vector(value, count: 3)
                    slots[u.slot] = SIMD4<Float>(v[0], v[1], v[2], 0)
                case "vec4", "ivec4", "bvec4":
                    let v = vector(value, count: 4)
                    slots[u.slot] = SIMD4<Float>(v[0], v[1], v[2], v[3])
                case "mat4":
                    let v = vector(value, count: 16)
                    for row in 0..<4 {
                        slots[u.slot + row] = SIMD4<Float>(
                            v[row * 4], v[row * 4 + 1], v[row * 4 + 2], v[row * 4 + 3]
                        )
                    }
                default:
                    slots[u.slot].x = scalar(value)
                }
            }
            return slots
        }
    }

    // MARK: - Fixtures

    private static func makePass(
        id: String,
        constants: [String: WPESceneShaderConstantValue] = [:],
        uniformValues: [String: WPESceneShaderConstantValue],
        materialUniformNames: [String: String] = [:]
    ) -> (WPERenderPass, WPEPreparedRenderPass) {
        let raw = WPERenderPass(
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
            pass: raw,
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
        return (raw, prepared)
    }

    private static func makeLayer(objectID: String, passes: [WPERenderPass]) -> WPERenderLayer {
        WPERenderLayer(
            objectID: objectID,
            objectName: "Layer \(objectID)",
            imagePath: "materials/base.png",
            materialPath: nil,
            geometry: WPERenderLayerGeometry(
                origin: SIMD3<Double>(120, -40, 7),
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
        time: 2.5,
        daytime: 0.75,
        brightness: 0.6,
        pointerPosition: SIMD2<Double>(0.1, 0.9)
    )

    private static let camera = WPEMetalCameraUniforms(
        orthogonalProjection: WPESceneOrthogonalProjection(width: 64, height: 32, auto: true),
        sceneCamera: .defaultCamera
    )

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

    private static func makeTexture(device: MTLDevice, width: Int, height: Int) throws -> MTLTexture {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm,
            width: width,
            height: height,
            mipmapped: false
        )
        descriptor.usage = [.shaderRead]
        return try #require(device.makeTexture(descriptor: descriptor))
    }

    /// Every source the plan can compile to, in one layout.
    private static func coverageLayout() -> [WPEUniformSlot] {
        [
            // frame-global vs a colliding authored key of the same name
            WPEUniformSlot(name: "g_Time", glslType: "float", slot: 0, slotCount: 1),
            // frame-global, object-scoped
            WPEUniformSlot(name: "g_ModelMatrix", glslType: "mat4", slot: 1, slotCount: 4),
            // frame-global, camera-scoped
            WPEUniformSlot(name: "g_ViewProjectionMatrix", glslType: "mat4", slot: 5, slotCount: 4),
            // static authored value
            WPEUniformSlot(name: "u_Static", glslType: "float", slot: 9, slotCount: 1),
            // animated value, re-resolved per frame
            WPEUniformSlot(name: "u_Anim", glslType: "float", slot: 10, slotCount: 1),
            // scripted override, addressed by its authored (material) name
            WPEUniformSlot(name: "g_Multiply", glslType: "float", slot: 11, slotCount: 1),
            // material-alias hit
            WPEUniformSlot(
                name: "u_Aliased", glslType: "vec4", slot: 12, slotCount: 1,
                materialName: "tintColor"
            ),
            // `u_` prefix stripped, capitalized spelling
            WPEUniformSlot(name: "u_Ratio", glslType: "float", slot: 13, slotCount: 1),
            // case-variant spelling → lowercased uniform-dict round
            WPEUniformSlot(name: "u_lowercasehit", glslType: "float", slot: 14, slotCount: 1),
            // case-variant frame-global spelling → lowercased frame round
            WPEUniformSlot(name: "g_daytime", glslType: "float", slot: 15, slotCount: 1),
            // constants, exact
            WPEUniformSlot(name: "u_FromConstants", glslType: "vec3", slot: 16, slotCount: 1),
            // constants, lowercased
            WPEUniformSlot(name: "u_ConstCaseHit", glslType: "float", slot: 17, slotCount: 1),
            // derived: texture resolution (bound and unbound)
            WPEUniformSlot(name: "g_Texture0Resolution", glslType: "vec4", slot: 18, slotCount: 1),
            WPEUniformSlot(name: "g_Texture5Resolution", glslType: "vec4", slot: 19, slotCount: 1),
            // derived: scene texel size — falls through while sceneSize is degenerate
            WPEUniformSlot(name: "g_TexelSize", glslType: "vec2", slot: 20, slotCount: 1),
            // nothing matches → slot default
            WPEUniformSlot(
                name: "u_Missing", glslType: "vec2", slot: 21, slotCount: 1,
                defaultValue: .vector([0.125, 0.375])
            ),
            // nothing matches and no default → zero
            WPEUniformSlot(name: "u_NoDefault", glslType: "float", slot: 22, slotCount: 1),
            // array element packing off a resolved value
            WPEUniformSlot(
                name: "g_AudioSpectrum16Left", glslType: "float", slot: 23, slotCount: 16,
                arrayLength: 16
            )
        ]
    }

    private struct Fixture {
        let executor: WPEMetalRenderExecutor
        let prepared: WPEPreparedRenderPipeline
        let frame: WPEFrameUniformContext
        let textures: WPEMetalTextureSlotTable
        let layout: [WPEUniformSlot]
    }

    private static func makeFixture() throws -> Fixture {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let executor = try WPEMetalRenderExecutor(device: device)
        let animated = try #require(makeAnimatedConstant())

        let (raw, pass) = makePass(
            id: "coverage.0",
            constants: [
                "u_FromConstants": .vector([0.2, 0.4, 0.6]),
                "U_CONSTCASEHIT": .number(9.5),
                // Constants must never beat the uniform dict for the same name.
                "u_Static": .number(-1)
            ],
            uniformValues: [
                "g_Time": .number(999),
                "u_Static": .number(3.25),
                "u_Anim": animated,
                "g_Multiply": .number(1),
                "tintColor": .vector([1, 0.5, 0.25, 1]),
                "Ratio": .number(0.8),
                "U_LOWERCASEHIT": .number(4.5)
            ],
            materialUniformNames: ["multiply1": "g_Multiply"]
        )
        let layer = makeLayer(objectID: "COV", passes: [raw])
        let pipeline = WPEPreparedRenderPipeline(layers: [
            WPEPreparedRenderLayer(graphLayer: layer, passes: [pass])
        ])
        let (prepared, frame) = pipeline.addingMetalRuntimeUniforms(
            runtime,
            camera: camera,
            scriptedConstants: ["coverage.0": ["multiply1": .number(0.25)]]
        )

        let textures = WPEMetalTextureSlotTable()
        textures[0] = try makeTexture(device: device, width: 24, height: 6)

        return Fixture(
            executor: executor,
            prepared: prepared,
            frame: frame,
            textures: textures,
            layout: coverageLayout()
        )
    }

    // MARK: - A. Slot-for-slot parity with the legacy walk

    @Test("Every compiled source packs the slots the legacy candidate walk packed")
    func compiledPlanMatchesLegacyWalk() throws {
        let fixture = try Self.makeFixture()
        let executor = fixture.executor
        let pass = fixture.prepared.layers[0].passes[0]
        executor.frameUniformContext = fixture.frame
        defer { executor.frameUniformContext = .empty }

        let actual = executor.packTranslatedUniforms(
            for: pass,
            layout: fixture.layout,
            texturesBySlot: fixture.textures
        )
        let reference = LegacyReference.packed(
            layout: fixture.layout,
            pass: pass,
            frame: fixture.frame,
            sceneSize: executor.currentSceneSize,
            texturesBySlot: fixture.textures
        )
        #expect(actual == reference, "\(actual)\nvs\n\(reference)")

        // The reference must actually discriminate: a layout where every slot
        // packs zero would pass trivially.
        #expect(reference.contains { $0 != SIMD4<Float>(0, 0, 0, 0) })
    }

    @Test("Same parity holds with no frame context and no bound textures")
    func compiledPlanMatchesLegacyWalkWithoutFrameContext() throws {
        let fixture = try Self.makeFixture()
        let executor = fixture.executor
        let pass = fixture.prepared.layers[0].passes[0]
        executor.frameUniformContext = .empty

        let actual = executor.packTranslatedUniforms(for: pass, layout: fixture.layout)
        let reference = LegacyReference.packed(
            layout: fixture.layout,
            pass: pass,
            frame: .empty,
            sceneSize: executor.currentSceneSize,
            texturesBySlot: nil
        )
        #expect(actual == reference, "\(actual)\nvs\n\(reference)")
    }

    // MARK: - B. The individual priorities, named

    @Test("Frame globals beat an authored key of the same name; authored beats constants")
    func priorityOrderIsPinned() throws {
        let fixture = try Self.makeFixture()
        let executor = fixture.executor
        let pass = fixture.prepared.layers[0].passes[0]
        executor.frameUniformContext = fixture.frame
        defer { executor.frameUniformContext = .empty }

        let slots = executor.packTranslatedUniforms(
            for: pass,
            layout: fixture.layout,
            texturesBySlot: fixture.textures
        )
        // g_Time: runtime 2.5 wins over the authored 999.
        #expect(slots[0].x == 2.5)
        // g_daytime: the lowercased frame round resolves to runtime g_Daytime.
        #expect(slots[15].x == 0.75)
        // u_Static: the uniform dict (3.25) wins over constants (-1).
        #expect(slots[9].x == 3.25)
        // g_Multiply: the scripted override landed under its shader name.
        #expect(slots[11].x == 0.25)
        // u_Anim: re-resolved at the frame time, not the 0.0 seed.
        #expect(slots[10].x > 0)
        // u_Aliased: material-alias hit.
        #expect(slots[12] == SIMD4<Float>(1, 0.5, 0.25, 1))
        // u_Ratio: `u_`-stripped, capitalized spelling.
        #expect(slots[13].x == 0.8)
        // u_lowercasehit: lowercased uniform round.
        #expect(slots[14].x == 4.5)
        // Constants, exact then lowercased.
        #expect(slots[16] == SIMD4<Float>(0.2, 0.4, 0.6, 0))
        #expect(slots[17].x == 9.5)
        // Bound texture resolution vs unbound slot (falls through to zero).
        #expect(slots[18].x == 24)
        #expect(slots[19] == SIMD4<Float>(0, 0, 0, 0))
        // Slot default, and the no-default zero.
        #expect(slots[21] == SIMD4<Float>(0.125, 0.375, 0, 0))
        #expect(slots[22].x == 0)
        // g_ModelMatrix is object-scoped: the layer origin reaches the matrix.
        #expect(slots[1...4].contains { $0 != SIMD4<Float>(0, 0, 0, 0) })
    }

    @Test("Compiled sources are the expected kind per slot")
    func compiledStepsNameTheExpectedSource() throws {
        let fixture = try Self.makeFixture()
        let pass = fixture.prepared.layers[0].passes[0]
        fixture.executor.frameUniformContext = fixture.frame
        defer { fixture.executor.frameUniformContext = .empty }

        let plans = fixture.executor.uniformPlans(for: pass, layout: fixture.layout)

        func firstStep(_ index: Int) -> WPEMetalRenderExecutor.UniformResolutionStep? {
            plans[index].steps.first
        }
        if case .frameGlobal("g_Time") = firstStep(0) {} else {
            Issue.record("g_Time should compile to a frame-global first step")
        }
        if case .passValue("u_Static") = firstStep(3) {} else {
            Issue.record("u_Static should compile to a pass-value step")
        }
        if case .passConstant("u_FromConstants") = firstStep(10) {} else {
            Issue.record("u_FromConstants should compile to a pass-constant step")
        }
        // A name that is not a frame global emits no frame probe at all, and the
        // constants entry behind the uniform value stays as a fallback step (a
        // scripted key can vanish while the key count stays put).
        #expect(plans[3].steps == [.passValue("u_Static"), .passConstant("u_Static")])
        // Nothing matches → no steps, only the default.
        #expect(plans[15].steps.isEmpty)
        #expect(plans[15].defaultValue == WPESceneShaderConstantValue.vector([0.125, 0.375]))
        #expect(plans[16].steps.isEmpty)
        #expect(plans[16].defaultValue == nil)
        // Derived sources are flagged, not compiled into steps.
        #expect(plans[12].textureResolutionSlot == 0)
        #expect(plans[13].textureResolutionSlot == 5)
        #expect(plans[14].isTexelSize)
    }

    // MARK: - C. Cache identity

    @Test("The plan is compiled once per pass and reused across frames")
    func planIsCompiledOncePerPass() throws {
        let fixture = try Self.makeFixture()
        let executor = fixture.executor
        let pass = fixture.prepared.layers[0].passes[0]
        executor.frameUniformContext = fixture.frame
        defer { executor.frameUniformContext = .empty }

        for _ in 0..<5 {
            _ = executor.packTranslatedUniforms(
                for: pass,
                layout: fixture.layout,
                texturesBySlot: fixture.textures
            )
        }
        #expect(executor.uniformPlanCompileCount == 1)
    }

    @Test("A different layout under the same pass id recompiles instead of reusing")
    func layoutIdentityIsPartOfTheCacheKey() throws {
        let fixture = try Self.makeFixture()
        let executor = fixture.executor
        let pass = fixture.prepared.layers[0].passes[0]
        executor.frameUniformContext = fixture.frame
        defer { executor.frameUniformContext = .empty }

        let first = executor.packTranslatedUniforms(
            for: pass,
            layout: [WPEUniformSlot(name: "u_Static", glslType: "float", slot: 0, slotCount: 1)]
        )
        let second = executor.packTranslatedUniforms(
            for: pass,
            layout: [WPEUniformSlot(name: "g_Multiply", glslType: "float", slot: 0, slotCount: 1)]
        )
        #expect(first[0].x == 3.25)
        #expect(second[0].x == 0.25)
        #expect(executor.uniformPlanCompileCount == 2)
    }

    @Test("A scripted key appearing after the first frame invalidates the plan")
    func newScriptedKeyRebuildsThePlan() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let executor = try WPEMetalRenderExecutor(device: device)

        let (raw, seed) = Self.makePass(
            id: "late.0",
            uniformValues: ["u_Known": .number(1)],
            materialUniformNames: ["late1": "g_Late"]
        )
        let layer = Self.makeLayer(objectID: "LATE", passes: [raw])
        let pipeline = WPEPreparedRenderPipeline(layers: [
            WPEPreparedRenderLayer(graphLayer: layer, passes: [seed])
        ])
        let layout = [WPEUniformSlot(name: "g_Late", glslType: "float", slot: 0, slotCount: 1)]

        // Frame 1: the script has not written yet → no source, slot default.
        let (before, frame1) = pipeline.addingMetalRuntimeUniforms(Self.runtime, camera: Self.camera)
        executor.frameUniformContext = frame1
        let firstSlots = executor.packTranslatedUniforms(for: before.layers[0].passes[0], layout: layout)
        #expect(firstSlots[0].x == 0)

        // Frame 2: the scripted constant appears, adding a key to the dict.
        let (after, frame2) = pipeline.addingMetalRuntimeUniforms(
            Self.runtime,
            camera: Self.camera,
            scriptedConstants: ["late.0": ["late1": .number(6.5)]]
        )
        executor.frameUniformContext = frame2
        let secondSlots = executor.packTranslatedUniforms(for: after.layers[0].passes[0], layout: layout)
        executor.frameUniformContext = .empty
        #expect(secondSlots[0].x == 6.5)
        #expect(executor.uniformPlanCompileCount == 2)
    }
}
#endif
