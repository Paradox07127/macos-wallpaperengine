import LiveWallpaperCore
import SwiftUI

/// The Schemes page: saved display setups. `HomePage`, whose apply path this mirrors, is off the tree while this page shows.
struct SchemesPage: View {
    let router: EditDeskRouter
    let toasts: EditDeskToastCenter

    @Environment(ScreenManager.self) private var screenManager
    @Environment(\.featureCatalog) private var featureCatalog
    @Environment(EditDeskUndoStack.self) private var undo: EditDeskUndoStack?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var applies = HomePage.ApplyQueue()
    @State private var drag = LibraryDragController()
    /// The window's own content size, which the top bar's budget is measured against.
    @State private var stageSize: CGSize = .zero

    var body: some View {
        ZStack(alignment: .top) {
            SchemeLibraryView(drag: drag, apply: { apply($0, to: $1) })
                .padding(.top, DesignTokens.EditDesk.Spacing.topBar)
            TopBar(
                page: Binding(get: { router.page }, set: { router.select($0) }),
                workshopAvailable: featureCatalog.isEnabled(.wpeImport),
                windowWidth: stageSize.width,
                status: nil
            )
            .allowsHitTesting(!interactionLock)
            ZStack(alignment: .top) {
                LibraryDragOverlay(drag: drag, targets: dragTargets, windowWidth: stageSize.width)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        // SCREENS.md measures from the window's top edge; the transparent title bar is part of the top bar.
        .ignoresSafeArea()
        .coordinateSpace(name: EditDeskCoordinateSpace.name)
        .onGeometryChange(for: CGSize.self) { $0.size } action: { stageSize = $0 }
        .onChange(of: reduceMotion, initial: true) { drag.reduceMotion = reduceMotion }
    }

    /// The top bar ignores clicks while a scheme drag runs.
    private var interactionLock: Bool {
        drag.payload != nil
    }

    private var dragTargets: [ModalDisplayTarget] {
        guard drag.payload != nil else { return [] }
        return ModalActions.targets(
            displays: screenManager.screens.map { ModalActions.Display(id: $0.id, name: $0.name, frame: $0.frame) },
            activeOn: [], covers: [:]
        )
    }

    private func apply(_ scheme: ScreenScheme, to screen: Screen) {
        applies.run(for: screen.id) { cancellation in
            let router = ApplyRouter(
                manager: screenManager, bookmarks: BookmarkStore.shared, sceneCapable: featureCatalog.isEnabled(.scene)
            )
            let recording = undo?.begin(.applyWallpaper, displays: [screen], includesOverlay: true)
            let report = await router.apply(.scheme(scheme), to: screen, cancellation: cancellation)
            let undoStepID = recording?.settle(screen.id, applied: report.outcome == .applied)
            guard !Task.isCancelled, !report.cancelled else { return }
            if report.exitedSpanMode {
                toasts.post(String(localized: "Left span mode", bundle: .appLanguage), style: .info)
            }
            switch report.outcome {
            case .applied:
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
