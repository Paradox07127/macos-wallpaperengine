import Foundation
import Testing

/// `MetalCaptureEnabled` in an Info.plist loads GPUToolsCapture into every launch
/// of the shipped app and grows the AGX `DataBufferAllocator` arena without bound.
@Suite("Metal capture layer stays out of shipped Info.plists")
struct MetalCaptureLayerGuardTests {
    @Test("No SKU Info.plist re-enables MetalCaptureEnabled",
          arguments: ["LiveWallpaperInfo.plist", "LoomscreenInfo.plist"])
    func plistDoesNotEnableMetalCapture(plist: String) throws {
        let contents = try RepositoryRoot.source(plist)
        #expect(
            !contents.contains("MetalCaptureEnabled"),
            Comment(rawValue: "\(plist) re-adds MetalCaptureEnabled; it ships GPUToolsCapture into release builds and leaks the AGX arena")
        )
    }
}
