import LiveWallpaperCore
import SwiftUI

/// `HomePage`, whose apply path this mirrors, is off the tree while this page shows.
struct SchemesPage: View {
    let router: EditDeskRouter
    let toasts: EditDeskToastCenter

    @Environment(ScreenManager.self) private var screenManager
    @Environment(\.featureCatalog) private var featureCatalog
    @Environment(EditDeskUndoStack.self) private var undo: EditDeskUndoStack?
    @State private var applies = HomePage.ApplyQueue()
    /// The window's own content size, which the top bar's budget is measured against.
    @State private var stageSize: CGSize = .zero

    var body: some View {
        ZStack(alignment: .top) {
            SchemeLibraryView(apply: apply)
                .padding(.top, DesignTokens.EditDesk.Spacing.topBar)
            TopBar(
                page: Binding(get: { router.page }, set: { router.select($0) }),
                workshopAvailable: featureCatalog.isEnabled(.wpeImport),
                windowWidth: stageSize.width,
                status: nil
            )
        }
        // SCREENS.md measures from the window's top edge; the transparent title bar is part of the top bar.
        .ignoresSafeArea()
        .onGeometryChange(for: CGSize.self) { $0.size } action: { stageSize = $0 }
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
            case let .failed(failure):
                toasts.post(failure.toastText, style: .failure, screenID: screen.id)
            case let .prepareFailed(reason, attemptID):
                // A Pro scene attempt has already raised its failure card, which opens that attempt.
                if attemptID == nil {
                    toasts.post(reason, style: .failure, screenID: screen.id)
                }
            case .registeredPreset, .importingLibrary:
                break
            }
        }
    }
}
