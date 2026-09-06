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
        // Control: a workshop shader has no mesh fragment, so it must NOT claim
        // the mesh path — it still belongs to the transpiled dispatcher.
        #expect(WPEMetalRenderExecutor.sceneModelMaterialShader(for: "workshop/2652493753/tint") == nil)
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
