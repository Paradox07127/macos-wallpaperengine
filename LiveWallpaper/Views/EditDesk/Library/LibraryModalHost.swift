import CoreGraphics
import LiveWallpaperCore
import SwiftUI

/// S4 + S5 over the home page: opens the modal for one library item, keeps the float strip's
/// drop targets, hit-tests the modal's drag against them and applies on release. The modal,
/// strip and ghost only share `EditDeskCoordinateSpace`, which this view's root defines.
struct LibraryModalHost: View {
    let library: SavedLibraryModel
    let stage: EditDeskStageModel
    let thumbnails: ShelfThumbnailCache
    @Binding var presentedItemID: String?
    let apply: @MainActor (ApplyIntent, CGDirectDisplayID) -> Void

    @Environment(ScreenManager.self) private var screenManager
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    #if !LITE_BUILD
    /// Optional: a host mounted without the Workshop services (tests) still opens the modal, minus
    /// update and delete.
    @Environment(SteamCMDDoctorService.self) private var doctor: SteamCMDDoctorService?
    #endif
    @State private var actions: ModalActions?
    @State private var content: WallpaperModalContent?
    @State private var dragPoint: CGPoint?
    @State private var dropTarget: CGDirectDisplayID?
    @State private var targetFrames: [CGDirectDisplayID: CGRect] = [:]
    @State private var shakeTrigger = 0
    @State private var dragEndTask: Task<Void, Never>?
    /// The thumbnail run's visible box; a thumbnail scrolled out of it is not a drop target.
    @State private var runFrame: CGRect?

    /// SCREENS.md S5: the strip rides at top 14 and enters from −130.
    private static let floatTop: CGFloat = 14
    private static let floatHiddenTop: CGFloat = -130

    /// The shelf's order, so ← → walk the same run the user came from.
    private var items: [LibraryItem] {
        library.visibleItems.filter { $0.kind != .aerial }
    }

    /// What the modal is showing right now: the loaded content's item, so a navigation whose
    /// content is still decoding keeps title, preview and actions on the same wallpaper.
    private var presentedItem: LibraryItem? {
        guard let id = content?.itemID ?? presentedItemID else { return nil }
        return library.items.first { $0.id == id }
    }

    private var requestedItem: LibraryItem? {
        guard let presentedItemID else { return nil }
        return library.items.first { $0.id == presentedItemID }
    }

    #if !LITE_BUILD
    /// Changes while a Workshop update runs, so the installed extras in `content` reload.
    private var downloadKey: String {
        guard let item = presentedItem, let id = Self.workshopID(of: item) else { return "" }
        let coordinator = WorkshopDownloadCoordinator.shared
        return "\(coordinator.phase(for: id)) \(coordinator.progress[id] ?? -1)"
    }

    private static func workshopID(of item: LibraryItem) -> UInt64? {
        switch item.source {
        case let .workshop(entry): UInt64(entry.origin.workshopID)
        case let .bookmark(bookmark): bookmark.wpeOrigin.flatMap { UInt64($0.workshopID) }
        case .aerial: nil
        }
    }
    #endif

    var body: some View {
        ZStack(alignment: .top) {
            if let item = presentedItem, let content, let actions {
                let targets = actions.targets(for: item, covers: covers)
                let modalActions = actions.actions(for: item)
                WallpaperModal(
                    content: content,
                    targets: targets,
                    actions: modalActions,
                    navigation: navigation(for: item),
                    windowSize: stage.stageSize,
                    // The whole top bar stays clickable: traffic lights and the window drag region live there.
                    titlebarInset: DesignTokens.EditDesk.Spacing.topBar,
                    onDismiss: dismiss,
                    onDrag: handleDrag
                )
                DisplayFloatLayer(
                    targets: targets,
                    mode: .dropTarget,
                    highlighted: dropTarget,
                    windowWidth: stage.stageSize.width,
                    onSelect: { _ in },
                    onApplyAll: modalActions.applyToAllDisplays,
                    onTargetFrame: { targetFrames[$0.id] = $0.rect },
                    onRunFrame: { runFrame = $0 }
                )
                .padding(.top, Self.floatTop)
                .transition(.offset(y: Self.floatHiddenTop - Self.floatTop).combined(with: .opacity))
                if let dragPoint {
                    ModalDragGhost(image: content.preview, isOverTarget: dropTarget != nil, shakeTrigger: shakeTrigger)
                        .position(dragPoint)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .coordinateSpace(name: EditDeskCoordinateSpace.name)
        .animation(DesignTokens.motion(reduceMotion, .spring(response: 0.45, dampingFraction: 0.82)), value: presentedItemID != nil)
        .onChange(of: presentedItemID, initial: true) { _, id in
            if id == nil {
                content = nil
                clearDrag()
            }
        }
        .task(id: presentedItemID) { await load() }
        .onChange(of: library.items) {
            // The shown item can be removed from under the modal (Remove from Saved, delete): the
            // modal has nothing left to show and the stage must not stay blocked behind it.
            if presentedItemID != nil, presentedItem == nil {
                presentedItemID = nil
            } else {
                Task { await load() }
            }
        }
        #if !LITE_BUILD
        .onChange(of: downloadKey) { Task { await load() } }
        #endif
    }

    // MARK: Content

    private var covers: [CGDirectDisplayID: CGImage] {
        Dictionary(uniqueKeysWithValues: stage.displays.compactMap { display in
            display.cover.map { (display.id, $0) }
        })
    }

    private func makeActions() -> ModalActions {
        #if LITE_BUILD
        ModalActions(library: library, screenManager: screenManager, thumbnails: thumbnails, apply: apply)
        #else
        if let doctor {
            return ModalActions(
                library: library, screenManager: screenManager, thumbnails: thumbnails, doctor: doctor, apply: apply
            )
        }
        return ModalActions(
            inputs: .live(library: library, screenManager: screenManager), bookmarks: .shared,
            thumbnails: thumbnails, apply: apply
        )
        #endif
    }

    private func load() async {
        guard let item = requestedItem else {
            if presentedItemID != nil {
                presentedItemID = nil
            }
            return
        }
        let actions = actions ?? makeActions()
        self.actions = actions
        var loaded = await actions.content(for: item)
        let panel = ModalGeometry.panelFrame(in: stage.stageSize)
        let preview = ModalGeometry.previewSize(inPanel: panel)
        let scale = NSScreen.main?.backingScaleFactor ?? 2
        loaded.preview = await actions.preview(
            for: item, pixelSize: CGSize(width: preview.width * scale, height: preview.height * scale), scale: scale
        )
        // The item can change under a slow preview decode; a stale load must not replace the newer one.
        guard presentedItemID == item.id else { return }
        content = loaded
    }

    private func navigation(for item: LibraryItem) -> ModalNavigation {
        let run = items
        let index = run.firstIndex { $0.id == item.id }
        return ModalNavigation(
            canGoPrevious: index.map { $0 > 0 } ?? false,
            canGoNext: index.map { $0 + 1 < run.count } ?? false,
            previous: {
                if let index, index > 0 {
                    presentedItemID = run[index - 1].id
                }
            },
            next: {
                if let index, index + 1 < run.count {
                    presentedItemID = run[index + 1].id
                }
            }
        )
    }

    private func dismiss() {
        presentedItemID = nil
    }

    // MARK: Drag

    private func handleDrag(_ phase: ModalDragPhase) {
        switch phase {
        case let .began(point):
            dragEndTask?.cancel()
            withAnimation(DesignTokens.motion(reduceMotion, .spring(response: 0.25, dampingFraction: 0.82))) {
                dragPoint = point
            }
            dropTarget = target(at: point)
        case let .moved(point):
            dragPoint = point
            dropTarget = target(at: point)
        case let .ended(point):
            if let target = target(at: point), let item = presentedItem, let actions {
                actions.actions(for: item).applyTo(target)
                clearDrag()
            } else {
                // MOTION 9: a miss shakes the ghost before it goes.
                shakeTrigger += 1
                dragEndTask = Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(320))
                    guard !Task.isCancelled else { return }
                    clearDrag()
                }
            }
        case .cancelled:
            clearDrag()
        }
    }

    private func target(at point: CGPoint) -> CGDirectDisplayID? {
        targetFrames.first { _, rect in
            let visible = runFrame.map { rect.intersection($0) } ?? rect
            return visible.contains(point)
        }?.key
    }

    private func clearDrag() {
        dragEndTask?.cancel()
        dragEndTask = nil
        withAnimation(DesignTokens.motion(reduceMotion, .spring(response: 0.25, dampingFraction: 0.82))) {
            dragPoint = nil
            dropTarget = nil
        }
    }
}
