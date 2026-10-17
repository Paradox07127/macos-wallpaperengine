import Foundation
@testable import LiveWallpaperProWPE
import XCTest

/// Which loaded objects join WPE's transparent member vector, and when `general.transparentsorting` turns it on.
final class ParityProgramTransparentMembershipTests: XCTestCase {
    private typealias D = ParitySceneDocuments

    func testMembershipFollowsBaseBlendPassthroughAndKind() throws {
        let program = try Self.scene(general: ["transparentsorting": true, "orthogonalprojection": NSNull()])
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
            "8": false, // model whose .mdl is missing
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
        let perspective: [String: Any] = ["orthogonalprojection": NSNull()]
        XCTAssertFalse(try Self.scene(general: perspective).scene.transparentSorting)
        for value: Any in [false, 1, "true", ["value": false]] {
            let general = perspective.merging(["transparentsorting": value]) { _, new in new }
            XCTAssertFalse(try Self.scene(general: general).scene.transparentSorting, "\(value)")
        }
        let general = perspective.merging(["transparentsorting": ["value": true]]) { _, new in new }
        XCTAssertTrue(try Self.scene(general: general).scene.transparentSorting)
    }

    func testOrthographicScenesNeverSort() throws {
        XCTAssertFalse(try Self.scene(general: ["transparentsorting": true]).scene.transparentSorting)
        let auto: [String: Any] = ["transparentsorting": true, "orthogonalprojection": ["auto": true]]
        XCTAssertFalse(try Self.scene(general: auto).scene.transparentSorting)
    }

    /// A model joins unless one of its sub-mesh materials blends normal or alpha-to-coverage; a missing file never joins.
    func testModelMembershipFollowsEverySubMeshBlend() throws {
        var files: [String: Data] = [
            "models/one.mdl": MembershipMDLFixture.data(materials: ["materials/translucent.json"]),
            "models/mixed.mdl": MembershipMDLFixture.data(materials: ["materials/translucent.json",
                                                                      "materials/normal.json"]),
        ]
        for blending in ["translucent", "normal"] {
            files["materials/\(blending).json"] = Data(#"{"passes":[{"shader":"generic4","blending":"\#(blending)"}]}"#.utf8)
        }
        let program = try D.programScene([
            D.layer("1", image: "models/one.mdl"), D.layer("2", image: "models/mixed.mdl"),
            D.layer("3", image: "models/missing.mdl"),
        ], binaries: files)
        let members = Dictionary(uniqueKeysWithValues: program.scene.objects.map { ($0.id, $0.transparentMember) })
        XCTAssertEqual(members, ["1": true, "2": false, "3": false])
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

/// MDLV0016 static model with one triangle submesh per material path.
private enum MembershipMDLFixture {
    static func data(materials: [String]) -> Data {
        var data = Data()
        data.append(contentsOf: Array("MDLV0016".utf8))
        data.appendLE(UInt32(0x0000_0F00))
        data.append(UInt8(0))
        data.appendLE(UInt32(1))
        data.appendLE(UInt32(materials.count))
        for (index, material) in materials.enumerated() {
            data.append(contentsOf: Array(material.utf8) + [0])
            data.appendLE(UInt32(0))
            data.appendLE(UInt32(0x0000_000F))
            let minX = Float(index * 2)
            var vertices = Data()
            vertices.appendVertex(position: SIMD3<Float>(minX, 0, 0), uv: SIMD2<Float>(0, 1))
            vertices.appendVertex(position: SIMD3<Float>(minX + 1, 0, 0), uv: SIMD2<Float>(1, 1))
            vertices.appendVertex(position: SIMD3<Float>(minX, 1, 0), uv: SIMD2<Float>(0, 0))
            data.appendLE(UInt32(vertices.count))
            data.append(vertices)
            data.appendLE(UInt32(3 * MemoryLayout<UInt16>.size))
            for vertexIndex: UInt16 in [0, 1, 2] {
                data.appendLE(vertexIndex)
            }
        }
        return data
    }
}

private extension Data {
    mutating func appendLE(_ value: UInt16) {
        var littleEndian = value.littleEndian
        Swift.withUnsafeBytes(of: &littleEndian) { append(contentsOf: $0) }
    }

    mutating func appendLE(_ value: UInt32) {
        var littleEndian = value.littleEndian
        Swift.withUnsafeBytes(of: &littleEndian) { append(contentsOf: $0) }
    }

    /// Position, normal, tangent (vec4), UV: the 0x0F vertex layout.
    mutating func appendVertex(position: SIMD3<Float>, uv: SIMD2<Float>) {
        for value in [position.x, position.y, position.z, 0, 0, 1, 1, 0, 0, 1, uv.x, uv.y] {
            appendLE(value.bitPattern)
        }
    }
}
