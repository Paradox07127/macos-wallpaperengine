#if !LITE_BUILD
import AppKit
import LiveWallpaperCore
import SwiftUI

extension WPECacheManagementView {
    // MARK: - Summary (total + clear-all)

    var totalBytes: UInt64 {
        var total = videoStats?.totalBytes ?? 0
        total += UInt64(max(0, workshopCacheBytes))
        return total
    }

    private var engineAssetBytes: UInt64 {
        inventory?.engineAssetsBytes ?? 0
    }

    private var systemWallpaperBytes: UInt64 {
        UInt64(max(0, exportService.diskUsageBytes))
    }

    private var storageFootprintBytes: UInt64 {
        engineAssetBytes + totalBytes + (inventory?.projectsTotalBytes ?? 0) + systemWallpaperBytes
    }

    private var isStorageOverviewLoading: Bool {
        isAnyLoading || (isLoadingInventory && inventory == nil)
    }

    private var storageOverviewSegments: [StorageOverviewSegment] {
        let projectBytes = inventory?.projectsTotalBytes ?? 0
        return [
            StorageOverviewSegment(
                id: "wallpapers",
                title: "Wallpapers",
                color: DesignTokens.Colors.Gauge.low,
                bytes: projectBytes,
                valueText: byteFormatter.string(fromByteCount: Int64(projectBytes))
            ),
            StorageOverviewSegment(
                id: "engine",
                title: "Engine",
                color: DesignTokens.Colors.accent,
                bytes: engineAssetBytes,
                valueText: byteFormatter.string(fromByteCount: Int64(engineAssetBytes))
            ),
            StorageOverviewSegment(
                id: "systemWallpaper",
                title: "System Wallpaper",
                color: DesignTokens.Colors.Gauge.high,
                bytes: systemWallpaperBytes,
                valueText: byteFormatter.string(fromByteCount: Int64(systemWallpaperBytes))
            ),
            StorageOverviewSegment(
                id: "caches",
                title: "Caches",
                color: DesignTokens.Colors.Gauge.medium,
                bytes: totalBytes,
                valueText: byteFormatter.string(fromByteCount: Int64(totalBytes))
            )
        ].filter { $0.bytes > 0 }
    }

    private var systemWallpaperSubtitle: Text {
        let count = exportService.items.count
        return count == 1
            ? Text("1 video copied for macOS to play")
            : Text("\(count) videos copied for macOS to play")
    }

    private var isAnyLoading: Bool {
        isLoading || isLoadingVideo
    }

    private var wallpapersSubtitle: Text {
        let count = inventory?.projects.count ?? 0
        return count == 1
            ? Text("1 wallpaper in your Steam library")
            : Text("\(count) wallpapers in your Steam library")
    }

    var storageDashboardSection: some View {
        Section {
            StorageOverviewPanel(
                totalText: byteFormatter.string(fromByteCount: Int64(storageFootprintBytes)),
                isLoading: isStorageOverviewLoading,
                segments: storageOverviewSegments
            )

            LazyVGrid(columns: dashboardColumns, alignment: .leading, spacing: DesignTokens.Spacing.md) {
                StorageDashboardTile(
                    title: "Wallpapers",
                    systemImage: "photo.stack",
                    accent: DesignTokens.Colors.Gauge.low,
                    subtitle: wallpapersSubtitle
                ) {
                    storageValue(
                        bytes: inventory?.projectsTotalBytes,
                        isLoading: isLoadingInventory && inventory == nil
                    )
                } actions: {
                    if let url = inventory?.projectsRootURL {
                        openFolderIconButton(url, scopeRoot: inventory?.projectsScopeRootURL)
                    }
                    StorageInfoButton {
                        infoNote("Your downloaded Workshop wallpapers, measured where Steam actually keeps them. Deleting a wallpaper from the Installed tab frees exactly this space.")
                    }
                }

                StorageDashboardTile(
                    title: "Engine Assets",
                    systemImage: "shippingbox",
                    accent: DesignTokens.Colors.accent,
                    subtitle: Text("Shared Wallpaper Engine runtime assets")
                ) {
                    storageValue(
                        bytes: inventory?.engineAssetsBytes,
                        isLoading: isLoadingInventory && inventory == nil
                    )
                } actions: {
                    if let url = inventory?.engineAssetsURL {
                        openFolderIconButton(url)
                    }
                    StorageInfoButton {
                        infoNote("Materials, models, and shaders shared by every scene — downloaded once and required by scenes that reference built-in files. Not a cache.")
                    }
                }

                if #available(macOS 26.0, *), systemWallpaperBytes > 0 {
                    StorageDashboardTile(
                        title: "System Wallpaper",
                        systemImage: "macwindow.on.rectangle",
                        accent: DesignTokens.Colors.Gauge.high,
                        subtitle: systemWallpaperSubtitle
                    ) {
                        storageValue(bytes: systemWallpaperBytes, isLoading: false)
                    } actions: {
                        openFolderIconButton(exportService.videosDirectory)
                        StorageInfoButton {
                            infoNote("macOS plays these copies itself, so it needs its own file for each one. Remove a video in Library › System Wallpaper to free its space.")
                        }
                    }
                }

                StorageDashboardTile(
                    title: "Caches",
                    systemImage: "internaldrive",
                    accent: DesignTokens.Colors.Gauge.medium,
                    subtitle: Text("Reclaimable files rebuilt automatically when needed")
                ) {
                    storageValue(bytes: totalBytes, isLoading: isAnyLoading)
                } actions: {
                    Button(role: .destructive) {
                        confirmClearAllCaches()
                    } label: {
                        Image(systemName: "trash")
                    }
                    .buttonStyle(.borderless)
                    .destructiveControlTint()
                    .controlSize(.small)
                    .disabled(totalBytes == 0)
                    .help(Text("Clear All Caches"))
                    .accessibilityLabel(Text("Clear All Caches"))
                    StorageInfoButton {
                        infoNote("Caches are bounded and cleared automatically — use these only to reclaim space now.")
                    }
                }
                .settingsSearchAnchorTarget(.storageCaches)

                StorageDashboardTile(
                    title: "Scene Video Texture Cache",
                    systemImage: "film",
                    accent: DesignTokens.Colors.Gauge.high,
                    subtitle: videoCacheSubtitle
                ) {
                    storageValue(
                        bytes: videoStats?.totalBytes,
                        isLoading: isLoadingVideo
                    )
                } actions: {
                    Button(role: .destructive) {
                        confirmPurgeVideoCache()
                    } label: {
                        Image(systemName: "trash")
                    }
                    .buttonStyle(.borderless)
                    .destructiveControlTint()
                    .controlSize(.small)
                    .disabled((videoStats?.totalBytes ?? 0) == 0)
                    .help(Text("Clear Video Cache"))
                    .accessibilityLabel(Text("Clear Video Cache"))
                    StorageInfoButton {
                        infoNote("Frames extracted from scene videos, reused across launches. Capped at 2 GB — the least-recently-used files are removed first, and orphaned scenes are reclaimed at startup.")
                    }
                }
            }
        } header: {
            SettingsSearchSectionHeader("Storage", anchor: .storageDashboard)
        }
    }

    @ViewBuilder
    private func storageValue(bytes: UInt64?, isLoading: Bool) -> some View {
        if isLoading {
            ProgressView()
                .controlSize(.small)
                .accessibilityLabel(Text("Calculating cache size…"))
        } else {
            Text(byteFormatter.string(fromByteCount: Int64(bytes ?? 0)))
                .font(DesignTokens.Typography.pageTitle)
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
    }

    private var videoCacheSubtitle: Text {
        if let last = lastVideoFreedBytes, last > 0 {
            return Text("Freed \(Int64(last), format: .byteCount(style: .file)).", comment: "WPE video texture cache footer shown after a purge. Placeholder is the freed byte total.")
        }
        return Text("Across \(videoStats?.fileCount ?? 0) extracted video file\((videoStats?.fileCount ?? 0) == 1 ? "" : "s")")
    }

    /// The Workshop tree lives in the user's Steam library, so LaunchServices
    /// refuses a sandboxed `open` on it ("does not have permission to open
    /// 431960"); reveal through Finder inside the library's scope, the same way
    /// the Installed tab does.
    private func openFolder(_ url: URL?, scopeRoot: URL?) {
        guard let url else { return }
        let root = scopeRoot ?? url
        let didStart = root.startAccessingSecurityScopedResource()
        defer { if didStart { root.stopAccessingSecurityScopedResource() } }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    private func openFolderIconButton(_ url: URL, scopeRoot: URL? = nil) -> some View {
        Button { openFolder(url, scopeRoot: scopeRoot) } label: {
            Image(systemName: "folder")
        }
        .buttonStyle(.borderless)
        .help(Text("Open Folder"))
        .accessibilityLabel(Text("Open Folder"))
    }
}
#endif
