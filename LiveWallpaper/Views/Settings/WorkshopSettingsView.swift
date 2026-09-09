#if !LITE_BUILD
import LiveWallpaperCore
import SwiftUI

struct WorkshopSettingsView: View {
    @Environment(SteamCMDDoctorService.self) private var doctorService
    @Environment(WorkshopServices.self) private var workshopServices
    @Environment(WorkshopSetupController.self) private var setupController

    @AppStorage("loomscreen.workshop.blurMatureThumbnails.v1", store: .appScoped()) private var blurMatureThumbnails = true
    @AppStorage("loomscreen.workshop.hidesDownloaded.v1", store: .appScoped()) private var hidesDownloadedInBrowse = false
    /// Stored in GlobalSettings for backup and restore.
    @State private var showsPresetsInBrowse: Bool
    @State private var defaultSort: WorkshopSortMode
    @State private var defaultTimeFrame: WorkshopTimeFrame

    @State private var engineAssets = WPEEngineAssetsLibrary.shared
    @State private var engineInstaller = WPEEngineAssetsInstaller.shared
    @State private var showingExportToast = false
    @Binding private var pendingSearchAnchor: SettingsSearchAnchor?

    init(pendingSearchAnchor: Binding<SettingsSearchAnchor?> = .constant(nil)) {
        _pendingSearchAnchor = pendingSearchAnchor
        let settings = SettingsManager.shared.loadGlobalSettings()
        _showsPresetsInBrowse = State(initialValue: settings.showsWorkshopPresetsInBrowse)
        _defaultSort = State(initialValue: BrowseViewModel.defaultSort(from: settings.workshopDefaultSort))
        _defaultTimeFrame = State(initialValue: BrowseViewModel.defaultTimeFrame(from: settings.workshopDefaultTimeFrame))
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
                            // Defer notification until after SwiftUI reconciliation.
                            Task { @MainActor in
                                NotificationCenter.default.post(
                                    name: .workshopPresetVisibilityDidChange, object: nil
                                )
                            }
                        }
                        .accessibilityLabel(Text("Show presets as wallpapers in Browse"))
                }
                SettingRow(
                    icon: "arrow.up.arrow.down",
                    iconColor: .blue,
                    title: "Default sort"
                ) {
                    Picker("", selection: $defaultSort) {
                        ForEach(Self.defaultSortOptions) { sort in
                            Text(verbatim: sort.title).tag(sort)
                        }
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                    .fixedSize()
                    .onChange(of: defaultSort) { _, newValue in
                        var settings = SettingsManager.shared.loadGlobalSettings()
                        settings.workshopDefaultSort = newValue.rawValue
                        SettingsManager.shared.saveGlobalSettings(settings)
                    }
                    .accessibilityLabel(Text("Default sort"))
                }
                SettingRow(
                    icon: "calendar",
                    iconColor: .orange,
                    title: "Default time frame",
                    subtitle: defaultSort == .mostPopular ? nil : "Requires Most Popular sort."
                ) {
                    Picker("", selection: $defaultTimeFrame) {
                        ForEach(Self.defaultTimeFrameOptions) { timeFrame in
                            Text(verbatim: timeFrame.title).tag(timeFrame)
                        }
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                    .fixedSize()
                    .disabled(defaultSort != .mostPopular)
                    .onChange(of: defaultTimeFrame) { _, newValue in
                        var settings = SettingsManager.shared.loadGlobalSettings()
                        settings.workshopDefaultTimeFrame = newValue.rawValue
                        SettingsManager.shared.saveGlobalSettings(settings)
                    }
                    .accessibilityLabel(Text("Default time frame"))
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
        .task {
            await workshopServices.refreshAPIKeyStatus()
        }
    }

    /// Exclude relevance without a query and the unbounded time range, matching BrowseViewModel.
    private static let defaultSortOptions: [WorkshopSortMode] = WorkshopSortMode.allCases.filter { $0 != .search }
    private static let defaultTimeFrameOptions: [WorkshopTimeFrame] = WorkshopTimeFrame.allCases.filter { $0.days != nil }

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
            // Browsing works without an API key.
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
