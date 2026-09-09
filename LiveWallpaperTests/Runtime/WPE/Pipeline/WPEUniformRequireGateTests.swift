@testable import LiveWallpaper
import Testing

/// `require` is parsed for DIAGNOSTICS ONLY. It must never gate uniform resolution.
///
/// Measured, not assumed — Windows capture of 3437487219 ordinal 2
/// (`.notes/oracle-runs/3437487219-…/windows.json`): `effects/lightshafts` runs with
/// `DIRECTDRAW: 1` while `g_Point0..3` are annotated `require {"DIRECTDRAW": 0}`, and WPE
/// binds them anyway — `g_Point0 = [6.83764, -3.17560]` with `usedByShader: true`, and the
/// same values appear again as the draw's vertex TEXCOORDs. So `require` decides only
/// whether the EDITOR exposes the field; the authored constant stays live regardless.
///
/// A gate was briefly wired here on the assumption those constants were stale leftovers.
/// It withheld values WPE was actively using and made the frame worse. The parse stays
/// (the diagnostic it feeds is what located the real geometry divergence); the gating does
/// not come back without a capture showing WPE dropping such a value.
@Suite("WPE uniform require gate")
struct WPEUniformRequireGateTests {
    /// Verbatim from assets/effects/lightshafts/shaders/effects/lightshafts.vert.
    private static let pointDeclaration = """
    uniform vec2 g_Point0; // {"material":"point0","label":"p0","default":"0.67728 0.01297","require":{"DIRECTDRAW":0}}
    """

    /// Verbatim from the same shader — no `require`, so it stays authorable either way.
    private static let radiusDeclaration = """
    uniform float g_Radius; // {"material":"rayradius","label":"ui_editor_properties_radius","default":0.2,"range":[0.0, 1.0]}
    """

    @Test("A require map is parsed off the annotation")
    func requireIsParsed() throws {
        let point = try #require(WPEUniformDecl.parse(line: Self.pointDeclaration))
        #expect(point.materialName == "point0")
        #expect(point.requiredCombos == ["DIRECTDRAW": 0])

        let radius = try #require(WPEUniformDecl.parse(line: Self.radiusDeclaration))
        #expect(radius.materialName == "rayradius")
        #expect(radius.requiredCombos.isEmpty, "no require annotation must mean unconditional")
    }

    @Test("Authorability follows the pass's combo values")
    func authorabilityFollowsCombos() throws {
        let point = try #require(WPEUniformDecl.parse(line: Self.pointDeclaration))
        let slot = WPEUniformSlot(
            name: point.name,
            glslType: point.type,
            slot: 0,
            slotCount: 1,
            materialName: point.materialName,
            defaultValue: point.defaultValue,
            requiredCombos: point.requiredCombos
        )
        // The scene's actual combo: the material constant must be withheld.
        #expect(!slot.isAuthorable(under: ["DIRECTDRAW": 1]))
        // The combo the annotation asks for: the constant applies.
        #expect(slot.isAuthorable(under: ["DIRECTDRAW": 0]))
        // A combo the pass never declares reads as 0, matching how combos default.
        #expect(slot.isAuthorable(under: [:]))
        // An unrelated combo must not disturb the decision.
        #expect(slot.isAuthorable(under: ["RAYMODE": 1]))
    }

    /// Every listed combo has to match, not just one.
    @Test("A multi-combo require needs all of them")
    func multiComboRequire() {
        let slot = WPEUniformSlot(
            name: "g_Thing",
            glslType: "float",
            slot: 0,
            slotCount: 1,
            materialName: "thing",
            requiredCombos: ["A": 1, "B": 2]
        )
        #expect(slot.isAuthorable(under: ["A": 1, "B": 2]))
        #expect(!slot.isAuthorable(under: ["A": 1, "B": 3]))
        #expect(!slot.isAuthorable(under: ["A": 0, "B": 2]))
    }

    /// An unconditional uniform must be unaffected — the gate has to be inert for the
    /// overwhelming majority of uniforms, which carry no `require` at all.
    @Test("Uniforms without a require stay authorable under any combos")
    func noRequireIsAlwaysAuthorable() throws {
        let radius = try #require(WPEUniformDecl.parse(line: Self.radiusDeclaration))
        let slot = WPEUniformSlot(
            name: radius.name,
            glslType: radius.type,
            slot: 0,
            slotCount: 1,
            materialName: radius.materialName,
            requiredCombos: radius.requiredCombos
        )
        #expect(slot.isAuthorable(under: ["DIRECTDRAW": 1]))
        #expect(slot.isAuthorable(under: [:]))
    }
}
