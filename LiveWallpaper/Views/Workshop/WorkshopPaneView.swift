#if !LITE_BUILD
import LiveWallpaperCore
import SwiftUI

/// Unified Workshop pane: one sidebar entry, two tabs.
struct WorkshopPaneView: View {
    @Environment(WorkshopServices.self) private var services
    @Environment(SteamCMDDoctorService.self) private var doctor
    @AppStorage("loomscreen.workshop.pane.selectedTab.v1", store: .appScoped()) private var selectedTab: WorkshopPaneTab = .installed
    @AppStorage("loomscreen.workshop.onboarding.shown.v1", store: .appScoped()) private var onboardingShown: Bool = false

    @State private var folderImport = WorkshopFolderImportCoordinator.shared
    @State private var browseViewModel: WorkshopBrowseViewModel?
    @State private var isShowingPasteSheet = false
    @State private var isShowingOnboarding = false
    @State private var isShowingKeyEntry = false
    @State private var isShowingInstallConsent = false
    @State private var installedCount = 0
    @State private var managedInstaller = SteamCMDManagedInstallCoordinator()
    @State private var steamCMDSetupError: String?

    var body: some View {
        DetailPageScaffold(showsHeader: false, header: { EmptyView() }) {
            tabBody
        }
        .toolbar {
            ToolbarItem(placement: .principal) {
                tabSwitcher
            }
        }
        .overlay(alignment: .bottomTrailing) {
            WorkshopDownloadToastHost()
                .padding(DesignTokens.Spacing.lg)
        }
        // Re-confirm SteamCMD readiness (so the Download button isn't greyed out just because this launch hasn't re-run the probes), then reconcile the library with what's on disk.
        .task {
            await doctor.autoConfirmDownloadReadinessIfNeeded()
            await folderImport.ingestExistingDownloads(using: doctor)
        }
        .onAppear {
            refreshInstalledCount()
            consumePendingDeepLink()
            // The tab is persisted, so a returning user can land on Online
            // without ever changing it.
            presentOnboardingIfNeeded()
        }
        .onChange(of: selectedTab) { _, _ in presentOnboardingIfNeeded() }
        .onReceive(NotificationCenter.default.publisher(for: .wpeHistoryDidChange)) { _ in
            refreshInstalledCount()
        }
        .onReceive(NotificationCenter.default.publisher(for: .openWorkshopPane)) { _ in
            consumePendingDeepLink()
        }
        .sheet(isPresented: $isShowingOnboarding) {
            WorkshopOnboardingSheet(
                onConfigureOnline: {
                    if !services.hasWebAPIKey { isShowingKeyEntry = true }
                },
                onDownloadByLink: { isShowingPasteSheet = true }
            )
        }
        .sheet(isPresented: $isShowingPasteSheet) {
            WorkshopPasteSheet()
        }
        .sheet(isPresented: $isShowingKeyEntry) {
            SteamWebAPIKeyEntrySheet(services: services) {
                Task { await services.refreshAPIKeyStatus() }
            }
        }
        .sheet(isPresented: $isShowingInstallConsent) {
            SteamCMDManagedInstallSheet(onConfirm: runManagedInstall)
        }
        .alert(
            "Action needed",
            isPresented: Binding(
                get: { steamCMDSetupError != nil },
                set: { if !$0 { steamCMDSetupError = nil } }
            )
        ) {
            Button("OK") { steamCMDSetupError = nil }
            Button("Configure") {
                steamCMDSetupError = nil
                openWorkshopSettings()
            }
        } message: {
            Text(verbatim: steamCMDSetupError ?? "")
        }
    }

    private func refreshInstalledCount() {
        installedCount = SettingsManager.shared.loadGlobalSettings().recentWPEImports.count
    }

    private var tabSwitcher: some View {
        Picker("Workshop tab", selection: $selectedTab) {
            ForEach(WorkshopPaneTab.allCases) { tab in
                Text(tab.title).tag(tab)
            }
        }
        .pickerStyle(.segmented)
        .fixedSize(horizontal: true, vertical: false)
        .accessibilityLabel(Text("Workshop tab"))
    }

    // MARK: - Tab body

    @ViewBuilder
    private var tabBody: some View {
        switch selectedTab {
        case .installed:
            WorkshopInstalledView(
                onBrowseTag: browseByTag,
                onBrowseOnline: { selectedTab = .browseOnline },
                onInstallSteamCMD: { isShowingInstallConsent = true },
                onOpenWorkshopSettings: openWorkshopSettings,
                isInstallingSteamCMD: isInstallingSteamCMD,
                paneHeader: makePaneHeader
            )
        case .browseOnline:
            browseTab
        }
    }

    /// Builds the shared pane header so both tabs render an identical one.
    private func makePaneHeader() -> AnyView {
        AnyView(
            WorkshopPaneHeader(
                selectedTab: selectedTab,
                installedCount: installedCount,
                onPaste: { presentPasteFlow() }
            )
        )
    }

    @ViewBuilder
    private var browseTab: some View {
        if let viewModel = browseViewModel {
            WorkshopBrowsePane(
                viewModel: viewModel,
                doctor: doctor,
                onRequestKeyEntry: { isShowingKeyEntry = true },
                onDownloadByLink: { presentPasteFlow() },
                paneHeader: makePaneHeader
            )
        } else {
            Color.clear
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .onAppear { browseViewModel = WorkshopBrowseViewModel(services: services) }
        }
    }

    /// Builds the Browse view-model on demand (the Installed tab may never have
    /// opened Browse) and remembers it for reuse.
    private func resolveBrowseViewModel() -> WorkshopBrowseViewModel {
        if let existing = browseViewModel { return existing }
        let created = WorkshopBrowseViewModel(services: services)
        browseViewModel = created
        return created
    }

    /// Switch to Browse Online scoped to the tapped tag.
    private func browseByTag(_ tag: String) {
        let viewModel = resolveBrowseViewModel()
        selectedTab = .browseOnline
        Task { await viewModel.browseTag(tag) }
    }

    /// Consumes a one-shot deep link: switch to Browse Online and search for the target.
    private func consumePendingDeepLink() {
        guard let query = WorkshopDeepLink.takePendingSearch() else { return }
        let viewModel = resolveBrowseViewModel()
        selectedTab = .browseOnline
        Task {
            viewModel.searchInput = query
            await viewModel.submitSearch()
        }
    }

    /// Browse Online is useless without a Web API key and SteamCMD, and neither
    /// is discoverable on its own — so the setup sheet greets the first visit to
    /// that tab. It used to hang off the paste button, which a user looking for
    /// downloads never presses.
    private func presentOnboardingIfNeeded() {
        guard selectedTab == .browseOnline, !onboardingShown else { return }
        isShowingOnboarding = true
    }

    private func presentPasteFlow() {
        if onboardingShown {
            isShowingPasteSheet = true
        } else {
            isShowingOnboarding = true
        }
    }

    private var isInstallingSteamCMD: Bool {
        switch managedInstaller.status {
        case .installing: return true
        case .idle, .removing, .installed, .failed: return false
        }
    }

    private func runManagedInstall() {
        steamCMDSetupError = nil
        Task {
            switch await managedInstaller.install() {
            case .installed:
                if !(await doctor.autoDetectBinary()) {
                    steamCMDSetupError = String(
                        localized: "SteamCMD was installed but could not be started.",
                        comment: "Workshop setup error after a managed SteamCMD install that will not launch."
                    )
                }
            case .failed(let reason):
                steamCMDSetupError = reason
            case .idle, .installing, .removing:
                break
            }
        }
    }

    private func openWorkshopSettings() {
        NotificationCenter.default.post(
            name: .openSettingsSection,
            object: nil,
            userInfo: [
                "destination": SettingsNavigation.workshopSetup.rawValue,
                "anchor": SettingsSearchAnchor.workshopSetup.rawValue
            ]
        )
    }
}

enum WorkshopPaneTab: String, CaseIterable, Identifiable {
    case installed
    case browseOnline

    var id: String { rawValue }

    var title: String {
        switch self {
        case .installed:
            return String(localized: "Installed", comment: "Workshop pane tab for the locally installed library.")
        case .browseOnline:
            return String(localized: "Workshop", comment: "Workshop pane tab for the online Steam Workshop catalog (zh: 创意工坊).")
        }
    }
}

/// One-shot hand-off for "open Workshop scoped to this item" deep links.
@MainActor
enum WorkshopDeepLink {
    private static var pendingSearch: String?

    static func requestSearch(_ query: String) {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        pendingSearch = trimmed.isEmpty ? nil : trimmed
    }

    /// Read-and-clear the pending target (nil if none).
    static func takePendingSearch() -> String? {
        defer { pendingSearch = nil }
        return pendingSearch
    }
}

// Merged from WorkshopPaneHeader.swift: single consumer, no independent test surface.
/// Shared Workshop header hosted inside each tab's main split column.
struct WorkshopPaneHeader: View {
    let selectedTab: WorkshopPaneTab
    let installedCount: Int
    let onPaste: () -> Void

    @Environment(WorkshopServices.self) private var services

    /// Same `DetailHeaderBar` as Bookmarks and Apple Aerials — this pane used to
    /// hand-roll an identical icon/title/metadata/actions row, so the three
    /// library headers drifted apart on spacing and type.
    var body: some View {
        DetailHeaderBar(
            systemImage: "cube.transparent.fill",
            title: { Text("Steam Workshop") },
            metadata: { headerStatView },
            actions: { headerActions }
        )
    }

    /// On Workshop, prefixes the request count with the API-key status seal so
    /// key health and today's request count read in one place.
    private var headerStatView: some View {
        HStack(spacing: 4) {
            if selectedTab == .browseOnline, services.hasWebAPIKey {
                Image(systemName: "checkmark.seal.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(DesignTokens.Colors.Status.active)
                    .accessibilityHidden(true)
            }
            Text(verbatim: headerStat)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .help(selectedTab == .browseOnline && services.hasWebAPIKey
            ? Text("Steam doesn't expose remaining quota; this counts only the requests this Mac has issued today.")
            : Text(""))
    }

    private var headerStat: String {
        switch selectedTab {
        case .installed:
            return String(localized: "\(installedCount) installed", comment: "Workshop header stat: number of installed wallpapers.")
        case .browseOnline:
            if !services.hasWebAPIKey {
                return String(localized: "API key required", comment: "Workshop header stat when no Steam Web API key is set.")
            }
            return String(localized: "\(WorkshopRequestCounter.countForToday()) API requests today", comment: "Workshop header stat: Steam Web API requests issued today.")
        }
    }

    // Folder import moved to the toolbar's single add button, which routes any
    // picked file or folder — including a Workshop library root — by what it is.
    // Circle glass at `.large`, matching the other pages' header actions.
    private var headerActions: some View {
        Button(action: onPaste) {
            Image(systemName: "link.badge.plus")
        }
        .adaptiveGlassButton(.regular, shape: .circle)
        .controlSize(.large)
        .help(Text("Add a Steam Workshop item by URL or ID"))
        .accessibilityLabel(Text("Add from Workshop URL or ID"))
    }
}
#endif
