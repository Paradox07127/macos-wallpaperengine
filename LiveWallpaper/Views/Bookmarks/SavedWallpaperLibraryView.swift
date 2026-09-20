#if !LITE_BUILD
import LiveWallpaperCore
import SwiftUI

struct SavedWallpaperLibraryView: View {
    @Environment(ScreenManager.self) private var screenManager
    @Environment(SteamCMDDoctorService.self) private var doctor
    @Environment(\.libraryTileSize) private var tileSize
    @State private var library = LocalWallpaperLibrary()
    @State private var searchText = ""
    @State private var selectedType: WallpaperType?
    @State private var scanGeneration = 0
    @State private var selectedEntry: WPEHistoryEntry?
    @AppStorage(SavedLibrarySortOrder.preferencesKey, store: .appScoped())
    private var sortOrder: SavedLibrarySortOrder = .recent

    var body: some View {
        DetailPageScaffold {
            VStack(spacing: 0) {
                LibraryFilterBar(searchText: $searchText, searchPrompt: "Search library") {
                    HStack {
                        FilterChip(title: Text("All"), isSelected: selectedType == nil) { selectedType = nil }
                        ForEach(WallpaperType.allCases) { type in
                            FilterChip(title: Text(type.titleKey), isSelected: selectedType == type) { selectedType = type }
                        }
                        Spacer(minLength: 0)
                        Button { scanGeneration += 1 } label: { Image(systemName: "arrow.clockwise") }
                            .disabled(library.isScanning)
                            .accessibilityLabel(Text("Refresh local wallpapers"))
                        SavedLibrarySortPicker(selection: $sortOrder)
                    }
                }
                Divider()
                ScrollView {
                    localSection
                    Divider()
                    WorkshopBookmarkGallery(bookmarks: workshopBookmarks)
                }
            }
        }
        .modifier(WorkshopBookmarkErrorModifier())
        .confirmationDialog(
            Text("Apply"),
            isPresented: Binding(
                get: { selectedEntry != nil },
                set: {
                    if !$0 {
                        selectedEntry = nil
                    }
                }
            ),
            presenting: selectedEntry
        ) { entry in
            ForEach(screenManager.screens, id: \.id) { screen in
                Button("Apply to \(screen.name)") {
                    Task { await screenManager.activateWPEHistoryEntry(entry, for: screen) }
                }
            }
            Button("Cancel", role: .cancel) { selectedEntry = nil }
        }
        .task(id: scanGeneration) { await library.reload(using: doctor) }
        .onReceive(NotificationCenter.default.publisher(for: .wpeHistoryDidChange)) { _ in
            scanGeneration += 1
        }
    }

    private var localSection: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.sm) {
            Text("Local Wallpapers").font(DesignTokens.Typography.sectionTitle)
            if library.isScanning {
                ProgressView().controlSize(.small)
            }
            if library.unreadableCount > 0 {
                Text("Some local wallpaper folders could not be read.")
                    .font(DesignTokens.Typography.caption)
                    .foregroundStyle(.secondary)
            }
            if localEntries.isEmpty, !library.isScanning {
                Text("No local wallpapers to show.")
                    .font(DesignTokens.Typography.caption)
                    .foregroundStyle(.secondary)
            }
            LibraryGalleryGrid(size: tileSize, aspect: .wide) {
                ForEach(localEntries) { entry in
                    HistoryRow(
                        entry: entry, previewURL: WPEPreviewURLCache.shared.url(for: entry.origin),
                        isActive: screenManager.screens.contains {
                            screenManager.getConfiguration(for: $0)?.wpeOrigin?.workshopID == entry.id
                        },
                        allowsInlineApply: true, screens: screenManager.screens,
                        onApply: { screen in
                            Task { await screenManager.activateWPEHistoryEntry(entry, for: screen) }
                        },
                        onApplyToAll: {
                            Task {
                                for screen in screenManager.screens {
                                    await screenManager.activateWPEHistoryEntry(entry, for: screen)
                                }
                            }
                        },
                        onTap: { selectedEntry = entry }
                    )
                }
            }
        }
        .libraryGridPadding()
    }

    private func matches(_ title: String, type: WallpaperType?) -> Bool {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        return (selectedType == nil || selectedType == type)
            && (query.isEmpty || title.localizedCaseInsensitiveContains(query))
    }

    private var localEntries: [WPEHistoryEntry] {
        sortOrder.sorted(
            library.entries.filter { matches($0.origin.title, type: $0.localWallpaperType) },
            name: { $0.origin.title }, date: \.importedAt, type: \.localWallpaperType
        )
    }

    private var workshopBookmarks: [WorkshopBookmark] {
        WorkshopBookmarkStore.shared.bookmarks
            .filter { matches($0.title, type: $0.wallpaperType) }
            .sorted { lhs, rhs in
                if sortOrder == .recent {
                    return lhs.createdAt > rhs.createdAt
                }
                if sortOrder == .type, lhs.wallpaperType != rhs.wallpaperType {
                    return (lhs.wallpaperType?.rawValue ?? "") < (rhs.wallpaperType?.rawValue ?? "")
                }
                return lhs.title.localizedStandardCompare(rhs.title) == .orderedAscending
            }
    }
}
#endif
