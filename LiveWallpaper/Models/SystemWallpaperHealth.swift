import Foundation

/// The one answer to "is the system side set up?", shared by the System Wallpaper page and Settings.
enum SystemWallpaperHealth: Equatable {
    case unavailable
    case serviceUnresponsive
    case otherCopyProvides
    case notConfigured
    case following(displayCount: Int)

    static func evaluate(
        status: WallpaperExportService.Status,
        providerIssue: WallpaperExportService.ProviderIssue?,
        activeDisplayCount: Int
    ) -> SystemWallpaperHealth {
        if status == .systemIncompatible {
            return .unavailable
        }
        switch providerIssue {
        case .stopped, .unresponsive:
            return .serviceUnresponsive
        case .differentCopy:
            return .otherCopyProvides
        case nil:
            return activeDisplayCount > 0 ? .following(displayCount: activeDisplayCount) : .notConfigured
        }
    }
}

/// A copy without a `sourceKey` is never followed; it only plays as the fallback when no display has a selection.
enum SystemWallpaperLegacyCopies {
    static func items(in items: [SystemWallpaperManifest.Item]) -> [SystemWallpaperManifest.Item] {
        items.filter { $0.sourceKey == nil }
    }

    /// Bytes on disk; a scene copy is a directory, so its contents are summed.
    static func byteCount(of fileNames: [String], in directory: URL) -> Int64 {
        let fileManager = FileManager.default
        var total: Int64 = 0
        for name in fileNames {
            let url = directory.appendingPathComponent(name)
            let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey])
            if values?.isDirectory == true {
                let files = fileManager.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey])?
                    .compactMap { $0 as? URL } ?? []
                total += files.reduce(Int64(0)) { $0 + Int64((try? $1.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
            } else {
                total += Int64(values?.fileSize ?? 0)
            }
        }
        return total
    }
}
