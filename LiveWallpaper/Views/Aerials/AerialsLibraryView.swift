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
            // Separate items let macOS own toolbar grouping and spacing.
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
        .task {
            if library.isAuthorized && library.assets.isEmpty {
                await library.refresh()
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

    private func scanErrorView(message: String) -> some View {
        LibraryGuideCard(
            icon: "exclamationmark.triangle",
            tint: DesignTokens.Colors.LibraryTint.aerials,
            title: "Couldn't scan Aerials",
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
            message: "Authorize access to downloaded aerials. Original files remain unchanged.",
            actionTitle: library.isScanning ? "Connecting…" : "Connect Library",
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
            message: "Download an aerial in System Settings, then refresh when the download completes.",
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
                title: "No aerials match your search"
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
