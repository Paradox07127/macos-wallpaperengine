#if !LITE_BUILD
import Foundation
@testable import LiveWallpaper
import Metal
import Testing

@MainActor
@Suite("GLSL/Metal interpolation compatibility")
struct WPEMetalMathCompatibilityTests {
    @Test("Numeric mix extrapolates; nonzero smoothstep intervals stay Hermite", arguments: [false, true])
    func numericGPU(fast: Bool) throws {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let cases: [SIMD4<Float>] = [
            SIMD4(0.2, 0.8, -1, 0), SIMD4(0.2, 0.8, -0.5, 0), SIMD4(1, 3, 0, 0),
            SIMD4(1, 3, 0.5, 0), SIMD4(1, 3, 1, 0), SIMD4(1, 3, 1.5, 0), SIMD4(1, 3, 2, 0),
            SIMD4(-4, 8, -0.5, 0), SIMD4(100_000, 200_000, 1.5, 0),
            SIMD4(Float.greatestFiniteMagnitude / 2, -Float.greatestFiniteMagnitude / 2, 0.5, 0),
            SIMD4(0, 1e-8, 5e-9, 1), SIMD4(0, 1e-8, 2.5e-9, 1), SIMD4(0, 1e-8, 7.5e-9, 1),
            SIMD4(0, 1e-8, 0, 1), SIMD4(0, 1e-8, 1e-8, 1),
            SIMD4(0.5, Float(0.5).nextUp, 0.5, 1), SIMD4(0.5, Float(0.5).nextUp, Float(0.5).nextUp, 1),
            SIMD4(1, 1, 0.99, 1), SIMD4(1, 1, 1, 1), SIMD4(1, 1, 1.01, 1),
            SIMD4(1.3, 1, 1.15, 1), SIMD4(1.3, 1, 1.3, 1), SIMD4(1.3, 1, 1, 1),
            SIMD4(1_000_000, Float(1_000_000).nextUp, 1_000_000, 1),
        ]
        let kernel = """
        kernel void check(device const float4* values [[buffer(0)]], device float4* output [[buffer(1)]], uint id [[thread_position_in_grid]]) {
            float4 v = values[id];
            float scalar = v.w == 0 ? wpe_glsl_mix(v.x,v.y,v.z) : wpe_smoothstep(v.x,v.y,v.z);
            float2 pair = v.w == 0 ? wpe_glsl_mix(float2(v.x),float2(v.y),v.z) : wpe_smoothstep(v.x,v.y,float2(v.z));
            float3 triple = v.w == 0 ? wpe_glsl_mix(v.x,float3(v.y),float3(v.z)) : wpe_smoothstep(float3(v.x),float3(v.y),float3(v.z));
            float4 quad = v.w == 0 ? wpe_glsl_mix(float4(v.x),float4(v.y),float4(v.z)) : wpe_smoothstep(float4(v.x),float4(v.y),float4(v.z));
            output[id] = float4(scalar,pair.x,triple.y,quad.z);
        }
        """
        let values = try run(device: device, fast: fast, kernel: kernel, inputs: cases)
        for (index, v) in cases.enumerated() {
            let expected: Float
            if v.w == 0 {
                expected = Float((1 - Double(v.z)) * Double(v.x) + Double(v.z) * Double(v.y))
            } else if v.x == v.y {
                expected = v.z < v.x ? 0 : 1
            } else {
                let t = min(max((Double(v.z) - Double(v.x)) / (Double(v.y) - Double(v.x)), 0), 1)
                expected = Float(t * t * (3 - 2 * t))
            }
            for component in 0 ..< 4 {
                #expect(values[index][component].isFinite)
                #expect(abs(values[index][component] - expected) <= max(1e-5, abs(expected) * 2e-6), "case \(index), component \(component), fast=\(fast)")
            }
        }
    }

    @Test("Boolean mix selects floating, integer, unsigned and Boolean vectors")
    func booleanGPU() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let kernel = """
        kernel void check(device const float4* values [[buffer(0)]], device float4* output [[buffer(1)]], uint id [[thread_position_in_grid]]) {
            float4 a=values[0];
            float3 selected=wpe_glsl_mix(float3(a.x,a.y,a.x),float3(a.y,a.x,a.y),bool3(false,true,false));
            int3 ints=wpe_glsl_mix(int3(11,22,33),int3(44,55,66),bool3(false,true,false));
            uint2 uints=wpe_glsl_mix(uint2(7,8),uint2(9,10),bool2(true,false));
            bool4 bools=wpe_glsl_mix(bool4(false),bool4(true),bool4(true,false,true,false));
            output[0]=float4(selected,wpe_glsl_mix(a.x,a.y,false));
            output[1]=float4(float3(ints),float(uints.x));
            output[2]=float4(float(uints.y),float3(bools.xyz));
            output[3]=float4(wpe_glsl_mix(0,2,1.5),wpe_glsl_mix(0.0,2.0,2),wpe_glsl_mix(float2(1),float2(3),true));
        }
        """
        // Safe mode is required for a NaN input; fast math assumes finite values.
        let values = try run(device: device, fast: false, kernel: kernel, inputs: [SIMD4(7, .nan, 0, 0)], outputCount: 4)
        #expect(values[0] == SIMD4(repeating: 7))
        #expect(values[1] == SIMD4(11, 55, 33, 9))
        #expect(values[2] == SIMD4(8, 1, 0, 1))
        #expect(values[3] == SIMD4(3, 4, 3, 3))
    }

    @Test("Final routing covers helpers/macros/lerp and preserves authored ownership")
    func routing() throws {
        let source = """
        uniform float amount;
        #define BLEND(a,b,t) mix(a,b,t)
        #define INTERPOLATE mix
        float helper(float a,float b,float t) { return mix(a,b,t); }
        void main() { gl_FragColor=vec4(lerp(0.0,1.0,amount),helper(1.0,2.0,amount),BLEND(1.0,2.0,amount),INTERPOLATE(1.0,2.0,amount)); }
        """
        let result = try WPEShaderTranspiler.translateFragment(shaderName: "test/math", preprocessedSource: source, comboValues: [:])
        #expect(result.mslSource.contains("wpe_glsl_mix(0.0,1.0,amount)"))
        #expect(result.mslSource.contains("#define INTERPOLATE wpe_glsl_mix"))
        #expect(!result.mslSource.contains("return mix(a,b,t)"))
        let authoredFunction = "float mix(float x,float y,float a,float extra) { return x+y+a+extra; }"
        let custom = WPEShaderTranspiler.routingGLSLMixCalls(in: authoredFunction + "\nfloat f(){return mix(1.,2.,3.,4.);}", authoredHelpers: authoredFunction, authoredMain: "")
        #expect(custom.contains("return mix(1.,2.,3.,4.)"))
        let authoredMacro = "#define mix(a,b,t) ((a)+(b)+(t))"
        #expect(WPEShaderTranspiler.routingGLSLMixCalls(in: authoredMacro + "\nmix(1.,2.,3.);", authoredHelpers: authoredMacro, authoredMain: "").contains("\nmix(1.,2.,3.);"))
        let qualified = "// 注释 mix(x,y,a)\nmetal::mix(x,y,a);\nmix(x,y,a);"
        #expect(WPEShaderTranspiler.routingGLSLMixCalls(in: qualified, authoredHelpers: "", authoredMain: "") == "// 注释 mix(x,y,a)\nmetal::mix(x,y,a);\nwpe_glsl_mix(x,y,a);")
        if let device = MTLCreateSystemDefaultDevice() {
            _ = try device.makeLibrary(source: result.mslSource, options: WPEMetalLibraryRegistry.Configuration().makeOptions())
        }
    }

    @Test("An authored mix function or macro skips routing and says so in the MSL", arguments: ["function", "macro", "identity"])
    func authoredMixSkipsRoutingWithDiagnostic(kind: String) throws {
        let sources = [
            "function": """
            uniform float amount;
            float mix(float x, float y, float a, float extra) { return x + y + a + extra; }
            void main() { gl_FragColor = vec4(mix(1.0, 2.0, amount, 0.5), mix(0.0, 1.0, amount), 0.0, 1.0); }
            """,
            "macro": """
            uniform float amount;
            #define mix(a, b, t) ((a) + (b) + (t))
            void main() { gl_FragColor = vec4(mix(1.0, 2.0, amount), 0.0, 0.0, 1.0); }
            """,
            // An authored self-referential macro is still the author claiming the name.
            "identity": """
            #define mix mix
            uniform float amount;
            void main() { gl_FragColor = vec4(mix(1.0, 2.0, amount), 0.0, 0.0, 1.0); }
            """,
        ]
        let result = try WPEShaderTranspiler.translateFragment(
            shaderName: "test/authored_mix_\(kind)", preprocessedSource: #require(sources[kind])
        )
        #expect(result.mslSource.hasPrefix("// WPE-DIAGNOSTIC: mix routing skipped (authored mix)"))
        #expect(result.mslSource.contains("mix(1.0, 2.0, amount"))
        #expect(!result.mslSource.contains("wpe_glsl_mix(1.0, 2.0, amount") && !result.mslSource.contains("wpe_glsl_mix(0.0, 1.0, amount"))
        if let device = MTLCreateSystemDefaultDevice() {
            _ = try device.makeLibrary(source: result.mslSource, options: WPEMetalLibraryRegistry.Configuration().makeOptions())
        }
    }

    @Test("Mixed integer/float scalar endpoints (blur_combine's `mix(x, 1, t)`) resolve and interpolate")
    func mixedIntegerAndFloatEndpointsResolve() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        // Corpus form: workshop blur_combine.frag `float div = mix(blurred.a, 1, step(blurred.a, 0));`.
        let source = """
        uniform sampler2D g_Texture0;
        varying vec2 v_TexCoord;
        void main() {
            vec4 blurred = texSample2D(g_Texture0, v_TexCoord);
            float div = mix(blurred.a, 1, step(blurred.a, 0));
            float lead = mix(0, blurred.r, blurred.g);
            float pick = mix(blurred.b, 1, blurred.a > 0.5);
            gl_FragColor = vec4(div, lead, pick, 1.0);
        }
        """
        let result = try WPEShaderTranspiler.translateFragment(shaderName: "test/mixed_mix", preprocessedSource: source)
        #expect(result.mslSource.contains("wpe_glsl_mix(blurred.a, 1, step(blurred.a, 0))"))
        _ = try device.makeLibrary(source: result.mslSource, options: WPEMetalLibraryRegistry.Configuration().makeOptions())

        let kernel = """
        kernel void check(device const float4* values [[buffer(0)]], device float4* output [[buffer(1)]], uint id [[thread_position_in_grid]]) {
            float4 v = values[id];
            output[id] = float4(wpe_glsl_mix(v.x, 1, v.z), wpe_glsl_mix(0, v.y, v.z), wpe_glsl_mix(v.x, 1, true), wpe_glsl_mix(v.x, 1, false));
        }
        """
        let cases: [SIMD4<Float>] = [SIMD4(0.25, 4, 0.5, 0), SIMD4(2, -3, 1.5, 0)]
        let values = try run(device: device, fast: false, kernel: kernel, inputs: cases)
        for (index, v) in cases.enumerated() {
            #expect(values[index] == SIMD4((1 - v.z) * v.x + v.z * 1, v.z * v.y, 1, v.x), "case \(index)")
        }
    }

    @Test("Native reflection uses ordered smoothstep edges and extrapolation helpers")
    func nativeSourceContract() throws {
        let source = try RepositoryRoot.source("LiveWallpaper/Runtime/Metal/WPEMetalBuiltins.metal")
        #expect(source.contains("wpe_lerp(u.chromaTintBack.rgb, u.chromaTintFront.rgb, dot(viewVector, worldNormal))"))
        #expect(source.contains("wpe_lerp(float3(luma), rgb, settings.saturation)"))
        #expect(!source.contains("smoothstep(1.3, 1.0"))
        #expect(source.contains("1.0 - smoothstep(1.0, 1.3, screenUV.x)"))
        #expect(source.contains("1.0 - smoothstep(1.0, 1.3, screenUV.y)"))
    }

    private func run(device: MTLDevice, fast: Bool, kernel: String, inputs: [SIMD4<Float>], outputCount: Int? = nil) throws -> [SIMD4<Float>] {
        let source = "#include <metal_stdlib>\nusing namespace metal;\n" + WPEShaderTranspiler.glslMathPrelude + "\n" + kernel
        let library = try device.makeLibrary(source: source, options: WPEMetalLibraryRegistry.Configuration(fastMathEnabled: fast).makeOptions())
        let function = try #require(library.makeFunction(name: "check"))
        let state = try device.makeComputePipelineState(function: function)
        let input = try #require(inputs.withUnsafeBytes { device.makeBuffer(bytes: $0.baseAddress!, length: $0.count, options: .storageModeShared) })
        let count = outputCount ?? inputs.count
        let output = try #require(device.makeBuffer(length: count * MemoryLayout<SIMD4<Float>>.stride, options: .storageModeShared))
        let queue = try #require(device.makeCommandQueue())
        let command = try #require(queue.makeCommandBuffer())
        let encoder = try #require(command.makeComputeCommandEncoder())
        encoder.setComputePipelineState(state)
        encoder.setBuffer(input, offset: 0, index: 0)
        encoder.setBuffer(output, offset: 0, index: 1)
        encoder.dispatchThreads(MTLSize(width: inputs.count, height: 1, depth: 1), threadsPerThreadgroup: MTLSize(width: 1, height: 1, depth: 1))
        encoder.endEncoding()
        command.commit()
        command.waitUntilCompleted()
        #expect(command.status == .completed, "\(String(describing: command.error))")
        let values = output.contents().assumingMemoryBound(to: SIMD4<Float>.self)
        return Array(UnsafeBufferPointer(start: values, count: count))
    }
}
#endif
