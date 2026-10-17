#if !LITE_BUILD && DEBUG
@testable import LiveWallpaper
import LiveWallpaperProWPE
import XCTest

final class WPEParityRenderTargetUniformTests: XCTestCase {
    func testShrunkTargetReportsItsLogicalSize() {
        let id = WPEResourceID("_rt_shrunk")
        let resource = WPELogicalResource(id: id, width: 480, height: 270, lifetime: .pooled)
        let texture = WPEParityFrameDrawPlanner.renderTargetUniformTexture(resource, logicalSizes: [id: SIMD2(960, 540)])
        XCTAssertEqual([texture.textureWidth, texture.textureHeight, texture.imageWidth, texture.imageHeight],
                       [960, 540, 960, 540])
    }

    func testFullSizeTargetReportsItsAllocatedSize() {
        let resource = WPELogicalResource(id: WPEResourceID("_rt_full"), width: 1920, height: 1080, mipCount: 3,
                                          lifetime: .pooled)
        let texture = WPEParityFrameDrawPlanner.renderTargetUniformTexture(resource, logicalSizes: [:])
        XCTAssertEqual([texture.textureWidth, texture.textureHeight, texture.imageWidth, texture.imageHeight],
                       [1920, 1080, 1920, 1080])
        XCTAssertEqual(texture.mipMapInfo, 3)
    }
}
#endif
