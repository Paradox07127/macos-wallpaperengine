@testable import LiveWallpaperProWPE
import XCTest

private struct MemorySources: WPEShaderSourceProviding {
    var files: [String: String]

    func shaderSource(named name: String) -> [UInt8]? {
        files[name].map { Array($0.utf8) }
    }
}

final class WPEShaderFrontendRuleTests: XCTestCase {
    private static let vertexShader = """
    uniform mat4 g_ModelViewProjectionMatrix;
    uniform float g_Time;
    uniform vec4 u_Custom;
    attribute vec3 a_Position;
    attribute vec2 a_TexCoord;
    varying vec2 v_TexCoord;
    varying float v_Fade[6];
    const float SCALE = 2.0;
    float mod(float a, float b) { return a; }
    void main() {
    \tgl_Position = mul(vec4(a_Position * SCALE, 1.0), g_ModelViewProjectionMatrix);
    \tv_TexCoord = a_TexCoord;
    \tv_Fade[0] = g_Time;
    }
    """

    private static let fragmentShader = """
    uniform sampler2D g_Texture0;
    uniform vec4 u_Tint;
    varying vec2 v_TexCoord;
    varying vec3 v_OnlyInFragment;
    void main() {
    \tgl_FragColor = texSample2D(g_Texture0, v_TexCoord) * u_Tint;
    }
    """

    private func text(_ bytes: [UInt8]?) -> String {
        Latin1.string(bytes ?? [])
    }

    private func blank(_ line: String) -> String {
        String(repeating: " ", count: line.count)
    }

    private func preprocess(_ source: String) throws -> String {
        try text(WPEShaderPreprocessor.run(Array(source.utf8)))
    }

    private func rewrite(
        _ files: [String: String],
        _ program: WPEHLSLProgramSources,
        defines: [WPEShaderDefine] = [],
        gs: Bool = true
    ) throws -> WPEHLSLProgram {
        try WPEHLSLRewriter(sources: MemorySources(files: files)).rewrite(
            program, defines: defines, geometryShadersEnabled: gs
        )
    }

    // MARK: - L: loading

    func testLoaderNormalisesLineEndsAndExpandsEachIncludeOnce() {
        let sources = MemorySources(files: ["shaders/util.h": "float helper;\r\n"])
        let source = "\r\nfirst;\r\n\r\n\nsecond;\n#include \"util.h\"\n#include \"util.h\"\n"
            + "#include \"missing.h\"\n#include broken\n  #include \"util.h\"\nlast\0ignored"
        var included = Set<[UInt8]>()
        let loaded = WPEShaderLoader(sources: sources).load(Array(source.utf8), included: &included)
        XCTAssertEqual(
            text(loaded),
            "\nfirst;\nsecond;\nfloat helper;\n\n\n\n\n  #include \"util.h\"\nlast\n"
        )
    }

    // MARK: - P: define block

    func testDefineBlockFollowsTheHeaderInWriteOrder() throws {
        let files = ["shaders/a.vert": "void main() {\n}\n"]
        let defines = [WPEShaderDefine(name: "ZETA", value: "0"), WPEShaderDefine(name: "ALPHA", value: "1")]
        let withGS = try text(rewrite(files, .init(vertex: "shaders/a.vert"), defines: defines).vertex)
        let block = "#define HLSL 1\n#define HLSL_SM40 1\n#define GS_ENABLED 1\n#define ZETA 0\n#define ALPHA 1\n"
        XCTAssertTrue(withGS.contains("};\n\n" + block))
        let withoutGS = try text(rewrite(files, .init(vertex: "shaders/a.vert"), defines: defines, gs: false).vertex)
        XCTAssertTrue(withoutGS.contains("#define HLSL_SM40 1\n#define ZETA 0\n"))
        XCTAssertFalse(withoutGS.contains("GS_ENABLED"))
    }

    // MARK: - C: preprocessing

    func testBlockCommentsBecomeSpacesAcrossLinesAndLineCommentsStay() throws {
        XCTAssertEqual(
            try preprocess("a /* x\nyy */ b // keep /* no\n"),
            "a     \n      b // keep /* no\n"
        )
    }

    func testConditionalAndInactiveLinesAreBlankedKeepingIndentation() throws {
        let lines: [(String, Bool)] = [
            ("#define FOO 1", false), ("  #ifdef FOO", true), ("A", false), ("#else", true), ("B", true),
            ("#endif", true), ("#if defined(FOO) && (2 + 3 * 4 == 14)", true), ("C", false), ("#elif 1", true),
            ("D", true), ("#endif", true), ("#if UNDEFINED_X || 5 / 0", true), ("E", true), ("#endif", true),
            ("#ifndef BAR", true), ("F", false), ("#endif", true), ("#undef FOO", false), ("#ifdef FOO", true),
            ("G", true), ("#endif", true), ("#pragma unknown", false),
        ]
        let source = lines.map { $0.0 + "\n" }.joined()
        let expected = lines.map { line, blanked in
            guard blanked else { return line + "\n" }
            let indent = line.prefix { $0 == " " }
            return indent + blank(String(line.dropFirst(indent.count))) + "\n"
        }.joined()
        XCTAssertEqual(try preprocess(source), expected)
    }

    func testIfExpressionsUseCPrecedenceAndExpandMacros() {
        func eval(_ expression: String, _ defines: [String: String] = [:]) -> Int {
            var macros: WPEShaderMacros = [:]
            for (name, value) in defines {
                macros[Array(name.utf8)] = Array(value.utf8)
            }
            return WPEShaderExpression.evaluate(Array(expression.utf8), defines: macros)
        }
        XCTAssertEqual(eval("1 + 2 * 3"), 7)
        XCTAssertEqual(eval("(1 + 2) * 3"), 9)
        XCTAssertEqual(eval("1 || 0 && 0"), 1)
        XCTAssertEqual(eval("-7 / 2"), -3)
        XCTAssertEqual(eval("-7 % 3"), -1)
        XCTAssertEqual(eval("4 / 0"), 0)
        XCTAssertEqual(eval("1 << 3 == 8"), 1)
        XCTAssertEqual(eval("0x1F & 7"), 7)
        XCTAssertEqual(eval("2147483647 + 1"), -2_147_483_648)
        XCTAssertEqual(eval("MISSING + 1"), 1)
        XCTAssertEqual(eval("TWICE > 5", ["TWICE": "LEVEL * 2", "LEVEL": "3"]), 1)
        XCTAssertEqual(eval("defined LEVEL + defined(OTHER)", ["LEVEL": "0"]), 1)
        XCTAssertEqual(eval("!defined(LEVEL)", ["LEVEL": "0"]), 0)
    }

    func testSelfReferencingMacroIsNotReexpandedInsideItsOwnExpansion() throws {
        XCTAssertEqual(
            try preprocess("#define X X+1\n#if X == 1\nkept\n#endif\n"),
            "#define X X+1\n\(blank("#if X == 1"))\nkept\n      \n"
        )
    }

    func testDoublingSelfReferenceExpandsOnceAndIsFalse() throws {
        let start = ContinuousClock.now
        XCTAssertEqual(
            try preprocess("#define A A A\n#if A\ndropped\n#endif\n"),
            "#define A A A\n\(blank("#if A"))\n\(blank("dropped"))\n      \n"
        )
        XCTAssertLessThan(ContinuousClock.now - start, .seconds(1))
    }

    func testMutuallyReferencingMacrosStopAtTheFirstRepeat() throws {
        let start = ContinuousClock.now
        XCTAssertEqual(
            try preprocess("#define A B\n#define B A\n#if A\ndropped\n#endif\n"),
            "#define A B\n#define B A\n\(blank("#if A"))\n\(blank("dropped"))\n      \n"
        )
        XCTAssertLessThan(ContinuousClock.now - start, .seconds(1))
    }

    func testDoublingChainOfDistinctMacrosStopsAtTheExpansionBudget() throws {
        let chain = (0 ..< 40).map { "#define M\($0) M\($0 + 1) M\($0 + 1)\n" }.joined()
        let start = ContinuousClock.now
        XCTAssertTrue(try preprocess(chain + "#if M0\nx\n#endif\n").hasSuffix("\(blank("x"))\n      \n"))
        XCTAssertLessThan(ContinuousClock.now - start, .seconds(1))
    }

    func testShaderVersionIsPredefinedAndActiveDefinesStayInText() throws {
        XCTAssertEqual(
            try preprocess("#if SHADERVERSION == 69\nkept\n#endif\n#define M_X a_Position\n"),
            "\(blank("#if SHADERVERSION == 69"))\nkept\n      \n#define M_X a_Position\n"
        )
    }

    func testRequireLightingInsertsGeneratedCodeAndBlanksDirective() throws {
        let counts = [
            "LIGHTS_POINT", "LIGHTS_SPOT", "LIGHTS_TUBE", "LIGHTS_DIRECTIONAL", "LIGHTS_SPOT_SHADOW_COOKIE",
            "LIGHTS_SPOT_SHADOW", "LIGHTS_SPOT_COOKIE", "LIGHTS_DIRECTIONAL_SHADOW", "LIGHTS_POINT_SHADOW",
        ]
        let zeroes = counts.map { "#define \($0) 0\n" }.joined()
        let output = try preprocess("#define LIGHTING 1\n" + zeroes + "#require LightingV1\n")
        XCTAssertTrue(output.hasSuffix(
            "vec3 PerformLighting_V1(vec3 worldPos, vec3 color, vec3 normal, vec3 viewVector, vec3 specularTint, "
                + "vec3 ambient, float roughness, float metallic)\n{\n\tvec3 light = CAST3(0.0);\n"
                + "\treturn light;\n}\n\(blank("#require LightingV1"))\n"
        ))
        XCTAssertEqual(try preprocess("#define LIGHTING 0\n#require LightingV1\n"), "#define LIGHTING 0\n\(blank("#require LightingV1"))\n")
        XCTAssertThrowsError(try preprocess("#define LIGHTING 1\n#require LightingV1\n")) { error in
            XCTAssertEqual(error as? WPEHLSLRewriteError, .missingDefine("LIGHTS_POINT"))
        }
    }

    func testRequiredLightUniformsLandInTheLightsBuffer() throws {
        let counts = [
            "LIGHTS_POINT": "2", "LIGHTS_SPOT": "0", "LIGHTS_TUBE": "0", "LIGHTS_DIRECTIONAL": "0",
            "LIGHTS_SPOT_SHADOW_COOKIE": "0", "LIGHTS_SPOT_SHADOW": "0", "LIGHTS_SPOT_COOKIE": "0",
            "LIGHTS_DIRECTIONAL_SHADOW": "0", "LIGHTS_POINT_SHADOW": "0",
        ]
        let defines = [WPEShaderDefine(name: "LIGHTING", value: "1")]
            + counts.keys.sorted().map { WPEShaderDefine(name: $0, value: counts[$0] ?? "0") }
        let files = ["shaders/lit.frag": "#require LightingV1\nvoid main() {\n}\n"]
        let ps = try text(rewrite(files, .init(fragment: "shaders/lit.frag"), defines: defines).fragment)
        XCTAssertTrue(ps.contains(
            "cbuffer g_bufLights:register(b3)\n{\nconst float4 g_LPoint_Color[2];\nconst float4 g_LPoint_Origin[2];\n}\n"
        ))
        XCTAssertTrue(ps.contains("{\n\tstatic const uint i = 1u;\n\tvec3 lightDelta = g_LPoint_Origin[i].xyz - worldPos;\n"))
        XCTAssertFalse(ps.contains("uniform vec4 g_LPoint_Color"))
    }

    // MARK: - W: vertex stage

    func testVertexStageBuildsInputOutputAndConstantBuffers() throws {
        let files = ["shaders/v.vert": Self.vertexShader]
        let vs = try text(rewrite(files, .init(vertex: "shaders/v.vert")).vertex)
        XCTAssertTrue(vs.hasPrefix(Latin1.string(WPEHLSLTables.prelude) + Latin1.string(WPEHLSLTables.backBufferLine)))
        XCTAssertTrue(vs.contains(
            "struct VS_INPUT\n{\nfloat3 a_Position : POSITION0;\nfloat2 a_TexCoord : TEXCOORD0;\n};\n\n"
                + "struct VS_OUTPUT\n{\nfloat2 v_TexCoord : TEXCOORD0;\nfloat4 v_Fade[2] : TEXCOORD1;\n"
                + "float4 gl_Position : SV_POSITION;\n};\n\n"
                + "cbuffer g_bufStatic:register(b0)\n{\nconst float4 u_Custom;\n}\n"
                + "cbuffer g_bufDynamic:register(b1)\n{\nconst float4x4 g_ModelViewProjectionMatrix;\nconst float g_Time;\n}\n"
                + "#define HLSL 1\n"
        ))
        XCTAssertFalse(vs.contains("attribute"))
        XCTAssertFalse(vs.contains("varying"))
        XCTAssertFalse(vs.contains("uniform"))
    }

    func testVertexMainIsWrappedAndIdentifiersArePrefixed() throws {
        let files = ["shaders/v.vert": Self.vertexShader]
        let vs = try text(rewrite(files, .init(vertex: "shaders/v.vert")).vertex)
        XCTAssertTrue(vs.contains("static const float SCALE = 2.0;\n"))
        XCTAssertTrue(vs.contains("float _deprFn_0(float a, float b)"))
        XCTAssertTrue(vs.hasSuffix(
            "VS_OUTPUT main(VS_INPUT IN)\n{\n\tVS_OUTPUT OUT;\nfloat accessArrayv_Fade[8] = (float[8])0;\n\n"
                + "\tOUT.gl_Position = mul(vec4(IN.a_Position * SCALE, 1.0), g_ModelViewProjectionMatrix);\n"
                + "\tOUT.v_TexCoord = IN.a_TexCoord;\n\taccessArrayv_Fade[0] = g_Time;\n"
                + "OUT.v_Fade = accessArrayv_Fade;\n\treturn OUT;\n}\n"
        ))
    }

    func testSystemValueInputsBecomeMainParameters() throws {
        let files = ["shaders/s.vert": "in uint gl_VertexID;\nvoid main() {\n}\n"]
        let vs = try text(rewrite(files, .init(vertex: "shaders/s.vert")).vertex)
        XCTAssertTrue(vs.contains("VS_OUTPUT main(VS_INPUT IN,uint gl_VertexID:SV_VERTEXID)\n{\n"))
    }

    // MARK: - W: fragment stage and stage linking

    func testFragmentUsesVertexVaryingsTexturesAndFragColor() throws {
        let files = ["shaders/v.vert": Self.vertexShader, "shaders/f.frag": Self.fragmentShader]
        let ps = try text(rewrite(files, .init(vertex: "shaders/v.vert", fragment: "shaders/f.frag")).fragment)
        XCTAssertTrue(ps.contains(
            Latin1.string(WPEHLSLTables.backBufferLine)
                + "struct PS_OUTPUT\n{\nfloat4 gl_FragColor : SV_TARGET;\n};\n"
                + "struct VS_OUTPUT\n{\nfloat2 v_TexCoord : TEXCOORD0;\nfloat4 v_Fade[2] : TEXCOORD1;\n"
                + "float4 gl_Position : SV_POSITION;\n};\n\n"
                + "Texture2D g_Texture0:register(t0);\nSamplerState g_Texture0SamplerState:register(s0);\n"
                + "cbuffer g_bufStatic:register(b0)\n{\nconst float4 u_Tint;\n}\n#define HLSL 1\n"
        ))
        XCTAssertFalse(ps.contains("v_OnlyInFragment"))
        XCTAssertTrue(ps.hasSuffix(
            "PS_OUTPUT main(VS_OUTPUT IN)\n{\n\tPS_OUTPUT OUT;\nfloat accessArrayv_Fade[8] = (float[8])IN.v_Fade;\n\n"
                + "\tOUT.gl_FragColor = texSample2D(g_Texture0, IN.v_TexCoord) * u_Tint;\n\treturn OUT;\n}\n"
        ))
    }

    func testBackBufferMultisampleComboChangesTheSampleMacro() throws {
        let files = ["shaders/f.frag": "void main() {\n}\n"]
        let defines = [WPEShaderDefine(name: "BACKBUFFER_MS", value: "0")]
        let ps = try text(rewrite(files, .init(fragment: "shaders/f.frag"), defines: defines).fragment)
        XCTAssertTrue(ps.contains(Latin1.string(WPEHLSLTables.backBufferMSLine) + "struct PS_OUTPUT {};\n"))
    }

    func testGeometryStageSwapsTheVaryingTableForTheFragment() throws {
        let files = [
            "shaders/g.vert": "varying vec4 v_Color;\nvoid main() {\n\tv_Color = vec4(1.0);\n}\n",
            "shaders/g.geom": "in vec4 v_Color[];\nout vec2 v_Quad;\nout vec4 v_Tint;\n[input:triangles]\n"
                + "void main() {\n\tv_Tint = IN[0].v_Color;\n}\n",
            "shaders/g.frag": "varying vec4 v_Color;\nvoid main() {\n\tgl_FragColor = v_Tint;\n}\n",
        ]
        let program = try rewrite(
            files, .init(vertex: "shaders/g.vert", geometry: "shaders/g.geom", fragment: "shaders/g.frag")
        )
        let gs = text(program.geometry)
        XCTAssertTrue(gs.contains(
            "struct VS_OUTPUT\n{\nfloat4 v_Color : TEXCOORD0;\nfloat4 gl_Position : SV_POSITION;\n};\n\n"
                + "struct PS_INPUT\n{\nfloat2 v_Quad : TEXCOORD0;\nfloat4 v_Tint : TEXCOORD1;\n};\n\n"
        ))
        XCTAssertTrue(gs.hasSuffix(
            "void main(triangle VS_OUTPUT IN[3], inout TriangleStream<PS_INPUT> OUT)\n{\n\t\n\tv_Tint = IN[0].v_Color;\n}\n"
        ))
        XCTAssertFalse(gs.contains("[input:triangles]"))
        let ps = text(program.fragment)
        XCTAssertTrue(ps.contains("struct VS_OUTPUT\n{\nfloat2 v_Quad : TEXCOORD0;\nfloat4 v_Tint : TEXCOORD1;\n};\n\n"))
        XCTAssertTrue(ps.hasSuffix("\tOUT.gl_FragColor = IN.v_Tint;\n\treturn OUT;\n}\n"))
    }

    func testMissingStageSourceThrows() {
        XCTAssertThrowsError(try rewrite([:], .init(vertex: "shaders/none.vert"))) { error in
            XCTAssertEqual(error as? WPEHLSLRewriteError, .missingShader("shaders/none.vert"))
        }
    }

    func testOversizedArrayLengthThrows() {
        let cases: [(decl: String, name: String, size: Int)] = [
            ("uniform float g_x[9223372036854775807];", "g_x", Int.max),
            ("varying vec2 v_x[5000000000000000000];", "v_x", 5_000_000_000_000_000_000),
        ]
        for (decl, name, size) in cases {
            let files = ["shaders/a.vert": decl + "\nvoid main() {\n}\n"]
            XCTAssertThrowsError(try rewrite(files, .init(vertex: "shaders/a.vert"))) { error in
                XCTAssertEqual(error as? WPEHLSLRewriteError, .arraySizeOutOfRange(name: name, size: size))
            }
        }
    }

    func testArrayLengthAtUpperBoundRewrites() throws {
        let files = ["shaders/a.vert": "uniform float g_x[65535];\nvarying vec2 v_x[65535];\nvoid main() {\n}\n"]
        let vs = try text(rewrite(files, .init(vertex: "shaders/a.vert")).vertex)
        XCTAssertTrue(vs.contains("float4 v_x[32768] : TEXCOORD0;\n"))
        XCTAssertTrue(vs.contains("const float4 g_x[16384];\n"))
        XCTAssertTrue(vs.contains("float2 accessArrayv_x[65536] = (float2[65536])0;\n"))
    }

    // MARK: - R: VS recompile

    func testPruningRemovesUnreadInputsExceptBlendIndices() {
        let hlsl = Array(
            ("x\nstruct VS_INPUT\n{\nfloat3 a_Position : POSITION0;\nfloat4 a_Color : COLOR0;\n"
                + "float4 a_Extra : COLOR01;\nuint4 a_BlendIndices : BLENDINDICES0;\n};\nrest COLOR0\n").utf8
        )
        let pruned = WPEHLSLRewriter.pruningVertexInputs(hlsl, unusedSemantics: ["COLOR0", "BLENDINDICES0"])
        XCTAssertEqual(
            text(pruned),
            "x\nstruct VS_INPUT\n{\nfloat3 a_Position : POSITION0;\nfloat4 a_Extra : COLOR01;\n"
                + "uint4 a_BlendIndices : BLENDINDICES0;\n};\nrest COLOR0\n"
        )
        XCTAssertNil(WPEHLSLRewriter.pruningVertexInputs(hlsl, unusedSemantics: ["BLENDINDICES0"]))
        XCTAssertNil(WPEHLSLRewriter.pruningVertexInputs(hlsl, unusedSemantics: []))
    }
}
