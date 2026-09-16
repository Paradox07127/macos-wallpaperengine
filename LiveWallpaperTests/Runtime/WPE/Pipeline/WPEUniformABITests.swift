#if !LITE_BUILD
import Foundation
import LiveWallpaperProWPE
import Metal
import Testing
@testable import LiveWallpaper

@Suite("Typed translated uniform ABI")
struct WPEUniformABITests {
    @Test(arguments: ["float", "vec2", "vec3", "vec4", "int", "ivec2", "ivec3", "ivec4",
                      "uint", "uvec2", "uvec3", "uvec4", "bool", "bvec2", "bvec3", "bvec4",
                      "mat2", "mat3", "mat4"])
    func arraysRetainTheirElementShape(typeName: String) throws {
        let type = try #require(WPEUniformType(glslType: typeName))
        let translated = try translate("uniform \(typeName) values[2];\nuniform float tail;")
        let slot = try #require(translated.uniformLayout.first)
        #expect(slot.typeLayout == type)
        #expect(slot.arrayLength == 2)
        #expect(slot.slotCount == 2 * type.columns)
        #expect(slot.arrayElementStride == 16 * type.columns)
        #expect(translated.uniformLayout[1].slot == slot.slotCount)
        #expect(translated.mslSource.contains("\(type.metalType) values[2];"))
    }

    @Test(arguments: ["mat4[257]", "mat4[9223372036854775807]", "double[2]", "mat2x3[2]", "SomeStruct[2]"])
    func unsupportedShapeOrOversizedSpanIsRejected(declaration: String) {
        let parts = declaration.split(separator: "[", maxSplits: 1)
        #expect(throws: WPEShaderCompilerError.self) {
            try translate("uniform \(parts[0]) value[\(parts[1]);")
        }
    }

    @Test func matrixArraysRespectSlotBudgetAndInlineBoundary() throws {
        #expect(try translate("uniform mat4 matrices[64];").totalSlots == 256)
        #expect(try translate("uniform mat4 matrices[65];").totalSlots == 260)
        #expect(try translate("uniform mat4 matrices[256];").totalSlots == 1024)
        #expect(throws: WPEShaderCompilerError.self) {
            try translate("uniform mat4 matrices[256];\nuniform float overflow;")
        }
    }

    @Test func integerTransportPreservesEveryInt32AndUInt32Bit() throws {
        let signed: [Double] = [16_777_215, 16_777_216, 16_777_217, -16_777_217,
                                Double(Int32.min), Double(Int32.max), -1, 0]
        let unsigned: [Double] = [16_777_215, 16_777_216, 16_777_217, Double(UInt32.max), 0, 1, 2, 3]
        let signedSlots = try packed(.vector(signed), name: "i", type: "ivec4", count: 2)
        let unsignedSlots = try packed(.vector(unsigned), name: "u", type: "uvec4", count: 2)
        for index in signed.indices {
            #expect(signedSlots[index / 4][index % 4].bitPattern == UInt32(bitPattern: Int32(signed[index])))
            #expect(unsignedSlots[index / 4][index % 4].bitPattern == UInt32(unsigned[index]))
        }
        #expect(try packed(.number(16_777_217), name: "scalar", type: "int")[0].x.bitPattern == 16_777_217)
        #expect(try packed(.number(Double(UInt32.max)), name: "scalar", type: "uint")[0].x.bitPattern == UInt32.max)
    }

    @Test(arguments: [Double.nan, Double.infinity, -Double.infinity, Double(Int32.max) + 1, Double(Int32.min) - 1])
    func invalidSignedIntegersFailBeforeBinding(value: Double) {
        #expect(throws: WPEUniformPackingError.self) {
            try packed(.vector([0, value]), name: "invalid", type: "ivec2")
        }
    }

    @Test(arguments: [Double.nan, Double.infinity, -1, Double(UInt32.max) + 1])
    func invalidUnsignedIntegersFailBeforeBinding(value: Double) {
        #expect(throws: WPEUniformPackingError.self) {
            try packed(.number(value), name: "invalid", type: "uint")
        }
    }

    @Test func fractionalIntegerConversionTruncatesAndBooleanArraysUseAllComponents() throws {
        let ints = try packed(.vector([1.9, -1.9]), name: "i", type: "ivec2")
        #expect(ints[0].x.bitPattern == 1)
        #expect(ints[0].y.bitPattern == UInt32(bitPattern: -1))
        let flags = try packed(.vector([0, -2, 0.25, 1, 0, -0.0]), name: "flags", type: "bvec3", count: 2)
        #expect(flags == [SIMD4<Float>(0, 1, 1, 0), SIMD4<Float>(1, 0, 0, 0)])
    }

    @Test(arguments: [2, 3, 4])
    func matrixArraysPackEveryColumnAndZeroPad(rows: Int) throws {
        let values = (1...(2 * rows * rows)).map(Double.init)
        let slots = try packed(.vector(values), name: "matrices", type: "mat\(rows)", count: 2)
        #expect(slots.count == 2 * rows)
        for column in slots.indices {
            for row in 0..<rows { #expect(slots[column][row] == Float(values[column * rows + row])) }
            for padding in rows..<4 { #expect(slots[column][padding] == 0) }
        }
    }

    @Test func typedHelperArraysCompileAndGPURoundTripsSignedUnsignedBooleanAndMatrices() throws {
        let declarations = """
        uniform ivec4 signedValues[2];
        uniform uvec4 unsignedValues[2];
        uniform bvec3 flags[2];
        uniform mat2 m2[2];
        uniform mat3 m3[2];
        uniform mat4 m4[2];
        uniform int scalarI;
        uniform uint scalarU;
        """
        let translated = try translate(declarations, helper: """
        vec4 helper() {
            return vec4(float(signedValues[1].z), float(unsignedValues[0].w),
                        flags[1].y ? 1.0 : 0.0, (m4[1] * vec4(m3[1][0], m2[0][1].x)).w);
        }
        """, body: "gl_FragColor = helper();")
        #expect(translated.mslSource.contains("thread const int4* signedValues"))
        #expect(translated.mslSource.contains("thread const uint4* unsignedValues"))
        #expect(translated.mslSource.contains("thread const bool3* flags"))
        #expect(translated.mslSource.contains("thread const float4x4* m4"))
        let values: [String: WPESceneShaderConstantValue] = [
            "signedValues": .vector([16_777_217, -16_777_217, Double(Int32.min), Double(Int32.max), -1, 0, 1, -2]),
            "unsignedValues": .vector([16_777_217, Double(UInt32.max), 0, 1, 2, 3, 4, 5]),
            "flags": .vector([0, -1, 0.125, 2, 0, 3]),
            "m2": .vector((1...8).map(Double.init)),
            "m3": .vector((1...18).map(Double.init)),
            "m4": .vector((1...32).map(Double.init)),
            "scalarI": .number(-16_777_217), "scalarU": .number(Double(UInt32.max))
        ]
        var slots = [SIMD4<Float>](repeating: .zero, count: translated.totalSlots)
        try slots.withUnsafeMutableBufferPointer { storage in
            for uniform in translated.uniformLayout {
                try WPEUniformPacking.pack(values[uniform.name], uniform: uniform, into: storage)
            }
        }
        let uniforms = declarations.components(separatedBy: "\n").flatMap(WPEUniformDecl.parseAll)
        var writes: [String] = []
        var expected: [SIMD4<UInt32>] = []
        for uniform in translated.uniformLayout {
            let type = try #require(uniform.typeLayout)
            for element in 0..<(uniform.arrayLength ?? 1) {
                let name = uniform.name + (uniform.arrayLength == nil ? "" : "[\(element)]")
                for column in 0..<type.columns {
                    let slotIndex = uniform.slot + element * type.columns + column
                    let expression: String
                    if type.columns > 1 {
                        let tail = type.rows == 4 ? "" : (type.rows == 3 ? ", 0.0" : ", 0.0, 0.0")
                        expression = "as_type<uint4>(float4(\(name)[\(column)]\(tail)))"
                    } else if type.scalar == .int {
                        expression = type.rows == 1 ? "uint4(as_type<uint>(\(name)), 0, 0, 0)" : "as_type<uint4>(\(name))"
                    } else if type.scalar == .uint {
                        expression = type.rows == 1 ? "uint4(\(name), 0, 0, 0)" : name
                    } else {
                        expression = "uint4(\(name), false)"
                    }
                    writes.append("    output[\(slotIndex)] = \(expression);")
                    let packed = slots[slotIndex]
                    expected.append(type.scalar == .bool
                        ? SIMD4<UInt32>(UInt32(packed.x), UInt32(packed.y), UInt32(packed.z), 0)
                        : SIMD4<UInt32>(packed.x.bitPattern, packed.y.bitPattern, packed.z.bitPattern, packed.w.bitPattern))
                }
            }
        }
        let probe = translated.mslSource + "\n" + """
        kernel void abiProbe(constant WPEUniforms& u [[buffer(0)]], device uint4* output [[buffer(1)]]) {
        \(WPEShaderTranspiler.uniformDeclarationLines(uniforms).joined(separator: "\n"))
        \(writes.joined(separator: "\n"))
        }
        """
        let device = try #require(MTLCreateSystemDefaultDevice())
        // Production's fast policy must also preserve bitcast integer payloads,
        // including bit patterns that would denote NaN if used as Float values.
        let library = try device.makeLibrary(source: probe, options: WPEMetalLibraryRegistry.Configuration().makeOptions())
        let function = try #require(library.makeFunction(name: "abiProbe"))
        let pipeline = try device.makeComputePipelineState(function: function)
        let input = try slots.withUnsafeBytes { raw in
            try #require(device.makeBuffer(bytes: raw.baseAddress!, length: raw.count, options: .storageModeShared))
        }
        let output = try #require(device.makeBuffer(length: expected.count * 16, options: .storageModeShared))
        let queue = try #require(device.makeCommandQueue())
        let command = try #require(queue.makeCommandBuffer())
        let encoder = try #require(command.makeComputeCommandEncoder())
        encoder.setComputePipelineState(pipeline)
        encoder.setBuffer(input, offset: 0, index: 0)
        encoder.setBuffer(output, offset: 0, index: 1)
        encoder.dispatchThreads(MTLSize(width: 1, height: 1, depth: 1), threadsPerThreadgroup: MTLSize(width: 1, height: 1, depth: 1))
        encoder.endEncoding()
        command.commit()
        command.waitUntilCompleted()
        try #require(command.status == .completed)
        let actual = output.contents().bindMemory(to: SIMD4<UInt32>.self, capacity: expected.count)
        for index in expected.indices { #expect(actual[index] == expected[index]) }
    }

    private func translate(_ declarations: String, helper: String = "", body: String = "gl_FragColor = vec4(0.0);") throws -> WPEShaderTranslationResult {
        try WPEShaderTranspiler.translateFragment(shaderName: "uniform_abi", preprocessedSource: """
        #version 410 core
        \(declarations)
        \(helper)
        void main() { \(body) }
        """)
    }

    private func packed(_ value: WPESceneShaderConstantValue, name: String, type: String, count: Int? = nil) throws -> [SIMD4<Float>] {
        let shape = try #require(WPEUniformType(glslType: type))
        let slot = WPEUniformSlot(name: name, glslType: type, slot: 0, slotCount: shape.columns * (count ?? 1), arrayLength: count)
        var result = [SIMD4<Float>](repeating: SIMD4<Float>(repeating: 99), count: slot.slotCount)
        try result.withUnsafeMutableBufferPointer { try WPEUniformPacking.pack(value, uniform: slot, into: $0) }
        return result
    }
}
#endif
