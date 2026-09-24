import LiveWallpaperCore
import SwiftUI

struct AerialsLibraryView: View {
    @Environment(\.libraryTileSize) private var tileSize
    private let library = AppleAerialsLibrary.shared
    @Environment(ScreenManager.self) private var screenManager
    @State private var searchText: String = ""
    @State private var pendingDestructive: PendingDestructive?
    @State private var dragSession = LibraryDragSession()

    var body: some View {
        DetailPageScaffold {
            content
        }
        .confirmDestructive($pendingDestructive)
        .toolbar {
            standaloneToolbar
        }
        .task {
            if library.isAuthorized, library.assets.isEmpty {
                await library.refresh()
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        if library.isAuthorized, !library.assets.isEmpty {
            galleryWithFilter
        } else {
            AerialsSourceStatusCard()
        }
    }

    @ToolbarContentBuilder
    private var standaloneToolbar: some ToolbarContent {
        LibraryIdentityToolbarItem(systemImage: "sparkles.tv", title: Text("Apple Aerials"))
        // Separate toolbar items let macOS own grouping and spacing.
        if library.isAuthorized {
            if library.isScanning {
                ToolbarItem(placement: .primaryAction) {
                    ProgressView()
                        .controlSize(.small)
                        .accessibilityLabel(Text("Scanning the Aerials library", comment: "A11y label for the toolbar spinner shown while the Apple Aerials library is being rescanned."))
                }
            }
            ToolbarItem(placement: .primaryAction) {
                refreshButton
            }
            ToolbarItem(placement: .primaryAction) {
                disconnectButton
            }
        }
    }

    private var refreshButton: some View {
        Button {
            Task { await library.refresh() }
        } label: {
            Image(systemName: "arrow.clockwise")
        }
        .help(Text("Refresh Aerials library"))
        .accessibilityLabel(Text("Refresh Aerials library"))
        .disabled(library.isScanning)
    }

    private var disconnectButton: some View {
        Button(role: .destructive) {
            pendingDestructive = PendingDestructive(.disconnectAerialsLibrary) {
                library.clearAccess()
            }
        } label: {
            Image(systemName: "folder.badge.minus")
                .foregroundStyle(DesignTokens.Colors.Status.danger)
        }
        .help(Text("Disconnect the Apple Aerials library folder"))
        .accessibilityLabel(Text("Disconnect Aerials Library"))
    }

    private var galleryWithFilter: some View {
        let visible = filteredAssets
        return VStack(spacing: 0) {
            LibraryFilterBar(searchText: $searchText, searchPrompt: "Search aerials")
            Divider()
            galleryGrid(visible)
            LibraryStatusBar(summary: statusSummary(shown: visible.count))
        }
    }

    private func statusSummary(shown: Int) -> Text {
        let total = library.assets.count
        return shown == total
            ? Text("\(total) aerials")
            : Text("\(shown) of \(total) shown")
    }

    private var filteredAssets: [AerialAsset] {
        let trimmed = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return library.assets }
        return library.assets.filter {
            $0.displayName.localizedCaseInsensitiveContains(trimmed) ||
                ($0.category?.localizedCaseInsensitiveContains(trimmed) ?? false)
        }
    }

    @ViewBuilder
    private func galleryGrid(_ visible: [AerialAsset]) -> some View {
        if visible.isEmpty {
            IllustratedEmptyState(
                symbol: "magnifyingglass",
                title: "No aerials match your search"
            )
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: DesignTokens.LibraryGrid.spacing) {
                    if library.isScanning {
                        HStack(spacing: DesignTokens.Spacing.sm) {
                            ProgressView()
                                .controlSize(.small)
                            Text("Scanning library…")
                                .font(DesignTokens.Typography.body)
                                .foregroundStyle(.secondary)
                        }
                    }

                    LibraryGalleryGrid(size: tileSize, aspect: .wide) {
                        ForEach(visible) { asset in
                            ThumbnailCard(
                                asset: asset,
                                screens: screenManager.screens,
                                onApply: { screen in apply(asset, to: screen) },
                                onApplyToAll: { applyToAll(asset) }
                            )
                            .onDrag {
                                NSItemProvider(object: dragSession.begin(payload: asset.id) as NSString)
                            } preview: {
                                LibraryDragPreview(systemImage: "sparkles.tv")
                            }
                        }
                    }
                }
                .libraryGridPadding()
            }
            .overlay(alignment: .top) {
                if dragSession.isDragging, !screenManager.screens.isEmpty {
                    dropBar
                }
            }
            .animation(.easeInOut(duration: 0.2), value: dragSession.isDragging)
        }
    }

    private var dropBar: some View {
        LibraryDragApplyBar(
            screens: screenManager.screens,
            onCancel: { dragSession.end() },
            makeDropHandler: { screen in
                { identifier, loadFailed in
                    dragSession.end()
                    guard !loadFailed,
                          let identifier,
                          // Re-read both sides: a rescan and a display change can
                          // both land while the provider read is in flight.
                          let asset = library.assets.first(where: { $0.id == identifier }),
                          let target = screenManager.screens.first(where: { $0.id == screen.id })
                    else { return }
                    apply(asset, to: target)
                }
            }
        )
    }

    // MARK: - Apply

    private func apply(_ asset: AerialAsset, to screen: Screen) {
        guard let url = (try? SecurityScopedBookmarkResolver.shared
            .resolve(asset.bookmarkData, target: .transient).get().url) else {
            Logger.error("Failed to resolve aerial bookmark; user may need to reconnect", category: .fileAccess)
            return
        }
        screenManager.setVideo(url: url, bookmarkData: asset.bookmarkData, for: screen)
    }

    private func applyToAll(_ asset: AerialAsset) {
        for screen in screenManager.screens {
            apply(asset, to: screen)
        }
    }
}
