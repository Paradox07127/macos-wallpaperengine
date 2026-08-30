#if !LITE_BUILD
import LiveWallpaperCore
import SwiftUI

struct WorkshopSettingsView: View {
    @Environment(SteamCMDDoctorService.self) private var doctorService
    @Environment(WorkshopServices.self) private var workshopServices
    @Environment(WorkshopSetupController.self) private var setupController

    @AppStorage("loomscreen.workshop.blurMatureThumbnails.v1", store: .appScoped()) private var blurMatureThumbnails = true
    @AppStorage("loomscreen.workshop.hidesDownloaded.v1", store: .appScoped()) private var hidesDownloadedInBrowse = false

    @State private var engineAssets = WPEEngineAssetsLibrary.shared
    @State private var engineInstaller = WPEEngineAssetsInstaller.shared
    @State private var showingExportToast = false
    @Binding private var pendingSearchAnchor: SettingsSearchAnchor?

    init(pendingSearchAnchor: Binding<SettingsSearchAnchor?> = .constant(nil)) {
        _pendingSearchAnchor = pendingSearchAnchor
    }

    /// One page, no pushed screens and no sheets for setup. Each thing
    /// Workshop needs is a section, and the status bar at the top is
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

            WorkshopConnectionSetup()

            WorkshopEngineAssetsSection()

            WorkshopAPIKeySection(services: workshopServices)

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

            WorkshopDiagnosticsSection(showingExportToast: $showingExportToast)

            WorkshopLegalSection()

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
                .workshopDiagnostics,
                .workshopLegal,
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
            // Split out of a single "Steam" segment: SteamCMD and signing in are
            // separate things to go do, and merging them hid which one was
            // outstanding behind one amber bar.
            WorkshopSetupFacet(
                key: "steamcmd",
                anchor: .workshopConnection,
                title: "SteamCMD",
                // The controller's reading, not the doctor's: a managed install
                // in flight has no binding yet, so the bar said "Not set" while
                // the row below it said "Setting up SteamCMD…".
                state: setupController.steamCMDState
            ),
            WorkshopSetupFacet(
                key: "steamSignIn",
                anchor: .workshopConnection,
                title: "Steam sign-in",
                state: doctorService.steamLibraryAndAccountState
            ),
            WorkshopSetupFacet(
                key: "assets",
                anchor: .workshopAssets,
                title: "Scene resources",
                state: engineAssetsState
            ),
            // Last and optional, matching the page order below it: browsing
            // works without a key.
            WorkshopSetupFacet(
                key: "apiKey",
                anchor: .workshopSetup,
                title: "API key",
                state: workshopServices.hasWebAPIKey
                    ? (workshopServices.apiKeyRejected ? .attention : .ready)
                    : .notStarted,
                isOptional: true
            )
        ]
    }

    private var engineAssetsState: WorkshopStepState {
        .engineAssets(library: engineAssets, installer: engineInstaller)
    }
}
#endif
