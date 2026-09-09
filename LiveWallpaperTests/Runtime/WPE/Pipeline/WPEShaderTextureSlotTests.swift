import Foundation
@testable import LiveWallpaper
import Metal
import Testing

/// The transpiler's texture-slot ceiling. WPE's own bundled shaders reach `g_Texture8`
/// (`chroma4`, `fur4`, `genericimage4` — surveyed against the installed
/// `wallpaper_engine/assets/shaders` on 2026-09-09), so a ceiling that stops at slot 7
/// makes stock effects fail translation and their pass is skipped entirely, leaving the
/// target with its cleared contents.
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

    /// The ceiling has to cover slot 8, i.e. at least 9 slots. 16 is a hard Metal limit
    /// (measured: a 17th sampler argument fails to compile), and the generator emits one
    /// sampler per slot — so this is a floor and a wall, not a free dial.
    @Test("The slot ceiling covers every slot WPE's bundled shaders use")
    func ceilingCoversBundledShaders() {
        #expect(WPEShaderTranspiler.customTextureSlotLimit >= 9)
        #expect(WPEShaderTranspiler.customTextureSlotLimit <= 16)
    }

    /// Slots are allocated per shader, not fixed: a shader sampling one texture must not
    /// pay for the ceiling. This is what makes the common case cheaper than before —
    /// most shaders in a local 58-scene corpus top out at slot 2.
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

    /// The generator and the binding loop must be sized by the SAME value. Binding fewer
    /// slots than the signature declares is undefined behaviour; binding more is merely
    /// wasteful — so a regression to a fixed span stays green on every behavioural test
    /// (verified: reverting the loop to `customTextureSlotLimit` failed nothing). A source
    /// assertion is the only thing that catches it, the same approach `SettingsOwnershipTests`
    /// uses to pin a structural decision.
    @Test("The dispatcher binds per-shader slots, not a fixed span")
    func dispatcherBindsPerShaderSlotCount() throws {
        let source = try RepositoryRoot.source("LiveWallpaper/Runtime/Metal/WPEMetalShaderDispatcher.swift")
        #expect(source.contains("for slot in 0..<result.textureSlotCount"))
        #expect(!source.contains("for slot in 0..<WPEShaderTranspiler.customTextureSlotLimit"))
    }

    /// A shader with no samplers at all must still emit a well-formed signature — the
    /// per-slot loops produce nothing, so a trailing comma on the previous parameter
    /// would be a compile error.
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

    /// Sparse slots must alias to their real index, not to enumeration order: the
    /// dispatcher binds by slot number, so `g_Texture8` reading `tex7` would sample a
    /// different texture entirely.
    @Test("Sparse high slots alias to their real texture index")
    func sparseSlotsKeepTheirIndex() throws {
        let result = try WPEShaderTranspiler.translateFragment(
            shaderName: "chroma4",
            preprocessedSource: Self.chroma4LikeSource
        )
        #expect(result.mslSource.contains("texture(8)"))
        #expect(!result.mslSource.contains("texture(5)_g_Texture8"))
    }
}
