import AppKit
import ImageIO
import LiveWallpaperCore
import SwiftUI

/// The status vocabulary is deliberately narrow: only what our own files prove — never a
/// system-side state it can't observe.
@available(macOS 26.0, *)
struct SystemWallpaperLibraryView: View {
    var isEmbedded = false
    @Environment(\.libraryTileSize) private var tileSize
    @Environment(WallpaperExportService.self) private var service
    @State private var pendingDestructive: PendingDestructive?
    @State private var searchText = ""

    var body: some View {
        DetailPageScaffold {
            VStack(spacing: 0) {
                if isEmbedded, isFunctional {
                    HStack(spacing: DesignTokens.Spacing.sm) {
                        Label("System Wallpaper", systemImage: "macwindow.on.rectangle")
                            .font(DesignTokens.Typography.sectionTitle)
                        Spacer()
                        SystemWallpaperAddMenu()
                        Button("Open Wallpaper Settings") { service.openWallpaperSettings() }
                    }
                    .buttonStyle(.bordered)
                    .padding(DesignTokens.Spacing.lg)
                }
                content
            }
        }
        .confirmDestructive($pendingDestructive)
        .toolbar {
            if !isEmbedded {
                LibraryIdentityToolbarItem(
                    systemImage: "macwindow.on.rectangle",
                    title: Text("System Wallpaper")
                )
                if isFunctional {
                    ToolbarItem(placement: .primaryAction) {
                        SystemWallpaperAddMenu()
                    }
                    ToolbarItem(placement: .primaryAction) {
                        Button {
                            service.openWallpaperSettings()
                        } label: {
                            Image(systemName: "arrow.up.forward.app")
                        }
                        .help(Text("Open Wallpaper settings in System Settings"))
                        .accessibilityLabel(Text("Open Wallpaper Settings"))
                    }
                }
            }
        }
        .onAppear { service.refresh() }
        .task { service.startObservingSharedRoot() }
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        if !isFunctional {
            unavailableState
        } else if service.items.isEmpty {
            // The notice belongs here too: a first import that fails leaves an
            // empty library, and without it the reason never reaches the user.
            // Gated on `hasNotice`: padding an EmptyView still reserves space.
            VStack(spacing: 0) {
                if hasNotice {
                    notice
                        .padding(DesignTokens.Spacing.lg)
                }
                emptyState
            }
        } else {
            gallery
        }
    }

    private var gallery: some View {
        VStack(spacing: 0) {
            LibraryFilterBar(searchText: $searchText, searchPrompt: "Search videos")
            Divider()
            galleryScroll
            LibraryStatusBar(summary: statusSummary) {
                if service.diskUsageBytes > 0 {
                    Text("Disk usage: \(WorkshopByteFormatter.platformDefault.string(fromByteCount: service.diskUsageBytes))")
                }
            }
        }
    }

    /// Bounded so controls stay adjacent to their labels on wide displays.
    private let maxContentWidth: CGFloat = 560

    private var filteredItems: [SystemWallpaperManifest.Item] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        return query.isEmpty ? service.items : service.items.filter { $0.title.localizedCaseInsensitiveContains(query) }
    }

    private var statusSummary: Text {
        filteredItems.count == service.items.count
            ? Text("\(service.items.count) videos")
            : Text("\(filteredItems.count) of \(service.items.count) shown")
    }

    @ViewBuilder
    private var galleryScroll: some View {
        if filteredItems.isEmpty {
            IllustratedEmptyState(symbol: "magnifyingglass", title: "No videos match your search")
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: DesignTokens.LibraryGrid.spacing) {
                    if hasNotice {
                        notice
                    }
                    LibraryGalleryGrid(size: tileSize, aspect: .wide) {
                        ForEach(filteredItems) { item in
                            SystemWallpaperTile(
                                item: item,
                                thumbnailURL: service.thumbnailURL(for: item),
                                videoURL: service.videoURL(for: item),
                                isInUse: service.isItemInUse(item.id),
                                onRemove: {
                                    pendingDestructive = PendingDestructive(
                                        .removeSystemWallpaper(title: item.title, isInUse: service.isItemInUse(item.id))
                                    ) { try? service.remove(itemID: item.id) }
                                }
                            )
                        }
                    }
                }
                .libraryGridPadding()
            }
        }
    }

    @ViewBuilder
    private var notice: some View {
        switch service.status {
        case let .failed(message):
            InlineNoticeBanner(
                tint: DesignTokens.Colors.Status.warning,
                symbol: "exclamationmark.triangle.fill",
                title: Text("Couldn't update System Wallpaper"),
                message: Text(verbatim: message),
                surface: .content
            ) {
                Button("Dismiss") { service.clearLastError() }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }
            .frame(maxWidth: maxContentWidth, alignment: .leading)
            .transition(.opacity)
            .animation(.easeOut(duration: 0.2), value: service.status)
        case .publishedNotSelected, .inUse, .empty, .systemIncompatible:
            EmptyView()
        }
    }

    /// Beside `notice` so a case added there fails to compile here too.
    private var hasNotice: Bool {
        switch service.status {
        case .failed:
            true
        case .publishedNotSelected, .inUse, .empty, .systemIncompatible:
            false
        }
    }

    // MARK: - Empty / unavailable

    private var emptyState: some View {
        LibraryGuideCard(
            icon: "macwindow.on.rectangle",
            tint: DesignTokens.Colors.LibraryTint.systemWallpaper,
            title: "Let macOS play your wallpaper",
            message: "macOS keeps a copy for the desktop and lock screen, and can play it with Loomscreen closed.",
            actionTitle: "Choose Video",
            actionSystemImage: "video.badge.plus",
            action: {
                SystemWallpaperVideoImport.present(publishingInto: service)
            }
        )
    }

    /// No action button: `barsPublishing` clears on a new OS build or a newer
    /// layout check, neither of which anything on this page can bring about.
    private var unavailableState: some View {
        LibraryGuideCard(
            icon: "exclamationmark.triangle",
            tint: DesignTokens.Colors.LibraryTint.systemWallpaper,
            title: "System Wallpaper is unavailable on this macOS version",
            message: "Other wallpaper features are unaffected. Try again after updating macOS or Loomscreen."
        )
    }

    private var isFunctional: Bool {
        service.status != .systemIncompatible
    }
}

// MARK: - Add menu

@available(macOS 26.0, *)
struct SystemWallpaperAddMenu: View {
    @State private var showingAddSheet = false

    var body: some View {
        Button {
            showingAddSheet = true
        } label: {
            Label("Add Video", systemImage: "plus")
        }
        .accessibilityLabel(Text("Add Video"))
        .sheet(isPresented: $showingAddSheet) {
            AppLanguageScope(defaults: .appScoped()) {
                SystemWallpaperAddSheet()
            }
        }
    }
}

@available(macOS 26.0, *)
enum SystemWallpaperVideoImport {
    @MainActor
    static func present(publishingInto service: WallpaperExportService) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = ResourceUtilities.supportedVideoContentTypes
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.prompt = L10n.Panel.addVideos
        guard panel.runModal() == .OK else { return }
        let urls = panel.urls
        Task { await service.publish(fileURLs: urls) }
    }
}

// MARK: - Tile

@available(macOS 26.0, *)
struct SystemWallpaperTile: View {
    let item: SystemWallpaperManifest.Item
    let thumbnailURL: URL?
    let videoURL: URL?
    let isInUse: Bool
    let onRemove: () -> Void

    @State private var isHovering = false
    @State private var thumbnail: CGImage?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        preview
            .overlay(alignment: .bottom) {
                ThumbnailTitleBand(title: item.title, isHovering: isHovering) {
                    if isInUse {
                        ThumbnailPresenceCheck(tint: DesignTokens.Colors.Status.active)
                            .accessibilityLabel(Text("Selected by macOS"))
                    }
                    overflowButton
                }
            }
            .galleryTileChrome(isHovering: isHovering, reduceMotion: reduceMotion)
            .settledHover { isHovering = $0 }
            .contextMenu {
                if let videoURL {
                    Button("Show in Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting([videoURL])
                    }
                    Divider()
                }
                Button("Remove from System Wallpaper", role: .destructive, action: onRemove)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel(accessibilityLabel)
    }

    private var overflowButton: some View {
        LibraryTileOverflowButton { dismiss in
            if let videoURL {
                Button("Show in Finder") {
                    dismiss()
                    NSWorkspace.shared.activateFileViewerSelecting([videoURL])
                }
                Divider()
            }
            Button("Remove from System Wallpaper", role: .destructive) {
                dismiss()
                onRemove()
            }
            .destructiveControlTint()
        }
    }

    private var accessibilityLabel: Text {
        isInUse
            ? Text("\(item.title), selected by macOS")
            : Text("\(item.title), ready in System Settings")
    }

    private var preview: some View {
        // Artwork must not contribute its intrinsic aspect ratio to the grid's layout.
        Rectangle()
            .fill(Color.secondary.opacity(0.12))
            .overlay {
                if let thumbnail {
                    Image(decorative: thumbnail, scale: 1)
                        .resizable()
                        .scaledToFill()
                } else {
                    Image(systemName: "film")
                        .font(.title)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity)
            .aspectRatio(16.0 / 9.0, contentMode: .fit)
            .clipped()
            // Keyed on the entry's own timestamp, not on the URL: a republish rewrites the same
            // `<id>.jpg` path, so the URL never changes and the tile would keep its stale poster.
            .tileTask(id: item.addedAt) {
                thumbnail = nil
                guard let thumbnailURL else { return }
                let loaded = await SystemWallpaperThumbnails.image(for: thumbnailURL)
                guard !Task.isCancelled else { return }
                thumbnail = loaded
            }
    }
}

/// Internal visibility lets cache-reclaimer tests observe purges.
enum SystemWallpaperThumbnails {
    /// Bound eager decoding independently of the source aspect ratio. The tile
    /// keeps its own 16:9 geometry and crops non-wide posters with scaledToFill.
    private static let maxPixelSize = 512

    nonisolated(unsafe) static let cache: NSCache<NSString, CGImageBox> = { // NSCache is thread-safe; the box is immutable.
        let cache = NSCache<NSString, CGImageBox>()
        cache.countLimit = 128
        cache.totalCostLimit = 32 * 1024 * 1024
        WPEImageCacheMeter.attach(cache, as: .systemWallpaperLibrary)
        LocalImageCacheRegistry.shared.register(cache)
        return cache
    }()

    final class CGImageBox {
        let image: CGImage
        init(_ image: CGImage) {
            self.image = image
        }
    }

    /// The cache key carries the modification date: keyed by URL alone, a regenerated
    /// thumbnail would serve old pixels for the rest of the session.
    static func image(for url: URL) async -> CGImage? {
        await PreviewWorkGate.shared.runDetached { () -> CGImage? in
            let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate?.timeIntervalSinceReferenceDate ?? 0
            let key = "\(modified)|\(url.absoluteString)" as NSString
            if let cached = cache.object(forKey: key) {
                return cached.image
            }

            guard let data = try? Data(contentsOf: url),
                  let source = CGImageSourceCreateWithData(
                      data as CFData,
                      [kCGImageSourceShouldCache: false] as CFDictionary
                  ),
                  let decoded = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                      kCGImageSourceShouldCache: false,
                      kCGImageSourceCreateThumbnailFromImageAlways: true,
                      kCGImageSourceCreateThumbnailWithTransform: true,
                      // Produce the pixels here, on this background thread,
                      // rather than lazily on the thread that draws the layer.
                      kCGImageSourceShouldCacheImmediately: true,
                      kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
                  ] as CFDictionary) else {
                return nil
            }
            // A completed decode remains reusable even if its tile just left the viewport.
            // Cancellation still withdraws queued work and prevents publishing to that tile.
            let box = CGImageBox(decoded)
            let cost = decoded.bytesPerRow * decoded.height
            WPEImageCacheMeter.recordInsert(box, cost: cost, in: .systemWallpaperLibrary)
            cache.setObject(box, forKey: key, cost: cost)
            return decoded
        }
    }
}
