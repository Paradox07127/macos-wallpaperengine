#if !LITE_BUILD
import Foundation
import LiveWallpaperProWPE

/// `du`-style allocated-size accounting for app-owned WPE data.
enum WPEStoragePaths {
    /// Sum of the allocated (`du`-equivalent) size of every regular file under
    /// `url`. Hidden files skipped.
    static func allocatedBytes(at url: URL, fileManager fm: FileManager = .default) -> UInt64 {
        guard let enumerator = fm.enumerator(
            at: url,
            includingPropertiesForKeys: [.totalFileAllocatedSizeKey, .fileAllocatedSizeKey],
            options: [.skipsHiddenFiles]
        ) else { return 0 }
        var total: UInt64 = 0
        for case let item as URL in enumerator {
            let values = try? item.resourceValues(forKeys: [.totalFileAllocatedSizeKey, .fileAllocatedSizeKey])
            total += UInt64(values?.totalFileAllocatedSize ?? values?.fileAllocatedSize ?? 0)
        }
        return total
    }
}
#endif
