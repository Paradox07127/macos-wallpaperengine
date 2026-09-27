import LiveWallpaperCore
import SwiftUI

/// The Saved page: bookmarks and schemes under one tab control. `HomePage`, whose apply path this mirrors,
/// is off the tree while this page shows.
struct SchemesPage: View {
    let router: EditDeskRouter
    let toasts: EditDeskToastCenter
    var bookmarkStore: BookmarkStore = .shared

    @Environment(ScreenManager.self) private var screenManager
    @Environment(\.featureCatalog) private var featureCatalog
    @Environment(EditDeskUndoStack.self) private var undo: EditDeskUndoStack?
    #if !LITE_BUILD
    @Environment(WorkshopSession.self) private var workshopSession: WorkshopSession?
    #endif
    @AppStorage(EditDeskRouter.SavedTab.preferencesKey, store: .appScoped())
    private var tab: EditDeskRouter.SavedTab = .bookmarks
    @State private var applies = HomePage.ApplyQueue()
    @State private var bookmarks: SavedBookmarks?
    /// The window's own content size, which the top bar's budget is measured against.
    @State private var stageSize: CGSize = .zero

    var body: some View {
        ZStack(alignment: .top) {
            VStack(spacing: 0) {
                tabPicker
                switch tab {
                case .bookmarks:
                    if let bookmarks {
                        BookmarksLibraryView(bookmarks: bookmarks, windowWidth: stageSize.width)
                    }
                case .schemes:
                    SchemeLibraryView(apply: { apply(.scheme($0), to: $1) })
                }
            }
            .padding(.top, DesignTokens.EditDesk.Spacing.topBar)
            TopBar(
                page: Binding(get: { router.page }, set: { router.select($0) }),
                workshopAvailable: featureCatalog.isEnabled(.wpeImport),
                windowWidth: stageSize.width,
                status: nil
            )
            if tab == .bookmarks, let bookmarks {
                modals(bookmarks)
            }
        }
        // SCREENS.md measures from the window's top edge; the transparent title bar is part of the top bar.
        .ignoresSafeArea()
        // A card's or the modal's drag is hit-tested against the strip `SavedBookmarkModal` draws.
        .coordinateSpace(name: EditDeskCoordinateSpace.name)
        .onGeometryChange(for: CGSize.self) { $0.size } action: { stageSize = $0 }
        .onAppear {
            if bookmarks == nil {
                bookmarks = makeBookmarks()
            }
        }
        .onChange(of: router.pendingSavedTab, initial: true) {
            if let requested = router.takeSavedTab() {
                tab = requested
            }
        }
    }

    private var tabPicker: some View {
        GlassSegmentedPicker(selection: $tab, values: [.bookmarks, .schemes], shell: .editDesk) { tab, isSelected in
            Text(Self.title(for: tab))
                .font(DesignTokens.EditDesk.Typography.navItem)
                .foregroundStyle(isSelected ? DesignTokens.EditDesk.Colors.textPrimary : DesignTokens.EditDesk.Colors.textCapsule)
        }
        .fixedSize()
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("Saved library tab"))
        .padding(.vertical, DesignTokens.EditDesk.Spacing.s8)
    }

    static func title(for tab: EditDeskRouter.SavedTab) -> LocalizedStringKey {
        switch tab {
        case .bookmarks: "Bookmarks"
        case .schemes: "Schemes"
        }
    }

    @ViewBuilder
    private func modals(_ bookmarks: SavedBookmarks) -> some View {
        SavedBookmarkModal(bookmarks: bookmarks, windowSize: stageSize)
        #if !LITE_BUILD
        if let workshopSession {
            WorkshopModalHost(
                presentedItemID: Binding(get: { bookmarks.presentedWorkshopID }, set: { bookmarks.presentedWorkshopID = $0 }),
                // Empty, so the modal asks Steam for the item rather than showing what was saved with it.
                items: [],
                session: workshopSession,
                toasts: toasts,
                windowSize: stageSize,
                // The Steam wizard is the Workshop page's sheet.
                onConnectSteam: {
                    bookmarks.presentedWorkshopID = nil
                    router.select(.workshop)
                }
            )
        }
        #endif
    }

    private func makeBookmarks() -> SavedBookmarks {
        let displays: @MainActor () -> [ModalActions.Display] = { [screenManager] in
            screenManager.screens.map { ModalActions.Display(id: $0.id, name: $0.name, frame: $0.frame) }
        }
        let applyTo: @MainActor (ApplyIntent, CGDirectDisplayID) -> Void = { intent, id in
            guard let screen = screenManager.screens.first(where: { $0.id == id }) else { return }
            apply(intent, to: screen)
        }
        #if LITE_BUILD
        return SavedBookmarks(store: bookmarkStore, undo: undo, displays: displays, apply: applyTo, applyToAll: applyToAll)
        #else
        return SavedBookmarks(
            store: bookmarkStore, workshopStore: .shared, undo: undo, displays: displays, apply: applyTo,
            applyToAll: applyToAll
        )
        #endif
    }

    /// Takes "All Displays" as one undo step.
    private func applyToAll(_ intent: ApplyIntent, to displayIDs: [CGDirectDisplayID]) {
        let screens = displayIDs.compactMap { id in screenManager.screens.first { $0.id == id } }
        let group = undo?.begin(.applyToAllDisplays, displays: screens)
        for screen in screens {
            apply(intent, to: screen, group: group)
        }
    }

    /// `group`: the recording of an apply to several displays, which announces them once, together.
    private func apply(_ intent: ApplyIntent, to screen: Screen, group: UndoRecording? = nil) {
        applies.run(for: screen.id) { cancellation in
            let router = ApplyRouter(
                manager: screenManager, bookmarks: BookmarkStore.shared, sceneCapable: featureCatalog.isEnabled(.scene)
            )
            let replacesOverlay = if case .scheme = intent {
                true
            } else {
                false
            }
            let recording = group ?? undo?.begin(.applyWallpaper, displays: [screen], includesOverlay: replacesOverlay)
            let report = await router.apply(intent, to: screen, cancellation: cancellation)
            let undoStepID = recording?.settle(screen.id, applied: report.outcome == .applied)
            if group != nil, let undoStepID {
                toasts.post(
                    ApplyOutcome.appliedToAllText(wallpapersOn: screenManager.wallpapersGloballyEnabled), style: .success,
                    undoStepID: undoStepID
                )
            }
            guard !Task.isCancelled, !report.cancelled else { return }
            if report.exitedSpanMode {
                toasts.post(String(localized: "Left span mode", bundle: .appLanguage), style: .info)
            }
            switch report.outcome {
            case .applied:
                // The group's own toast covers this display.
                guard group == nil else { break }
                let text = ApplyOutcome.appliedText(on: screen.name, wallpapersOn: screenManager.wallpapersGloballyEnabled)
                toasts.post(text, style: .success, screenID: screen.id, undoStepID: undoStepID)
            case let .registeredPreset(name):
                toasts.post(ApplyOutcome.registeredPresetText(name), style: .info)
            case let .failed(failure):
                toasts.post(failure.toastText, style: .failure, screenID: screen.id)
            case let .prepareFailed(reason, attemptID):
                // A Pro scene attempt has already raised its failure card, which opens that attempt.
                if attemptID == nil {
                    toasts.post(reason, style: .failure, screenID: screen.id)
                }
            case .importingLibrary:
                break
            }
        }
    }
}
