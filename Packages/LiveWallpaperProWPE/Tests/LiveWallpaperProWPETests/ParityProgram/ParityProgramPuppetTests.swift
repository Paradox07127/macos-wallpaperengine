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
        XCTAssertEqual(puppet.indices, [0, 1, 2])
        XCTAssertEqual(puppet.vertices[1].skinBlendIndices, SIMD4(1, 0, 0, 0))
        XCTAssertEqual(puppet.boneCount, 2)
        XCTAssertTrue(puppet.skinned)
        XCTAssertNil(puppet.blendMeshIndex)
        XCTAssertFalse(object.puppetForcesComposite)
        XCTAssertFalse(object.requiresLayerComposite)

        let frame = try WPEParityFrameComposer.compose(scene: scene.scene, post: scene.postProcess, frameIndex: 0)
        let (index, albedo) = try sceneDraw(frame, "7/albedo")
        XCTAssertEqual(albedo.geometry, .puppetMesh)
        XCTAssertNil(frame.draws.values.first { draw in
            if case let .scene(draw) = draw {
                draw.pass.rawValue == "7/passthrough4"
            } else {
                false
            }
        })
        let program = try XCTUnwrap(WPEParityProgramBuilder.draws(frame: frame, scene: scene)
            .first { $0.operationIndex == index }?.description)
        XCTAssertEqual(program.material.shader, "genericimage2")
        XCTAssertEqual(program.material.combos["SKINNING"], 1)
        XCTAssertEqual(program.material.combos["BONECOUNT"], 2)
        XCTAssertEqual(program.material.blending, .translucent)
    }

    func testPuppetLayerWithAnEffectDrawsItsMeshThroughTheLayerComposite() throws {
        let scene = try puppetScene(effects: [D.effect(passes: [D.pass("fx")])])
        let object = try XCTUnwrap(scene.scene.objects.first)
        XCTAssertTrue(object.puppetForcesComposite)
        XCTAssertTrue(object.requiresLayerComposite)

        let frame = try WPEParityFrameComposer.compose(scene: scene.scene, post: scene.postProcess, frameIndex: 0)
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

    /// Workshop 2370640409: layers 43 (no effect), 47 and 51 (opacity effect) are skinned puppets.
    func testRealPuppetSceneBuildsSkinnedPrograms() throws {
        let package = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(
            "Library/Application Support/Steam/steamapps/workshop/content/431960/2370640409/scene.pkg"
        )
        guard FileManager.default.fileExists(atPath: package.path) else {
            throw XCTSkip("Workshop 2370640409 is not installed")
        }
        let install = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Steam/steamapps/common/wallpaper_engine/assets")
        let wpeAssets = ProcessInfo.processInfo.environment["WPE_ASSETS_DIR"].map { URL(fileURLWithPath: $0) } ?? install
        guard FileManager.default.fileExists(atPath: wpeAssets.appendingPathComponent("materials/util").path) else {
            throw XCTSkip("Set WPE_ASSETS_DIR to a WPE 2.8.42 assets directory (materials/util, shaders)")
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("parity-puppet-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try Self.unpack(package, into: root)
        let document = try WPESceneDocumentParser.parse(data: Data(contentsOf: root.appendingPathComponent("scene.json")),
                                                        userValues: [:],
                                                        makeTransformScriptResolver: { _, _ in NoScripts() })
        let assets = WPEParityProgramAssets(sceneDirectory: root, assetRoots: [wpeAssets])
        let scene = WPEParityProgramScene(document: document, assets: assets, settings: WPEParityProgramSettings())

        let puppets = scene.scene.objects.filter { $0.puppet != nil }
        for object in puppets {
            let puppet = try XCTUnwrap(object.puppet)
            print("puppet layer \(object.id): \(puppet.vertices.count) vertices, \(puppet.indices.count) indices, "
                + "\(puppet.boneCount) bones, skinned \(puppet.skinned), bit4 \(object.puppetForcesComposite)")
            XCTAssertFalse(puppet.vertices.isEmpty, object.id)
            XCTAssertFalse(puppet.indices.isEmpty, object.id)
            XCTAssertGreaterThan(puppet.boneCount, 0, object.id)
            XCTAssertTrue(puppet.skinned, object.id)
            XCTAssertEqual(object.kind, .image, object.id)
        }
        XCTAssertEqual(puppets.map(\.id).sorted(), ["43", "47", "51"])
        XCTAssertEqual(puppets.filter(\.puppetForcesComposite).map(\.id).sorted(), ["47", "51"])

        let frame = try WPEParityFrameComposer.compose(scene: scene.scene, post: scene.postProcess, frameIndex: 0)
        let puppetDraws = frame.draws.compactMap { index, draw -> (Int, WPEParitySceneDraw)? in
            guard case let .scene(draw) = draw, draw.geometry == .puppetMesh else { return nil }
            return (index, draw)
        }
        XCTAssertEqual(Set(puppetDraws.map(\.1.pass.rawValue)),
                       ["43/albedo", "47/passthrough4", "51/passthrough4"])
        let programs = WPEParityProgramBuilder.draws(frame: frame, scene: scene)
        for (index, draw) in puppetDraws {
            let description = try XCTUnwrap(programs.first { $0.operationIndex == index }?.description,
                                            draw.pass.rawValue)
            let program = try WPEParityProgramResolver.resolve(description, sources: assets)
            XCTAssertTrue(program.combos.contains { $0.name == "SKINNING" && $0.value == "1" }, draw.pass.rawValue)
            let vertex = String(bytes: program.hlsl.vertex ?? [], encoding: .isoLatin1)
            XCTAssertEqual(vertex?.contains("g_Bones["), true, draw.pass.rawValue)
        }
    }

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

private struct NoScripts: WPESceneTransformScriptResolving {
    func resolveVec3(script _: String, properties _: [String: WPESceneScriptPropertyValue],
                     seed _: SIMD3<Double>) -> SIMD3<Double>? {
        nil
    }
}
