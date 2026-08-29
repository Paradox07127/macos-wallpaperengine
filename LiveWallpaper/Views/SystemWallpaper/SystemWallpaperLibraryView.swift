import ImageIO
import LiveWallpaperCore
import SwiftUI

/// Library › System Wallpaper. Lists the videos handed to macOS, which keep
/// playing with Loomscreen closed.
///
/// The status vocabulary is deliberately narrow: only what our own files prove
/// (the manifest we write, the heartbeat the appex writes back). The page never
/// claims a system-side state it cannot observe.
@available(macOS 26.0, *)
struct SystemWallpaperLibraryView: View {
    @Environment(WallpaperExportService.self) private var service
    @State private var pendingDestructive: PendingDestructive?

    var body: some View {
        DetailPageScaffold(
            header: { header },
            content: { content }
        )
        .confirmDestructive($pendingDestructive)
        .onAppear { service.refresh() }
    }

    // MARK: - Header

    private var header: some View {
        DetailHeaderBar(
            systemImage: "macwindow.on.rectangle",
            title: { Text("System Wallpaper") },
            metadata: { headerMetadata },
            actions: {
                if isFunctional {
                    HStack(spacing: DesignTokens.Spacing.sm) {
                        SystemWallpaperAddMenu()
                        Button("Open Wallpaper Settings") { service.openWallpaperSettings() }
                            .adaptiveGlassButton(.regular, size: .small)
                            .fixedSize()
                    }
                }
            }
        )
    }

    @ViewBuilder
    private var headerMetadata: some View {
        switch service.status {
        case .unsupported:
            Text("Requires macOS 26 or later")
        case .systemIncompatible:
            Text("Not available on this version of macOS")
        case .empty:
            Text("Nothing handed to the system yet")
        case .failed, .publishedNotSelected, .inUse:
            Text("\(Int64(service.items.count)) videos handed to the system")
        }
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        if !isFunctional {
            unavailableState
        } else if service.items.isEmpty {
            // The notice belongs here too: a first import that fails leaves an
            // empty library, and without this the only thing on screen is the
            // "nothing here yet" illustration — the reason it failed never
            // reaches the user.
            VStack(spacing: DesignTokens.Spacing.lg) {
                notice
                emptyState
            }
            .padding(DesignTokens.Spacing.lg)
        } else {
            gallery
        }
    }

    private var gallery: some View {
        ScrollView {
            LazyVStack(spacing: DesignTokens.Spacing.lg) {
                notice
                LazyVGrid(
                    columns: DesignTokens.LibraryGrid.columns,
                    spacing: DesignTokens.LibraryGrid.spacing
                ) {
                    ForEach(service.items) { item in
                        SystemWallpaperTile(
                            item: item,
                            thumbnailURL: service.thumbnailURL(for: item),
                            isInUse: service.isItemInUse(item.id),
                            onRemove: {
                                pendingDestructive = PendingDestructive(
                                    .removeSystemWallpaper(
                                        title: item.title,
                                        isInUse: service.isItemInUse(item.id)
                                    )
                                ) { try? service.remove(itemID: item.id) }
                            }
                        )
                        .transition(.opacity)
                    }
                }
                playbackModeRow
                footnote
            }
            .padding(DesignTokens.Spacing.lg)
            .animation(.easeOut(duration: 0.2), value: service.items)
        }
    }

    /// Flat and in-flow: this is page content, and the app reserves glass for
    /// floating chrome. Only states that need something from the reader get a
    /// row — "playing right now" is already legible on the tile itself.
    @ViewBuilder
    private var notice: some View {
        switch service.status {
        case .failed(let message):
            noticeRow(
                icon: "exclamationmark.triangle.fill",
                tint: DesignTokens.Colors.Status.warning,
                title: Text("Couldn't update System Wallpaper"),
                detail: Text(verbatim: message)
            ) {
                Button("Dismiss") { service.clearLastError() }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .fixedSize()
            }
        case .publishedNotSelected:
            noticeRow(
                icon: "arrow.right.circle.fill",
                tint: .accentColor,
                title: Text("Ready — pick one in System Settings"),
                detail: Text("macOS decides which wallpaper is on screen; Loomscreen only supplies them.")
            ) {
                Button("Open…") { service.openWallpaperSettings() }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .fixedSize()
            }
        case .inUse, .empty, .unsupported, .systemIncompatible:
            EmptyView()
        }
    }

    private func noticeRow<Action: View>(
        icon: String,
        tint: Color,
        title: Text,
        detail: Text,
        @ViewBuilder action: () -> Action
    ) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: DesignTokens.Spacing.md) {
            Image(systemName: icon)
                .foregroundStyle(tint)
            VStack(alignment: .leading, spacing: 2) {
                title.font(.callout.weight(.medium))
                detail
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: DesignTokens.Spacing.sm)
            action()
        }
        .padding(DesignTokens.Spacing.md)
        .background(
            RoundedRectangle(cornerRadius: DesignTokens.Corner.md, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
        .transition(.opacity)
        .animation(.easeOut(duration: 0.2), value: service.status)
    }

    /// One switch for the whole feature rather than per video: the system shows
    /// one wallpaper at a time, and Apple's own videos behave one way for all.
    private var playbackModeRow: some View {
        HStack(alignment: .firstTextBaseline, spacing: DesignTokens.Spacing.md) {
            VStack(alignment: .leading, spacing: 2) {
                Text("On the desktop")
                    .font(.callout.weight(.medium))
                Text("The lock screen plays unless low power or heat slows it. This is what happens after you unlock.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: DesignTokens.Spacing.sm)
            Picker("On the desktop", selection: Binding(
                get: { service.playbackMode },
                set: { service.setPlaybackMode($0) }
            )) {
                Text("Keep playing").tag(SystemWallpaperPlaybackMode.always)
                Text("Ease to a still").tag(SystemWallpaperPlaybackMode.stillOnDesktop)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
        }
        .padding(DesignTokens.Spacing.md)
        .background(
            RoundedRectangle(cornerRadius: DesignTokens.Corner.md, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
    }

    private var footnote: some View {
        VStack(alignment: .leading, spacing: 2) {
            if service.diskUsageBytes > 0 {
                Text("Uses \(ByteCountFormatter.string(fromByteCount: service.diskUsageBytes, countStyle: .file)) on disk — the system needs its own copy of each video.")
            }
            // Not "deleting the app removes them" — trashing an app does not
            // delete its container, so that claim was simply false.
            Text("Removing a video here also deletes the system's copy from disk.")
            if !service.items.isEmpty {
                Button("Remove All from System Wallpaper") {
                    pendingDestructive = PendingDestructive(
                        .clearSystemWallpaperLibrary(
                            itemCount: service.items.count,
                            formattedSize: ByteCountFormatter.string(
                                fromByteCount: service.diskUsageBytes, countStyle: .file
                            )
                        )
                    ) { try? service.clearLibrary() }
                }
                .buttonStyle(.link)
                .padding(.top, DesignTokens.Spacing.xs)
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Empty / unavailable

    private var emptyState: some View {
        IllustratedEmptyState(
            symbol: "macwindow.on.rectangle",
            title: "Let macOS play your wallpaper",
            message: "Videos you hand to the system keep playing with Loomscreen closed, and the lock screen changes too."
        ) {
            SystemWallpaperAddMenu()
        }
    }

    @ViewBuilder
    private var unavailableState: some View {
        switch service.status {
        case .systemIncompatible:
            IllustratedEmptyState(
                symbol: "exclamationmark.triangle",
                title: "Not available on this version of macOS",
                message: "Your other Loomscreen wallpapers are unaffected."
            )
        default:
            IllustratedEmptyState(
                symbol: "macwindow.on.rectangle",
                title: "Requires macOS 26 or later",
                message: "On earlier versions Loomscreen plays wallpapers itself, which needs the app running."
            )
        }
    }

    /// False for the two states where nothing on this page can work, so the
    /// page shows one explanation instead of dead controls.
    private var isFunctional: Bool {
        switch service.status {
        case .unsupported, .systemIncompatible: return false
        default: return true
        }
    }
}

// MARK: - Add menu

/// Adding is a menu, not a picker sheet: a sheet would stack a second list of
/// videos on top of the grid already on screen. Import comes first because it
/// is the only source that works on a fresh install.
@available(macOS 26.0, *)
struct SystemWallpaperAddMenu: View {
    @Environment(WallpaperExportService.self) private var service
    @State private var store = BookmarkStore.shared

    /// Already-published entries are dropped rather than shown disabled: a menu
    /// is a list of things you can do, not a status display.
    private var libraryVideos: [WallpaperBookmark] {
        store.bookmarks.filter {
            guard case .video = $0.content else { return false }
            return !service.isPublished(bookmarkID: $0.id)
        }
    }

    var body: some View {
        Menu {
            Button("Import from Files…", systemImage: "folder.badge.plus") { importFromFiles() }
            if !libraryVideos.isEmpty {
                Section("In your library") {
                    ForEach(libraryVideos) { bookmark in
                        Button {
                            Task { try? await service.publish(bookmark: bookmark) }
                        } label: {
                            Text(verbatim: bookmark.label)
                        }
                    }
                }
            }
            workshopSection
        } label: {
            Image(systemName: "plus")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(Text("Add a video to System Wallpaper"))
        .accessibilityLabel(Text("Add Video"))
    }

    private func importFromFiles() {
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

// MARK: - Workshop source

#if LITE_BUILD
@available(macOS 26.0, *)
extension SystemWallpaperAddMenu {
    @ViewBuilder fileprivate var workshopSection: some View { EmptyView() }
}
#else
@available(macOS 26.0, *)
extension SystemWallpaperAddMenu {
    /// Installed Workshop wallpapers keep their own list, so they are
    /// publishable without being added to Bookmarks first.
    private var workshopVideos: [WPEHistoryEntry] {
        SettingsManager.shared.loadGlobalSettings().recentWPEImports.filter {
            $0.origin.originalType == .video && !(($0.origin.entryFile ?? "").isEmpty)
        }
    }

    @ViewBuilder fileprivate var workshopSection: some View {
        if !workshopVideos.isEmpty {
            Section("Installed from Workshop") {
                ForEach(workshopVideos, id: \.origin.workshopID) { entry in
                    Button {
                        guard let content = WPECachedContentResolver().content(for: entry.origin) else { return }
                        Task { try? await service.publish(content: content, title: entry.origin.title) }
                    } label: {
                        Text(verbatim: entry.origin.title)
                    }
                }
            }
        }
    }
}
#endif

// MARK: - Tile

@available(macOS 26.0, *)
private struct SystemWallpaperTile: View {
    let item: SystemWallpaperManifest.Item
    let thumbnailURL: URL?
    let isInUse: Bool
    let onRemove: () -> Void

    @State private var isHovering = false
    @State private var thumbnail: CGImage?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        preview
            .galleryTileChrome(isHovering: isHovering, reduceMotion: reduceMotion)
        .onHover { isHovering = $0 }
        .contextMenu {
            Button("Remove from System Wallpaper", role: .destructive, action: onRemove)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel)
    }

    private var accessibilityLabel: Text {
        isInUse
            ? Text("\(item.title), on screen now")
            : Text("\(item.title), ready in System Settings")
    }

    private var preview: some View {
        ZStack {
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
        .overlay(alignment: .topTrailing) {
            if isHovering {
                Button(action: onRemove) {
                    Image(systemName: "xmark")
                        .font(.caption2.weight(.semibold))
                        .padding(6)
                }
                .buttonStyle(.plain)
                .floatingGlyphGlass(hovered: isHovering)
                .padding(DesignTokens.Spacing.sm)
                .accessibilityLabel(Text("Remove from System Wallpaper"))
            }
        }
        // The in-use state is still stated once, now inside the band. The
        // caption that used to carry it is gone with it: its other half was the
        // resting state of every tile on the page, so per-card it said nothing.
        // That leaves its catalog key unreferenced — deliberately not deleted.
        .overlay(alignment: .bottom) {
            ThumbnailTitleBand(title: item.title, isHovering: isHovering) {
                if isInUse {
                    ThumbnailPresenceCheck(tint: DesignTokens.Colors.Status.active)
                        .accessibilityLabel(Text("On screen"))
                }
            }
        }
        .task(id: item.addedAt) {
            guard let thumbnailURL else { return }
            thumbnail = await SystemWallpaperThumbnails.image(for: thumbnailURL)
        }
    }
}

/// Tile-sized, already-decoded posters for the System Wallpaper grid.
///
/// The grid used to read the file off-main and then hand the bytes to
/// `NSImage(data:)` on the main actor — which does not decode there either, it
/// defers the pixels to whichever thread first draws the layer — with nothing
/// cached, so scrolling a tile out and back paid for the whole thing again.
///
/// Internal, not private, only so `LocalImageCacheReclaimerTests` can observe
/// the purge; every production reader stays in this file.
enum SystemWallpaperThumbnails {
    /// 220 pt (`LibraryGrid.maximumColumnWidth`) at 2×, with headroom. The tile
    /// is 16:9 and so is the poster, so `scaledToFill` never crops here.
    private static let maxPixelSize = 512

    nonisolated(unsafe) static let cache: NSCache<NSString, CGImageBox> = {
        let cache = NSCache<NSString, CGImageBox>()
        cache.countLimit = 128
        cache.totalCostLimit = 32 * 1024 * 1024
        WPEImageCacheMeter.attach(cache, as: .systemWallpaperLibrary)
        LocalImageCacheRegistry.shared.register(cache)
        return cache
    }()

    final class CGImageBox {
        let image: CGImage
        init(_ image: CGImage) { self.image = image }
    }

    /// Everything — the `stat`, the read, the decode and the cache probe — runs
    /// off the main actor. `NSCache` is internally thread-safe, and doing the
    /// lookup here is what lets the key carry the modification date: keyed by URL
    /// alone, a regenerated thumbnail would keep serving the old pixels for the
    /// rest of the session.
    static func image(for url: URL) async -> CGImage? {
        await Task.detached(priority: .userInitiated) { () -> CGImage? in
            let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate?.timeIntervalSinceReferenceDate ?? 0
            let key = "\(modified)|\(url.absoluteString)" as NSString
            if let cached = cache.object(forKey: key) { return cached.image }

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
                      kCGImageSourceThumbnailMaxPixelSize: maxPixelSize
                  ] as CFDictionary) else {
                return nil
            }
            let box = CGImageBox(decoded)
            let cost = decoded.bytesPerRow * decoded.height
            WPEImageCacheMeter.recordInsert(box, cost: cost, in: .systemWallpaperLibrary)
            cache.setObject(box, forKey: key, cost: cost)
            return decoded
        }.value
    }
}
