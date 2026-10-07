#if !LITE_BUILD && DEBUG
import CryptoKit
import Foundation
@testable import LiveWallpaper
import LiveWallpaperProWPE
import Metal
import Testing

@Suite("Production stage translation GPU contracts", .serialized)
struct WPELinkedShaderStageTests {
    @Test func vertexVectorTruncationPreservesConsumedChannelsThroughInterpolation() throws {
        // Active patterns from cloudmotion and iris: an output float2 receives a
        // float4, and a cursor float4 multiplies a float2 scale before sampling.
        let vertex = """
        attribute vec3 a_Position;
        attribute vec2 a_TexCoord;
        varying vec2 v_NoiseCoord;
        varying vec2 v_Cursor;
        uniform vec2 scale;
        void main() {
            gl_Position = vec4(a_Position, 1.0);
            vec4 coord = vec4(a_TexCoord, 31, 47);
            v_NoiseCoord = coord;
            vec2 scaled = (coord * scale * 0.5).xy;
            v_Cursor = scaled;
        }
        """
        let fragment = """
        varying vec2 v_NoiseCoord;
        varying vec2 v_Cursor;
        void main() { gl_FragColor = vec4(v_NoiseCoord, v_Cursor); }
        """
        let pixels = try replay(vertex: vertex, fragment: fragment, vertexValues: ["scale": .vector([2, 3])])
        for y in 0 ..< 4 {
            for x in 0 ..< 4 {
                let uv = SIMD2<Float>((Float(x) + 0.5) / 4, (Float(y) + 0.5) / 4)
                let pixel = pixels[y * 4 + x]
                #expect(abs(pixel.x - uv.x) < 0.00001 && abs(pixel.y - uv.y) < 0.00001)
                #expect(abs(pixel.z - uv.x) < 0.00001 && abs(pixel.w - uv.y * 1.5) < 0.00001)
            }
        }
    }

    @Test func authoredObjectQuadReceivesRawModelPixelsAndIndependentMVP() throws {
        let vertex = """
        attribute vec3 a_Position;
        attribute vec2 a_TexCoord;
        uniform mat4 g_ModelViewProjectionMatrix;
        varying vec2 v_Raw;
        void main(){gl_Position=mul(vec4(a_Position,1.0),g_ModelViewProjectionMatrix);v_Raw=a_Position.xy/vec2(4.0,8.0)+0.5;}
        """
        let fragment = "varying vec2 v_Raw; void main(){gl_FragColor=vec4(v_Raw,0.375,1.0);}"
        let matrix: [Double] = [0.5, 0, 0, 0, 0, 0.25, 0, 0, 0, 0, 0.00025, 0, 0, 0, 0.5, 1]
        let pixels = try replay(vertex: vertex, fragment: fragment, vertexValues: ["g_ModelViewProjectionMatrix": .vector(matrix)],
                                execution: .authoredObjectQuad, positionScale: SIMD2(2, 4))
        for y in 0 ..< 4 {
            for x in 0 ..< 4 {
                #expect(abs(pixels[y * 4 + x].x - (Float(x) + 0.5) / 4) < 0.00001)
                #expect(abs(pixels[y * 4 + x].y - (1 - (Float(y) + 0.5) / 4)) < 0.00001)
            }
        }
    }

    @Test func authoredObjectQuadRetainsWindowsDiagonalForVertexVaryings() throws {
        let vertex = """
        attribute vec3 a_Position;
        attribute vec2 a_TexCoord;
        varying float v_Corner;
        void main(){gl_Position=vec4(a_Position,1.0);v_Corner=a_TexCoord.x*a_TexCoord.y;}
        """
        let pixels = try replay(vertex: vertex, fragment: "varying float v_Corner; void main(){gl_FragColor=vec4(v_Corner,0.0,0.0,1.0);}",
                                execution: .authoredObjectQuad)
        for y in 0 ..< 4 {
            for x in 0 ..< 4 {
                let expected = min((Float(x) + 0.5) / 4, (Float(y) + 0.5) / 4)
                #expect(abs(pixels[y * 4 + x].x - expected) < 0.00001)
            }
        }
    }

    @Test func unobservedInverseWriteRetainsRealVSAndDoesNotAlterRasterOutput() throws {
        let vertex = """
        #define mul(a,b) ((b)*(a))
        attribute vec3 a_Position;
        attribute vec2 a_TexCoord;
        uniform mat4 g_ModelViewProjectionMatrix;
        uniform mat4 g_ModelViewProjectionMatrixInverse;
        varying vec2 uv;
        varying vec4 unused;
        void main() {
            gl_Position=mul(vec4(a_Position,1),g_ModelViewProjectionMatrix);
            uv=a_TexCoord*0.25+0.375;
            unused=mul(vec4(0.5,0.25,0,1),g_ModelViewProjectionMatrixInverse);
        }
        """
        let fragment = """
        varying vec2 uv;
        void main(){gl_FragColor=vec4(uv,0.625,1);}
        """
        for scale: Double in [1, 7] {
            let matrix = [scale, 0, 0, 0, 0, scale, 0, 0, 0, 0, scale, 0, 0, 0, 0, 1]
            let identity: [Double] = [1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1]
            let pixels = try replay(vertex: vertex, fragment: fragment, vertexValues: ["g_ModelViewProjectionMatrix": .vector(identity), "g_ModelViewProjectionMatrixInverse": .vector(matrix)], requiredPositionProof: true)
            for y in 0 ..< 4 {
                for x in 0 ..< 4 {
                    #expect(abs(pixels[y * 4 + x].x - (0.375 + (Float(x) + 0.5) / 16)) < 0.00001)
                    #expect(abs(pixels[y * 4 + x].y - (0.375 + (Float(y) + 0.5) / 16)) < 0.00001)
                    #expect(pixels[y * 4 + x].z == 0.625)
                }
            }
        }
    }

    @Test func locallyShadowedInputsUseLocalValuesAndRealVertexInterpolation() throws {
        let vertex = """
        attribute vec3 a_Position;
        attribute vec2 a_TexCoord;
        varying vec2 v_UV;
        void main() { gl_Position = vec4(a_Position, 1); v_UV = a_TexCoord * 0.25 + 0.375; }
        """
        let fragment = """
        varying vec2 v_UV;
        varying vec4 timer;
        varying vec4 rValue;
        void main() {
            float timer = 0.625;
            vec4 rValue = vec4(v_UV, timer, 1);
            gl_FragColor = rValue;
        }
        """
        let pixels = try replay(vertex: vertex, fragment: fragment)
        for y in 0 ..< 4 {
            for x in 0 ..< 4 {
                let pixel = pixels[y * 4 + x]
                #expect(abs(pixel.x - (0.375 + (Float(x) + 0.5) / 16)) < 0.00001)
                #expect(abs(pixel.y - (0.375 + (Float(y) + 0.5) / 16)) < 0.00001)
                #expect(pixel.z == 0.625 && pixel.w == 1)
            }
        }
    }

    @Test func unreferencedOrphanInputsPreserveRealVertexInterpolation() throws {
        let vertex = """
        attribute vec3 a_Position;
        attribute vec2 a_TexCoord;
        varying vec4 v_Result;
        void main() {
            gl_Position = vec4(a_Position, 1.0);
            v_Result = vec4(a_TexCoord * a_TexCoord, a_TexCoord * 0.25 + 0.375);
        }
        """
        let fragment = """
        varying vec4 v_Result;
        varying vec2 v_Scroll;
        #define USE_SCROLL 0
        #if USE_SCROLL
        vec2 helper() { return v_Scroll; }
        #endif
        // v_Scroll has no producer and no active reference.
        void main() { gl_FragColor = v_Result; }
        """
        let pixels = try replay(vertex: vertex, fragment: fragment)
        for y in 0 ..< 4 {
            for x in 0 ..< 4 {
                let uv = SIMD2<Float>((Float(x) + 0.5) / 4, (Float(y) + 0.5) / 4)
                let pixel = pixels[y * 4 + x]
                // Squaring the vertex endpoints still interpolates to uv. Doing
                // this arithmetic per fragment would instead produce uv * uv.
                #expect(abs(pixel.x - uv.x) < 0.00001 && abs(pixel.y - uv.y) < 0.00001)
                #expect(abs(pixel.z - (0.375 + uv.x * 0.25)) < 0.00001)
                #expect(abs(pixel.w - (0.375 + uv.y * 0.25)) < 0.00001)
            }
        }
        let link = try WPEShaderStageLink(vertex: vertex, fragment: fragment)
        #expect(link.interface.unreferencedFragmentInputs == ["v_Scroll"])
        #expect(link.interface.issues.contains { $0.code == .missingVertexOutput && $0.name == "v_Scroll" })
        for extra in ["vec2 helper() { return v_Scroll; }", "#define READ_SCROLL v_Scroll"] {
            #expect(throws: WPEShaderCompilerError.self) {
                try WPEShaderStageLink(vertex: vertex, fragment: fragment + "\n" + extra)
            }
        }
        #expect(throws: WPEShaderCompilerError.self) {
            try WPEShaderStageLink(vertex: vertex, fragment: fragment.replacingOccurrences(of: "gl_FragColor = v_Result", with: "gl_FragColor = vec4(v_Scroll, 0, 1)"))
        }
    }

    @Test func floatVaryingPrefixesKeepAuthoredFragmentTypes() throws {
        let vertex = """
        attribute vec3 a_Position; attribute vec2 a_TexCoord;
        varying vec4 v_Result;
        void main() { gl_Position=vec4(a_Position,1.0); v_Result=vec4(a_TexCoord*a_TexCoord,0.125,0.875); }
        """
        let fragment = """
        varying vec2 v_Result;
        vec2 shift(vec2 uv) { return uv*0.5+0.25; }
        void main() { gl_FragColor=vec4(shift(v_Result),0.375,1.0); }
        """
        let pixels = try replay(vertex: vertex, fragment: fragment)
        for y in 0 ..< 4 {
            for x in 0 ..< 4 {
                #expect(abs(pixels[y * 4 + x].x - (0.25 + (Float(x) + 0.5) / 8)) < 0.00001)
                #expect(abs(pixels[y * 4 + x].y - (0.25 + (Float(y) + 0.5) / 8)) < 0.00001)
            }
        }
        let link = try WPEShaderStageLink(vertex: vertex, fragment: fragment)
        #expect(link.fragmentDeclarations.contains { $0.contains("float2 v_Result = in.wpe_v0_0.xy;") })
        #expect(link.interface.issues.contains { $0.code == .varyingTypeMismatch })
        let smaller = vertex.replacingOccurrences(of: "varying vec4 v_Result", with: "varying vec2 v_Result")
            .replacingOccurrences(of: "vec4(a_TexCoord*a_TexCoord,0.125,0.875)", with: "a_TexCoord*a_TexCoord")
        let wider = fragment.replacingOccurrences(of: "varying vec2 v_Result", with: "varying vec4 v_Result")
            .replacingOccurrences(of: "shift(v_Result)", with: "shift(v_Result.xy)")
        #expect(try replay(vertex: smaller, fragment: wider) == pixels)
        for read in ["v_Result.zw", "v_Result[2]", "v_Result.xyfoo", "vec2(v_Result)"] {
            #expect(throws: WPEShaderCompilerError.self) {
                try WPEShaderStageLink(vertex: smaller, fragment: "varying vec4 v_Result; void main(){gl_FragColor=vec4(" + read + ",0,1);}")
            }
        }
    }

    @Test func fragmentReadsChannelsActuallyProducedBeyondItsDeclaredWidth() throws {
        let vertex = """
        attribute vec3 a_Position; attribute vec2 a_TexCoord;
        varying vec4 v_Result;
        void main(){gl_Position=vec4(a_Position,1.0);v_Result=vec4(a_TexCoord,0.125,0.875);}
        """
        let fragment = """
        varying vec2 v_Result;
        vec2 prefix(vec2 value){return value;}
        void main(){vec2 uv=prefix(v_Result);gl_FragColor=vec4(uv,v_Result.zw);}
        """
        let pixels = try replay(vertex: vertex, fragment: fragment)
        for y in 0 ..< 4 {
            for x in 0 ..< 4 {
                let pixel = pixels[y * 4 + x]
                #expect(abs(pixel.x - (Float(x) + 0.5) / 4) < 0.00001)
                #expect(abs(pixel.y - (Float(y) + 0.5) / 4) < 0.00001)
                #expect(pixel.z == 0.125 && pixel.w == 0.875)
            }
        }
        let gradient = (0 ..< 16).map { SIMD4<Float>(Float($0 % 4) / 3, Float($0 / 4) / 3, 0.25, 1) }
        let sampled = try replay(vertex: vertex, fragment: """
        varying vec2 v_Result;
        uniform sampler2D g_Texture0;
        void main(){gl_FragColor=vec4(texSample2D(g_Texture0,v_Result).rg,v_Result.zw);}
        """, fragmentPixels: gradient)
        for y in 0 ..< 4 {
            for x in 0 ..< 4 {
                #expect(abs(sampled[y * 4 + x].x - Float(x) / 3) < 0.00001)
                #expect(abs(sampled[y * 4 + x].y - Float(y) / 3) < 0.00001)
                #expect(sampled[y * 4 + x].z == 0.125 && sampled[y * 4 + x].w == 0.875)
            }
        }
        let link = try WPEShaderStageLink(vertex: vertex, fragment: fragment)
        #expect(link.fragmentDeclarations.contains { $0.contains("float4 v_Result = in.wpe_v0_0;") })
        #expect(link.interface.variables(stage: .fragment, kind: .varyingInput).first?.glslType == "vec2")
        let masked = try WPEShaderStageLink(vertex: vertex, fragment: "varying vec2 v_Result; void main(){gl_FragColor=vec4(v_Result,0,1);/*v_Result.zw*/}")
        #expect(masked.fragmentDeclarations.contains { $0.contains("float2 v_Result") })
    }

    @Test func unusedWidthMismatchAndLocatedNamesDoNotInventConsumedInputs() throws {
        let vertex = """
        attribute vec3 a_Position; attribute vec2 a_TexCoord;
        varying vec2 unused;
        layout(location=3) out vec4 producer;
        void main(){gl_Position=vec4(a_Position,1.0);unused=a_TexCoord;producer=vec4(a_TexCoord,0.2,0.8);}
        """
        let fragment = """
        varying vec4 unused;
        layout(location=3) in vec2 renamed;
        void main(){gl_FragColor=vec4(renamed,0.375,1.0);}
        """
        let pixels = try replay(vertex: vertex, fragment: fragment)
        for y in 0 ..< 4 {
            for x in 0 ..< 4 {
                #expect(abs(pixels[y * 4 + x].x - (Float(x) + 0.5) / 4) < 0.00001)
                #expect(abs(pixels[y * 4 + x].y - (Float(y) + 0.5) / 4) < 0.00001)
            }
        }
        let link = try WPEShaderStageLink(vertex: vertex, fragment: fragment)
        #expect(link.fragmentDeclarations.count == 1)
        #expect(link.fragmentDeclarations[0].contains("float2 renamed = in.wpe_v1_0.xy;"))
        #expect(link.interface.unreferencedFragmentInputs == ["unused"])
    }

    @Test func inversePreludeIsEmittedOnlyInConsumingStages() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let compiler = WPESwiftShaderCompiler(device: device, translationCache: WPEShaderTranslationCache(rootURL: root))
        let vertex = "attribute vec3 a_Position; void main(){ gl_Position = inverse(mat4(1.0)) * vec4(a_Position,1.0); }"
        let request = WPEShaderCompileRequest(shaderName: "inverse-prelude-admission", processedVertexSource: vertex,
                                              processedFragmentSource: "void main(){gl_FragColor=vec4(1.0);}",
                                              sourceHash: "inverse-prelude-admission", comboValues: [:], textureBindings: [:])
        let linked = try compiler.compile(request.replacingVertexExecution(.authoredFullscreen))
        #expect(linked.vertexStage?.mslSource.contains("inline float4x4 wpe_glsl_inverse") == true)
        #expect(!linked.mslSource.contains("wpe_glsl_inverse"))
        #expect(try !compiler.compile(request).mslSource.contains("wpe_glsl_inverse"))
    }

    @Test func depthParallaxBasisUsesVertexMatrixAndIndependentFragmentBinding() throws {
        let vertex = """
        attribute vec3 a_Position;
        uniform mat4 shared;
        uniform vec2 u_Pointer;
        varying vec2 v_Parallax;
        void main() {
            gl_Position = vec4(a_Position, 1.0);
            vec2 dirX = normalize(shared[0].xy);
            vec2 dirY = normalize(shared[1].xy);
            vec2 pointer = u_Pointer * 2.0 - 1.0;
            v_Parallax = 0.5 + 0.5 * (pointer.x * dirX + pointer.y * dirY);
        }
        """
        let fragment = """
        varying vec2 v_Parallax;
        uniform float shared;
        void main() { gl_FragColor = vec4(v_Parallax, shared, 1.0); }
        """
        let fixtures: [([Double], SIMD2<Float>)] = [
            // Actual captured positive axes: normalization cancels the non-unit scale.
            ([0.914285660, 0, 0, 0, 0, 0.863999963, 0, 0, 0, 0, 3999.999756, 0, -0.000359072, -0.045459863, -1499.999878, 1], .init(0.75, 0.25)),
            ([1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1], .init(0.75, 0.25)),
            ([0, 2, 0, 0, -3, 0, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1], .init(0.75, 0.75)),
            ([-2, 0, 0, 0, 0, 3, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1], .init(0.25, 0.25)),
        ]
        for (matrix, expected) in fixtures {
            let pixels = try replay(vertex: vertex, fragment: fragment,
                                    vertexValues: ["shared": .vector(matrix), "u_Pointer": .vector([0.75, 0.25])],
                                    fragmentValues: ["shared": .number(0.375)])
            for pixel in pixels {
                #expect(abs(pixel.x - expected.x) < 0.00001)
                #expect(abs(pixel.y - expected.y) < 0.00001)
                #expect(pixel.z == 0.375 && pixel.w == 1)
            }
        }
    }

    @Test func actualVertexValuesAreInterpolatedAndZWIsPreserved() throws {
        let vertex = """
        attribute vec3 a_Position;
        attribute vec2 a_TexCoord;
        varying vec4 v_TexCoord;
        void main() {
            gl_Position = vec4(a_Position, 1.0);
            v_TexCoord = vec4(a_TexCoord * a_TexCoord, a_TexCoord * 0.25 + 0.375);
        }
        """
        let fragment = """
        varying vec4 v_TexCoord;
        void main() { gl_FragColor = vec4(v_TexCoord.xy, v_TexCoord.zw); }
        """
        let pixels = try replay(vertex: vertex, fragment: fragment)
        for y in 0 ..< 4 {
            for x in 0 ..< 4 {
                let uv = SIMD2<Float>((Float(x) + 0.5) / 4, (Float(y) + 0.5) / 4)
                let pixel = pixels[y * 4 + x]
                #expect(abs(pixel.x - uv.x) < 0.00001 && abs(pixel.y - uv.y) < 0.00001)
                #expect(abs(pixel.z - (uv.x * 0.25 + 0.375)) < 0.00001)
                #expect(abs(pixel.w - (uv.y * 0.25 + 0.375)) < 0.00001)
            }
        }
    }

    @Test func helperUniformArraysAndDifferentStageTypesKeepIndependentLayouts() throws {
        let vertex = """
        attribute vec3 a_Position;
        attribute vec2 a_TexCoord;
        uniform mat4 shared;
        uniform vec2 offsets[2];
        varying vec2 v_Result[2];
        vec2 calc(vec2 inputValue) { return inputValue + offsets[1]; }
        void main() {
            gl_Position = shared * vec4(a_Position, 1.0);
            v_Result[0] = calc(a_TexCoord);
            v_Result[1] = a_TexCoord * 0.5;
        }
        """
        let fragment = """
        uniform float shared;
        varying vec2 v_Result[2];
        void main() { gl_FragColor = vec4(v_Result[0], v_Result[1].x, shared); }
        """
        let identity: [Double] = [1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1]
        let pixels = try replay(vertex: vertex, fragment: fragment,
                                vertexValues: ["shared": .vector(identity), "offsets": .vector([0, 0, 0.125, 0.25])],
                                fragmentValues: ["shared": .number(0.625)])
        for y in 0 ..< 4 {
            for x in 0 ..< 4 {
                let pixel = pixels[y * 4 + x]
                #expect(abs(pixel.x - ((Float(x) + 0.5) / 4 + 0.125)) < 0.00001)
                #expect(abs(pixel.y - ((Float(y) + 0.5) / 4 + 0.25)) < 0.00001)
                #expect(abs(pixel.z - (Float(x) + 0.5) / 8) < 0.00001 && pixel.w == 0.625)
            }
        }
    }

    @Test func flatInterpolationIsExecutedAndMismatchedContractIsRejected() throws {
        let vertex = """
        attribute vec3 a_Position;
        attribute vec2 a_TexCoord;
        flat varying float v_Value;
        void main() { gl_Position = vec4(a_Position, 1); v_Value = a_TexCoord.x; }
        """
        let fragment = """
        flat varying float v_Value;
        void main() { gl_FragColor = vec4(v_Value, 0, 0, 1); }
        """
        let pixels = try replay(vertex: vertex, fragment: fragment)
        #expect(pixels.allSatisfy { $0.x == 0 || $0.x == 1 })
        #expect(throws: WPEShaderCompilerError.self) {
            try WPEShaderStageLink(vertex: vertex, fragment: fragment.replacingOccurrences(of: "flat varying", with: "varying"))
        }
    }

    @Test func inverseUsesColumnMajorMatricesRowPivotingAndSmallNonzeroScales() throws {
        let fixtures: [(Int, [Double], [Double], SIMD4<Float>)] = [
            (2, [0, 2, -3, 0], [3, 4], SIMD4<Float>(2, -1, 0, 1)),
            (3, [1e-8, 0, 0, 0, 2, 0, 0, 0, -4], [1e-8, 6, 8], SIMD4<Float>(1, 3, -2, 1)),
            (4, [0, 2, 0, 0, -3, 0, 0, 0, 0, 0, 4, 0, 5, 6, 7, 1], [11, 10, 15, 1], SIMD4<Float>(2, -2, 2, 1)),
        ]
        for (width, matrix, point, expected) in fixtures {
            let value = width == 4 ? "inverse(matrix) * point" : "vec4(inverse(matrix) * point, \(width == 2 ? "0," : "") 1)"
            let vertex = """
            attribute vec3 a_Position;
            uniform mat\(width) matrix;
            uniform vec\(width) point;
            varying vec4 v_Value;
            void main() { gl_Position = vec4(a_Position, 1); v_Value = \(value); }
            """
            let fragment = """
            varying vec4 v_Value;
            void main() { gl_FragColor = v_Value; }
            """
            let pixels = try replay(vertex: vertex, fragment: fragment,
                                    vertexValues: ["matrix": .vector(matrix), "point": .vector(point)])
            for actual in pixels {
                #expect(abs(actual.x - expected.x) < 0.00005 && abs(actual.y - expected.y) < 0.00005)
                #expect(abs(actual.z - expected.z) < 0.00005 && abs(actual.w - expected.w) < 0.00005)
            }
        }
        let authored = "float inverse(float x) { return x + 0.25; }"
        #expect(try WPEShaderTranspiler.applySubstitutions(authored).contains("float inverse("))
        #expect(try WPEShaderTranspiler.applySubstitutions("inverse(0.5)", functionDeclarations: authored).contains("inverse(0.5)"))
    }

    @Test func vertexTextureSamplingUsesLODZeroAndInputAlphaContract() throws {
        let vertex = """
        attribute vec3 a_Position;
        attribute vec2 a_TexCoord;
        uniform sampler2D g_Texture0;
        varying vec4 v_Value;
        void main() { gl_Position = vec4(a_Position, 1); v_Value = texture(g_Texture0, a_TexCoord); }
        """
        let fragment = """
        varying vec4 v_Value;
        void main() { gl_FragColor = v_Value; }
        """
        let pixels = try replay(vertex: vertex, fragment: fragment, vertexSample: SIMD4<Float>(0.25, 0.125, 0, 0.5), premultipliedInputSlots: [0])
        #expect(pixels.allSatisfy { $0 == SIMD4<Float>(0.5, 0.25, 0, 0.5) })
    }

    @Test func largeVertexArrayUsesRealBufferBinding() throws {
        let vertex = """
        attribute vec3 a_Position;
        uniform float weights[257];
        varying float v_Value;
        float readLast() { return weights[256]; }
        void main() { gl_Position = vec4(a_Position, 1); v_Value = readLast(); }
        """
        let fragment = """
        varying float v_Value;
        void main() { gl_FragColor = vec4(v_Value, 0, 0, 1); }
        """
        var values = [Double](repeating: 0, count: 257); values[256] = 0.625
        let pixels = try replay(vertex: vertex, fragment: fragment, vertexValues: ["weights": .vector(values)])
        #expect(pixels.allSatisfy { $0.x == 0.625 && $0.w == 1 })
    }

    @Test func vertexUVAndDerivativeSemanticsAreNotFragmentRewrites() throws {
        let source = "v_TexCoord.zw = vec2(0.2); vec2 p = v_TexCoord.zw; float d = dFdy(p.x);"
        let translated = try WPEShaderTranspiler.applySubstitutions(source, stage: .vertex)
        #expect(translated.contains("v_TexCoord.zw") && translated.contains("dFdy("))
        #expect(!translated.contains("dfdy("))
    }

    @Test func stageArtifactsSurviveDiskAndMemoryCacheAndHaveDistinctExecutionKeys() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = WPEShaderTranslationCache(rootURL: root)
        let compiler = try WPESwiftShaderCompiler(device: #require(MTLCreateSystemDefaultDevice()), translationCache: cache)
        let request = WPEShaderCompileRequest(shaderName: "stage-cache",
                                              processedVertexSource: """
                                              attribute vec3 a_Position;
                                              uniform mat4 shared;
                                              varying vec4 v_TexCoord;
                                              void main() { gl_Position = shared * vec4(a_Position, 1); v_TexCoord = vec4(0.625); }
                                              """,
                                              processedFragmentSource: """
                                              varying vec4 v_TexCoord;
                                              uniform float shared;
                                              void main() { gl_FragColor = v_TexCoord * shared; }
                                              """, sourceHash: "stage-cache-fixture", comboValues: [:], textureBindings: [:], premultipliedInputSlots: [7], premultipliedOutput: true, vertexExecution: .authoredFullscreen)
        #expect(request.translationCacheKey != request.replacingVertexExecution(.synthesized).translationCacheKey)
        let cold = try compiler.compile(request)
        cache.dropMemoryForTesting()
        let disk = try compiler.compile(request)
        let memory = try compiler.compile(request)
        for result in [cold, disk, memory] {
            let vertex = try #require(result.vertexStage)
            #expect(vertex.uniformLayout.first?.glslType == "mat4")
            #expect(result.uniformLayout.first?.glslType == "float")
            #expect(vertex.library.makeFunction(name: result.vertexFunctionName) != nil)
            #expect(vertex.mslSource == cold.vertexStage?.mslSource)
            #expect(result.mslSource == cold.mslSource)
            #expect(result.shaderInterface == cold.shaderInterface)
            #expect(result.alphaContract == .init(unpremultipliedInputSlots: [7], premultipliedOutput: true))
        }
        #expect(cache.diskHitCountForTesting == 1 && cache.memoryHitCountForTesting == 1)
    }

    @Test(.enabled(if: TestScratch.externalFixtureURL(pathKey: "WPE_DEPTHPARALLAX_VERTEX_PATH") != nil,
                   "opt-in: provide the locally owned depthparallax vertex source"))
    func actualDepthParallaxVertexFeedsResolutionAndProjectionVaryings() throws {
        let path = try #require(TestScratch.externalFixtureURL(pathKey: "WPE_DEPTHPARALLAX_VERTEX_PATH"))
        let data = try Data(contentsOf: path)
        let source = try #require(String(data: data, encoding: .utf8))
        let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        print("[authored-vertex-probe] sourceSHA256=\(hash) bytes=\(data.count)")
        let identity: [Double] = [1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1]
        let matrices: [([Double], SIMD2<Float>)] = [
            ([0.914285660, 0, 0, 0, 0, 0.863999963, 0, 0, 0, 0, 3999.999756, 0, -0.000359072, -0.045459863, -1499.999878, 1], .init(0.75, 0.25)),
            ([0, 2, 0, 0, -3, 0, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1], .init(0.75, 0.75)),
        ]
        for mask in [0, 1] {
            let vertex = "#define MASK \(mask)\n" + source
            let fragment = """
            varying vec4 v_TexCoord;
            varying vec2 v_ParallaxOffset;
            void main() { gl_FragColor = vec4(v_ParallaxOffset, v_TexCoord.zw); }
            """
            for (inverse, expected) in matrices {
                let uniforms: [String: WPESceneShaderConstantValue] = [
                    "g_ModelViewProjectionMatrix": .vector(identity),
                    "g_EffectTextureProjectionMatrix": .vector(identity),
                    "g_EffectTextureProjectionMatrixInverse": .vector(inverse),
                    "g_Texture1Resolution": .vector([512, 256, 320, 160]),
                    "g_Texture2Resolution": .vector([1024, 512, 256, 128]),
                    "g_ParallaxPosition": .vector([0.75, 0.25]), "g_Screen": .vector([4, 4, 1]),
                ]
                let pixels = try replay(vertex: vertex, fragment: fragment, vertexValues: uniforms)
                for y in 0 ..< 4 {
                    for x in 0 ..< 4 {
                        let pixel = pixels[y * 4 + x]
                        #expect(abs(pixel.x - expected.x) < 0.00001 && abs(pixel.y - expected.y) < 0.00001)
                        #expect(abs(pixel.z - (Float(x) + 0.5) / 4 * 0.625) < 0.00001)
                        #expect(abs(pixel.w - (Float(y) + 0.5) / 4 * 0.625) < 0.00001)
                    }
                }
                if mask == 1 {
                    let maskFragment = "varying vec2 v_TexCoordMask; void main() { gl_FragColor = vec4(v_TexCoordMask, 0.0, 1.0); }"
                    let maskPixels = try replay(vertex: vertex, fragment: maskFragment, vertexValues: uniforms)
                    for y in 0 ..< 4 {
                        for x in 0 ..< 4 {
                            #expect(abs(maskPixels[y * 4 + x].x - (Float(x) + 0.5) / 4 * 0.25) < 0.00001)
                            #expect(abs(maskPixels[y * 4 + x].y - (Float(y) + 0.5) / 4 * 0.25) < 0.00001)
                        }
                    }
                }
            }
        }
    }

    @Test func fragmentReadsVertexOutputItNeverDeclared() throws {
        // foliagesway's fragment reads v_Bounds but only the vertex stage
        // declares it; WPE links vertex outputs into the fragment implicitly.
        let vertex = """
        attribute vec3 a_Position;
        attribute vec2 a_TexCoord;
        varying vec2 v_UV;
        varying vec2 v_Bounds;
        varying vec2 v_Unread;
        void main() {
            gl_Position = vec4(a_Position, 1.0);
            v_UV = a_TexCoord;
            v_Bounds = a_TexCoord * 0.25 + 0.375;
            v_Unread = vec2(0.0);
        }
        """
        let fragment = """
        varying vec2 v_UV;
        void main() { gl_FragColor = vec4(v_UV, v_Bounds.x, v_Bounds.y); }
        """
        let pixels = try replay(vertex: vertex, fragment: fragment)
        for y in 0 ..< 4 {
            for x in 0 ..< 4 {
                let uv = SIMD2<Float>((Float(x) + 0.5) / 4, (Float(y) + 0.5) / 4)
                let pixel = pixels[y * 4 + x]
                #expect(abs(pixel.x - uv.x) < 0.00001 && abs(pixel.y - uv.y) < 0.00001)
                #expect(abs(pixel.z - (0.375 + uv.x * 0.25)) < 0.00001)
                #expect(abs(pixel.w - (0.375 + uv.y * 0.25)) < 0.00001)
            }
        }
        let link = try WPEShaderStageLink(vertex: vertex, fragment: fragment)
        #expect(link.fragmentDeclarations.contains { $0.contains("float2 v_Bounds = in.wpe_v1_0;") })
        // Unreferenced outputs stay unbound; a same-named fragment uniform keeps its own meaning.
        #expect(!link.fragmentDeclarations.contains { $0.contains("v_Unread") })
        let shadowed = try WPEShaderStageLink(vertex: vertex, fragment: fragment.replacingOccurrences(
            of: "varying vec2 v_UV;", with: "varying vec2 v_UV;\nuniform vec2 v_Bounds;"
        ))
        #expect(!shadowed.fragmentDeclarations.contains { $0.contains("v_Bounds = in.") })
    }

    @Test func authoredFragmentNamesDoNotBecomeImplicitInputs() throws {
        let vertex = """
        attribute vec3 a_Position;
        varying vec2 v_Bounds;
        void main() { gl_Position = vec4(a_Position, 1.0); v_Bounds = vec2(0.9); }
        """
        let fragments = [
            "void main() { vec2 v_Bounds = vec2(0.25, 0.75); gl_FragColor = vec4(v_Bounds, 0.0, 1.0); }",
            "void main() { vec2 scratch, v_Bounds; v_Bounds = vec2(0.25, 0.75); gl_FragColor = vec4(v_Bounds, 0.0, 1.0); }",
            "void main() { vec2 scratch = vec2(0.0, 1.0), v_Bounds = vec2(0.25, 0.75); gl_FragColor = vec4(v_Bounds, 0.0, 1.0); }",
            """
            vec2 v_Bounds = vec2(0.25, 0.75);
            void main() { gl_FragColor = vec4(v_Bounds, 0.0, 1.0); }
            """,
            """
            vec2 readBounds(vec2 v_Bounds) { return v_Bounds; }
            void main() { gl_FragColor = vec4(readBounds(vec2(0.25, 0.75)), 0.0, 1.0); }
            """,
        ]
        for fragment in fragments {
            let link = try WPEShaderStageLink(vertex: vertex, fragment: fragment)
            #expect(!link.fragmentDeclarations.contains { $0.contains("v_Bounds = in.") })
            let pixels = try replay(vertex: vertex, fragment: fragment)
            #expect(pixels.allSatisfy { abs($0.x - 0.25) < 0.00001 && abs($0.y - 0.75) < 0.00001 })
        }
    }

    @Test func helperParameterOwnershipDoesNotHideUnboundMainRead() throws {
        let vertex = """
        attribute vec3 a_Position;
        varying vec2 v_Bounds;
        void main() { gl_Position = vec4(a_Position, 1.0); v_Bounds = vec2(0.25, 0.75); }
        """
        let fragment = """
        vec2 readBounds(vec2 v_Bounds) { return v_Bounds; }
        void main() {
            vec2 scratch = vec2(v_Bounds.x, v_Bounds.y), offset = readBounds(vec2(0.0));
            gl_FragColor = vec4(scratch + offset, 0.0, 1.0);
        }
        """
        let link = try WPEShaderStageLink(vertex: vertex, fragment: fragment)
        #expect(link.fragmentDeclarations.contains { $0.contains("v_Bounds = in.") })
        let pixels = try replay(vertex: vertex, fragment: fragment)
        #expect(pixels.allSatisfy { abs($0.x - 0.25) < 0.00001 && abs($0.y - 0.75) < 0.00001 })
    }

    @Test func implicitPositionReadRemainsRequiredForFullscreenAdmission() {
        let vertex = """
        attribute vec3 a_Position;
        uniform mat4 g_ModelViewProjectionMatrix;
        varying vec2 v_Position;
        void main() {
            gl_Position = g_ModelViewProjectionMatrix * vec4(a_Position, 1.0);
            v_Position = a_Position.xy;
        }
        """
        #expect(!WPEShaderStageLink.usesMVPOnlyForFullscreenPosition(
            vertex, fragment: "void main() { gl_FragColor = vec4(v_Position, 0.0, 1.0); }"
        ))
        #expect(WPEShaderStageLink.usesMVPOnlyForFullscreenPosition(
            vertex, fragment: "void main() { vec2 v_Position = vec2(0.5); gl_FragColor = vec4(v_Position, 0.0, 1.0); }"
        ))
    }

    @Test func singleAuthoredAngleSignaturesPreserveBuiltinOtherWidths() throws {
        let vertex = """
        attribute vec3 a_Position;
        void main() { gl_Position = vec4(a_Position, 1.0); }
        """
        let fragment = """
        float radians(float value) { return value + 0.25; }
        vec2 degrees(vec2 value) { return value + vec2(0.5); }
        void main() {
            gl_FragColor = vec4(radians(0.0), degrees(vec2(0.0)), radians(vec3(180.0)).x / degrees(3.141592653589793));
        }
        """
        let pixels = try replay(vertex: vertex, fragment: fragment)
        #expect(pixels.allSatisfy {
            abs($0.x - 0.25) < 0.00001 && abs($0.y - 0.5) < 0.00001
                && abs($0.z - 0.5) < 0.00001 && abs($0.w - .pi / 180) < 0.00001
        })
    }

    @Test func authoredAngleOverloadsPreserveBuiltinOtherWidths() throws {
        let vertex = """
        attribute vec3 a_Position;
        void main() { gl_Position = vec4(a_Position, 1.0); }
        """
        let fragment = """
        float radians(float value) { return value + 0.25; }
        vec2 radians(vec2 value) { return value + vec2(0.5); }
        float degrees(float value) { return value + 1.0; }
        vec2 degrees(vec2 value) { return value + vec2(0.75); }
        void main() {
            vec2 authoredRadians = radians(vec2(0.0));
            vec2 authoredDegrees = degrees(vec2(0.0));
            vec3 builtinRadians = radians(vec3(180.0));
            vec4 builtinDegrees = degrees(vec4(3.141592653589793));
            gl_FragColor = vec4(radians(0.0) + authoredRadians.x, degrees(0.0) + authoredDegrees.x,
                                authoredDegrees.y, builtinRadians.x / builtinDegrees.x);
        }
        """
        let pixels = try replay(vertex: vertex, fragment: fragment)
        #expect(pixels.allSatisfy {
            abs($0.x - 0.75) < 0.00001 && abs($0.y - 1.75) < 0.00001
                && abs($0.z - 0.75) < 0.00001 && abs($0.w - .pi / 180) < 0.00001
        })
    }

    private func replay(vertex: String, fragment: String,
                        vertexValues: [String: WPESceneShaderConstantValue] = [:],
                        fragmentValues: [String: WPESceneShaderConstantValue] = [:],
                        vertexSample: SIMD4<Float>? = nil, fragmentPixels: [SIMD4<Float>]? = nil, premultipliedInputSlots: Set<Int> = [],
                        execution: WPEVertexExecution = .authoredFullscreen, positionScale: SIMD2<Float> = SIMD2(1, 1), requiredPositionProof: Bool? = nil) throws -> [SIMD4<Float>] {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let compiler = WPESwiftShaderCompiler(device: device, translationCache: WPEShaderTranslationCache(rootURL: root))
        // Exercise the production loader as well as preprocessing: real WPE
        // bodies rely on its engine macro prelude and newline normalization.
        let shaderRoot = root.appendingPathComponent("shaders")
        try FileManager.default.createDirectory(at: shaderRoot, withIntermediateDirectories: true)
        try vertex.write(to: shaderRoot.appendingPathComponent("linked_stage.vert"), atomically: true, encoding: .utf8)
        try fragment.write(to: shaderRoot.appendingPathComponent("linked_stage.frag"), atomically: true, encoding: .utf8)
        let draw = WPERenderPass(id: "probe", phase: .material, shader: "linked_stage", source: .asset("unused"), target: .scene,
                                 textures: [:], binds: [:], constants: [:], combos: [:], blending: "disabled", cullMode: "nocull",
                                 depthTest: "disabled", depthWrite: "disabled")
        let graph = WPERenderGraph(layers: [.init(objectID: "probe", objectName: "probe", imagePath: "unused", materialPath: nil,
                                                  geometry: .identity, compositeA: "a", compositeB: "b", localFBOs: [], passes: [draw])])
        let prepared = try #require(WPERenderPipelineBuilder(cacheRootURL: root).build(graph: graph).layers.first?.passes.first)
        let request = try #require(try WPEMetalRenderExecutor.makeCompileRequest(for: prepared, recordFailure: false))
            .replacingPremultipliedAlphaSettings(inputSlots: premultipliedInputSlots, output: false)
            .replacingVertexExecution(execution)
        let fs = try compiler.compile(request)
        if let requiredPositionProof {
            #expect(fs.fullscreenMVPPositionOnly == requiredPositionProof, Comment(rawValue: request.processedVertexSource))
        }
        let vs = try #require(fs.vertexStage)
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = vs.library.makeFunction(name: fs.vertexFunctionName)
        descriptor.fragmentFunction = try WPEMetalColorOutput.fragment(library: fs.library, name: fs.fragmentFunctionName, format: .rgba32Float)
        descriptor.colorAttachments[0].pixelFormat = .rgba32Float
        let pipeline = try device.makeRenderPipelineState(descriptor: descriptor)
        let binder = try WPEMetalRenderExecutor(device: device)
        let sampled: MTLTexture?
        if let vertexSample {
            let sampleDescriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba32Float, width: 1, height: 1, mipmapped: false)
            sampleDescriptor.storageMode = .shared; sampleDescriptor.usage = [.shaderRead]
            let texture = try #require(device.makeTexture(descriptor: sampleDescriptor))
            var value = vertexSample
            withUnsafeBytes(of: &value) { texture.replace(region: MTLRegionMake2D(0, 0, 1, 1), mipmapLevel: 0, withBytes: $0.baseAddress!, bytesPerRow: 16) }
            sampled = texture
        } else {
            sampled = nil
        }
        let td = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba32Float, width: 4, height: 4, mipmapped: false)
        td.storageMode = .shared; td.usage = [.renderTarget]
        let target = try #require(device.makeTexture(descriptor: td))
        let command = try #require(device.makeCommandQueue()?.makeCommandBuffer())
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = target
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].clearColor = MTLClearColorMake(-99, -99, -99, -99)
        pass.colorAttachments[0].storeAction = .store
        let encoder = try #require(command.makeRenderCommandEncoder(descriptor: pass))
        encoder.setRenderPipelineState(pipeline)
        if execution == .authoredObjectQuad {
            let corners: [SIMD4<Float>] = [SIMD4(-positionScale.x, positionScale.y, 0, 0),
                                           SIMD4(positionScale.x, positionScale.y, 1, 0),
                                           SIMD4(positionScale.x, -positionScale.y, 1, 1),
                                           SIMD4(-positionScale.x, -positionScale.y, 0, 1)]
            let inputs = [0, 2, 1, 0, 3, 2].map { corners[$0] }
            inputs.withUnsafeBytes { encoder.setVertexBytes($0.baseAddress!, length: $0.count, index: 2) }
        }
        if let sampled {
            let sampler = try #require(device.makeSamplerState(descriptor: MTLSamplerDescriptor()))
            for slot in 0 ..< vs.textureSlotCount {
                encoder.setVertexTexture(sampled, index: slot); encoder.setVertexSamplerState(sampler, index: slot)
            }
        }
        if let fragmentPixels {
            #expect(fragmentPixels.count == 16)
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba32Float, width: 4, height: 4, mipmapped: false)
            descriptor.storageMode = .shared; descriptor.usage = [.shaderRead]
            let texture = try #require(device.makeTexture(descriptor: descriptor))
            fragmentPixels.withUnsafeBytes { texture.replace(region: MTLRegionMake2D(0, 0, 4, 4), mipmapLevel: 0, withBytes: $0.baseAddress!, bytesPerRow: 64) }
            let sampler = try #require(device.makeSamplerState(descriptor: MTLSamplerDescriptor()))
            for slot in 0 ..< fs.textureSlotCount {
                encoder.setFragmentTexture(texture, index: slot); encoder.setFragmentSamplerState(sampler, index: slot)
            }
        }
        for (stage, layout, values) in [(WPEShaderStage.vertex, vs.uniformLayout, vertexValues), (.fragment, fs.uniformLayout, fragmentValues)] {
            var slots = [SIMD4<Float>](repeating: .zero, count: max(1, layout.map { $0.slot + $0.slotCount }.max() ?? 0))
            try slots.withUnsafeMutableBufferPointer { storage in
                for uniform in layout {
                    try WPEUniformPacking.pack(values[uniform.name], uniform: uniform, into: storage)
                }
            }
            let binding = binder.bindTranslatedUniformSlots(slots, to: encoder, stage: stage)
            if slots.count > 256 {
                #expect(binding == .buffer(byteCount: slots.count * 16))
            }
        }
        encoder.drawPrimitives(type: execution == .authoredObjectQuad ? .triangle : .triangleStrip,
                               vertexStart: 0, vertexCount: execution == .authoredObjectQuad ? 6 : 4)
        encoder.endEncoding(); command.commit(); command.waitUntilCompleted()
        #expect(command.status == .completed && command.error == nil)
        var pixels = [SIMD4<Float>](repeating: .zero, count: 16)
        pixels.withUnsafeMutableBytes { target.getBytes($0.baseAddress!, bytesPerRow: 64, from: MTLRegionMake2D(0, 0, 4, 4), mipmapLevel: 0) }
        return pixels
    }
}
#endif
