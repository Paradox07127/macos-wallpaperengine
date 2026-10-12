@testable import LiveWallpaperProWPE
import XCTest

final class ParityUniformTexturesTests: XCTestCase {
    private func floats(_ value: WPECBufferValue?) -> [Float] {
        switch value {
        case let .float(scalar)?: [scalar]
        case let .vector(vector)?: vector
        default: []
        }
    }

    func testSpriteRotationDividesPerAxis() {
        let frame = WPEParityUniformSpriteFrame(x: 64, y: 32, widthX: 100, widthY: 20, heightX: -10, heightY: 50,
                                                imageWidth: 400, imageHeight: 200)
        XCTAssertEqual(frame.rotation, SIMD4(0.25, 0.1, -0.025, 0.25))
        XCTAssertEqual(frame.translation, SIMD2(0.16, 0.16))
        let texture = WPEParityUniformTexture(textureWidth: 512, textureHeight: 256, imageWidth: 400,
                                              imageHeight: 200, mipMapInfo: -3, spriteFrame: frame)
        let values = WPEParityUniformTextures.values(slot: 2, texture: texture)
        XCTAssertEqual(floats(values["g_Texture2Rotation"]), [0.25, 0.1, -0.025, 0.25])
        XCTAssertEqual(floats(values["g_Texture2Translation"]), [0.16, 0.16])
        XCTAssertEqual(floats(values["g_Texture2Resolution"]), [512, 256, 400, 200])
        XCTAssertEqual(floats(values["g_Texture2Texel"]), [1.0 / 512, 1.0 / 256, 512, 256])
        XCTAssertEqual(floats(values["g_Texture2MipMapInfo"]), [0])
    }

    func testUnboundTextureDefaults() {
        let values = WPEParityUniformTextures.values(slot: 7, texture: nil)
        XCTAssertEqual(floats(values["g_Texture7Resolution"]), [2, 2, 2, 2])
        XCTAssertEqual(floats(values["g_Texture7Texel"]), [0.5, 0.5, 2, 2])
        XCTAssertEqual(floats(values["g_Texture7MipMapInfo"]), [1])
        XCTAssertNil(values["g_Texture7Rotation"])
        XCTAssertNil(values["g_Texture7Translation"])
    }
}
