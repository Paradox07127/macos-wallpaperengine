import SwiftUI
import AppKit
import LiveWallpaperCore

struct AerialsLibraryView: View {
    @Environment(\.libraryTileSize) private var tileSize
    private let library = AppleAerialsLibrary.shared
    @Environment(ScreenManager.self) private var screenManager
    @State private var searchText: String = ""
    @State private var pendingDestructive: PendingDestructive?


    var body: some View {
        DetailPageScaffold {
            if !library.isAuthorized {
                unauthorizedState
            } else if let err = library.lastScanError, !err.isEmpty, library.assets.isEmpty {
                scanErrorView(message: err)
            } else if library.assets.isEmpty {
                emptyState
            } else {
                galleryWithFilter
            }
        }
        .confirmDestructive($pendingDestructive)
        .toolbar {
            LibraryIdentityToolbarItem(systemImage: "sparkles.tv", title: Text("Apple Aerials"))
            // Nothing to refresh or disconnect until a folder is linked.
            if library.isAuthorized {
                ToolbarItem(placement: .primaryAction) {
                    libraryActions
                }
            }
        }
        .task {
            if library.isAuthorized && library.assets.isEmpty {
                await library.refresh()
            }
        }
    }

    /// The scan spinner rides beside the refresh button rather than inside it:
    /// `GlassIconButton` takes a symbol, not an arbitrary view, and a toolbar
    /// spinner beside the control it belongs to is what Mail does while fetching.
    private var libraryActions: some View {
        HStack(spacing: DesignTokens.Spacing.sm) {
            if library.isScanning {
                ProgressView()
                    .controlSize(.small)
                    .accessibilityLabel(Text("Scanning the Aerials library", comment: "A11y label for the toolbar spinner shown while the Apple Aerials library is being rescanned."))
            }

            Button {
                Task { await library.refresh() }
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .help(Text("Refresh — rescan the Aerials library for new content"))
            .accessibilityLabel(Text("Refresh Aerials library"))
            .disabled(library.isScanning)

            disconnectButton
        }
    }

    private func scanErrorView(message: String) -> some View {
        LibraryGuideCard(
            icon: "exclamationmark.triangle",
            tint: DesignTokens.Colors.LibraryTint.aerials,
            title: "Couldn't scan Aerials",
            message: "We hit a problem while scanning the Apple Aerials library.",
            features: [
                LibraryGuideFeature(icon: "folder.badge.gearshape", text: "macOS may have moved the folder"),
                LibraryGuideFeature(icon: "arrow.triangle.2.circlepath", text: "A download in progress can lock it briefly"),
                LibraryGuideFeature(icon: "checkmark.shield", text: "Nothing on disk was modified"),
            ],
            actionTitle: "Reconnect",
            actionSystemImage: "folder.badge.gearshape",
            secondaryTitle: "Retry",
            secondarySystemImage: "arrow.clockwise",
            errorMessage: message,
            action: {
                library.clearAccess()
            },
            secondaryAction: {
                Task { await library.refresh() }
            }
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// A single destructive action doesn't earn an overflow menu, and the icon
    /// now says what it does — unlink a folder, not dismiss something.
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
        VStack(spacing: 0) {
            LibraryFilterBar(
                searchText: $searchText,
                searchPrompt: "Search aerials",
                resultCount: filteredAssets.count,
                totalCount: library.assets.count
            )
            Divider()
            galleryGrid
        }
    }

    private var filteredAssets: [AerialAsset] {
        let trimmed = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return library.assets }
        return library.assets.filter {
            $0.displayName.localizedCaseInsensitiveContains(trimmed) ||
            ($0.category?.localizedCaseInsensitiveContains(trimmed) ?? false)
        }
    }

    private var unauthorizedState: some View {
        LibraryGuideCard(
            icon: "sparkles.tv",
            tint: DesignTokens.Colors.LibraryTint.aerials,
            title: "Connect Apple Aerials",
            message: "Connect the local Apple Aerials library that contains downloaded aerial videos.",
            features: [
                LibraryGuideFeature(icon: "display.2", text: "Put any downloaded aerial on any display"),
                LibraryGuideFeature(icon: "arrow.triangle.2.circlepath", text: "New aerials show up as macOS downloads them"),
                LibraryGuideFeature(icon: "checkmark.shield", text: "Read-only — the files stay where they are"),
            ],
            actionTitle: library.isScanning ? "Connecting..." : "Connect Library",
            actionSystemImage: "folder.badge.plus",
            isActionInProgress: library.isScanning,
            errorMessage: library.lastScanError,
            action: {
                Task { _ = await library.requestAccess() }
            }
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var emptyState: some View {
        LibraryGuideCard(
            icon: "sparkles.tv",
            tint: DesignTokens.Colors.LibraryTint.aerials,
            title: "No aerials downloaded yet",
            message: "Apple downloads aerial wallpapers on demand. Pick one from System Settings → Wallpaper, then refresh.",
            features: [
                LibraryGuideFeature(icon: "gearshape", text: "Choosing one in System Settings downloads it"),
                LibraryGuideFeature(icon: "arrow.triangle.2.circlepath", text: "It appears here once the download finishes"),
                LibraryGuideFeature(icon: "checkmark.shield", text: "Only fully downloaded aerials are listed"),
            ],
            actionTitle: "Open System Settings",
            actionSystemImage: "gearshape",
            secondaryTitle: "Refresh",
            secondarySystemImage: "arrow.clockwise",
            action: openWallpaperSettings,
            secondaryAction: {
                Task { await library.refresh() }
            }
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private var galleryGrid: some View {
        if filteredAssets.isEmpty {
            IllustratedEmptyState(
                symbol: "magnifyingglass",
                title: "No aerials match your search",
                message: "Try a different keyword, or clear the search field to see every downloaded aerial."
            )
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if library.isScanning {
                        HStack(spacing: 8) {
                            ProgressView()
                                .controlSize(.small)
                            Text("Scanning library…")
                                .font(DesignTokens.Typography.body)
                                .foregroundStyle(.secondary)
                        }
                        .padding(.horizontal, 4)
                    }

                    LazyVGrid(columns: DesignTokens.LibraryGrid.columns(for: tileSize), spacing: DesignTokens.LibraryGrid.spacing) {
                        ForEach(filteredAssets) { asset in
                            ThumbnailCard(
                                asset: asset,
                                screens: screenManager.screens,
                                onApply: { screen in apply(asset, to: screen) },
                                onApplyToAll: { applyToAll(asset) }
                            )
                        }
                    }
                }
                .padding(20)
            }
        }
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

    private func openWallpaperSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.Wallpaper-Settings.extension") {
            NSWorkspace.shared.open(url)
        }
    }
}
