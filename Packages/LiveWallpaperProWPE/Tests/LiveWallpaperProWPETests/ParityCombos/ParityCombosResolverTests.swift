@testable import LiveWallpaperProWPE
import XCTest

final class ParityCombosResolverTests: XCTestCase {
    func testAnnotationStageOverwriteAndCopies() {
        let annotations = WPEShaderAnnotationCombos(vertexSource: """
        // [COMBO] {"combo":"a","default":1}
        // [COMBO] {"combo":"b","default":2}
        // [COMBO] {"combo":"i","default":3}
        uniform sampler2D g_Texture0; // {"combo":"OLD"}
        uniform sampler2D g_Texture8; // {"combo":"EIGHT"}
        """, fragmentSource: """
        // [COMBO] {"combo":"q","default":true} trailing text
        // [COMBO] {"combo":"b","default":"7"}
        // [COMBO] {"combo":"invalid","default":"not an integer"}
        // [COMBO] {"combo":17,"default":99}
        uniform samplerCube g_Texture0; // {"combo":"NEW","formatcombo":true,"default":"white","components":[{},null,{"combo":"MASK"}]}
        """)
        XCTAssertEqual(annotations.defaults.keys, ["a", "i", "q", "b", "invalid"])
        XCTAssertEqual(annotations.defaults["b"], 7)
        XCTAssertEqual(annotations.defaults["q"], 1)
        XCTAssertEqual(annotations.defaults["invalid"], 0)
        XCTAssertEqual(annotations.samplers.keys, [8, 0])
        XCTAssertEqual(annotations.samplers[0], WPEShaderSamplerCombos(
            combo: "NEW", formatCombo: true, defaultTexture: "white", componentCombos: ["", "MASK"]
        ))
    }

    func testJSONByteOrderBeforeUppercaseThenBlendThenDefaults() {
        let result = WPEComboResolver.resolve(
            passJSONCombos: [.init(key: "i", value: 4), .init(key: "a", value: 3), .init(key: "B", value: 2)],
            blendingMode: 2, vertexSource: """
            // [COMBO] {"combo":"A","default":9}
            // [COMBO] {"combo":"C","default":5}
            // [COMBO] {"combo":"ADDITIVE","default":0}
            """, fragmentSource: "", engineFlags: .init(), boundTextures: [:]
        )
        XCTAssertEqual(result, defines([("ADDITIVE", 1), ("B", 2), ("I", 4), ("A", 3), ("REVERSEDEPTH", 1), ("C", 5)]))
        let collision = WPEComboResolver.resolve(
            passJSONCombos: [.init(key: "a", value: 0), .init(key: "A", value: 9)],
            blendingMode: 3, vertexSource: "", fragmentSource: "", engineFlags: .init(), boundTextures: [:]
        )
        XCTAssertEqual(collision.first(where: { $0.name == "A" })?.value, "0")
        XCTAssertEqual(collision.first(where: { $0.name == "ALPHATOCOVERAGE" })?.value, "1")
    }

    func testNonzeroEngineLightsAndFogInsertionOrder() {
        var flags = WPEEngineComboFlags()
        flags.pointLights = 1
        flags.spotLights = 2
        flags.tubeLights = 3
        flags.directionalLights = 4
        flags.spotShadowCookieLights = 1
        flags.spotShadowLights = 2
        flags.spotCookieLights = 3
        flags.directionalShadowLights = 1
        flags.pointShadowLights = 2
        flags.shadowQuality = 3
        flags.orthographicProjection = true
        flags.fogDistance = true
        flags.fogHeight = true
        flags.backbufferMSAA = true
        flags.hdr = true
        let result = WPEComboResolver.resolve(
            passJSONCombos: [.init(key: "LIGHTING", value: 1), .init(key: "FOG", value: 1)],
            blendingMode: 0, vertexSource: "", fragmentSource: "", engineFlags: flags, boundTextures: [:]
        )
        XCTAssertEqual(result, defines([
            ("FOG", 1), ("HDR", 1), ("LIGHTS_SPOT_SHADOW_COOKIE", 1), ("LIGHTS_SPOT", 2), ("LIGHTING", 1),
            ("BACKBUFFER_MS", 1), ("LIGHTS_POINT", 1), ("LIGHTS_DIRECTIONAL", 4), ("LIGHTS_COOKIE", 1),
            ("LIGHTS_TUBE", 3), ("REVERSEDEPTH", 1), ("LIGHTS_SPOT_SHADOW", 2), ("LIGHTS_SPOT_COOKIE", 3),
            ("LIGHTS_DIRECTIONAL_SHADOW", 1), ("LIGHTS_POINT_SHADOW", 2), ("FOG_DIST", 1),
            ("LIGHTS_SHADOW_MAPPING", 1), ("LIGHTS_SHADOW_MAPPING_QUALITY", 3), ("SCENE_ORTHO", 1), ("FOG_HEIGHT", 1),
        ]))
    }

    func testEngineGatesAndZeroLightCounts() {
        var flags = WPEEngineComboFlags()
        flags.shadowQuality = 0
        flags.spotShadowLights = 2
        flags.fogDistance = true
        flags.fogHeight = true
        let result = WPEComboResolver.resolve(
            passJSONCombos: [.init(key: "LIGHTING", value: 1), .init(key: "FOG", value: 0)],
            blendingMode: 0, vertexSource: "", fragmentSource: "", engineFlags: flags, boundTextures: [:]
        )
        let values = Dictionary(uniqueKeysWithValues: result.map { ($0.name, $0.value) })
        for name in ["LIGHTS_POINT", "LIGHTS_SPOT", "LIGHTS_TUBE", "LIGHTS_DIRECTIONAL", "LIGHTS_SPOT_SHADOW_COOKIE",
                     "LIGHTS_SPOT_SHADOW", "LIGHTS_SPOT_COOKIE", "LIGHTS_DIRECTIONAL_SHADOW", "LIGHTS_POINT_SHADOW"] {
            XCTAssertEqual(values[name], "0")
        }
        for name in ["FOG_DIST", "FOG_HEIGHT", "LIGHTS_SHADOW_MAPPING", "LIGHTS_SHADOW_MAPPING_QUALITY", "LIGHTS_COOKIE"] {
            XCTAssertNil(values[name])
        }
        let disabled = WPEComboResolver.resolve(
            passJSONCombos: [.init(key: "LIGHTING", value: 0)], blendingMode: 0,
            vertexSource: "", fragmentSource: "", engineFlags: flags, boundTextures: [:]
        )
        XCTAssertEqual(Set(disabled.map(\.name)), ["LIGHTING", "REVERSEDEPTH"])
    }

    func testTextureFormatsAndFlaggedTailInSamplerOrder() {
        let source = """
        uniform sampler2D g_Texture0; // {"combo":"MAIN","formatcombo":true,"components":[{"combo":"C0"},{"combo":"C1"}]}
        uniform sampler2D g_Texture8; // {"combo":"OTHER","formatcombo":true}
        uniform sampler2D g_Texture4; // {"formatcombo":true,"default":"gradient"}
        """
        var flags = WPEEngineComboFlags()
        flags.textureFormats = [0: 8, 8: 9, 4: 9, 2: 7]
        let result = WPEComboResolver.resolve(
            passJSONCombos: [], blendingMode: 0, vertexSource: source, fragmentSource: "", engineFlags: flags,
            boundTextures: [0: .init(flags: 0x200000), 8: .init()]
        )
        XCTAssertEqual(Array(result.suffix(3)), defines([("OTHER", 1), ("MAIN", 1), ("C1", 1)]))
        for (name, value) in [("TEX0FORMAT", "8"), ("TEX4FORMAT", "9"), ("TEX8FORMAT", "9")] {
            XCTAssertEqual(result.first(where: { $0.name == name })?.value, value)
        }
        XCTAssertFalse(result.contains { ["C0", "TEX2FORMAT", "HLSL", "HLSL_SM40", "GS_ENABLED"].contains($0.name) })
        let unbound = WPEComboResolver.resolve(
            passJSONCombos: [], blendingMode: 0, vertexSource: source, fragmentSource: "", engineFlags: flags,
            boundTextures: [:]
        )
        XCTAssertEqual(unbound.count, 4)
    }

    func testAnnotationOverloadMatchesSourceSignature() {
        var lights = WPEEngineComboFlags()
        lights.pointLights = 1
        lights.shadowQuality = 2
        lights.pointShadowLights = 1
        lights.fogDistance = true
        lights.hdr = true
        var formats = WPEEngineComboFlags()
        formats.textureFormats = [0: 8, 8: 9]
        let samplers = """
        uniform sampler2D g_Texture0; // {"combo":"MAIN","formatcombo":true,"components":[{"combo":"C0"},{"combo":"C1"}]}
        uniform sampler2D g_Texture8; // {"combo":"OTHER","formatcombo":true}
        """
        let cases: [([WPEPassJSONCombo], Int32, String, WPEEngineComboFlags, [Int32: WPEBoundComboTexture])] = [
            ([.init(key: "i", value: 4), .init(key: "B", value: 2)], 2,
             "// [COMBO] {\"combo\":\"C\",\"default\":5}", .init(), [:]),
            ([.init(key: "LIGHTING", value: 1), .init(key: "FOG", value: 1)], 3, "", lights, [:]),
            ([], 0, samplers, formats, [0: .init(flags: 0x200000), 8: .init()]),
        ]
        for (combos, blending, source, flags, textures) in cases {
            let annotations = WPEShaderAnnotationCombos(vertexSource: source, fragmentSource: "")
            let memoized = WPEComboResolver.resolve(passJSONCombos: combos, blendingMode: blending,
                                                    annotations: annotations, engineFlags: flags,
                                                    boundTextures: textures)
            let parsed = WPEComboResolver.resolve(passJSONCombos: combos, blendingMode: blending,
                                                  vertexSource: source, fragmentSource: "", engineFlags: flags,
                                                  boundTextures: textures)
            XCTAssertEqual(memoized, parsed)
            if flags.hdr {
                XCTAssertTrue(memoized.contains(WPEShaderDefine(name: "HDR", value: "1")))
            }
        }
    }

    private func defines(_ entries: [(String, Int32)]) -> [WPEShaderDefine] {
        entries.map { WPEShaderDefine(name: $0.0, value: String($0.1)) }
    }
}
