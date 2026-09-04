import ImageIO
import LiveWallpaperCore
import SwiftUI

/// Library › System Wallpaper. Lists the videos handed to macOS, which keep
/// playing with Loomscreen closed.
/// The status vocabulary is deliberately narrow: only what our own files prove (the manifest
/// we write, the heartbeat the appex writes back) — never a system-side state it can't observe.
@available(macOS 26.0, *)
struct SystemWallpaperLibraryView: View {
    @Environment(\.libraryTileSize) private var tileSize
    @Environment(WallpaperExportService.self) private var service
    @State private var pendingDestructive: PendingDestructive?

    var body: some View {
        DetailPageScaffold { content }
            .confirmDestructive($pendingDestructive)
            .toolbar {
                LibraryIdentityToolbarItem(
                    systemImage: "macwindow.on.rectangle",
                    title: Text("System Wallpaper")
                )
                if isFunctional {
                    ToolbarItem(placement: .primaryAction) {
                        HStack(spacing: DesignTokens.Spacing.sm) {
                            SystemWallpaperAddMenu()
                            // No `adaptiveGlassButton` here: the toolbar section
                            // is already the visible container, and stacking our
                            // own glass on top reads as a button inside a button.
                            //
                            // `gearshape` is the app's own glyph for "this opens
                            // System Settings" — the Aerials guide card's button
                            // uses it for the same destination.
                            Button {
                                service.openWallpaperSettings()
                            } label: {
                                Image(systemName: "gearshape")
                            }
                            .help(Text("Open Wallpaper settings in System Settings"))
                            .accessibilityLabel(Text("Open Wallpaper Settings"))
                        }
                    }
                }
            }
            .onAppear { service.refresh() }
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        if !isFunctional {
            unavailableState
        } else if service.items.isEmpty {
            // The notice belongs here too: a first import that fails leaves an
            // empty library, and without it the reason never reaches the user.
            // Only the notice carries insets — the card's halo must reach the
            // page margins. Gated on `hasNotice`: padding an EmptyView still
            // reserves space.
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
        ScrollView {
            LazyVStack(spacing: DesignTokens.Spacing.lg) {
                notice
                LazyVGrid(
                    columns: DesignTokens.LibraryGrid.columns(for: tileSize),
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
                Button("Open") { service.openWallpaperSettings() }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .fixedSize()
            }
        case .inUse, .empty, .systemIncompatible:
            EmptyView()
        }
    }

    /// Beside `notice` so a case added there fails to compile here too.
    private var hasNotice: Bool {
        switch service.status {
        case .failed, .publishedNotSelected:
            true
        case .inUse, .empty, .systemIncompatible:
            false
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
            GlassSegmentedPicker(
                selection: Binding(
                    get: { service.playbackMode },
                    set: { service.setPlaybackMode($0) }
                ),
                values: [.always, .stillOnDesktop],
                shell: .flat,
                title: { (mode: SystemWallpaperPlaybackMode) in
                    mode == .always ? "Keep playing" : "Ease to a still"
                }
            )
            .frame(width: 230)
            .accessibilityElement(children: .contain)
            .accessibilityLabel(Text("On the desktop"))
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
                Text("Uses \(WorkshopByteFormatter.platformDefault.string(fromByteCount: service.diskUsageBytes)) on disk — the system needs its own copy of each video.")
            }
            // Not "deleting the app removes them" — trashing an app does not
            // delete its container, so that claim was simply false.
            Text("Removing a video here also deletes the system's copy from disk.")
            if !service.items.isEmpty {
                Button("Remove All from System Wallpaper", role: .destructive) {
                    pendingDestructive = PendingDestructive(
                        .clearSystemWallpaperLibrary(
                            itemCount: service.items.count,
                            formattedSize: WorkshopByteFormatter.platformDefault.string(
                                fromByteCount: service.diskUsageBytes
                            )
                        )
                    ) { try? service.clearLibrary() }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .tint(DesignTokens.Colors.Status.danger)
                .padding(.top, DesignTokens.Spacing.xs)
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Empty / unavailable

    /// A labelled button, not the header's "+" menu: on an empty page a bare
    /// glyph never says what it adds, and the picker is the only source that
    /// works on a fresh install anyway — the other sources stay one click away
    /// in the header menu.
    private var emptyState: some View {
        LibraryGuideCard(
            icon: "macwindow.on.rectangle",
            tint: DesignTokens.Colors.LibraryTint.systemWallpaper,
            title: "Let macOS play your wallpaper",
            message: "Hand a video to the system and macOS plays it itself, so it keeps running with Loomscreen closed.",
            features: [
                LibraryGuideFeature(icon: "infinity", text: "Keeps playing with Loomscreen quit"),
                LibraryGuideFeature(icon: "lock", text: "The lock screen changes with it"),
                LibraryGuideFeature(icon: "internaldrive", text: "macOS keeps its own copy of each video"),
            ],
            actionTitle: "Choose Video…",
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
            title: "System Wallpaper is paused on this macOS build",
            message: "Our wallpaper extension checked this build of macOS and found a layout it can't drive, so it stopped handing videos to the system.",
            features: [
                LibraryGuideFeature(icon: "exclamationmark.triangle", text: "The build changed what the extension reads"),
                LibraryGuideFeature(icon: "checkmark.shield", text: "Your other Loomscreen wallpapers are unaffected"),
                LibraryGuideFeature(icon: "arrow.triangle.2.circlepath", text: "Clears itself after a macOS or app update"),
            ]
        )
    }

    private var isFunctional: Bool {
        service.status != .systemIncompatible
    }
}

// MARK: - Add menu

/// Adding is a menu, not a picker sheet: a sheet would stack a second list of
/// videos on top of the grid already on screen. Import comes first because it
/// is the only source that works on a fresh install.
@available(macOS 26.0, *)
struct SystemWallpaperAddMenu: View {
    @State private var showingAddSheet = false

    var body: some View {
        // Labelled, not a bare `plus`: the window toolbar already carries a
        // `plus` for "pick a wallpaper for the selected display", and two
        // identical glyphs in the same slot did different things.
        Button {
            showingAddSheet = true
        } label: {
            Label("Add Video", systemImage: "plus")
        }
        .help(Text("Add a video to System Wallpaper"))
        .accessibilityLabel(Text("Add Video"))
        .sheet(isPresented: $showingAddSheet) {
            AppLanguageScope(defaults: .appScoped()) {
                SystemWallpaperAddSheet()
            }
        }
    }
}

/// Shared by the header menu and the empty state's button, which offer the same
/// picker from two places.
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
            .settledHover { isHovering = $0 }
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
        // Keyed on the entry's own timestamp, not on the URL: a republish
        // rewrites the same `<id>.jpg` path, so the URL never changes and the
        // tile went on drawing the poster it had already loaded.
        .task(id: item.addedAt) {
            guard let thumbnailURL else { return }
            thumbnail = await SystemWallpaperThumbnails.image(for: thumbnailURL)
        }
    }
}

/// Tile-sized, already-decoded posters for the System Wallpaper grid.
/// Used to read the file off-main, then hand bytes to `NSImage(data:)` on the main actor — which
/// doesn't decode there either, deferring pixels to whichever thread first draws the layer — with
/// nothing cached, so scrolling a tile out and back paid for the whole thing again. Internal, not private, only so `LocalImageCacheReclaimerTests` can observe the purge.
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

    /// Everything — `stat`, read, decode, cache probe — runs off the main actor. `NSCache` is
    /// internally thread-safe, and doing the lookup here lets the key carry the modification
    /// date: keyed by URL alone, a regenerated thumbnail would serve old pixels for the rest of the session.
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
