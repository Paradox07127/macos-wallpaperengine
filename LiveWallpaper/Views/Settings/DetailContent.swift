import LiveWallpaperCore
import SwiftUI

struct SettingsDetailContent: View {
    @Binding var selection: SettingsNavigation?
    @Binding var pendingSearchAnchor: SettingsSearchAnchor?
    @Environment(\.featureCatalog) private var featureCatalog

    var body: some View {
        Group {
            switch selection ?? .general {
            case .general:
                GeneralSettingsView(page: .general)
                    .settingsSearchAnchorScroller(
                        pendingSearchAnchor: $pendingSearchAnchor,
                        anchors: [.generalAppearance, .generalStartup, .generalWallpaper]
                    )
            case .displayDefaults:
                DisplayDefaultsView(pendingSearchAnchor: $pendingSearchAnchor)
            case .systemWallpaper:
                if #available(macOS 26.0, *) {
                    SystemWallpaperSettingsView()
                }
            case .performancePower:
                GeneralSettingsView(page: .performancePower)
                    .settingsSearchAnchorScroller(
                        pendingSearchAnchor: $pendingSearchAnchor,
                        anchors: [.performancePause, .performanceRendering, .performanceMemory]
                    )
            case .integrations:
                GeneralSettingsView(page: .integrations)
                    .settingsSearchAnchorScroller(
                        pendingSearchAnchor: $pendingSearchAnchor,
                        anchors: [.integrationsAudio, .integrationsWeather]
                    )
            case .overlays:
                OverlaysSettingsView()
                    .settingsSearchAnchorScroller(
                        pendingSearchAnchor: $pendingSearchAnchor,
                        anchors: [.overlaysAppearance, .overlaysUnits]
                    )
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
            case .about:
                GeneralSettingsView(page: .about)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(DesignTokens.Colors.pageBackground)
    }
}
