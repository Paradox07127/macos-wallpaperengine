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

    private static let wavePowerProbeSource = """
    uniform float g_Time;
    uniform float g_Speed;
    uniform float g_Exponent;
    void main() {
        float distance = g_Time * g_Speed;
        float val1 = sin(distance);
        float s1 = sign(val1);
        val1 = pow(abs(val1), g_Exponent);
        gl_FragColor = vec4(val1 * s1);
    }
    """

    @Test("Water power fast path is scalar, keeps live uniforms and can be disabled")
    func waterPowerFastPathEligibility() throws {
        let optimized = try WPEShaderTranspiler.translateFragment(
            shaderName: "custom/water", preprocessedSource: Self.wavePowerProbeSource,
            waterOptimizationsEnabled: true
        )
        let reference = try WPEShaderTranspiler.translateFragment(
            shaderName: "custom/water", preprocessedSource: Self.wavePowerProbeSource,
            waterOptimizationsEnabled: false
        )
        #expect(optimized.mslSource.contains("wpe_unit_exponent_power(abs(val1), g_Exponent)"))
        #expect(!reference.mslSource.contains("wpe_unit_exponent_power"))
        #expect(optimized.uniformLayout.map(\.name) == reference.uniformLayout.map(\.name))
        try makeLibrary(optimized.mslSource)
        let customPow = try WPEShaderTranspiler.translateFragment(
            shaderName: "effects/waterwaves",
            preprocessedSource: "float pow(float a, float b) { return a + b; }\n" + Self.wavePowerProbeSource,
            waterOptimizationsEnabled: true
        )
        #expect(!customPow.mslSource.contains("wpe_unit_exponent_power"))
        let vectorLookalike = Self.wavePowerProbeSource
            .replacingOccurrences(of: "float val1 = sin(distance);", with: "// float val1 = sin(distance);\nvec4 val1 = sin(vec4(distance));")
            .replacingOccurrences(of: "float s1 = sign(val1);", with: "vec4 s1 = sign(val1);")
        let vector = try WPEShaderTranspiler.translateFragment(
            shaderName: "effects/waterwaves", preprocessedSource: vectorLookalike, waterOptimizationsEnabled: true
        )
        #expect(!vector.mslSource.contains("wpe_unit_exponent_power"))
        let nested = Self.wavePowerProbeSource.replacingOccurrences(
            of: "gl_FragColor = vec4(val1 * s1);",
            with: "{ vec4 unused, val1 = sin(vec4(distance)); gl_FragColor = pow(abs(val1), g_Exponent); }"
        )
        let shadow = try WPEShaderTranspiler.translateFragment(
            shaderName: "effects/waterwaves", preprocessedSource: nested, waterOptimizationsEnabled: true
        )
        #expect(!shadow.mslSource.contains("wpe_unit_exponent_power"))
    }

    @Test("Water power preserves oscillation after ten minutes and a day, with changing exponents", arguments: [false, true])
    func waterPowerPreservesLongRunningMotion(fastMath: Bool) throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let translated = try WPEShaderTranspiler.translateFragment(
            shaderName: "effects/waterwaves", preprocessedSource: Self.wavePowerProbeSource,
            waterOptimizationsEnabled: true
        )
        let kernel = """
        kernel void phase_probe(constant float4* inputs [[buffer(0)]],
                                device float4* outputs [[buffer(1)]],
                                uint tid [[thread_position_in_grid]]) {
            float4 v = inputs[tid];
            float x = sin(v.x * v.y + v.w);
            float shaped = wpe_unit_exponent_power(abs(x), v.z) * sign(x);
            outputs[tid * 2] = float4(shaped, x, v.z, 1.0);
            outputs[tid * 2 + 1] = float4(0.0);
        }
        """
        let candidate = translated.mslSource + "\n" + kernel
        let reference = candidate.replacingOccurrences(
            of: "if (exponent == 1.0) { return magnitude; }", with: "// reference always evaluates pow"
        )
        var inputs: [SIMD4<Float>] = []
        for origin: Float in [0, 600, 3600, 86400] {
            for frame in 0 ..< 120 {
                // Different live exponents exercise fallback and return to one
                // without recompiling or baking time into a PSO/cache key.
                let exponent: Float = [1, 0.51, 4, 1, Float(1).nextUp][frame % 5]
                inputs.append(SIMD4(origin + Float(frame) / 60, frame % 4 == 0 ? 0 : 5, exponent, 0.37))
            }
        }
        let expected = try waterflowProbeBits(reference, device: device, inputs: inputs, fastMath: fastMath)
        let actual = try waterflowProbeBits(candidate, device: device, inputs: inputs, fastMath: fastMath)
        for index in inputs.indices {
            let before = Float(bitPattern: expected[index * 8])
            let after = Float(bitPattern: actual[index * 8])
            #expect(after.isFinite && abs(after - before) <= 0.000001)
            if inputs[index].z != 1 {
                #expect(actual[index * 8] == expected[index * 8])
            }
        }
        for block in 0 ..< 4 {
            let samples = (0 ..< 120).filter { inputs[block * 120 + $0].z == 1 }
                .map { Float(bitPattern: actual[(block * 120 + $0) * 8]) }
            #expect((samples.max() ?? 0) - (samples.min() ?? 0) > 1)
        }
    }

    private static let flowEndpointProbeSource = """
    uniform sampler2D g_Texture0;
    uniform sampler2D g_Texture1;
    uniform float g_Time;
    in vec4 v_TexCoord;
    void main() {
        float flowPhase = texture(g_Texture1, v_TexCoord.xy).r;
        vec4 flowUVOffset = vec4(0.17, -0.12, -0.3, 0.2) + g_Time * 0.0001;
        vec4 flowUVOffset2 = vec4(-0.07, 0.2, 0.14, -0.23) - g_Time * 0.0001;
        vec2 v_Blend = vec2(0.37, 0.63);
        vec4 albedo = texture(g_Texture0, v_TexCoord.xy);
        vec4 flowAlbedo = mix(texture(g_Texture0, v_TexCoord.xy + flowUVOffset.xy),
            texture(g_Texture0, v_TexCoord.xy + flowUVOffset.zw), v_Blend.x);
        vec4 flowAlbedo2 = mix(texture(g_Texture0, v_TexCoord.xy + flowUVOffset2.xy),
            texture(g_Texture0, v_TexCoord.xy + flowUVOffset2.zw), v_Blend.y);
        flowAlbedo = mix(flowAlbedo, flowAlbedo2, smoothstep(0.2, 0.8, flowPhase));
        gl_FragColor = mix(albedo, flowAlbedo, 0.73);
    }
    """

    @Test("Flow endpoint sampling preserves HDR, alpha, wrap and mip fallback", arguments: [false, true])
    func flowEndpointsPreserveFilteredHDR(premultiplied: Bool) throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let sources = try [false, true].map { enabled in
            try WPEShaderTranspiler.translateFragment(
                shaderName: "custom/flow", preprocessedSource: "#define mix mix\n" + Self.flowEndpointProbeSource,
                premultipliedInputSlots: premultiplied ? [0] : [],
                premultipliedOutput: premultiplied, waterOptimizationsEnabled: enabled
            ).mslSource
        }
        #expect(!sources[0].contains("inline float4 wpe_flow_endpoint_color"))
        #expect(sources[1].contains("inline float4 wpe_flow_endpoint_color"))
        // An author reading the second intermediate after the recognized block
        // must keep the original local variable and original implementation.
        let extended = Self.flowEndpointProbeSource.replacingOccurrences(
            of: "gl_FragColor = mix(albedo, flowAlbedo, 0.73);", with: "gl_FragColor = flowAlbedo2;"
        )
        let preserved = try WPEShaderTranspiler.translateFragment(
            shaderName: "effects/waterflow", preprocessedSource: extended, waterOptimizationsEnabled: true
        )
        #expect(!preserved.mslSource.contains("inline float4 wpe_flow_endpoint_color"))
        for macro in ["# define wpe_smoothstep custom", "#define\twpe_unpremultiply_sample custom", "# define mix custom", "#/**/define wpe_smoothstep custom", "#define wpe_smooth" + "\\\n" + "step custom"] {
            let custom = try WPEShaderTranspiler.translateFragment(
                shaderName: "effects/waterflow", preprocessedSource: macro + "\n" + Self.flowEndpointProbeSource,
                waterOptimizationsEnabled: true
            )
            #expect(!custom.mslSource.contains("inline float4 wpe_flow_endpoint_color"))
        }
        for mipmapped in [false, true] {
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: .rgba16Float, width: 32, height: 16, mipmapped: mipmapped
            )
            descriptor.storageMode = .shared
            descriptor.usage = .shaderRead
            let input = try #require(device.makeTexture(descriptor: descriptor))
            for level in 0 ..< input.mipmapLevelCount {
                let width = max(32 >> level, 1), height = max(16 >> level, 1)
                let pixels: [UInt16] = (0 ..< width * height).flatMap { index in
                    let alpha: Float = [0, 0.00001, 0.25, 1][index % 4]
                    let factor: Float = premultiplied ? alpha : 1
                    return [Float(index % 7) * factor, Float(index % 3) * factor, Float(level) * factor, alpha]
                        .map { Float16($0).bitPattern }
                }
                pixels.withUnsafeBytes { bytes in
                    input.replace(region: MTLRegionMake2D(0, 0, width, height), mipmapLevel: level,
                                  withBytes: bytes.baseAddress!, bytesPerRow: width * 8)
                }
            }
            let phaseDescriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .r32Float, width: 8, height: 1, mipmapped: false)
            phaseDescriptor.storageMode = .shared
            phaseDescriptor.usage = .shaderRead
            let phase = try #require(device.makeTexture(descriptor: phaseDescriptor))
            let phases: [Float] = [0, Float(0.2).nextDown, 0.2, 0.5, 0.8, Float(0.8).nextUp, 1, 0]
            phases.withUnsafeBytes { bytes in
                phase.replace(region: MTLRegionMake2D(0, 0, 8, 1), mipmapLevel: 0, withBytes: bytes.baseAddress!, bytesPerRow: 32)
            }
            for repeatUV in [false, true] {
                for nearest in [false, true] {
                    let sampler = MTLSamplerDescriptor()
                    sampler.sAddressMode = repeatUV ? .repeat : .clampToEdge
                    sampler.tAddressMode = sampler.sAddressMode
                    sampler.minFilter = nearest ? .nearest : .linear
                    sampler.magFilter = sampler.minFilter
                    sampler.mipFilter = .linear
                    let state = try #require(device.makeSamplerState(descriptor: sampler))
                    for time: Float in [0, 600.5, 86400.125] {
                        let before = try flowProbePixels(sources[0], device: device, input: input, phase: phase, sampler: state, time: time)
                        let after = try flowProbePixels(sources[1], device: device, input: input, phase: phase, sampler: state, time: time)
                        let error = zip(before, after).map { abs($0 - $1) }.max() ?? .infinity
                        let allFinite = after.allSatisfy(\.isFinite)
                        #expect(allFinite)
                        #expect(error <= 0.00001, "HDR/alpha flow delta exceeds numeric rounding tolerance")
                    }
                }
            }
        }
    }

    private func flowProbePixels(_ source: String, device: MTLDevice, input: MTLTexture,
                                 phase: MTLTexture, sampler: MTLSamplerState, time: Float) throws -> [Float] {
        let vertex = """
        vertex WPEStageIn flow_probe_vertex(uint id [[vertex_id]]) {
            float2 positions[4] = {float2(-1,-1),float2(1,-1),float2(-1,1),float2(1,1)};
            WPEStageIn o; o.position = float4(positions[id],0,1);
            o.uv = (positions[id] * 0.5 + 0.5) * 1.7 - 0.25; return o;
        }
        """
        let library = try device.makeLibrary(source: source + "\n" + vertex, options: nil)
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = library.makeFunction(name: "flow_probe_vertex")
        descriptor.fragmentFunction = library.makeFunction(name: "wpe_translated_fragment")
        descriptor.colorAttachments[0].pixelFormat = .rgba32Float
        let pipeline = try device.makeRenderPipelineState(descriptor: descriptor)
        let outputDescriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba32Float, width: 33, height: 17, mipmapped: false)
        outputDescriptor.storageMode = .shared
        outputDescriptor.usage = .renderTarget
        let output = try #require(device.makeTexture(descriptor: outputDescriptor))
        let queue = try #require(device.makeCommandQueue())
        let command = try #require(queue.makeCommandBuffer())
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = output
        pass.colorAttachments[0].loadAction = .dontCare
        pass.colorAttachments[0].storeAction = .store
        let encoder = try #require(command.makeRenderCommandEncoder(descriptor: pass))
        encoder.setRenderPipelineState(pipeline)
        encoder.setFragmentTexture(input, index: 0)
        encoder.setFragmentTexture(phase, index: 1)
        encoder.setFragmentSamplerState(sampler, index: 0)
        encoder.setFragmentSamplerState(sampler, index: 1)
        var uniforms = SIMD4<Float>(time, 0, 0, 0)
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<SIMD4<Float>>.stride, index: 0)
        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        encoder.endEncoding()
        command.commit()
        command.waitUntilCompleted()
        try #require(command.status == .completed)
        var pixels = [Float](repeating: 0, count: 33 * 17 * 4)
        pixels.withUnsafeMutableBytes { bytes in
            output.getBytes(bytes.baseAddress!, bytesPerRow: 33 * 16, from: MTLRegionMake2D(0, 0, 33, 17), mipmapLevel: 0)
        }
        return pixels
    }

    private static let waterflowProbeSource = """
    uniform float g_Time;
    uniform float g_FlowSpeed;
    uniform float g_PhaseFeather;
    in vec4 v_Cycles;
    in vec2 v_Blend;
    void main() { gl_FragColor = vec4(v_Cycles.xz, v_Blend); }
    """

    /// Writes both helpers' raw Float words per thread: `cycles` then `blend` padded to
    /// float4, so one dispatch yields 8 words at `tid * 8`.
    private static let waterflowProbeKernel = """
    kernel void phase_probe(constant float4* inputs [[buffer(0)]],
                            device float4* outputs [[buffer(1)]],
                            uint tid [[thread_position_in_grid]]) {
        float4 values = inputs[tid];
        outputs[tid * 2] = wpe_waterflow_cycles(values.x, values.y);
        outputs[tid * 2 + 1] = float4(wpe_waterflow_blend(values.x, values.y, values.z), 0.0, 1.0);
    }
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
        let candidate = translated.mslSource + "\n" + Self.waterflowProbeKernel
        // Only the inline hint differs, so both sides move together when the formula changes —
        // the formula itself is pinned by `waterflowHelperMathMatchesModel`.
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
        guard fastMath else {
            let differences = zip(expected, actual).enumerated().compactMap { index, values in
                values.0 == values.1 ? nil : index
            }
            #expect(differences.isEmpty, Comment(rawValue: "GPU Float mismatch indices: \(differences.prefix(8))"))
            return
        }
        // Production compiles with fast math (`WPESwiftShaderCompiler.assemble`), which lets the
        // optimizer reassociate the `t` / `fract` expressions the two helpers share.
        let violations = waterflowFastMathViolations(expected: expected, actual: actual, inputs: inputs)
        #expect(violations.isEmpty, Comment(rawValue: violations.prefix(8).joined(separator: "\n")))
    }

    /// Each build may land up to one float ULP of `t` from the exact phase, and
    /// `b = 2 * |fract(phase) - 0.5|` doubles that, so `b` is admitted over `+/- 2 * 2 * ulp(t)`
    /// and a blend output is admissible exactly when it lands in `wpe_smoothstep`'s image of it.
    private func waterflowFastMathViolations(
        expected: [UInt32], actual: [UInt32], inputs: [SIMD4<Float>]
    ) -> [String] {
        let outputSlack = 4 * Double(Float(1).ulp)
        var violations: [String] = []
        for (tid, input) in inputs.enumerated() {
            let phaseSlack = max(abs(input.x * input.y), 1).ulp
            for component in 0 ..< 4 {
                let index = tid * 8 + component
                let lhs = Float(bitPattern: expected[index]), rhs = Float(bitPattern: actual[index])
                guard abs(lhs - rhs) > phaseSlack else { continue }
                violations.append(
                    "cycles[\(component)] tid=\(tid) time=\(input.x) speed=\(input.y): "
                        + "\(lhs) vs \(rhs) exceeds one ULP (\(phaseSlack))"
                )
            }
            let low = Double(0.5 - input.z), high = Double(0.5 + input.z)
            let width = high - low
            func smoothstep(_ x: Double) -> Double {
                if abs(width) <= 1.0e-7 {
                    return x < low ? 0 : 1
                }
                let u = min(max((x - low) / width, 0), 1)
                return u * u * (3 - 2 * u)
            }
            let bandSlack = 4 * Double(phaseSlack)
            let t = Double(input.x) * Double(input.y)
            for component in 4 ..< 6 {
                let index = tid * 8 + component
                guard expected[index] != actual[index] else { continue }
                let phase = component == 4 ? t : 0.25 + t
                let band = 2 * abs((phase - floor(phase)) - 0.5)
                let image = [smoothstep(band - bandSlack), smoothstep(band), smoothstep(band + bandSlack)]
                let lower = image.min()! - outputSlack, upper = image.max()! + outputSlack
                for value in [expected[index], actual[index]].map({ Double(Float(bitPattern: $0)) })
                    where value < lower || value > upper {
                    violations.append(
                        "blend[\(component - 4)] tid=\(tid) time=\(input.x) speed=\(input.y) "
                            + "feather=\(input.z): \(value) outside [\(lower), \(upper)]"
                    )
                }
            }
        }
        return violations
    }

    /// `waterflowInliningPreservesGPUValues` compares two builds of the same translated
    /// source, so a helper edit lands on both sides and cancels; this pins the arithmetic
    /// against an independent Double model. waterflow.vert stays the oracle for semantics.
    @Test("Waterflow helper phases and blend weights match an independent CPU model", arguments: [false, true])
    func waterflowHelperMathMatchesModel(fastMath: Bool) throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let translated = try WPEShaderTranspiler.translateFragment(
            shaderName: "effects/waterflow",
            preprocessedSource: Self.waterflowProbeSource
        )
        let speeds: [Float] = [1, -1, 0.5, 3]
        let feathers: [Float] = [0, 0.05, 0.1, 0.25, 0.4, 0.5, -0.1]
        var inputs: [SIMD4<Float>] = []
        for time in Self.waterflowModelTimes {
            for speed in speeds {
                for feather in feathers {
                    inputs.append(SIMD4(time, speed, feather, 0))
                }
            }
        }
        let words = try waterflowProbeBits(
            translated.mslSource + "\n" + Self.waterflowProbeKernel,
            device: device,
            inputs: inputs,
            fastMath: fastMath
        )
        var failures: [String] = []
        var interiorBlends = 0
        for (tid, input) in inputs.enumerated() {
            let phases = Self.waterflowPhases(time: input.x, speed: input.y)
            for component in 0 ..< 4 {
                let admitted = Self.waterflowCycleAdmissible(phases[component])
                let value = Double(Float(bitPattern: words[tid * 8 + component]))
                if Self.waterflowMeasure(admitted) > 1.0e-3 {
                    failures.append(
                        "cycles[\(component)] tid=\(tid) time=\(input.x) speed=\(input.y): "
                            + "admitted \(admitted) is too wide to pin the phase"
                    )
                }
                if !Self.waterflowAdmits(admitted, value) {
                    failures.append(
                        "cycles[\(component)] tid=\(tid) time=\(input.x) speed=\(input.y): "
                            + "\(value) outside \(admitted)"
                    )
                }
            }
            for component in 0 ..< 2 {
                let admitted = Self.waterflowBlendAdmissible(
                    phases[component == 0 ? 0 : 2], feather: input.z
                )
                let value = Double(Float(bitPattern: words[tid * 8 + 4 + component]))
                // A feather this narrow degenerates to a hard step, where a legitimate phase ULP
                // is a 0->1 flip; those rows only assert membership.
                if abs(input.z) >= 0.05, Self.waterflowMeasure(admitted) > 1.0e-2 {
                    failures.append(
                        "blend[\(component)] tid=\(tid) time=\(input.x) speed=\(input.y) "
                            + "feather=\(input.z): admitted \(admitted) is too wide to pin the weight"
                    )
                }
                if !Self.waterflowAdmits(admitted, value) {
                    failures.append(
                        "blend[\(component)] tid=\(tid) time=\(input.x) speed=\(input.y) "
                            + "feather=\(input.z): \(value) outside \(admitted)"
                    )
                }
                if value > 0.001, value < 0.999 {
                    interiorBlends += 1
                }
            }
        }
        // Report a handful: a broken formula misses on thousands of rows, and Swift Testing
        // expands whole arrays into the diagnostic.
        let reported = Array(failures.prefix(8))
        #expect(
            reported.isEmpty,
            Comment(rawValue: "\(failures.count) of \(inputs.count * 6) probes off model:\n"
                + reported.joined(separator: "\n"))
        )
        // Without rows inside the feather band the smoothstep shape is never evaluated, and the
        // band edges would be pinned only through the 0/1 plateaus.
        #expect(interiorBlends > 100)
    }

    /// The 1/32 grid pins most rows bit-exactly and the integer offsets cover `fract`
    /// wrapping; the trailing values are not representable in Float, exercising rounding.
    private static let waterflowModelTimes: [Float] = {
        var times: [Float] = []
        for step in 0 ..< 32 {
            for offset in [Float(0), 3, -5, 40] {
                times.append(Float(step) / 32 + offset)
            }
        }
        return times + [0.1, 0.3, 0.7, 1.2345, 7.77, -0.123]
    }()

    /// (exact phase, how far a Float build may land from it): `t = time * speed` is one
    /// correctly-rounded multiply and carries no slack; each Float add after it may round.
    private static func waterflowPhases(time: Float, speed: Float) -> [(phase: Double, slack: Double)] {
        let t = Double(time * speed)
        return zip([0.0, 0.5, 0.25, 0.75], [0.0, 1, 1, 2]).map { offset, adds in
            let phase = t + offset
            return (phase, adds * Double(Float(phase).ulp))
        }
    }

    /// `fract`'s image of a phase interval, as a union because the interval can wrap an integer.
    private static func waterflowFractImage(_ phase: (phase: Double, slack: Double)) -> [ClosedRange<Double>] {
        let lo = phase.phase - phase.slack, hi = phase.phase + phase.slack
        guard hi - lo < 1 else { return [0 ... 1] }
        let low = lo - floor(lo), high = hi - floor(hi)
        return low <= high ? [low ... high] : [0 ... high, low ... 1]
    }

    private static func waterflowCycleAdmissible(_ phase: (phase: Double, slack: Double)) -> [ClosedRange<Double>] {
        // `cycles - 0.5` rounds once more, and Metal's `fract` clamps its result to the largest
        // Float below 1 — both are worth well under a ULP of 0.5.
        let slack = 2 * Double(Float(0.5).ulp)
        return waterflowFractImage(phase).map {
            ($0.lowerBound - 0.5 - slack) ... ($0.upperBound - 0.5 + slack)
        }
    }

    private static func waterflowBlendAdmissible(
        _ phase: (phase: Double, slack: Double), feather: Float
    ) -> [ClosedRange<Double>] {
        // Edges in Float, exactly as the helper builds them, including the degenerate-width
        // branch `wpe_smoothstep` takes at `|edge1 - edge0| <= 1e-7`.
        let edge0 = 0.5 - feather, edge1 = 0.5 + feather
        let width = edge1 - edge0
        let bandSlack = 2 * Double(Float(1).ulp)
        let outputSlack = 8 * Double(Float(1).ulp)
        func smoothstep(_ x: Double) -> Double {
            guard abs(width) > 1.0e-7 else { return x < Double(edge0) ? 0 : 1 }
            let u = min(max((x - Double(edge0)) / Double(width), 0), 1)
            return u * u * (3 - 2 * u)
        }
        return waterflowFractImage(phase).map { range in
            let ends = [2 * abs(range.lowerBound - 0.5), 2 * abs(range.upperBound - 0.5)]
            // `2 * |x - 0.5|` folds at x = 0.5, so a range spanning it reaches down to 0.
            let band = (range.contains(0.5) ? 0 : ends.min()!) ... ends.max()!
            // `wpe_smoothstep` is monotone in x (rising or, for a negative feather, falling),
            // so the band's endpoints bound its image.
            let image = [smoothstep(band.lowerBound - bandSlack), smoothstep(band.upperBound + bandSlack)]
            return (image.min()! - outputSlack) ... (image.max()! + outputSlack)
        }
    }

    private static func waterflowMeasure(_ ranges: [ClosedRange<Double>]) -> Double {
        ranges.reduce(0) { $0 + ($1.upperBound - $1.lowerBound) }
    }

    private static func waterflowAdmits(_ ranges: [ClosedRange<Double>], _ value: Double) -> Bool {
        ranges.contains { $0.contains(value) }
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
