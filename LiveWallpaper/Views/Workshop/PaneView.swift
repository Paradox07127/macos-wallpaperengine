#if !LITE_BUILD
import LiveWallpaperCore
import SwiftUI

/// Unified Workshop pane: one sidebar entry, two tabs.
struct PaneView: View {
    @Environment(WorkshopServices.self) private var services
    @Environment(SteamCMDDoctorService.self) private var doctor
    @Environment(WorkshopSetupController.self) private var setupController
    @AppStorage("loomscreen.workshop.pane.selectedTab.v1", store: .appScoped()) private var selectedTab: WorkshopPaneTab = .installed
    @AppStorage("loomscreen.workshop.onboarding.shown.v1", store: .appScoped()) private var onboardingShown: Bool = false
    @AppStorage("loomscreen.workshop.privateSessionNotice.shown.v1", store: .appScoped()) private var privateSessionNoticeShown = false

    @State private var folderImport = WorkshopFolderImportCoordinator.shared
    @State private var browseViewModel: BrowseViewModel?
    @State private var isShowingPasteSheet = false
    @State private var isShowingOnboarding = false
    @State private var isShowingKeyEntry = false
    @State private var isShowingInstallConsent = false
    @State private var isShowingSetupAlert = false

    var body: some View {
        DetailPageScaffold {
            tabBody
        }
        .toolbar {
            ToolbarItem(placement: .principal) {
                tabSwitcher
            }
            // Separate items let macOS own toolbar grouping and spacing.
            ToolbarItem(placement: .primaryAction) {
                WorkshopPasteAction(onPaste: { presentPasteFlow() })
            }
            ToolbarItem(placement: .primaryAction) {
                WorkshopSubscriptionSyncAction()
            }
            ToolbarItem(placement: .primaryAction) {
                WorkshopAccountAction()
            }
        }
        // Re-confirm SteamCMD readiness (so the Download button isn't greyed out just because this launch hasn't re-run the probes), then reconcile the library with what's on disk.
        .task {
            await doctor.autoConfirmDownloadReadinessIfNeeded()
            await folderImport.ingestExistingDownloads(using: doctor)
        }
        .onAppear {
            consumePendingDeepLink()
            // The tab is persisted, so a returning user can land on Online
            // without ever changing it.
            presentOnboardingIfNeeded()
        }
        .onChange(of: selectedTab) { _, _ in presentOnboardingIfNeeded() }
        .onReceive(NotificationCenter.default.publisher(for: .openWorkshopPane)) { _ in
            consumePendingDeepLink()
        }
        .sheet(isPresented: $isShowingOnboarding) {
            AppLanguageScope(defaults: .appScoped()) {
                OnboardingSheet(
                    onConfigureOnline: {
                        if !services.hasWebAPIKey { isShowingKeyEntry = true }
                    },
                    onDownloadByLink: { isShowingPasteSheet = true }
                )
            }
        }
        .sheet(isPresented: $isShowingPasteSheet) {
            AppLanguageScope(defaults: .appScoped()) {
                PasteSheet()
            }
        }
        .sheet(isPresented: $isShowingKeyEntry) {
            AppLanguageScope(defaults: .appScoped()) {
                SteamWebAPIKeyEntrySheet(services: services) {
                    Task { await services.refreshAPIKeyStatus() }
                }
            }
        }
        .sheet(isPresented: $isShowingInstallConsent) {
            AppLanguageScope(defaults: .appScoped()) {
                SteamCMDSetupSheet(onConfirmManagedInstall: { setupController.runManagedInstall() })
            }
        }
        // Presented off local state, not off `setupError != nil`: a Binding
        // whose setter clears the error runs on *every* dismissal, including
        // the one SwiftUI performs when "Configure" is tapped — so the error
        // this hands over to Settings was being erased on the way there.
        .onChange(of: setupController.setupError) { _, error in
            isShowingSetupAlert = error != nil
        }
        .alert("Action needed", isPresented: $isShowingSetupAlert) {
            Button("OK") { setupController.setupError = nil }
            // Leaves the error set on purpose: Settings renders it inline next
            // to the step it belongs to.
            Button("Configure") { openWorkshopSettings(anchor: .workshopConnection) }
        } message: {
            Text(verbatim: setupController.setupError ?? "")
        }
    }

    private var tabSwitcher: some View {
        Picker("Workshop tab", selection: $selectedTab) {
            ForEach(WorkshopPaneTab.allCases) { tab in
                Label(tab.title, systemImage: tab.systemImage).tag(tab)
            }
        }
        .pickerStyle(.segmented)
        // Without this a segmented picker renders the label icon-only.
        .labelStyle(.titleAndIcon)
        .fixedSize(horizontal: true, vertical: false)
        .accessibilityLabel(Text("Workshop tab"))
    }

    // MARK: - Tab body

    private var tabBody: some View {
        VStack(spacing: 0) {
            if doctor.username != nil, !privateSessionNoticeShown {
                PrivateSessionNoticeBanner(
                    onConnect: {
                        privateSessionNoticeShown = true
                        openWorkshopSettings(anchor: .workshopConnection)
                    },
                    onDismiss: { privateSessionNoticeShown = true }
                )
            }
            switch selectedTab {
            case .installed:
                InstalledView(
                    onBrowseTag: browseByTag,
                    onBrowseOnline: { selectedTab = .browseOnline },
                    onInstallSteamCMD: { isShowingInstallConsent = true },
                    onOpenWorkshopSettings: { openWorkshopSettings() },
                    isInstallingSteamCMD: isInstallingSteamCMD
                )
            case .browseOnline:
                browseTab
            }
        }
    }

    @ViewBuilder
    private var browseTab: some View {
        if let viewModel = browseViewModel {
            BrowsePane(
                viewModel: viewModel,
                doctor: doctor,
                onRequestKeyEntry: { isShowingKeyEntry = true },
                onDownloadByLink: { presentPasteFlow() }
            )
        } else {
            Color.clear
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .onAppear { browseViewModel = BrowseViewModel(services: services) }
        }
    }

    /// Builds the Browse view-model on demand (the Installed tab may never have
    /// opened Browse) and remembers it for reuse.
    private func resolveBrowseViewModel() -> BrowseViewModel {
        if let existing = browseViewModel { return existing }
        let created = BrowseViewModel(services: services)
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
        // Not plain searchInput+submit: a leftover creator/tag scope would make
        // makeRequest drop the query, so the VM clears the scope first.
        Task { await viewModel.searchFromDeepLink(query) }
    }

    /// Presents browsing onboarding on the first visit; API key setup is optional.
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

    /// The controller's reading, not `installer.status` alone: the install is
    /// not done until the connector has launched the binary, and the pane used
    /// to drop its progress state during that window.
    private var isInstallingSteamCMD: Bool { setupController.isSteamCMDBusy }

    /// `anchor` defaults to the API-key section, where the Installed tab's "Configure" wants to
    /// land. A setup failure passes `.workshopConnection` instead: `.workshopSetup` is the key
    /// section, and with the key moved to the bottom of the page it scrolled past the rows the error was about.
    private func openWorkshopSettings(anchor: SettingsSearchAnchor = .workshopSetup) {
        NotificationCenter.default.post(
            name: .openSettingsSection,
            object: nil,
            userInfo: [
                "destination": SettingsNavigation.workshopSetup.rawValue,
                "anchor": anchor.rawValue
            ]
        )
    }
}

/// One-time notice for users configured before downloads got their own Steam
/// session (they used to share, and sign out, the Steam app's).
private struct PrivateSessionNoticeBanner: View {
    let onConnect: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "person.badge.key")
                .font(.title3)
                .foregroundStyle(DesignTokens.Colors.Status.warning)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text("Steam downloads now sign in separately")
                    .font(.subheadline.weight(.semibold))
                    .fixedSize(horizontal: false, vertical: true)
                Text("Connect the account for Workshop downloads. Steam app sign-in is unaffected.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .accessibilityElement(children: .combine)
            Spacer(minLength: 8)
            Button("Dismiss", action: onDismiss)
                .buttonStyle(.plain)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .controlSize(.small)
            Button(action: onConnect) {
                Label("Connect account", systemImage: "arrow.right")
                    .font(.caption.weight(.semibold))
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .adaptiveGlassSurface(.roundedRectangle(DesignTokens.Corner.md), tint: DesignTokens.Colors.Status.warning)
        .overlay {
            RoundedRectangle(cornerRadius: DesignTokens.Corner.md, style: .continuous)
                .strokeBorder(DesignTokens.Colors.Status.warning.opacity(0.30), lineWidth: 1)
        }
        .padding(.horizontal, 24)
        .padding(.top, 16)
    }
}

enum WorkshopPaneTab: String, CaseIterable, Identifiable {
    case installed
    case browseOnline

    var id: String { rawValue }

    var title: String {
        switch self {
        case .installed:
            return String(localized: "Installed", bundle: .appLanguage, comment: "Workshop pane tab for the locally installed library.")
        case .browseOnline:
            return String(localized: "Workshop", bundle: .appLanguage, comment: "Workshop pane tab for the online Steam Workshop catalog (zh: 创意工坊).")
        }
    }

    var systemImage: String {
        switch self {
        case .installed: "square.grid.2x2"
        case .browseOnline: "cube.transparent.fill"
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

/// Page-level Workshop toolbar action: add an item by URL or ID.
struct WorkshopPasteAction: View {
    let onPaste: () -> Void

    var body: some View {
        Button {
            onPaste()
        } label: {
            Image(systemName: "link.badge.plus")
        }
        .help(Text("Add a Steam Workshop item by URL or ID"))
        .accessibilityLabel(Text("Add from Workshop URL or ID"))
    }
}

/// Page-level Workshop toolbar action: fetch subscribed items missing locally.
struct WorkshopSubscriptionSyncAction: View {
    @State private var showingSubscriptionSync = false

    var body: some View {
        Button {
            showingSubscriptionSync = true
        } label: {
            Image(systemName: "arrow.down.circle")
        }
        .help(Text("Download subscribed wallpapers missing from this Mac"))
        .accessibilityLabel(Text("Sync subscribed wallpapers"))
        .sheet(isPresented: $showingSubscriptionSync) {
            AppLanguageScope(defaults: .appScoped()) {
                SubscriptionSyncSheet()
            }
        }
    }
}

/// Page-level Workshop toolbar action: the Steam account control.
struct WorkshopAccountAction: View {
    @Environment(WorkshopServices.self) private var services
    @Environment(SteamCMDDoctorService.self) private var doctor
    @Environment(WorkshopSetupController.self) private var setupController

    @State private var showingSignIn = false
    @State private var showingAccountMenu = false
    @State private var showingRemoveSessionConfirm = false

    var body: some View {
        accountControl
            .task { await setupController.loadAccounts() }
            .sheet(isPresented: $showingSignIn) {
                AppLanguageScope(defaults: .appScoped()) {
                    SteamSignInSheet { accountName in
                        setupController.adoptSignedInAccount(accountName)
                    }
                }
            }
            .confirmationDialog(
                Text("Remove the saved Steam session?"),
                isPresented: $showingRemoveSessionConfirm,
                titleVisibility: .visible
            ) {
                // No destructive role on the confirm button: the user already
                // pressed a control labelled Remove (rules/ui-design.md).
                Button("Remove") {
                    Task { await doctor.removeSignedInSession() }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Removes this account's Loomscreen download session. Reconnect before downloading again. Steam app sign-in is unaffected.")
            }
    }

    /// An icon, not the Steam avatar: the app never learns the signed-in user's
    /// SteamID64, so a portrait would cost a profile lookup to distinguish one
    /// account from no others.
    @ViewBuilder
    private var accountControl: some View {
        // Gated on having accounts to list, not on a stored username: the name
        // outlives the Steam profile it came from, and a menu with nothing to
        // switch between is a menu that only knows how to sign in.
        if setupController.discoveredAccounts.isEmpty {
            Button {
                showingSignIn = true
            } label: {
                Image(systemName: "person.crop.circle.badge.plus")
            }
            .help(Text("Sign In"))
            .accessibilityLabel(Text("Steam sign-in"))
        } else {
            // Still not a Menu: an AppKit popup ignores its label's
            // `foregroundStyle` and paints the system control colour, which goes
            // invisible over dark chrome (probed 2026-08-31). A real Button with
            // a popover keeps the glyph ours.
            let glyph = doctor.username == nil ? "person.crop.circle.badge.plus" : "person.crop.circle.fill"
            Button {
                showingAccountMenu = true
            } label: {
                Image(systemName: glyph)
            }
            .help(Text(verbatim: setupController.setupError ?? doctor.username ?? ""))
            .accessibilityLabel(Text("Steam account"))
            .popover(isPresented: $showingAccountMenu, arrowEdge: .bottom) {
                accountMenuPopover
            }
        }
    }

    /// A popover rather than a Menu so the control itself can be a real (glass)
    /// Button.
    private var accountMenuPopover: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.xs) {
            steamAccountMenuItems(
                accounts: setupController.discoveredAccounts,
                current: doctor.username,
                onSelect: { account in
                    showingAccountMenu = false
                    setupController.selectAccount(account)
                },
                onSignIn: {
                    showingAccountMenu = false
                    showingSignIn = true
                },
                onRescan: {
                    showingAccountMenu = false
                    Task { await setupController.loadAccounts() }
                },
                onRemoveSession: {
                    showingAccountMenu = false
                    showingRemoveSessionConfirm = true
                }
            )
            .buttonStyle(.borderless)
            .frame(maxWidth: .infinity, alignment: .leading)

            Divider()

            webAPIKeyStatusLine
        }
        .settingsPopoverChrome(width: 240)
    }

    /// Key health and today's request count. Both were a caption in the page
    /// header; they read as connection status, so they live with the account
    /// controls rather than as a glyph wedged into the toolbar.
    private var webAPIKeyStatusLine: some View {
        HStack(spacing: DesignTokens.Spacing.xs) {
            Image(systemName: services.hasWebAPIKey ? "checkmark.seal.fill" : "key.slash")
                .foregroundStyle(services.hasWebAPIKey ? DesignTokens.Colors.Status.active : .secondary)
                .accessibilityHidden(true)
            if services.hasWebAPIKey {
                Text("\(WorkshopRequestCounter.countForToday()) API requests today")
                    .help(Text("Steam doesn't expose remaining quota; this counts only the requests this Mac has issued today."))
            } else {
                Text("Browsing without an API key")
            }
        }
        .font(DesignTokens.Typography.caption)
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

}
#endif
