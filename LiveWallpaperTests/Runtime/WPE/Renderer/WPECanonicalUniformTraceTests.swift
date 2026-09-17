#if !LITE_BUILD && DEBUG
import Foundation
@testable import LiveWallpaper
import LiveWallpaperProWPE
import Metal
import Testing

@Suite("Canonical typed uniform trace")
struct WPECanonicalUniformTraceTests {
    @Test(arguments: ["float", "vec2", "vec3", "vec4", "int", "ivec2", "ivec3", "ivec4",
                      "uint", "uvec2", "uvec3", "uvec4", "bool", "bvec2", "bvec3", "bvec4",
                      "mat2", "mat3", "mat4"])
    func arraysDecodeAllComponentsWithoutPadding(typeName: String) throws {
        let type = try #require(WPEUniformType(glslType: typeName))
        let uniform = WPEUniformSlot(name: "values", glslType: typeName, slot: 1,
                                     slotCount: 2 * type.columns, arrayLength: 2)
        let values = (1 ... (2 * type.componentCount)).map(Double.init)
        var slots = [SIMD4<Float>](repeating: .init(repeating: 99), count: uniform.slotCount + 1)
        try slots.withUnsafeMutableBufferPointer {
            try WPEUniformPacking.pack(.vector(values), uniform: uniform, into: $0)
        }
        let record = try #require(WPECanonicalUniformTrace.variables(layout: [uniform], slots: slots).first)
        let data = try JSONSerialization.data(withJSONObject: record)
        let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let elements = try #require(json["value"] as? [Any])
        #expect(elements.count == 2)
        for index in 0 ..< 2 {
            let components = type.componentCount == 1 ? [elements[index]] : try #require(elements[index] as? [Any])
            #expect(components.count == type.componentCount)
            for (component, value) in components.enumerated() {
                let number = try #require(value as? NSNumber)
                #expect(number.doubleValue == (type.scalar == .bool ? 1 : values[index * type.componentCount + component]))
            }
        }
        if type.columns > 1 {
            #expect(json["matrixMajor"] as? String == "column")
        }
    }

    @Test func integerExtremesAndNonfiniteFloatBitsSurviveJSON() throws {
        let layout = [
            WPEUniformSlot(name: "i", glslType: "ivec4", slot: 0, slotCount: 1),
            WPEUniformSlot(name: "u", glslType: "uvec4", slot: 1, slotCount: 1),
            WPEUniformSlot(name: "f", glslType: "vec4", slot: 2, slotCount: 1),
        ]
        var slots = [SIMD4<Float>](repeating: .zero, count: 3)
        try slots.withUnsafeMutableBufferPointer {
            try WPEUniformPacking.pack(.vector([-1, Double(Int32.min), Double(Int32.max), 16_777_217]), uniform: layout[0], into: $0)
            try WPEUniformPacking.pack(.vector([Double(UInt32.max), 0, 1, 16_777_217]), uniform: layout[1], into: $0)
        }
        slots[2] = SIMD4(Float(bitPattern: 0x7FC0_1234), .infinity, -.infinity, -0.0)
        let records = WPECanonicalUniformTrace.variables(layout: layout, slots: slots)
        let data = try JSONSerialization.data(withJSONObject: records)
        let json = try #require(JSONSerialization.jsonObject(with: data) as? [[String: Any]])
        #expect((json[0]["value"] as? [NSNumber])?.map(\.int64Value) == [-1, -2_147_483_648, 2_147_483_647, 16_777_217])
        #expect((json[1]["value"] as? [NSNumber])?.map(\.uint64Value) == [4_294_967_295, 0, 1, 16_777_217])
        let floats = try #require(json[2]["value"] as? [Any])
        #expect(Array(floats.prefix(3)) as? [String] == ["NaN", "+Infinity", "-Infinity"])
        #expect((json[2]["rawSlotBits"] as? [NSNumber])?.map(\.uint32Value) == [0x7FC0_1234, 0x7F80_0000, 0xFF80_0000, 0x8000_0000])
    }

    @Test func customPassFinishesWithNegativeIntegerUniform() throws {
        let translated = try WPEShaderTranspiler.translateFragment(shaderName: "trace_test", preprocessedSource:
            "uniform int counter;\nvoid main() { gl_FragColor = vec4(float(counter)); }")
        let uniform = try #require(translated.uniformLayout.first)
        var slots = [SIMD4<Float>](repeating: .zero, count: translated.totalSlots)
        try slots.withUnsafeMutableBufferPointer { try WPEUniformPacking.pack(.number(-1), uniform: uniform, into: $0) }
        let device = try #require(MTLCreateSystemDefaultDevice())
        let library = try device.makeLibrary(source: translated.mslSource, options: nil)
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: 1, height: 1, mipmapped: false)
        descriptor.storageMode = .shared
        let texture = try #require(device.makeTexture(descriptor: descriptor))
        [UInt8](repeating: 0, count: 4).withUnsafeBytes {
            texture.replace(region: MTLRegionMake2D(0, 0, 1, 1), mipmapLevel: 0, withBytes: $0.baseAddress!, bytesPerRow: 4)
        }
        let artifacts = WPESceneDebugArtifacts()
        artifacts.setEnabledForTesting(true)
        let recorder = WPECanonicalTraceRecorder(artifacts: artifacts)
        recorder.beginScene(workshopID: "typed-trace", projectJsonPath: nil, descriptor: "regression")
        let pass = WPERenderPass(id: "layer.0", phase: .command(file: "trace"), shader: "trace_test",
                                 source: .image("source"), target: .scene, textures: [:], binds: [:],
                                 constants: [:], combos: [:], blending: "normal", cullMode: "nocull",
                                 depthTest: "disabled", depthWrite: "disabled")
        recorder.recordCustomPass(
            pass: WPEPreparedRenderPass(pass: pass, shader: nil, textureBindings: [:], comboValues: [:], uniformValues: [:]),
            destination: (.scene, texture),
            result: WPEShaderCompileResult(library: library, vertexFunctionName: "unused", fragmentFunctionName: "unused",
                                           mslSource: translated.mslSource, uniformLayout: translated.uniformLayout,
                                           samplerNames: [], textureSlotCount: 0),
            textureBindings: [], packedUniformSlots: slots, usesObjectQuad: false,
            nativeState: .scenePass(blendMode: "normal", alphaWritePolicy: .all, cullMode: "nocull",
                                    depthAttached: false, depthTest: "disabled", depthWrite: "disabled", reversedZ: false)
        )
        let data = try #require(recorder.finishFrame(outputTexture: texture, runtimeUniforms: nil,
                                                     firstFrameStats: nil, resolutionDiagnostics: .init(events: [])))
        let trace = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let passes = try #require(trace["passes"] as? [[String: Any]])
        #expect(passes.count == 1)
        let buffers = try #require(passes[0]["constantBuffers"] as? [[String: Any]])
        let variables = try #require(buffers[0]["variables"] as? [[String: Any]])
        #expect((variables[0]["value"] as? NSNumber)?.intValue == -1)
        #expect(!recorder.isAccumulating)
        #expect(recorder.finishFrame(outputTexture: texture, runtimeUniforms: nil,
                                     firstFrameStats: nil, resolutionDiagnostics: .init(events: [])) == nil)
    }
}
#endif
