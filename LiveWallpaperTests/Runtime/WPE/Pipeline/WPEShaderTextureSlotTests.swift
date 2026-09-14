import Foundation
@testable import LiveWallpaper
import Metal
import Testing

/// The transpiler's texture-slot ceiling. A ceiling that stops at slot 7 makes stock
/// shaders (chroma4, fur4, genericimage4) fail translation, leaving the target cleared.
@MainActor
@Suite("WPE shader texture slots")
struct WPEShaderTextureSlotTests {
    private func makeLibrary(_ msl: String) throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let opts = MTLCompileOptions()
        opts.languageVersion = .version3_0
        _ = try device.makeLibrary(source: msl, options: opts)
    }

    /// The sparse, highest-slot layout `chroma4` actually declares: 0-4 plus 6, 7, 8 —
    /// slot 5 is deliberately absent, so slot count and max index are not the same number.
    private static let chroma4LikeSource = """
    #version 410 core
    uniform sampler2D g_Texture0;
    uniform sampler2D g_Texture1;
    uniform sampler2D g_Texture2;
    uniform sampler2D g_Texture3;
    uniform sampler2D g_Texture4;
    uniform sampler2D g_Texture6;
    uniform sampler2D g_Texture7;
    uniform sampler2D g_Texture8;
    in vec2 v_TexCoord;
    void main() {
        vec4 c = texture(g_Texture0, v_TexCoord);
        c += texture(g_Texture1, v_TexCoord);
        c += texture(g_Texture2, v_TexCoord);
        c += texture(g_Texture3, v_TexCoord);
        c += texture(g_Texture4, v_TexCoord);
        c += texture(g_Texture6, v_TexCoord);
        c += texture(g_Texture7, v_TexCoord);
        c += texture(g_Texture8, v_TexCoord);
        gl_FragColor = c;
    }
    """

    @Test("A stock shader binding g_Texture8 translates and compiles")
    func slotEightTranslates() throws {
        let result = try WPEShaderTranspiler.translateFragment(
            shaderName: "chroma4",
            preprocessedSource: Self.chroma4LikeSource
        )
        try makeLibrary(result.mslSource)
    }

    /// The ceiling must cover slot 8 (≥9 slots); 16 is a hard Metal limit, and the
    /// generator emits one sampler per slot — a floor and a wall, not a free dial.
    @Test("The slot ceiling covers every slot WPE's bundled shaders use")
    func ceilingCoversBundledShaders() {
        #expect(WPEShaderTranspiler.customTextureSlotLimit >= 9)
        #expect(WPEShaderTranspiler.customTextureSlotLimit <= 16)
    }

    @Test("A shader declares only the slots it uses")
    func slotsAreAllocatedPerShader() throws {
        let single = """
        #version 410 core
        uniform sampler2D g_Texture0;
        in vec2 v_TexCoord;
        void main() { gl_FragColor = texture(g_Texture0, v_TexCoord); }
        """
        let lean = try WPEShaderTranspiler.translateFragment(
            shaderName: "single", preprocessedSource: single
        )
        #expect(lean.textureSlotCount == 1)
        #expect(lean.mslSource.contains("texture(0)"))
        #expect(!lean.mslSource.contains("texture(1)"))
        try makeLibrary(lean.mslSource)

        // The sparse chroma4 layout still reserves through its highest index.
        let wide = try WPEShaderTranspiler.translateFragment(
            shaderName: "chroma4", preprocessedSource: Self.chroma4LikeSource
        )
        #expect(wide.textureSlotCount == 9)
    }

    /// The generator and the binding loop must be sized by the SAME value: a regression
    /// to a fixed span stays green on every behavioural test, so only a source assertion catches it.
    @Test("The dispatcher binds per-shader slots, not a fixed span")
    func dispatcherBindsPerShaderSlotCount() throws {
        let source = try RepositoryRoot.source("LiveWallpaper/Runtime/Metal/WPEMetalShaderDispatcher.swift")
        #expect(source.contains("for slot in 0..<result.textureSlotCount"))
        #expect(!source.contains("for slot in 0..<WPEShaderTranspiler.customTextureSlotLimit"))
    }

    /// With no samplers the per-slot loops produce nothing, so a trailing comma on the
    /// previous parameter would be a compile error.
    @Test("A shader with no samplers still generates valid MSL")
    func zeroSamplersStillCompiles() throws {
        let source = """
        #version 410 core
        uniform vec4 g_Color;
        in vec2 v_TexCoord;
        void main() { gl_FragColor = g_Color; }
        """
        let result = try WPEShaderTranspiler.translateFragment(
            shaderName: "solid", preprocessedSource: source
        )
        #expect(result.textureSlotCount == 0)
        try makeLibrary(result.mslSource)
    }

    /// The dispatcher binds by slot number, so `g_Texture8` reading `tex7` would sample
    /// a different texture entirely.
    @Test("Sparse high slots alias to their real texture index")
    func sparseSlotsKeepTheirIndex() throws {
        let result = try WPEShaderTranspiler.translateFragment(
            shaderName: "chroma4",
            preprocessedSource: Self.chroma4LikeSource
        )
        #expect(result.mslSource.contains("texture(8)"))
        // Slot 5 is absent from the source, so enumeration order would shift
        // every sampler above the hole down by one (g_Texture6→tex5, 8→tex7).
        #expect(result.mslSource.contains("[[maybe_unused]] auto g_Texture6 = tex6;"))
        #expect(result.mslSource.contains("[[maybe_unused]] auto g_Texture7 = tex7;"))
        #expect(result.mslSource.contains("[[maybe_unused]] auto g_Texture8 = tex8;"))
    }
}
