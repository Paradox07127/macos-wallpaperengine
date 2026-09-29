#if !LITE_BUILD && DEBUG
import Foundation
@testable import LiveWallpaper
import LiveWallpaperProWPE
import Metal
import simd
import Testing

@Suite("Uniform binding source trace")
struct WPEUniformSourceTraceTests {
    @Test
    func zeroDefaultsAliasesAndMissingValuesKeepTheirOrigin() throws {
        let executor = try makeExecutor()
        executor.frameUniformContext = WPEFrameUniformContext(
            runtimeUniformValues: ["g_Time": .number(7), "g_Brightness": .number(0.2)],
            cameraUniformValues: [:], objectUniformValuesByPassID: [:]
        )
        let pass = makePass(values: ["u_Zero": .number(0), "Wind": .vector([2, 3]), "g_Time": .number(99), "Brightness": .number(0.6)],
                            constants: ["U_COUNT": .vector([-1, 5])])
        let layout = [
            WPEUniformSlot(name: "u_Zero", glslType: "float", slot: 0, slotCount: 1, defaultValue: .number(9)),
            WPEUniformSlot(name: "u_Default", glslType: "float", slot: 1, slotCount: 1, defaultValue: .number(0)),
            WPEUniformSlot(name: "u_Missing", glslType: "float", slot: 2, slotCount: 1),
            WPEUniformSlot(name: "u_Wind", glslType: "vec2", slot: 3, slotCount: 1, materialName: "Wind", requiredCombos: ["OFF": 1]),
            WPEUniformSlot(name: "u_Count", glslType: "ivec2", slot: 4, slotCount: 1),
            WPEUniformSlot(name: "g_EffectTextureProjectionMatrixInverse", glslType: "mat4", slot: 5, slotCount: 4),
            WPEUniformSlot(name: "u_Array", glslType: "vec2", slot: 9, slotCount: 2, arrayLength: 2, defaultValue: .vector([1, 2, 3, 4])),
            WPEUniformSlot(name: "g_Time", glslType: "float", slot: 11, slotCount: 1),
            WPEUniformSlot(name: "g_Brightness", glslType: "float", slot: 12, slotCount: 1, materialName: "Brightness"),
        ]
        let (slots, sources) = try executor.withUniformSourceTracing {
            try executor.packTranslatedUniforms(for: pass, layout: layout)
        }
        #expect(sources == [.passValue("u_Zero"), .authoredDefault, .missing, .passValue("Wind"),
                            .passConstant("U_COUNT"), .missing, .authoredDefault, .frameContext("g_Time"), .passValue("Brightness")])
        #expect(Array(slots.prefix(3)) == [.zero, .zero, .zero])
        #expect(slots[3] == SIMD4(2, 3, 0, 0))
        #expect(slots[4].x.bitPattern == UInt32.max)
        #expect(slots[4].y.bitPattern == 5)
        #expect(slots[5 ..< 9].allSatisfy { $0 == .zero })
        #expect(slots[9] == SIMD4(1, 2, 0, 0))
        #expect(slots[10] == SIMD4(3, 4, 0, 0))
        #expect(slots[11].x == 7)
        #expect(slots[12].x == Float(0.6))
        #expect(executor.uniformSourceTrace == nil)
        let records = WPECanonicalUniformTrace.variables(layout: layout, slots: slots, sources: sources)
        #expect((records[0]["bindingSource"] as? [String: String])?["kind"] == "pass-value")
        #expect((records[1]["bindingSource"] as? [String: String])?["kind"] == "authored-default")
        #expect((records[2]["bindingSource"] as? [String: String])?["kind"] == "missing")
        #expect(records[5]["byteOffset"] as? Int == 80)
        #expect(JSONSerialization.isValidJSONObject(records))
    }

    @Test
    func drawContextSuppliesEffectTextureProjection() throws {
        let executor = try makeExecutor()
        let matrix = WPEMetalObjectUniforms.effectTextureProjectionMatrix(quad: WPEObjectQuadUniforms(
            centerAndSize: SIMD4(-75.76, 43.84, 4066.68, 2287.5),
            sceneSizeAndRotation: SIMD4(3840, 2160, 0.3, 0),
            uvSignAndPadding: SIMD4(1, 1, 0, 0)
        ))
        let layout = [
            WPEUniformSlot(name: "u_Missing", glslType: "float", slot: 0, slotCount: 1),
            WPEUniformSlot(name: "g_EffectTextureProjectionMatrixInverse", glslType: "mat4", slot: 5, slotCount: 4),
        ]
        let (slots, sources) = try executor.withUniformSourceTracing {
            try executor.packTranslatedUniforms(for: makePass(), layout: layout, effectTextureProjection: { matrix })
        }
        let inverse = WPEMetalObjectUniforms.safeInverse(matrix)
        #expect(sources == [.missing, .effectTextureProjection(inverse: true)])
        #expect(Array(slots[5 ..< 9]) == [inverse.columns.0, inverse.columns.1, inverse.columns.2, inverse.columns.3]
            .map { SIMD4<Float>($0) })
        let records = WPECanonicalUniformTrace.variables(layout: layout, slots: slots, sources: sources)
        let source = records[1]["bindingSource"] as? [String: String]
        #expect(source?["kind"] == "layer-derived")
        #expect(source?["key"] == "g_EffectTextureProjectionMatrixInverse")
        #expect(source?["scope"] == "layer")
    }

    @Test(arguments: [false, true])
    func directAndOrdinaryPackingRecordIdenticalDerivedSources(useArena: Bool) throws {
        let executor = try makeExecutor()
        executor.setCurrentScenePixelSizeForTesting(CGSize(width: 200, height: 100))
        if useArena {
            executor.currentUniformArenaSlot = 0
            executor.uniformArena.beginFrame(slot: 0)
        }
        let texture = try #require(executor.device.makeTexture(descriptor: .texture2DDescriptor(
            pixelFormat: .rgba8Unorm, width: 32, height: 16, mipmapped: false
        )))
        let textures = WPEMetalTextureSlotTable()
        textures.set(texture: texture, samplingDescriptor: .identity,
                     resolution: WPEMetalTextureResolution(texture: texture, imageWidth: 24, imageHeight: 12), at: 0)
        let layout = [
            WPEUniformSlot(name: "g_Screen", glslType: "vec3", slot: 0, slotCount: 1),
            WPEUniformSlot(name: "g_TexelSize", glslType: "vec2", slot: 1, slotCount: 1),
            WPEUniformSlot(name: "g_TexelSizeHalf", glslType: "vec2", slot: 2, slotCount: 1),
            WPEUniformSlot(name: "g_Texture0Resolution", glslType: "vec4", slot: 3, slotCount: 1),
            WPEUniformSlot(name: "g_Texture0Rotation", glslType: "vec4", slot: 4, slotCount: 1),
            WPEUniformSlot(name: "g_Texture0Translation", glslType: "vec2", slot: 5, slotCount: 1),
            WPEUniformSlot(name: "g_Texture1Resolution", glslType: "vec4", slot: 6, slotCount: 1, defaultValue: .vector([9, 8, 7, 6])),
        ]
        let expected: [SIMD4<Float>] = [SIMD4(200, 100, 2, 0), SIMD4(0.005, 0.01, 0, 0),
                                        SIMD4(0.0025, 0.005, 0, 0), SIMD4(32, 16, 24, 12), SIMD4(1, 0, 0, 1), .zero, SIMD4(9, 8, 7, 6)]
        for direct in [false, true] {
            executor.derivedUniformPackingEnabled = direct
            let (packed, sources) = try executor.withUniformSourceTracing {
                try executor.packTranslatedUniformsForBinding(for: makePass(), layout: layout, texturesBySlot: textures)
            }
            if useArena {
                guard case .arena = packed else { Issue.record("Expected arena storage"); return }
            }
            #expect(packed.slotsForTracing() == expected)
            #expect(sources == [.derived(.screen), .derived(.texelSize), .derived(.texelSizeHalf),
                                .derived(.textureResolution(0)), .derived(.textureRotation(0)), .derived(.textureTranslation(0)), .authoredDefault])
        }
        executor.setCurrentScenePixelSizeForTesting(.zero)
        let (slots, sources) = try executor.withUniformSourceTracing {
            try executor.packTranslatedUniforms(for: makePass(values: ["g_Screen": .vector([10, 20, 0.5])]), layout: [layout[0]])
        }
        #expect(slots[0] == SIMD4(10, 20, 0.5, 0))
        #expect(sources == [.passValue("g_Screen")])
    }

    @Test func disabledNestedAndThrowingScopesCannotLeakOrigins() throws {
        let executor = try makeExecutor()
        let slot = WPEUniformSlot(name: "u_Value", glslType: "float", slot: 0, slotCount: 1)
        let (_, disabled) = try executor.withUniformSourceTracing(enabled: false) {
            try executor.packTranslatedUniforms(for: makePass(), layout: [slot])
        }
        #expect(disabled == nil)
        let (_, outer) = try executor.withUniformSourceTracing {
            let (_, inner) = try executor.withUniformSourceTracing {
                try executor.packTranslatedUniforms(for: makePass(), layout: [slot])
            }
            #expect(inner == [.missing])
            let invalid = WPEUniformSlot(name: "u_Invalid", glslType: "mat4", slot: 0, slotCount: 1)
            #expect(throws: WPEUniformPackingError.self) {
                try executor.withUniformSourceTracing { try executor.packTranslatedUniforms(for: makePass(), layout: [invalid]) }
            }
            return try executor.packTranslatedUniforms(for: makePass(values: ["u_Value": .number(0)]), layout: [slot])
        }
        #expect(outer == [.passValue("u_Value")])
        #expect(executor.uniformSourceTrace == nil)
        for sources: [WPEUniformValueSource]? in [nil, [], [.missing, .authoredDefault]] {
            let records = WPECanonicalUniformTrace.variables(layout: [slot], slots: [.zero], sources: sources)
            #expect((records[0]["bindingSource"] as? [String: String])?["kind"] == "unrecorded")
        }
    }

    private func makeExecutor() throws -> WPEMetalRenderExecutor {
        try WPEMetalRenderExecutor(device: #require(MTLCreateSystemDefaultDevice()))
    }

    private func makePass(values: [String: WPESceneShaderConstantValue] = [:], constants: [String: WPESceneShaderConstantValue] = [:]) -> WPEPreparedRenderPass {
        WPEPreparedRenderPass(
            pass: WPERenderPass(id: "source.trace", phase: .effect(file: "probe"), shader: "source_trace",
                                source: .image("unused"), target: .scene, textures: [:], binds: [:], constants: constants, combos: [:],
                                blending: "disabled", cullMode: "nocull", depthTest: "disabled", depthWrite: "disabled"),
            shader: nil, textureBindings: [:], comboValues: [:], uniformValues: values
        )
    }
}
#endif
