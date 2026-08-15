#if !LITE_BUILD
import LiveWallpaperCore
import SwiftUI

struct WorkshopSettingsView: View {
    @Environment(SteamCMDDoctorService.self) private var doctorService
    @Environment(WorkshopServices.self) private var workshopServices

    @AppStorage("loomscreen.workshop.blurMatureThumbnails.v1", store: .appScoped()) private var blurMatureThumbnails = true
    @AppStorage("loomscreen.workshop.hidesDownloaded.v1", store: .appScoped()) private var hidesDownloadedInBrowse = false

    @State private var engineAssets = WPEEngineAssetsLibrary.shared
    @State private var engineInstaller = WPEEngineAssetsInstaller.shared
    @State private var showingExportToast = false
    @Binding private var pendingSearchAnchor: SettingsSearchAnchor?

    init(pendingSearchAnchor: Binding<SettingsSearchAnchor?> = .constant(nil)) {
        _pendingSearchAnchor = pendingSearchAnchor
    }

    /// One page, no pushed screens and no sheets for setup. The three things
    /// Workshop needs are three sections, and the status bar at the top is
    /// where their state is read — which is why no row carries a status seal
    /// next to its title any more.
    var body: some View {
        Form {
            // Plain section, no row-inset override: this is how the Storage
            // page seats its own overview panel, and the two are the same
            // furniture.
            Section {
                WorkshopSetupOverview(facets: facets) { anchor in
                    pendingSearchAnchor = anchor
                }
            }

            WorkshopAPIKeySection(services: workshopServices)

            WorkshopConnectionSetup(showingExportToast: $showingExportToast) {
                SettingsSearchSectionHeader("Steam connection", anchor: .workshopConnection)
            }

            WorkshopEngineAssetsSection {
                pendingSearchAnchor = .workshopConnection
            }

            Section {
                SettingRow(
                    icon: "eye.slash",
                    iconColor: .pink,
                    title: "Blur mature thumbnails",
                    subtitle: "Hide Mature covers in Browse until you click to reveal"
                ) {
                    Toggle("", isOn: $blurMatureThumbnails)
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .accessibilityLabel(Text("Blur mature thumbnails until clicked"))
                }
                SettingRow(
                    icon: "tray.full",
                    iconColor: .indigo,
                    title: "Hide items already in my library",
                    subtitle: "Keep Browse Online focused on wallpapers you don't have yet"
                ) {
                    Toggle("", isOn: $hidesDownloadedInBrowse)
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .accessibilityLabel(Text("Hide items already in my library when browsing"))
                }
            } header: {
                SettingsSearchSectionHeader("Content", anchor: .workshopContent)
            }

            WorkshopBadgeSection()
        }
        .settingsFormChrome()
        .settingsSearchAnchorScroller(
            pendingSearchAnchor: $pendingSearchAnchor,
            anchors: [
                .workshopSetup,
                .workshopConnection,
                .workshopAssets,
                .workshopContent,
                .workshopBadges
            ]
        )
        .overlay(alignment: .bottom) {
            ExportToast(isPresented: $showingExportToast)
                .padding(.bottom, DesignTokens.Spacing.xl)
                .allowsHitTesting(false)
        }
        .overlay(alignment: .bottomTrailing) {
            DownloadToastHost()
                .padding(DesignTokens.Spacing.lg)
        }
        .task {
            await workshopServices.refreshAPIKeyStatus()
        }
    }

    // MARK: - Status bar

    /// Each facet reads exactly what its old title seal read, so moving the
    /// status to the top of the page didn't quietly change what "ready" means.
    private var facets: [WorkshopSetupFacet] {
        [
            WorkshopSetupFacet(
                anchor: .workshopSetup,
                title: "API key",
                state: workshopServices.hasWebAPIKey ? .ready : .notStarted
            ),
            WorkshopSetupFacet(
                anchor: .workshopConnection,
                title: "Steam",
                state: doctorService.connectionStepState
            ),
            WorkshopSetupFacet(
                anchor: .workshopAssets,
                title: "Assets",
                state: engineAssetsState
            )
        ]
    }

    private var engineAssetsState: WorkshopStepState {
        if engineInstaller.updateAvailable { return .attention }
        if engineInstaller.hasManagedInstall || engineAssets.isAuthorized { return .ready }
        return .notStarted
    }
}
#endif
