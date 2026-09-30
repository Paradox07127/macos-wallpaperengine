#if !LITE_BUILD
import LiveWallpaperCore
import SwiftUI

/// SCREENS S8: browse-only Workshop. "Installed" is gone — the wallpaper library owns it now. The
/// long-lived state (browse model, deferred applies, mature reveals, deep links) lives in
/// `WorkshopSession` at the root; this page owns only its sheets.
struct WorkshopPage: View {
    let router: EditDeskRouter
    let session: WorkshopSession
    let toasts: EditDeskToastCenter

    @Environment(WorkshopServices.self) private var services
    @Environment(SteamCMDDoctorService.self) private var doctor
    @Environment(WorkshopSetupController.self) private var setupController
    @Environment(\.featureCatalog) private var featureCatalog
    @Environment(PageGuideSession.self) private var pageGuide: PageGuideSession?

    /// Kept under its original key so a dismissal recorded by earlier builds still counts.
    @AppStorage("loomscreen.workshop.privateSessionNotice.shown.v1", store: .appScoped())
    private var privateSessionNoticeShown = false

    @State private var isShowingWizard = false
    @State private var isShowingPasteSheet = false
    @State private var isShowingKeyEntry = false
    @State private var isShowingInstallConsent = false
    @State private var isShowingSetupAlert = false
    @State private var isShowingSignIn = false
    @State private var isShowingSubscriptionSync = false
    @State private var isShowingRemoveSessionConfirm = false
    @State private var presentedItemID: UInt64?
    /// The window's own content size, which the modal's geometry is measured against.
    @State private var stageSize: CGSize = .zero

    var body: some View {
        ZStack(alignment: .top) {
            BrowsePane(
                viewModel: session.browse,
                doctor: doctor,
                onRequestKeyEntry: { isShowingKeyEntry = true },
                onDownloadByLink: { presentPasteFlow() },
                onOpenItem: { presentedItemID = $0.id },
                matureReveal: session.matureReveal,
                listing: Bindable(session).listing
            )
            .padding(.top, DesignTokens.EditDesk.Spacing.topBar)
            TopBar(
                page: pageBinding,
                workshopAvailable: featureCatalog.isEnabled(.wpeImport),
                windowWidth: stageSize.width,
                status: nil
            ) {
                steamMenu.pageGuideTarget(.steamMenu)
            }
            WorkshopModalHost(
                presentedItemID: $presentedItemID,
                items: modalItems,
                // A like's saved snapshot can be stale; a browse result is what Steam just sent.
                refreshDetailsOnOpen: session.listing == .likes,
                session: session,
                toasts: toasts,
                windowSize: stageSize,
                onConnectSteam: presentWizard
            )
        }
        // SCREENS.md measures from the window's top edge; the transparent title bar is part of the top bar.
        .ignoresSafeArea()
        .onGeometryChange(for: CGSize.self) { $0.size } action: { stageSize = $0 }
        .task { await session.prepareDownloads() }
        .task { await setupController.loadAccounts() }
        .onChange(of: router.pendingOnboardingStep, initial: true) { _, step in
            guard step == .workshop else { return }
            router.pendingOnboardingStep = nil
            presentedItemID = nil
        }
        .onChange(of: pageGuide?.context != nil) { _, shown in
            if shown {
                presentedItemID = nil
            }
        }
        // Before the sheets modifier, so the wizard overlay itself stays enabled.
        .disabled(isShowingWizard)
        .accessibilityHidden(isShowingWizard)
        .modifier(WorkshopPageSheets(page: self))
    }

    /// The grid the modal pages through, in the order the listing on screen shows it.
    private var modalItems: [WorkshopQueryItem] {
        switch session.listing {
        case .results: session.browse.items
        case .likes: WorkshopBookmarkActions.likedItems(browseItems: session.browse.items)
        }
    }

    // MARK: Chrome

    /// Writing `router.page` straight from the pill skips `select`, which records the page to come
    /// back to and turns Workshop away when the SKU does not have it.
    private var pageBinding: Binding<EditDeskRouter.Page> {
        Binding(get: { router.page }, set: { router.select($0) })
    }

    private var steamMenu: some View {
        WorkshopSteamMenu(
            accounts: setupController.discoveredAccounts,
            currentAccount: doctor.username,
            onSelectAccount: { setupController.selectAccount($0) },
            onSignIn: { isShowingSignIn = true },
            onRescan: { Task { await setupController.loadAccounts() } },
            onRemoveSession: { isShowingRemoveSessionConfirm = true },
            onSyncSubscriptions: { isShowingSubscriptionSync = true },
            onDownloadByLink: { presentPasteFlow() },
            onEnterAPIKey: { isShowingKeyEntry = true },
            onInstallSteamCMD: { isShowingInstallConsent = true },
            onLocateSteamCMD: { setupController.autoDetectBinary() },
            onImportLocalFolder: { SteamWizard.importLocalFolder() },
            steamCMDReady: doctor.isBinaryPresumedReady,
            steamCMDBusy: setupController.isSteamCMDBusy,
            showsPrivateSessionNotice: doctor.username != nil && !privateSessionNoticeShown,
            onDismissPrivateSessionNotice: { privateSessionNoticeShown = true }
        )
    }

    // MARK: Sheets

    /// The sheet chain lives in its own modifier: inlined it pushes the body past what the type
    /// checker will finish.
    private struct WorkshopPageSheets: ViewModifier {
        let page: WorkshopPage

        func body(content: Content) -> some View {
            content
                .infoOverlay(isPresented: page.$isShowingWizard) { close in
                    AppLanguageScope(defaults: .appScoped()) {
                        SteamWizard(onDismiss: close)
                    }
                }
                .sheet(isPresented: page.$isShowingPasteSheet) {
                    AppLanguageScope(defaults: .appScoped()) {
                        PasteSheet()
                    }
                }
                .sheet(isPresented: page.$isShowingKeyEntry) {
                    AppLanguageScope(defaults: .appScoped()) {
                        SteamWebAPIKeyEntrySheet(services: page.services) {
                            Task { await page.services.refreshAPIKeyStatus() }
                        }
                    }
                }
                .sheet(isPresented: page.$isShowingSubscriptionSync) {
                    AppLanguageScope(defaults: .appScoped()) {
                        SubscriptionSyncSheet()
                    }
                }
                .sheet(isPresented: page.$isShowingSignIn) {
                    AppLanguageScope(defaults: .appScoped()) {
                        SteamSignInSheet { accountName in
                            page.setupController.adoptSignedInAccount(accountName)
                        }
                    }
                }
                .sheet(isPresented: page.$isShowingInstallConsent) {
                    AppLanguageScope(defaults: .appScoped()) {
                        SteamCMDSetupSheet(onConfirmManagedInstall: { page.setupController.runManagedInstall() })
                    }
                }
                .confirmationDialog(
                    Text("Remove the saved Steam session?"),
                    isPresented: page.$isShowingRemoveSessionConfirm,
                    titleVisibility: .visible
                ) {
                    // No destructive role on the confirm button: the user already pressed a control
                    // labelled Remove (rules/ui-design.md).
                    Button("Remove") {
                        Task { await page.doctor.removeSignedInSession() }
                    }
                    Button("Cancel", role: .cancel) {}
                } message: {
                    Text("Removes this account's Loomscreen download session. Reconnect before downloading again. Steam app sign-in is unaffected.")
                }
                // Presented off local state, not off `setupError != nil`: a Binding whose setter
                // clears the error runs on *every* dismissal, including the one SwiftUI performs
                // when "Configure" is tapped — erasing the error on its way to Settings.
                .onChange(of: page.setupController.setupError) { _, error in
                    page.isShowingSetupAlert = error != nil && !page.isShowingWizard
                }
                .alert("Action needed", isPresented: page.$isShowingSetupAlert) {
                    Button("OK") { page.setupController.setupError = nil }
                    // Leaves the error set on purpose: Settings renders it inline next to the step
                    // it belongs to.
                    Button("Configure") { page.openWorkshopSettings(anchor: .workshopConnection) }
                } message: {
                    Text(verbatim: page.setupController.setupError ?? "")
                }
        }
    }

    // MARK: Actions

    private func presentWizard() {
        isShowingWizard = true
    }

    private func presentPasteFlow() {
        isShowingPasteSheet = true
    }

    /// `anchor` defaults to the API-key section; a setup failure passes `.workshopConnection`.
    private func openWorkshopSettings(anchor: SettingsSearchAnchor = .workshopSetup) {
        NotificationCenter.default.post(
            name: .openSettingsSection,
            object: nil,
            userInfo: [
                "destination": SettingsNavigation.workshopSetup.rawValue,
                "anchor": anchor.rawValue,
            ]
        )
    }
}
#endif
