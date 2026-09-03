#if !LITE_BUILD
import Foundation
import LiveWallpaperProWPE

/// `du`-style allocated-size accounting for app-owned WPE data.
enum WPEStoragePaths {
    /// Entries one inventory pass may visit before it stops early. The Steam
    /// library holds a folder per subscribed wallpaper, so the walk grows with
    /// the user's library rather than with anything this app controls.
    static let defaultWalkBudget = 200_000

    /// Sum of the allocated (`du`-equivalent) size of every regular file under
    /// `url`. Hidden files skipped.
    ///
    /// Stops early when the task is cancelled or `visited` reaches `budget`, so
    /// a caller can spend one budget across several roots and tell a complete
    /// total from a lower bound.
    static func allocatedBytes(
        at url: URL,
        fileManager fm: FileManager = .default,
        budget: Int,
        visited: inout Int
    ) -> UInt64 {
        // `enumerator(at:)` yields nothing when the root itself is a symlink.
        guard let enumerator = fm.enumerator(
            at: url.standardizedFileURL.resolvingSymlinksInPath(),
            includingPropertiesForKeys: [.totalFileAllocatedSizeKey, .fileAllocatedSizeKey],
            options: [.skipsHiddenFiles]
        ) else { return 0 }
        var total: UInt64 = 0
        for case let item as URL in enumerator {
            guard !Task.isCancelled, visited < budget else { return total }
            visited += 1
            let values = try? item.resourceValues(forKeys: [.totalFileAllocatedSizeKey, .fileAllocatedSizeKey])
            total += UInt64(values?.totalFileAllocatedSize ?? values?.fileAllocatedSize ?? 0)
        }
        return total
    }

    static func allocatedBytes(at url: URL, fileManager fm: FileManager = .default) -> UInt64 {
        var visited = 0
        return allocatedBytes(at: url, fileManager: fm, budget: .max, visited: &visited)
    }
}
#endif
