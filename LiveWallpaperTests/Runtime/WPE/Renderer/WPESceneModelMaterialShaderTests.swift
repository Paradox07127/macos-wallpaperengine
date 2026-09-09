#if !LITE_BUILD
@testable import LiveWallpaper
import Testing

/// A `.mdl` scene-model layer draws its MESH only if the mesh encoder recognises
/// the material's shader. An unrecognised name is not an error: the pass falls
/// through to the transpiled dispatcher, which has no mesh vertex and draws an
/// object quad — the mesh is silently replaced by a flat billboard, and a
/// camera-enclosing model then fills the whole frame with one colour.
/// 3470948192 shipped that way: `generic2` had no entry, so the star dome and the
/// doppler cylinder both collapsed into a full-screen flat fill (pass 07 output
/// was ONE distinct colour over 4145805 pixels).
@Suite("WPE scene-model material shader recognition")
struct WPESceneModelMaterialShaderTests {
    @Test("Every model material shader in the corpus reaches the mesh encoder")
    func recognisesModelMaterialShaders() {
        // Names taken from the local 125-scene corpus (`input_coverage inventory
        // --section material.pass`), which ships exactly these model materials.
        #expect(WPEMetalRenderExecutor.sceneModelMaterialShader(for: "generic2") == .generic2)
        #expect(WPEMetalRenderExecutor.sceneModelMaterialShader(for: "generic4") == .genericImage4)
        #expect(WPEMetalRenderExecutor.sceneModelMaterialShader(for: "genericimage2") == .genericImage2)
        #expect(WPEMetalRenderExecutor.sceneModelMaterialShader(for: "genericimage3") == .genericImage2)
        #expect(WPEMetalRenderExecutor.sceneModelMaterialShader(for: "genericimage4") == .genericImage4)
        // chroma4: same failure, third occurrence. 3437487219's cloud layer
        // (`materials/models/Cloud_Cover/DefaultMaterial.json` → "shader": "chroma4")
        // fell through to the transpiler, whose MSL then failed to compile at all, so
        // the pass was skipped and the target kept its cleared contents — flat green.
        #expect(WPEMetalRenderExecutor.sceneModelMaterialShader(for: "chroma4") == .chroma4)
        // Control: a workshop shader has no mesh fragment, so it must NOT claim
        // the mesh path — it still belongs to the transpiled dispatcher.
        #expect(WPEMetalRenderExecutor.sceneModelMaterialShader(for: "workshop/2652493753/tint") == nil)
    }

    /// This failure has now happened three times (generic2, then chroma4 twice over —
    /// once as a slot-limit rejection and once as a compile failure), always silently.
    /// The transpiled path CANNOT render a model shader even when it compiles: its
    /// vertex function is hard-coded to `wpe_fullscreen_vertex`, which supplies only
    /// `v_TexCoord`, while these shaders read v_WorldPos / v_WorldNormal / v_Tangent /
    /// v_Bitangent / v_ViewDir / v_ScreenPos. Anything WPE ships as a model material
    /// must therefore be claimed here, not left to fall through.
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

    /// Known gaps, asserted so the list stays honest rather than drifting: these are
    /// WPE model shaders we have NOT ported. They still fall through to the transpiler
    /// and will render wrong. No local corpus scene uses them, so they are untested
    /// rather than working — flip these to `!= nil` when a fragment is written.
    @Test("Unported model shaders are still unclaimed")
    func unportedModelShadersRemainGaps() {
        #expect(WPEMetalRenderExecutor.sceneModelMaterialShader(for: "fur4") == nil)
        #expect(WPEMetalRenderExecutor.sceneModelMaterialShader(for: "foliage4") == nil)
    }

    /// `generic2` is a MODEL shader (g_TintColor/g_TintAlpha/g_Brightness material
    /// constants); `genericimage2` is the image-layer shader (g_Color/g_Alpha).
    /// Aliasing one to the other draws the mesh but reads the wrong constants —
    /// measured on 3470948192's doppler cylinder, whose authored Alpha of 0.025
    /// rendered as an opaque wall.
    @Test("generic2 is not aliased to the image shader")
    func generic2IsNotAliasedToGenericImage2() {
        #expect(WPEBuiltinShaderName.normalized("generic2") == "generic2")
        #expect(WPEBuiltinShaderKind(normalizing: "generic2") == nil)
        // Its sibling IS aliased, which is why generic4 always had the mesh path.
        #expect(WPEBuiltinShaderName.normalized("generic4") == "genericimage4")
    }
}
#endif
