import Foundation
@testable import LiveWallpaperProWPE
import XCTest

/// Which loaded objects join WPE's transparent member vector, and when `general.transparentsorting` turns it on.
final class ParityProgramTransparentMembershipTests: XCTestCase {
    private typealias D = ParitySceneDocuments

    func testMembershipFollowsBaseBlendPassthroughAndKind() throws {
        let program = try Self.scene(general: ["transparentsorting": true])
        XCTAssertTrue(program.scene.transparentSorting)
        let members = Dictionary(uniqueKeysWithValues: program.scene.objects.map { ($0.id, $0.transparentMember) })
        XCTAssertEqual(members, [
            "1": true, // translucent
            "2": true, // additive
            "3": false, // normal
            "4": false, // alphatocoverage
            "5": true, // normal, passthrough, no copybackground
            "6": false, // normal, passthrough, copybackground
            "7": false, // normal under colorBlendMode 31
            "8": false, // model
            "9": true, // particle system
        ])
        // The mode-31 row really draws additive; membership reads its base material instead.
        XCTAssertEqual(program.scene.objects.first { $0.id == "7" }?.blend, .additive)
        guard case .model? = program.scene.objects.first(where: { $0.id == "8" })?.kind else {
            return XCTFail("8 is not a model")
        }
    }

    func testTextLayersAreMembers() throws {
        _ = try ParityTextPlannerTests.makePlanner()
        let font = try Data(contentsOf: ParityFontChainTests.assetsRoot.appendingPathComponent(ParityFontChainTests.notoSans))
        let program = try D.programScene([], general: ["transparentsorting": true], objects: [
            ["id": 11, "name": "label", "text": "Hi", "font": ParityFontChainTests.notoSans, "pointsize": 32],
        ], binaries: [ParityFontChainTests.notoSans: font])
        let text = try XCTUnwrap(program.scene.objects.first { $0.id == "11" })
        guard case .text = text.kind else { return XCTFail("no text object") }
        XCTAssertTrue(text.transparentMember)
    }

    /// Absent, false and non-bool keys leave sorting off; an object's immediate `value` is unwrapped.
    func testSortingNeedsAnAuthoredBoolTrue() throws {
        XCTAssertFalse(try Self.scene(general: [:]).scene.transparentSorting)
        for value: Any in [false, 1, "true", ["value": false]] {
            XCTAssertFalse(try Self.scene(general: ["transparentsorting": value]).scene.transparentSorting, "\(value)")
        }
        XCTAssertTrue(try Self.scene(general: ["transparentsorting": ["value": true]]).scene.transparentSorting)
    }

    /// One row per membership rule: image ids 1-7 by base material and layer keys, a model, a particle system.
    private static func scene(general: [String: Any]) throws -> WPEParityProgramScene {
        func image(_ id: String, _ blending: String, json: [String: Any] = [:],
                   passthrough: Bool = false) -> D.Layer {
            var layer = D.layer(id, json: json)
            layer.model = ["material": "materials/\(blending).json"]
            if passthrough {
                layer.model["passthrough"] = true
            }
            return layer
        }
        let layers = [
            image("1", "translucent"), image("2", "additive"), image("3", "normal"), image("4", "alphatocoverage"),
            image("5", "normal", json: ["copybackground": false], passthrough: true),
            image("6", "normal", json: ["copybackground": true], passthrough: true),
            image("7", "normal", json: ["colorBlendMode": 31]),
        ]
        var files: [String: Any] = [
            "materials/particle.json": ["passes": [["shader": "genericparticle"]]],
            "particles/fx.json": ["maxcount": 1, "material": "materials/particle.json", "renderer": [["name": "sprite"]]],
        ]
        for blending in ["translucent", "additive", "normal", "alphatocoverage"] {
            files["materials/\(blending).json"] = ["passes": [["shader": "genericimage2", "blending": blending]]]
        }
        return try D.programScene(layers, general: general, objects: [
            ["id": 8, "name": "8", "image": "models/8.mdl", "size": "400 200"],
            ["id": 9, "name": "fx", "particle": "particles/fx.json"],
        ], binaries: files.mapValues { try JSONSerialization.data(withJSONObject: $0) })
    }
}
