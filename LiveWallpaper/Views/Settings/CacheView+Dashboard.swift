#if !LITE_BUILD
import AppKit
import LiveWallpaperCore
import SwiftUI

extension WPECacheManagementView {
    // MARK: - Summary (total + clear-all)

    var totalBytes: UInt64 {
        storageMeasurements.filter(\.location.kind.isCache).reduce(0) { $0 + $1.bytes }
    }

    var clearableBytes: UInt64 {
        storageMeasurements.filter(\.location.kind.canClear).reduce(0) { $0 + $1.bytes }
    }

    var retainedBytes: UInt64 {
        storageMeasurements.filter {
            !$0.location.kind.isCache && ![.localWallpapers, .legacyScenes, .application].contains($0.location.kind)
        }.reduce(0) { $0 + $1.bytes }
    }

    var wallpaperBytes: UInt64 {
        (inventory?.projectsTotalBytes ?? 0) + storageMeasurements.filter {
            [.localWallpapers, .legacyScenes].contains($0.location.kind)
        }.reduce(0) { $0 + $1.bytes }
    }

    var applicationBytes: UInt64 {
        storageMeasurements.filter { $0.location.kind == .application }.reduce(0) { $0 + $1.bytes }
    }

    var engineAssetBytes: UInt64 {
        inventory?.engineAssetsBytes ?? 0
    }

    var systemWallpaperBytes: UInt64 {
        UInt64(max(0, exportService.diskUsageBytes))
    }

    /// Reveal Steam library files in Finder while holding the library’s security scope.
    func openFolder(_ url: URL?, scopeRoot: URL?) {
        guard let url else { return }
        let root = scopeRoot ?? url
        let didStart = root.startAccessingSecurityScopedResource()
        defer {
            if didStart {
                root.stopAccessingSecurityScopedResource()
            }
        }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    func openFolderIconButton(_ url: URL, scopeRoot: URL? = nil) -> some View {
        Button { openFolder(url, scopeRoot: scopeRoot) } label: {
            Image(systemName: "folder")
        }
        .buttonStyle(.borderless)
        .help(Text("Open Folder"))
        .accessibilityLabel(Text("Open Folder"))
    }
}
#endif
