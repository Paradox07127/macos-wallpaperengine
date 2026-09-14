#if !LITE_BUILD
@testable import LiveWallpaper
import Testing

/// An unrecognised model-material shader is not an error: the pass falls through to
/// the transpiled dispatcher, which draws an object quad instead of the mesh.
@Suite("WPE scene-model material shader recognition")
struct WPESceneModelMaterialShaderTests {
    @Test("Every model material shader in the corpus reaches the mesh encoder")
    func recognisesModelMaterialShaders() {
        #expect(WPEMetalRenderExecutor.sceneModelMaterialShader(for: "generic2") == .generic2)
        #expect(WPEMetalRenderExecutor.sceneModelMaterialShader(for: "generic4") == .genericImage4)
        #expect(WPEMetalRenderExecutor.sceneModelMaterialShader(for: "genericimage2") == .genericImage2)
        #expect(WPEMetalRenderExecutor.sceneModelMaterialShader(for: "genericimage3") == .genericImage2)
        #expect(WPEMetalRenderExecutor.sceneModelMaterialShader(for: "genericimage4") == .genericImage4)
        #expect(WPEMetalRenderExecutor.sceneModelMaterialShader(for: "chroma4") == .chroma4)
        // Control: a workshop shader has no mesh fragment, so it must NOT claim
        // the mesh path — it still belongs to the transpiled dispatcher.
        #expect(WPEMetalRenderExecutor.sceneModelMaterialShader(for: "workshop/2652493753/tint") == nil)
    }

    /// The transpiled path cannot render a model shader even when it compiles: its vertex
    /// is hard-coded to `wpe_fullscreen_vertex` and supplies only `v_TexCoord`.
    @Test("Every model material shader WPE bundles is claimed by the mesh encoder")
    func bundledModelShadersAreClaimed() {
        // Model materials in WPE's own assets/shaders that a `.mdl` can reference.
        // fur4/foliage4 are listed as KNOWN GAPS below, not asserted here.
        for name in ["generic2", "generic4", "genericimage2", "genericimage3", "genericimage4", "chroma4"] {
            #expect(
                WPEMetalRenderExecutor.sceneModelMaterialShader(for: name) != nil,
                "\(name) must reach the mesh encoder; falling through renders it wrong or not at all"
            )
        }
    }

    /// Known gaps, not correctness: these WPE model shaders are unported — flip to
    /// `!= nil` when a fragment is written.
    @Test("Unported model shaders are still unclaimed")
    func unportedModelShadersRemainGaps() {
        #expect(WPEMetalRenderExecutor.sceneModelMaterialShader(for: "fur4") == nil)
        #expect(WPEMetalRenderExecutor.sceneModelMaterialShader(for: "foliage4") == nil)
    }

    /// `generic2` is a MODEL shader (g_TintColor/g_TintAlpha/g_Brightness); `genericimage2`
    /// is the image-layer shader (g_Color/g_Alpha) — aliasing reads the wrong constants.
    @Test("generic2 is not aliased to the image shader")
    func generic2IsNotAliasedToGenericImage2() {
        #expect(WPEBuiltinShaderName.normalized("generic2") == "generic2")
        #expect(WPEBuiltinShaderKind(normalizing: "generic2") == nil)
        // Its sibling IS aliased, which is why generic4 always had the mesh path.
        #expect(WPEBuiltinShaderName.normalized("generic4") == "genericimage4")
    }
}
#endif
