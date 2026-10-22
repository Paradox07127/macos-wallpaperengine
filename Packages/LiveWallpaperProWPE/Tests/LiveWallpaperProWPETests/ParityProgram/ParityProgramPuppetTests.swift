import Foundation
@testable import LiveWallpaperProWPE
import XCTest

final class ParityProgramPuppetTests: XCTestCase {
    private typealias D = ParitySceneDocuments

    private func puppetScene(effects: [D.Effect]) throws -> WPEParityProgramScene {
        var layer = D.layer(effects: effects)
        layer.model["puppet"] = "models/7_puppet.mdl"
        return try D.programScene([layer], binaries: ["models/7_puppet.mdl": Self.skinnedMDL(boneCount: 2)])
    }

    private func sceneDraw(_ frame: WPEParityFrame, _ pass: String) throws -> (Int, WPEParitySceneDraw) {
        try XCTUnwrap(frame.draws.lazy.compactMap { index, draw -> (Int, WPEParitySceneDraw)? in
            guard case let .scene(draw) = draw, draw.pass.rawValue == pass else { return nil }
            return (index, draw)
        }.first, pass)
    }

    func testPuppetLayerWithoutEffectsDrawsItsSkinnedMeshDirectly() throws {
        let scene = try puppetScene(effects: [])
        let object = try XCTUnwrap(scene.scene.objects.first)
        XCTAssertEqual(object.kind, .image)
        let puppet = try XCTUnwrap(object.puppet)
        XCTAssertEqual(puppet.vertices.count, 3)
        XCTAssertEqual(puppet.vertexStream?.vertexCount, 3)
        XCTAssertEqual(puppet.vertexStream?.layout.stride, 52)
        XCTAssertEqual(puppet.vertexStream?.data.count, 156)
        XCTAssertEqual(puppet.indices, [0, 1, 2])
        XCTAssertEqual(puppet.vertices[1].skinBlendIndices, SIMD4(1, 0, 0, 0))
        XCTAssertEqual(puppet.boneCount, 2)
        XCTAssertTrue(puppet.skinned)
        XCTAssertNil(puppet.blendMeshIndex)
        XCTAssertFalse(object.puppetForcesComposite)
        XCTAssertFalse(object.requiresLayerComposite)

        let frame = try WPEParityFrameComposer.compose(scene: scene.scene, post: scene.postProcess)
        let (index, albedo) = try sceneDraw(frame, "7/albedo")
        XCTAssertEqual(albedo.geometry, .puppetMesh)
        XCTAssertNil(frame.draws.values.first { draw in
            if case let .scene(draw) = draw {
                draw.pass.rawValue == "7/passthrough4"
            } else {
                false
            }
        })
        let program = try XCTUnwrap(frame.draws[index].flatMap { WPEParityProgramBuilder.description(of: $0, scene: scene) })
        XCTAssertEqual(program.material.shader, "genericimage2")
        XCTAssertEqual(program.material.combos["SKINNING"], 1)
        XCTAssertEqual(program.material.combos["BONECOUNT"], 2)
        XCTAssertEqual(program.material.blending, .translucent)
        XCTAssertEqual(WPEParityProgramBuilder.bindings(frame: frame, scene: scene)[index]?.layerColorObjectID, "7",
                       "the skinned albedo takes the layer colour and alpha")
    }

    func testPuppetLayerWithAnEffectDrawsItsMeshThroughTheLayerComposite() throws {
        let scene = try puppetScene(effects: [D.effect(passes: [D.pass("fx")])])
        let object = try XCTUnwrap(scene.scene.objects.first)
        XCTAssertTrue(object.puppetForcesComposite)
        XCTAssertTrue(object.requiresLayerComposite)

        let frame = try WPEParityFrameComposer.compose(scene: scene.scene, post: scene.postProcess)
        let (_, albedo) = try sceneDraw(frame, "7/albedo")
        XCTAssertEqual(albedo.geometry, .fullscreenQuad)
        XCTAssertTrue(albedo.fillsComposite)
        XCTAssertNil(albedo.source?.combos["SKINNING"])
        let (_, final) = try sceneDraw(frame, "7/passthrough4")
        XCTAssertEqual(final.geometry, .puppetMesh)
        XCTAssertEqual(final.source?.materialPath, "materials/util/effectpassthrough_4.json")
        XCTAssertEqual(final.source?.combos["SKINNING"], 1)
        XCTAssertEqual(final.source?.combos["BONECOUNT"], 2)
        XCTAssertNil(final.source?.combos["SKINNING_ALPHA"])
        XCTAssertNil(final.source?.combos["MORPHING"])
    }

    func testClipColorRoleReachesProgramBindingWithNonWhiteHalfAlpha() throws {
        for composite in [false, true] {
            var layer = D.layer(json: ["color": "0.2 0.4 0.6", "alpha": 0.5],
                                effects: composite ? [D.effect(passes: [D.pass("fx")])] : [])
            layer.model["puppet"] = "models/7_puppet.mdl"
            let scene = try D.programScene([layer], binaries: ["models/7_puppet.mdl": Self.skinnedMDL(boneCount: 2)])
            XCTAssertEqual(scene.layerColors["7"], SIMD4(0.2, 0.4, 0.6, 0.5))
            var description = scene.scene
            let original = try XCTUnwrap(description.objects[0].puppet)
            description.objects[0].puppet = WPEParityScenePuppet(
                vertices: original.vertices, indices: original.indices, boneCount: original.boneCount, skinned: true,
                parts: [.init(id: 0, start: 0, count: 3), .init(id: 1, start: 0, count: 3)],
                clipGroups: [.init(clipped: [1], mask: [0], maskTexture: "mask")], vertexStream: original.vertexStream
            )
            let frame = try WPEParityFrameComposer.compose(scene: description, post: scene.postProcess)
            let (index, target) = try sceneDraw(frame, "7/clip1/target")
            XCTAssertEqual(target.colorRole, composite ? .compositePublish : .albedo)
            let binding = try XCTUnwrap(WPEParityProgramBuilder.bindings(frame: frame, scene: scene,
                                                                         description: description)[index])
            XCTAssertEqual(binding.layerColorObjectID, composite ? nil : "7",
                           "native bit4 publish resets layer colour/alpha after its FBO fill")
            if composite {
                let (fill, _) = try sceneDraw(frame, "7/albedo")
                XCTAssertEqual(WPEParityProgramBuilder.bindings(frame: frame, scene: scene,
                                                                description: description)[fill]?.layerColorObjectID, "7")
            }
        }
    }

    /// Workshop 2370640409: layers 43 (no effect), 47 and 51 (opacity effect) are skinned puppets.

    /// Part 0 shapes the mask, part 1 is clipped: the mask part draws, then its mask, then part 1 through it.
    func testTwoPartPuppetWithOneClipGroupBuildsWPEsOperationList() {
        let parts = [WPEPuppetMeshPart(id: 0, start: 0, count: 3), WPEPuppetMeshPart(id: 0, start: 3, count: 3)]
        let puppet = WPEParityScenePuppet(vertices: [], indices: [0, 1, 2, 3, 4, 5], boneCount: 1, skinned: true,
                                          parts: parts,
                                          clipGroups: [WPEParityPuppetClipGroup(clipped: [1], mask: [0],
                                                                                maskTexture: "masks/m")])
        XCTAssertEqual(puppet.clipOperations, [.segment(0), .clip(group: 0, ancestors: [], segment: 1)])
        XCTAssertEqual(puppet.clipSegments, [0 ..< 3, 3 ..< 6, 6 ..< 9])
        XCTAssertEqual(puppet.clipIndices, [0, 1, 2, 0, 1, 2, 3, 4, 5])
    }

    /// Group 1's mask part is clipped by group 0, so group 1 is its child and merges group 0's mask first (op 2).
    func testNestedClipGroupMergesItsAncestorsMask() {
        let mesh = WPEPuppetMesh(materialPath: "m", vertices: [], indices: [0, 1, 2, 3, 4, 5, 6, 7, 8],
                                 parts: (0 ..< 3).map { WPEPuppetMeshPart(id: 0, start: $0 * 3, count: 3) },
                                 clipGroups: [WPEPuppetClipGroup(maskName: "a", sourcePartIndices: [0],
                                                                 targetPartIndices: [1]),
                                              WPEPuppetClipGroup(maskName: "b", sourcePartIndices: [1],
                                                                 targetPartIndices: [2])])
        let groups = WPEParityPuppetClipGroup.groups(of: mesh)
        XCTAssertEqual(groups.map(\.parent), [nil, 0])
        let puppet = WPEParityScenePuppet(vertices: [], indices: WPEParityScenePuppet.indices(of: mesh), boneCount: 1,
                                          skinned: true, parts: mesh.parts, clipGroups: groups)
        XCTAssertEqual(puppet.clipOperations, [
            .segment(0),
            .clip(group: 0, ancestors: [], segment: 1),
            .clip(group: 1, ancestors: [.init(group: 0, segment: 1)], segment: 3),
        ])
        XCTAssertEqual(puppet.clipSegments, [0 ..< 3, 3 ..< 6, 6 ..< 9, 9 ..< 12, 12 ..< 15])
        XCTAssertEqual(puppet.clipIndices, [0, 1, 2, 0, 1, 2, 3, 4, 5, 3, 4, 5, 6, 7, 8])
    }

    /// Workshop 3704273480 and 3808922316 have puppets with clip groups.

    /// MDLV0017 with one mesh (position, bone indices, weights, uv) and an MDLS0001 skeleton.
    private static func skinnedMDL(boneCount: Int) -> Data {
        var data = Data("MDLV0017".utf8) + [0]
        data.append(uint32: 0x0180_0009)
        data.append(uint32: 1)
        data.append(uint32: 1)
        data.append(Data("materials/genericimage2.json".utf8) + [0])
        data.append(uint32: 0)
        for value: Float in [0, 0, 0, 1, 1, 0] {
            data.append(uint32: value.bitPattern)
        }
        data.append(uint32: 0x0180_0009)
        var vertices = Data()
        for (bone, x, y) in [(UInt32(0), Float(0), Float(0)), (1, 1, 0), (1, 0, 1)] {
            for value in [x, y, 0] {
                vertices.append(uint32: value.bitPattern)
            }
            for index in [bone, 0, 0, 0] {
                vertices.append(uint32: index)
            }
            for weight: Float in [1, 0, 0, 0] {
                vertices.append(uint32: weight.bitPattern)
            }
            for value in [x, y] {
                vertices.append(uint32: value.bitPattern)
            }
        }
        data.append(uint32: UInt32(vertices.count))
        data.append(vertices)
        data.append(uint32: 6)
        data.append(contentsOf: [0, 0, 1, 0, 2, 0])
        data.append(Data("MDLS0001".utf8) + [0])
        data.append(uint32: 0)
        data.append(contentsOf: [UInt8(boneCount), 0, 0, 0])
        for bone in 0 ..< boneCount {
            data.append(Data("bone\(bone)".utf8) + [0])
            data.append(uint32: 0)
            data.append(uint32: .max)
            data.append(uint32: 64)
            for value: Float in [1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1] {
                data.append(uint32: value.bitPattern)
            }
            data.append(0)
        }
        return data
    }

    /// PKGV: a length-prefixed version, the entry table (name, offset, size), then the entry bytes.
    static func unpack(_ package: URL, into root: URL) throws {
        let bytes = try [UInt8](Data(contentsOf: package))
        var offset = 0
        func uint32() -> Int {
            defer { offset += 4 }
            return (0 ..< 4).reduce(0) { $0 | Int(bytes[offset + $1]) << (8 * $1) }
        }
        func string() -> String {
            let count = uint32()
            defer { offset += count }
            return String(bytes: bytes[offset ..< offset + count], encoding: .utf8) ?? ""
        }
        _ = string()
        let entries = (0 ..< uint32()).map { _ in (name: string(), offset: uint32(), size: uint32()) }
        for entry in entries {
            let url = root.appendingPathComponent(entry.name)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            let start = offset + entry.offset
            try Data(bytes[start ..< start + entry.size]).write(to: url)
        }
    }
}

private extension Data {
    mutating func append(uint32 value: UInt32) {
        Swift.withUnsafeBytes(of: value.littleEndian) { append(contentsOf: $0) }
    }
}
