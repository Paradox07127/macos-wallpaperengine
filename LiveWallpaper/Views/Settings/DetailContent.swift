import LiveWallpaperCore
import SwiftUI

struct SettingsDetailContent: View {
    @Binding var selection: SettingsNavigation?
    @Binding var pendingSearchAnchor: SettingsSearchAnchor?
    /// The sidebar's search text; empty when the sidebar is not searching.
    var searchText = ""
    /// The sidebar's count of picked search results.
    var searchRequest = 0
    @Environment(\.featureCatalog) private var featureCatalog

    var body: some View {
        Group {
            switch selection ?? .general {
            case .general:
                GeneralSettingsView(page: .general)
                    .settingsSearchAnchorScroller(page: .general, pendingSearchAnchor: $pendingSearchAnchor)
            case .displayDefaults:
                DisplayDefaultsView(pendingSearchAnchor: $pendingSearchAnchor)
            case .systemWallpaper:
                if #available(macOS 26.0, *) {
                    SystemWallpaperSettingsView()
                        .settingsSearchAnchorScroller(page: .systemWallpaper, pendingSearchAnchor: $pendingSearchAnchor)
                }
            case .performancePower:
                GeneralSettingsView(page: .performancePower)
                    .settingsSearchAnchorScroller(page: .performancePower, pendingSearchAnchor: $pendingSearchAnchor)
            case .integrations:
                GeneralSettingsView(page: .integrations)
                    .settingsSearchAnchorScroller(page: .integrations, pendingSearchAnchor: $pendingSearchAnchor)
            case .overlays:
                OverlaysSettingsView()
                    .settingsSearchAnchorScroller(page: .overlays, pendingSearchAnchor: $pendingSearchAnchor)
            case .shortcuts:
                ShortcutsView(pendingSearchAnchor: $pendingSearchAnchor)
            case .storage:
                #if !LITE_BUILD
                if featureCatalog.isEnabled(.wpeImport) {
                    WPECacheManagementView(pendingSearchAnchor: $pendingSearchAnchor)
                } else {
                    GeneralSettingsView(page: .general)
                }
                #else
                GeneralSettingsView(page: .general)
                #endif
            case .backupRestore:
                GeneralSettingsView(page: .backupRestore)
                    .settingsSearchAnchorScroller(page: .backupRestore, pendingSearchAnchor: $pendingSearchAnchor)
            case .workshopSetup:
                #if !LITE_BUILD
                if featureCatalog.isEnabled(.workshopOnline) {
                    WorkshopSettingsView(pendingSearchAnchor: $pendingSearchAnchor)
                } else {
                    GeneralSettingsView(page: .general)
                }
                #else
                GeneralSettingsView(page: .general)
                #endif
            case .advanced:
                GeneralSettingsView(page: .advanced)
                    .settingsSearchAnchorScroller(page: .advanced, pendingSearchAnchor: $pendingSearchAnchor)
            case .about:
                GeneralSettingsView(page: .about)
                    .settingsSearchAnchorScroller(page: .about, pendingSearchAnchor: $pendingSearchAnchor)
            }
        }
        .environment(\.settingsSearchQuery, searchText)
        .environment(\.settingsSearchRequest, searchRequest)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentColumnBackground()
    }
}
