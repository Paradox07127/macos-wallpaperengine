import Foundation
import Metal
import Testing
@testable import LiveWallpaper

@MainActor
@Suite("WPE 2.8 shader compatibility")
struct WPE28ShaderCompatibilityTests {

    private func makeLibrary(_ msl: String) throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let opts = MTLCompileOptions()
        opts.languageVersion = .version3_0
        _ = try device.makeLibrary(source: msl, options: opts)
    }

    @Test("combine_video_hdr translates with g_HDRParams and compiles")
    func combineVideoHDRCompiles() throws {
        let source = """
        #version 410 core
        uniform sampler2D g_Texture0;
        uniform vec2 g_HDRParams;
        in vec2 v_TexCoord;
        void main() {
            vec4 albedo = texture(g_Texture0, v_TexCoord);
            float maxHDR = g_HDRParams.y * 2.0;
            albedo.rgb /= maxHDR;
            albedo.rgb = clamp(albedo.rgb, 0.0, 1.0);
            albedo.rgb *= maxHDR;
            gl_FragColor = albedo;
        }
        """
        let result = try WPEShaderTranspiler.translateFragment(
            shaderName: "combine_video_hdr",
            preprocessedSource: source
        )
        #expect(result.uniformLayout.contains { $0.name == "g_HDRParams" && $0.glslType == "vec2" })
        try makeLibrary(result.mslSource)
    }

    @Test("passthroughsrgb uses the 2.8 piecewise sRGB linearization and compiles")
    func passthroughSRGBCompiles() throws {
        let source = """
        #version 410 core
        uniform sampler2D g_Texture0;
        in vec2 v_TexCoord;
        vec3 lin(vec3 v) {
            vec3 c = step(0.04045, v);
            return c * (pow((v + 0.055) / 1.055, vec3(2.4))) + (1.0 - c) * (v / 12.92);
        }
        void main() {
            vec4 albedo = texture(g_Texture0, v_TexCoord);
            albedo.rgb = lin(albedo.rgb);
            gl_FragColor = albedo;
        }
        """
        let result = try WPEShaderTranspiler.translateFragment(
            shaderName: "passthroughsrgb",
            preprocessedSource: source
        )
        #expect(result.mslSource.contains("step("))
        try makeLibrary(result.mslSource)
    }

    @Test("genericparticle REFRACT branch no longer requires NORMALMAP")
    func genericParticleRefractWithoutNormalMap() throws {
        let source = """
        #version 410 core
        uniform sampler2D g_Texture0;
        in vec2 v_TexCoord;
        in vec4 v_ScreenCoord;
        void main() {
            vec2 screenRefractionOffset = vec2(0.0);
            vec2 refractTexCoord = v_ScreenCoord.xy / v_ScreenCoord.z * vec2(0.5, 0.5) + 0.5 + screenRefractionOffset;
            gl_FragColor = texture(g_Texture0, refractTexCoord);
        }
        """
        let result = try WPEShaderTranspiler.translateFragment(
            shaderName: "genericparticle",
            preprocessedSource: source
        )
        try makeLibrary(result.mslSource)
    }

    @Test("Fragment-only compiler keeps the built-in fullscreen vertex (no model-vertex path)")
    func fragmentOnlyVertexContract() {
        #expect(WPESwiftShaderCompiler.fixedVertexFunctionName == "wpe_fullscreen_vertex")
    }

    private static let waterflowProbeSource = """
    uniform float g_Time;
    uniform float g_FlowSpeed;
    uniform float g_PhaseFeather;
    in vec4 v_Cycles;
    in vec2 v_Blend;
    void main() { gl_FragColor = vec4(v_Cycles.xz, v_Blend); }
    """

    @Test("Waterflow inlining preserves existing varying eligibility across shader names and combos")
    func waterflowInliningKeepsVaryingEligibility() throws {
        for shaderName in ["effects/waterflow", "workshop/custom/effects/waterflow", "other_shader"] {
            for position in 0 ... 2 {
                let translated = try WPEShaderTranspiler.translateFragment(
                    shaderName: shaderName,
                    preprocessedSource: Self.waterflowProbeSource,
                    comboValues: ["POSITION": position]
                )
                #expect(translated.totalSlots == 3)
                #expect(translated.textureSlotCount == 0)
                let body = try #require(translated.mslSource.components(separatedBy: "fragment float4").last)
                #expect(body.contains("wpe_waterflow_cycles(g_Time, g_FlowSpeed)"))
                #expect(body.contains("wpe_waterflow_blend(g_Time, g_FlowSpeed, g_PhaseFeather)"))
            }
        }
        let missingUniform = Self.waterflowProbeSource.replacingOccurrences(of: "g_FlowSpeed", with: "g_FlowSpeedOther")
        let translated = try WPEShaderTranspiler.translateFragment(
            shaderName: "effects/waterflow",
            preprocessedSource: missingUniform
        )
        let body = try #require(translated.mslSource.components(separatedBy: "fragment float4").last)
        #expect(!body.contains("wpe_waterflow_cycles("))
        #expect(!body.contains("wpe_waterflow_blend("))
    }

    @Test("Waterflow inline hint preserves raw GPU Float phases and feather boundaries", arguments: [false, true])
    func waterflowInliningPreservesGPUValues(fastMath: Bool) throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let translated = try WPEShaderTranspiler.translateFragment(
            shaderName: "effects/waterflow",
            preprocessedSource: Self.waterflowProbeSource
        )
        let marker = "__attribute__((always_inline)) inline float2 wpe_waterflow_blend"
        #expect(translated.mslSource.components(separatedBy: marker).count == 2)
        let kernel = """
        kernel void phase_probe(constant float4* inputs [[buffer(0)]],
                                device float4* outputs [[buffer(1)]],
                                uint tid [[thread_position_in_grid]]) {
            float4 values = inputs[tid];
            outputs[tid * 2] = wpe_waterflow_cycles(values.x, values.y);
            outputs[tid * 2 + 1] = float4(wpe_waterflow_blend(values.x, values.y, values.z), 0.0, 1.0);
        }
        """
        let candidate = translated.mslSource + "\n" + kernel
        // Change only the new hint: the reference keeps the production helper
        // formula and compiler options, without a CPU approximation of Metal math.
        let reference = candidate.replacingOccurrences(
            of: marker,
            with: "inline float2 wpe_waterflow_blend"
        )
        let boundaries: [Float] = [-1, -0.75, -0.5, -0.25, 0, 0.25, 0.5, 0.75, 1, 16, 1_048_576]
        let speeds: [Float] = [0, 0.01, 0.5, 1, 2, -1]
        let featherThreshold: Float = 0.00000005
        let feathers: [Float] = [0, featherThreshold.nextDown, featherThreshold, featherThreshold.nextUp, 0.1, 0.4, 0.5, -0.1]
        var inputs: [SIMD4<Float>] = []
        for boundary in boundaries {
            for time in [boundary.nextDown, boundary, boundary.nextUp] {
                for speed in speeds {
                    for feather in feathers {
                        inputs.append(SIMD4(time, speed, feather, 0))
                    }
                }
            }
        }
        let expected = try waterflowProbeBits(reference, device: device, inputs: inputs, fastMath: fastMath)
        let actual = try waterflowProbeBits(candidate, device: device, inputs: inputs, fastMath: fastMath)
        #expect(Set(expected).count > 4)
        let differences = zip(expected, actual).enumerated().compactMap { index, values in
            values.0 == values.1 ? nil : index
        }
        #expect(differences.isEmpty, Comment(rawValue: "GPU Float mismatch indices: \(differences.prefix(8))"))
    }

    private func waterflowProbeBits(
        _ source: String,
        device: MTLDevice,
        inputs: [SIMD4<Float>],
        fastMath: Bool
    ) throws -> [UInt32] {
        let options = MTLCompileOptions()
        options.languageVersion = .version3_0
        options.fastMathEnabled = fastMath
        let library = try device.makeLibrary(source: source, options: options)
        let function = try #require(library.makeFunction(name: "phase_probe"))
        let pipeline = try device.makeComputePipelineState(function: function)
        let inputBuffer = try #require(device.makeBuffer(
            bytes: inputs,
            length: inputs.count * MemoryLayout<SIMD4<Float>>.stride,
            options: .storageModeShared
        ))
        let wordCount = inputs.count * 8
        let outputBuffer = try #require(device.makeBuffer(length: wordCount * MemoryLayout<UInt32>.stride, options: .storageModeShared))
        let queue = try #require(device.makeCommandQueue())
        let commandBuffer = try #require(queue.makeCommandBuffer())
        let encoder = try #require(commandBuffer.makeComputeCommandEncoder())
        encoder.setComputePipelineState(pipeline)
        encoder.setBuffer(inputBuffer, offset: 0, index: 0)
        encoder.setBuffer(outputBuffer, offset: 0, index: 1)
        encoder.dispatchThreads(
            MTLSize(width: inputs.count, height: 1, depth: 1),
            threadsPerThreadgroup: MTLSize(width: pipeline.threadExecutionWidth, height: 1, depth: 1)
        )
        encoder.endEncoding()
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        try #require(commandBuffer.status == .completed)
        let words = outputBuffer.contents().bindMemory(to: UInt32.self, capacity: wordCount)
        return Array(UnsafeBufferPointer(start: words, count: wordCount))
    }

    @Test("font.frag R8 coverage branch (ConvertSampleR8) translates and compiles")
    func fontRasterBranchCompiles() throws {
        let source = """
        #version 410 core
        uniform sampler2D g_Texture0;
        uniform vec4 g_Color4;
        in vec2 v_TexCoord;
        float ConvertSampleR8(vec4 _sample) { return _sample.r; }
        void main() {
            float _sample = ConvertSampleR8(texture(g_Texture0, v_TexCoord.xy));
            gl_FragColor = vec4(g_Color4.rgb, _sample * g_Color4.a);
        }
        """
        let result = try WPEShaderTranspiler.translateFragment(
            shaderName: "font",
            preprocessedSource: source
        )
        try makeLibrary(result.mslSource)
    }
}
