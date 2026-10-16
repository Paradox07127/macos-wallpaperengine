import Foundation
@testable import LiveWallpaperProWPE
import XCTest

final class ParityProgramTextureTests: XCTestCase {
    private static func header(format: UInt32, flags: UInt32, containerVersion: Int = 5) -> Data {
        var bytes = Array((containerVersion == 4 ? "TEXV0004\0" : "TEXV0005\0TEXI0001\0").utf8)
        for value in [format, flags, 64, 32, 48, 20] {
            withUnsafeBytes(of: value.littleEndian) { bytes.append(contentsOf: $0) }
        }
        return Data(bytes)
    }

    func testSyntheticHeaderReadsFormatFlagsAndSizes() {
        for version in [4, 5] {
            let bytes = Array(Self.header(format: 9, flags: 0x0080_0002, containerVersion: version))
            let header = WPEParityProgramTextureHeader(bytes: bytes)
            XCTAssertEqual(header, WPEParityProgramTextureHeader(format: 9, flags: 0x0080_0002, textureWidth: 64,
                                                                 textureHeight: 32, imageWidth: 48, imageHeight: 20))
            XCTAssertNil(WPEParityProgramTextureHeader(bytes: Array(bytes.dropLast())))
        }
        var wrongMagic = Array(Self.header(format: 9, flags: 0))
        wrongMagic[9] = UInt8(ascii: "X")
        XCTAssertNil(WPEParityProgramTextureHeader(bytes: wrongMagic))
        XCTAssertNil(WPEParityProgramTextureHeader(bytes: Array(Self.header(format: 9, flags: 0).prefix(41))))
        for magic in ["TEXV0006", "TEXVxxxx"] {
            var bytes = Array(Self.header(format: 9, flags: 0))
            bytes.replaceSubrange(0 ..< 8, with: magic.utf8)
            XCTAssertNil(WPEParityProgramTextureHeader(bytes: bytes))
        }
        var unknownInfo = Array(Self.header(format: 9, flags: 0))
        unknownInfo.replaceSubrange(9 ..< 17, with: "TEXI0002".utf8)
        XCTAssertNil(WPEParityProgramTextureHeader(bytes: unknownInfo))
        XCTAssertEqual(WPEParityProgramTextureHeader(bytes: Array(Self.header(format: .max, flags: .max)))?.format, -1)
        XCTAssertEqual(WPEParityProgramTextureHeader(bytes: Array(Self.header(format: .max, flags: .max)))?.flags, .max)
    }

    /// FUN_140209360 sizes an autosize layer from its albedo; a missing file is the 6×6 placeholder (1400ec220.c:223-226).
    func testMissingAlbedoShrinksOnlyAnAutosizeLayerToThePlaceholder() throws {
        for autosize in [true, false] {
            var layer = ParitySceneDocuments.layer(
                width: 400, height: 200,
                effects: [ParitySceneDocuments.effect(passes: [ParitySceneDocuments.pass("p")])]
            )
            layer.model = ["material": "materials/albedo.json", "autosize": autosize]
            let scene = try ParitySceneDocuments.programScene([layer], files: [
                "materials/albedo.json": #"{"passes":[{"shader":"genericimage2","textures":["gone"]}]}"#,
            ])
            let object = try XCTUnwrap(scene.scene.objects.first)
            XCTAssertEqual([object.width, object.height], autosize ? [6, 6] : [400, 200], "autosize \(autosize)")
            XCTAssertEqual(scene.imageSizes["7"], autosize ? SIMD2(6, 6) : nil, "autosize \(autosize)")
        }
    }

    /// FUN_140209360 (140209360.c:26-49): a present autosize albedo gives the layer its TEXI image size.
    func testPresentAutosizeAlbedoSizesTheLayerFromItsImageSize() throws {
        var tex = Array("TEXV0005\0TEXI0001\0".utf8)
        for value: UInt32 in [0, 0, 32, 16, 24, 12] {
            withUnsafeBytes(of: value.littleEndian) { tex.append(contentsOf: $0) }
        }
        for autosize in [true, false] {
            var layer = ParitySceneDocuments.layer("1", width: 48, height: 24)
            layer.model = ["material": "materials/albedo.json", "autosize": autosize]
            let scene = try ParitySceneDocuments.programScene([layer], files: [
                "materials/albedo.json": #"{"passes":[{"shader":"genericimage2","textures":["present"]}]}"#,
            ], binaries: ["materials/present.tex": Data(tex)])
            let object = try XCTUnwrap(scene.scene.objects.first)
            XCTAssertEqual([object.width, object.height], autosize ? [24, 12] : [48, 24], "autosize \(autosize)")
            XCTAssertEqual(scene.imageSizes["1"], autosize ? SIMD2(24, 12) : nil, "autosize \(autosize)")
        }
    }

    func testVersionFourRG8AndR8ReachProductionFormatCombos() {
        let files = [
            "shaders/probe.vert": Data("void main() {}".utf8),
            "shaders/probe.frag": Data("""
            uniform sampler2D g_Texture0; // {"formatcombo":true}
            uniform sampler2D g_Texture1; // {"formatcombo":true}
            """.utf8),
            "materials/rg.tex": Self.header(format: 8, flags: 0x0080_0002, containerVersion: 4),
            "materials/r.tex": Self.header(format: 9, flags: 2, containerVersion: 4),
        ]
        let assets = WPEParityProgramAssets(sources: [.lookup(URL(fileURLWithPath: "/tex-v4-fixture")) { files[$0] }])
        let material = WPEParityProgramMaterial(shader: "probe", textures: [0: "rg", 1: "r"])
        let description = WPEParityProgramBuilder.description(material, engineFlags: WPEEngineComboFlags(), assets: assets)
        XCTAssertEqual(description.engineFlags.textureFormats, [0: 8, 1: 9])
        XCTAssertEqual(description.boundTextures[0]?.flags, 0x0080_0002)
        let defines = WPEComboResolver.resolve(passJSONCombos: [], blendingMode: 0, vertexSource: "",
                                               fragmentSource: Latin1.string(assets.shaderSource(named: "shaders/probe.frag") ?? []),
                                               engineFlags: description.engineFlags, boundTextures: description.boundTextures)
        XCTAssertEqual(Set(defines.map { "\($0.name)=\($0.value)" }), Set(["REVERSEDEPTH=1", "TEX0FORMAT=8", "TEX1FORMAT=9"]))
    }

    func testRealMaskTextureFlagsEmissiveComponent() throws {
        guard let directory = ProcessInfo.processInfo.environment["WPE_HLSL_CAPTURE_DIR"], !directory.isEmpty else {
            throw XCTSkip("Set WPE_HLSL_CAPTURE_DIR to the capture directory containing scene-sources/")
        }
        let scene = URL(fileURLWithPath: directory).appendingPathComponent("scene-sources/3509243656")
        let assets = WPEParityProgramAssets(sceneDirectory: scene, assetRoots: [])
        // generic4 g_Texture2 components[3] is EMISSIVE_MAP: bit 0x100000 << 3.
        let mask = assets.textureHeader(named: "masks/Material__50_mask_fe7471cd")
        XCTAssertEqual(mask?.format, 0)
        XCTAssertEqual(mask?.flags, 0x0080_0002)
        XCTAssertEqual(assets.textureHeader(named: "masks/材质_mask_d86e683c")?.flags, 2)
        XCTAssertNil(assets.textureHeader(named: "_rt_FullFrameBuffer"))
    }

    func testUnboundSamplerLoadsItsDefaultTextureForFormatOnly() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let scene = root.appendingPathComponent("scene"), wpe = root.appendingPathComponent("wpe")
        let files: [(URL, Data)] = [
            (wpe.appendingPathComponent("shaders/probe.vert"), Data("void main() {}\n".utf8)),
            (wpe.appendingPathComponent("shaders/probe.frag"), Data("""
            uniform sampler2D g_Texture0; // {"default":"util/white"}
            uniform sampler2D g_Texture2; // {"combo":"MASKS","components":[{"combo":"A_MAP"},{"combo":"B_MAP"}]}
            uniform sampler2D g_Texture4; // {"default":"gradient/ramp","formatcombo":true}
            uniform sampler2D g_Texture5; // {"default":"gradient/missing","formatcombo":true}
            """.utf8)),
            (wpe.appendingPathComponent("materials/util/white.tex"), Self.header(format: 0, flags: 0)),
            (wpe.appendingPathComponent("materials/gradient/ramp.tex"), Self.header(format: 7, flags: 0)),
            // The wallpaper directory wins over the WPE assets for the same name.
            (scene.appendingPathComponent("materials/gradient/ramp.tex"), Self.header(format: 9, flags: 0)),
            (scene.appendingPathComponent("materials/mask.tex"), Self.header(format: 0, flags: 0x0020_0002)),
        ]
        for (url, data) in files {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try data.write(to: url)
        }
        let assets = WPEParityProgramAssets(sceneDirectory: scene, assetRoots: [wpe])
        let material = WPEParityProgramMaterial(shader: "probe", textures: [0: "_rt_FullFrameBuffer", 2: "mask"])
        let description = WPEParityProgramBuilder.description(material, engineFlags: WPEEngineComboFlags(),
                                                              assets: assets)

        XCTAssertEqual(description.engineFlags.textureFormats, [2: 0, 4: 9])
        XCTAssertEqual(description.boundTextures, [0: WPEBoundComboTexture(), 2: WPEBoundComboTexture(flags: 0x0020_0002)])
        let defines = WPEComboResolver.resolve(
            passJSONCombos: [], blendingMode: 0, vertexSource: "", fragmentSource: Latin1.string(
                assets.shaderSource(named: "shaders/probe.frag") ?? []
            ),
            engineFlags: description.engineFlags, boundTextures: description.boundTextures
        )
        XCTAssertEqual(defines.map { "\($0.name)=\($0.value)" }, ["REVERSEDEPTH=1", "TEX4FORMAT=9", "MASKS=1", "B_MAP=1"])
    }
}
