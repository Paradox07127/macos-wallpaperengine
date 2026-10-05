#if !LITE_BUILD
import Foundation
@testable import LiveWallpaper
import Testing

@MainActor
@Suite("Storage cache clear accounting")
struct CacheClearAccountingTests {
    private static func measured(_ kind: AppStorageLocation.Kind, _ bytes: UInt64) -> AppStorageMeasurement {
        let url = URL(fileURLWithPath: "/storage-accounting/\(kind.rawValue)", isDirectory: true)
        return AppStorageMeasurement(location: .init(kind: kind, url: url), bytes: bytes, fileCount: 1, status: .complete)
    }

    @Test("Freed bytes follow the cleared caches even when an unrelated cache grows meanwhile")
    func unrelatedGrowthDoesNotHideFreedBytes() {
        let before = [Self.measured(.video, 300), Self.measured(.query, 20), Self.measured(.previews, 50)]
        let after = [Self.measured(.video, 0), Self.measured(.query, 5), Self.measured(.previews, 900)]
        #expect(WPECacheManagementView.freedBytes(of: [.video], before: before, after: after) == 300)
        #expect(WPECacheManagementView.freedBytes(of: [.video, .query], before: before, after: after) == 315)
    }

    @Test("A cleared cache that ends up larger reports nothing freed")
    func targetGrowthClampsToZero() {
        let freed = WPECacheManagementView.freedBytes(
            of: [.audio], before: [Self.measured(.audio, 10)], after: [Self.measured(.audio, 40)]
        )
        #expect(freed == 0)
    }
}
#endif
