import Foundation
@testable import LiveWallpaper
import Testing

@Suite(.serialized, .timeLimit(.minutes(1)))
@MainActor
struct WPESceneScriptTransformGetterCopyTests {
    private let isolatedGovernor = WPESceneScriptExecutionGovernor(limit: 4)

    private func sharedState() -> WPESharedScriptState {
        WPESharedScriptState(layers: [
            .init(id: "568", name: "可调整组合层", size: SIMD2(4500, 3840), origin: SIMD2(1920, 1020), index: 0, parentName: nil),
            .init(id: "600", name: "Partner", size: SIMD2(8, 8), origin: SIMD2(10, 20), index: 1, parentName: nil),
            .init(id: "601", name: "Child", size: SIMD2(8, 8), origin: SIMD2(30, 40), index: 2, parentName: "Partner"),
        ])
    }

    @Test("An origin cached in init stays the base offset while update reassigns the layer origin")
    func cachedBaseOriginDoesNotAccumulateOffsets() throws {
        let instance = try WPELayerScriptInstance(script: """
        let baseOG;
        export function init() { baseOG = thisLayer.origin; }
        export function update() {
            let c = Math.cos(engine.runtime) * 0.5 + 0.5;
            thisLayer.origin = baseOG.add(new Vec3(0, -30, 0).multiply(c));
        }
        """, shared: sharedState(), ownLayerName: "可调整组合层", ownObjectID: "568", governor: isolatedGovernor)
        for frame in 0 ... 600 {
            let seconds = Double(frame) / 60
            let output = try #require(instance.tick(runtimeSeconds: seconds))
            let y = try #require(output.ownTransform.origin?.y)
            #expect(abs(y - (1020 - 30 * (0.5 + 0.5 * cos(seconds)))) <= 1e-9, "frame \(frame): y = \(y)")
            if frame == 536 {
                #expect(abs(y - 1018.22) < 0.01, "frame 536: y = \(y)")
            }
        }
    }

    @Test("Cached own, getLayer and getParent vectors keep their seed after the property is reassigned")
    func cachedHandleVectorsSurviveAssignment() throws {
        let shared = sharedState()
        _ = try WPELayerScriptInstance(script: """
        export function init() {
            let own = thisLayer.origin;
            thisLayer.origin = new Vec3(4, 5, 6);
            let partner = thisScene.getLayer('Partner');
            let other = partner.origin;
            partner.origin = new Vec3(4, 5, 6);
            let parent = thisScene.getLayer('Child').getParent();
            let parentScale = parent.scale;
            parent.scale = new Vec3(4, 5, 6);
            shared.result = [own.x, other.x, parentScale.x, thisLayer.origin.x, partner.origin.x].join(':');
        }
        """, shared: shared, ownLayerName: "可调整组合层", ownObjectID: "568", governor: isolatedGovernor)
        #expect(shared.get("result") as? String == "1920:10:1:4:4")
    }
}
