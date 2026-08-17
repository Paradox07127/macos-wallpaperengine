import Foundation
import Testing

/// `MetalCaptureEnabled` in an Info.plist makes Metal load GPUToolsCapture
/// into every launch of the shipped app — no Xcode attachment required. Its
/// per-draw encoder interposition grew the AGX `DataBufferAllocator` arena
/// without bound (~40-60MB/min resident on a scene wallpaper; caught by
/// breakpointing `AGX::DataBufferAllocator<45ul>::grow`, ledger §14). Debug
/// captures use Xcode attach or an `MTL_CAPTURE_ENABLED=1` launch instead.
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
