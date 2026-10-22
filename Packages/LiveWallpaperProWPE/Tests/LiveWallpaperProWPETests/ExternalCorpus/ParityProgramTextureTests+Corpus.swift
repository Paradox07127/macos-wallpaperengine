import Foundation
@testable import LiveWallpaperProWPE
import XCTest

extension ParityProgramTextureTests {
    func testRealMaskTextureFlagsEmissiveComponent() throws {
        guard let directory = ProcessInfo.processInfo.environment["WPE_HLSL_CAPTURE_DIR"], !directory.isEmpty else {
            throw CorpusFixtures.MissingInput("Set WPE_HLSL_CAPTURE_DIR to the capture directory containing scene-sources/")
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
}
