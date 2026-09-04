import Foundation
@testable import LiveWallpaper
import Testing

/// `lib.sceneScript.d.ts` declares `mix(other, amount: Number|Vec3)` as Vec3's
/// instance interpolator and has no `lerp` at all — we had it backwards, with
/// `lerp` on the instance and `mix` only as a global function. 10 of the 54
/// installed scenes call `.mix(` on a vector, so each of them threw
/// `TypeError: … is not a function` and got quarantined by the fault policy.
@Suite(.serialized)
@MainActor
struct WPESceneScriptVectorMixTests {
    private let isolatedGovernor = WPESceneScriptExecutionGovernor(limit: 4)

    private func evaluate(_ body: String) throws -> String {
        try LiveWallpaper.WPESceneScriptInstance(
            script: "export function update(value) { \(body) }",
            initialValue: "not-evaluated",
            setupBudget: 2,
            tickBudget: 0.5,
            governor: isolatedGovernor
        ).tickString()
    }

    @Test("Vec3 exposes mix as an instance method")
    func vec3InstanceMix() throws {
        let result = try evaluate("""
        var c = new Vec3(0, 0, 0).mix(new Vec3(1, 1, 1), 0.5);
        return c.x.toFixed(2) + ',' + c.y.toFixed(2) + ',' + c.z.toFixed(2);
        """)
        #expect(result == "0.50,0.50,0.50")
    }

    /// The declared amount is `Number|Vec3`, so a vector blends per component.
    @Test("A vector amount mixes each component independently")
    func vec3PerComponentMix() throws {
        let result = try evaluate("""
        var c = new Vec3(0, 0, 0).mix(new Vec3(1, 1, 1), new Vec3(0, 0.5, 1));
        return c.x.toFixed(2) + ',' + c.y.toFixed(2) + ',' + c.z.toFixed(2);
        """)
        #expect(result == "0.00,0.50,1.00")
    }

    @Test("Vec2 and Vec4 carry the same instance method")
    func vec2AndVec4InstanceMix() throws {
        let two = try evaluate("""
        var v = new Vec2(0, 0).mix(new Vec2(2, 4), 0.5);
        return v.x.toFixed(2) + ',' + v.y.toFixed(2);
        """)
        #expect(two == "1.00,2.00")

        let four = try evaluate("""
        var v = new Vec4(0, 0, 0, 0).mix(new Vec4(1, 1, 1, 1), 0.25);
        return v.w.toFixed(2);
        """)
        #expect(four == "0.25")
    }

    /// The shape scene 3326873240's colour script uses: hold two colours and
    /// cross-fade them every tick. It threw before `mix` existed.
    @Test("The authored colour cross-fade shape evaluates")
    func authoredColourCrossFadeShape() throws {
        let result = try evaluate("""
        var oldColor = new Vec3(1, 0, 0);
        var newColor = new Vec3(0, 0, 1);
        var c = oldColor.mix(newColor, 0.5);
        return c.x.toFixed(2) + ',' + c.z.toFixed(2);
        """)
        #expect(result == "0.50,0.50")
    }
}
