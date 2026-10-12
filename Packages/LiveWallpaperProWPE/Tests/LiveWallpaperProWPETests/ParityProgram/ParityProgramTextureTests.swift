import Foundation
@testable import LiveWallpaperProWPE
import XCTest

final class ParityProgramTextureTests: XCTestCase {
    private static func header(format: UInt32, flags: UInt32) -> Data {
        var bytes = Array("TEXV0005\0TEXI0001\0".utf8)
        for value in [format, flags, 64, 2] {
            withUnsafeBytes(of: value.littleEndian) { bytes.append(contentsOf: $0) }
        }
        return Data(bytes)
    }

    func testSyntheticHeaderReadsFormatAndFlags() {
        let header = WPEParityProgramTextureHeader(bytes: Array(Self.header(format: 9, flags: 0x0080_0002)))
        XCTAssertEqual(header, WPEParityProgramTextureHeader(format: 9, flags: 0x0080_0002))
        var wrongMagic = Array(Self.header(format: 9, flags: 0))
        wrongMagic[9] = UInt8(ascii: "X")
        XCTAssertNil(WPEParityProgramTextureHeader(bytes: wrongMagic))
        XCTAssertNil(WPEParityProgramTextureHeader(bytes: Array(Self.header(format: 9, flags: 0).prefix(25))))
    }

    func testRealMaskTextureFlagsEmissiveComponent() throws {
        guard let directory = ProcessInfo.processInfo.environment["WPE_HLSL_CAPTURE_DIR"], !directory.isEmpty else {
            throw XCTSkip("Set WPE_HLSL_CAPTURE_DIR to the capture directory containing scene-sources/")
        }
        let scene = URL(fileURLWithPath: directory).appendingPathComponent("scene-sources/3509243656")
        let assets = WPEParityProgramAssets(sceneDirectory: scene, assetRoots: [])
        // generic4 g_Texture2 components[3] is EMISSIVE_MAP: bit 0x100000 << 3.
        XCTAssertEqual(assets.textureHeader(named: "masks/Material__50_mask_fe7471cd"),
                       WPEParityProgramTextureHeader(format: 0, flags: 0x0080_0002))
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
