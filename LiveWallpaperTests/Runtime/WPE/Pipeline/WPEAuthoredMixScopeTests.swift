#if !LITE_BUILD
import Foundation
@testable import LiveWallpaper
import Metal
import Testing

@Suite("WPE authored mix scope")
struct WPEAuthoredMixScopeTests {
    @Test("An earlier intrinsic mix call does not receive a later authored overload's uniform resources")
    func earlierIntrinsicWithLaterResourceUsingOverload() throws {
        let source = """
        uniform float amount;
        float earlier(float a) { return mix(0.0, 1.0, a); }
        float mix(float x, float y, float a, float extra) { return x + y + a + extra + amount; }
        void main() { gl_FragColor = vec4(earlier(amount), mix(1.0, 2.0, amount, 0.5), 0.0, 1.0); }
        """
        let result = try WPEShaderTranspiler.translateFragment(shaderName: "test/authored_mix_scope", preprocessedSource: source)
        let device = try #require(MTLCreateSystemDefaultDevice())
        _ = try device.makeLibrary(source: result.mslSource, options: WPEMetalLibraryRegistry.Configuration().makeOptions())
        #expect(result.mslSource.contains("wpe_glsl_mix(0.0, 1.0, a)"))
        #expect(result.mslSource.contains("mix(1.0, 2.0, amount, 0.5, amount)"))
    }

    @Test("Declarations, prototypes and macros retain authored ownership")
    func ownershipBoundaries() {
        let custom = "float mix(float x, float y, float a) { return x + y + a; }"
        let after = custom + "\nfloat later(float a) { return mix(0.0, 1.0, a); }"
        #expect(WPEShaderTranspiler.routingMixBeforeAuthoredDeclaration(in: after) == after)
        let prototype = "float mix(float x, float y, float a);\nfloat earlier(float a) { return mix(0.0, 1.0, a); }\n" + custom
        #expect(WPEShaderTranspiler.routingMixBeforeAuthoredDeclaration(in: prototype) == prototype)
        let macro = "#define mix mix\nfloat earlier(float a) { return mix(0.0, 1.0, a); }\n" + custom
        #expect(WPEShaderTranspiler.routingMixBeforeAuthoredDeclaration(in: macro) == macro)
    }

    @Test("Nested argument commas and comments do not alter the call boundary")
    func nestedCallsAndComments() {
        let source = """
        // 注释: float mix(float x, float y, float a) { return x; }
        #define BLEND(x,y,a) mix(x,y,a)
        float3 earlier(float a) { return mix(float3(0, 1, 2), float3(3, 4, 5), mix(0.0, 1.0, a)); }
        float qualified(float a) { return metal::mix(0.0, 1.0, a); }
        float mix(float x, float y, float a, float extra) { return x + y + a + extra; }
        """
        let actual = WPEShaderTranspiler.routingMixBeforeAuthoredDeclaration(in: source)
        #expect(actual.contains("return wpe_glsl_mix(float3(0, 1, 2), float3(3, 4, 5), wpe_glsl_mix(0.0, 1.0, a))"))
        #expect(actual.contains("#define BLEND(x,y,a) mix(x,y,a)"))
        #expect(actual.contains("return metal::mix(0.0, 1.0, a)"))
        #expect(actual.contains("// 注释: float mix(float x, float y, float a) { return x; }"))
        #expect(actual.contains("float mix(float x, float y, float a, float extra)"))
    }
}
#endif
