#if !LITE_BUILD
import LiveWallpaperCore
import SwiftUI

struct WorkshopSettingsView: View {
    @Environment(SteamCMDDoctorService.self) private var doctorService
    @Environment(WorkshopServices.self) private var workshopServices
    @Environment(WorkshopSetupController.self) private var setupController

    @AppStorage("loomscreen.workshop.blurMatureThumbnails.v1", store: .appScoped()) private var blurMatureThumbnails = true
    @AppStorage("loomscreen.workshop.hidesDownloaded.v1", store: .appScoped()) private var hidesDownloadedInBrowse = false
    /// Backed by `GlobalSettings` (not `@AppStorage`): it needs to survive backup/restore
    /// the same way the rest of `GlobalSettings` does.
    @State private var showsPresetsInBrowse: Bool

    @State private var engineAssets = WPEEngineAssetsLibrary.shared
    @State private var engineInstaller = WPEEngineAssetsInstaller.shared
    @State private var showingExportToast = false
    @Binding private var pendingSearchAnchor: SettingsSearchAnchor?

    init(pendingSearchAnchor: Binding<SettingsSearchAnchor?> = .constant(nil)) {
        _pendingSearchAnchor = pendingSearchAnchor
        _showsPresetsInBrowse = State(initialValue: SettingsManager.shared.loadGlobalSettings().showsWorkshopPresetsInBrowse)
    }

    /// Page overview summarizes readiness; failing steps show their reasons inline.
    var body: some View {
        Form {
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
                    info: "Click a blurred thumbnail to reveal it."
                ) {
                    Toggle("", isOn: $blurMatureThumbnails)
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .accessibilityLabel(Text("Blur mature thumbnails until clicked"))
                }
                SettingRow(
                    icon: "tray.full",
                    iconColor: .indigo,
                    title: "Hide items already in my library"
                ) {
                    Toggle("", isOn: $hidesDownloadedInBrowse)
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .accessibilityLabel(Text("Hide items already in my library when browsing"))
                }
                SettingRow(
                    icon: "square.stack.3d.up.slash",
                    iconColor: .teal,
                    title: "Show presets as wallpapers",
                    info: "Presets are variations of existing wallpapers."
                ) {
                    Toggle("", isOn: $showsPresetsInBrowse)
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .onChange(of: showsPresetsInBrowse) { _, newValue in
                            var settings = SettingsManager.shared.loadGlobalSettings()
                            settings.showsWorkshopPresetsInBrowse = newValue
                            SettingsManager.shared.saveGlobalSettings(settings)
                            // Deferred to the next MainActor turn like the other
                            // settings posts, so it does not fire inside the
                            // SwiftUI reconcile pass that triggered the save.
                            Task { @MainActor in
                                NotificationCenter.default.post(
                                    name: .workshopPresetVisibilityDidChange, object: nil
                                )
                            }
                        }
                        .accessibilityLabel(Text("Show presets as wallpapers in Browse"))
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

    /// Uses the same readiness sources as the setup rows.
    private var facets: [WorkshopSetupFacet] {
        [
            WorkshopSetupFacet(
                key: "steamcmd",
                anchor: .workshopConnection,
                title: "SteamCMD",
                // The controller includes managed installs that have no binding yet.
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
