import Foundation
@testable import LiveWallpaper
import Testing

@Suite(.serialized, .timeLimit(.minutes(1)))
@MainActor
struct WPESceneScriptCanvasVectorTests {
    private let isolatedGovernor = WPESceneScriptExecutionGovernor(limit: 4)

    private func textInstance(_ body: String) throws -> LiveWallpaper.WPESceneScriptInstance {
        try LiveWallpaper.WPESceneScriptInstance(
            script: "export function update(value) { \(body) }",
            initialValue: "not-evaluated",
            setupBudget: 2,
            tickBudget: 0.5,
            governor: isolatedGovernor,
            canvasSize: SIMD2(100, 50),
            screenSize: SIMD2(200, 100)
        )
    }

    private func evaluate(_ body: String) throws -> String {
        try textInstance(body).tickString()
    }

    private static let vec3Text = "function t(v) { return v.x + ',' + v.y + ',' + v.z; }"

    @Test("engine.canvasSize and engine.screenResolution are Vec2 instances with Vec2 methods")
    func textEngineSizesAreVec2() throws {
        let instance = try textInstance("""
        return [engine.canvasSize instanceof Vec2, engine.canvasSize.divide(2).x,
                engine.screenResolution instanceof Vec2, engine.screenResolution.divide(2).y].join(',');
        """)
        #expect(instance.tickString() == "true,50,true,50")
        // No resizeScreen export, so this returns false; the engine vector is still updated in place.
        instance.resizeScreen(SIMD2(300, 160))
        #expect(instance.tickString() == "true,50,true,80", "a resized screenResolution must stay a live Vec2")
    }

    @Test("Transform scripts see Vec2 canvasSize and screenResolution")
    func transformEngineSizesAreVec2() throws {
        let instance = try LiveWallpaper.WPEDynamicTransformScriptInstance(
            script: """
            export function update(value) {
                return new Vec3(engine.canvasSize instanceof Vec2 ? 1 : 0,
                                engine.canvasSize.divide(2).x, engine.screenResolution.divide(2).y);
            }
            """,
            seed: SIMD3(9, 9, 9),
            canvasSize: SIMD2(100, 50),
            screenSize: SIMD2(200, 100),
            governor: isolatedGovernor
        )
        let value = try #require(instance.tick(pointerPosition: .zero, runtimeSeconds: 0))
        #expect(value == SIMD3(1, 50, 50))
    }

    @Test("Static transform evaluation sees Vec2 canvasSize and screenResolution")
    func staticEvaluatorSizesAreVec2() throws {
        let evaluator = LiveWallpaper.WPETransformScriptEvaluator(
            canvasWidth: 100, canvasHeight: 50, governor: isolatedGovernor
        )
        let value = try #require(evaluator.resolveVec3(
            script: """
            export function update(value) {
                value.x = engine.canvasSize.divide(2).x;
                value.y = engine.screenResolution.divide(2).y;
                value.z = engine.screenResolution instanceof Vec2 ? 1 : 0;
                return value;
            }
            """,
            properties: [:],
            seed: SIMD3(9, 9, 9)
        ))
        #expect(value == SIMD3(50, 25, 1))
    }

    @Test("Vec3 construction follows WPE for vector, scalar and string arguments", arguments: [
        ("new Vec3(new Vec2(3, 4), 1)", "3,4,0"),
        ("new Vec3(new Vec3(1, 2, 3))", "1,2,3"),
        ("new Vec3(new Vec3(1, 2, 3), 7, 8)", "1,2,3"),
        ("new Vec3(5)", "5,5,5"),
        ("new Vec3(1, 2)", "1,2,0"),
        ("new Vec3('1 2 3')", "1,2,3"),
    ])
    func vec3Construction(expression: String, expected: String) throws {
        #expect(try evaluate("\(Self.vec3Text) return t(\(expression));") == expected)
    }

    @Test("Vec2 construction from a vector ignores later arguments like WPE")
    func vec2ConstructionFromVector() throws {
        let result = try evaluate("""
        var a = new Vec2(new Vec3(3, 4, 5), 9), b = new Vec2(new Vec2(6, 7), 9);
        return [a.x, a.y, b.x, b.y].join(',');
        """)
        #expect(result == "3,4,6,7")
    }

    @Test("Canvas-relative Vec3 division from scene 3808922316 yields finite x and y")
    func canvasRelativeDivision() throws {
        let result = try evaluate("""
        let d = new Vec3(10, 20, 0).divide(new Vec3(engine.canvasSize.divide(0.1), 1));
        return [Number.isFinite(d.x), Number.isFinite(d.y), d.x.toFixed(4), d.y.toFixed(4)].join(',');
        """)
        #expect(result == "true,true,0.0100,0.0400")
    }
}
