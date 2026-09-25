import CoreGraphics
import LiveWallpaperCore
import SwiftUI

/// S4 + S5 over the home page: opens the modal for one library item, keeps the float strip's
/// drop targets, hit-tests the modal's drag against them and applies on release. The modal,
/// strip and ghost only share `EditDeskCoordinateSpace`, which this view's root defines.
struct LibraryModalHost: View {
    let library: SavedLibraryModel
    let stage: EditDeskStageModel
    /// Shared with the home page's context menus, whose rows the modal draws as title-row buttons.
    let actions: ModalActions
    /// Open the home page's rename alert and delete confirmation for an item, the ones its context menus open.
    let requestRename: @MainActor (LibraryItem) -> Void
    let requestDelete: @MainActor (LibraryItem) -> Void
    @Binding var presentedItemID: String?
    /// The display the modal's first apply button targets; nil keeps the leftmost display there.
    var preferredTarget: CGDirectDisplayID?
    /// Displays with an apply still preparing.
    var applying: Set<CGDirectDisplayID> = []

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var content: WallpaperModalContent?
    @State private var dragPoint: CGPoint?
    @State private var dropTarget: ModalDropTarget?
    @State private var targetFrames: [CGDirectDisplayID: CGRect] = [:]
    @State private var applyAllFrame: CGRect?
    @State private var shakeTrigger = 0
    @State private var dragEndTask: Task<Void, Never>?
    /// The thumbnail run's visible box; a thumbnail scrolled out of it is not a drop target.
    @State private var runFrame: CGRect?
    #if !LITE_BUILD
    @Environment(WorkshopServices.self) private var services: WorkshopServices?
    /// What Steam answered per Workshop ID this session, so paging back and reloads ask it once.
    @State private var steamLookups: [UInt64: SteamLookup] = [:]
    #endif

    /// SCREENS.md S5: the strip enters from −130 above its resting top.
    private static let floatHiddenTop: CGFloat = -130

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
    /// Changes while a Workshop update runs or the daily check flags the item, so the installed extras in `content` reload.
    private var downloadKey: String {
        presentedItem.map(actions.installedStateKey) ?? ""
    }
    #endif

    var body: some View {
        ZStack(alignment: .top) {
            if let item = presentedItem, let content {
                let targets = actions.targets(for: item, covers: covers, preferred: preferredTarget).map { target in
                    var target = target
                    target.isPreparing = applying.contains(target.id)
                    return target
                }
                modal(for: item, content: content, targets: targets)
                if dragPoint != nil {
                    DisplayFloatLayer(
                        targets: targets,
                        mode: .dropTarget,
                        highlighted: highlightedDisplay,
                        windowWidth: stage.stageSize.width,
                        onSelect: { _ in },
                        onTargetFrame: { targetFrames[$0.id] = $0.rect },
                        onRunFrame: { runFrame = $0 },
                        applyAllHighlighted: dropTarget == .allDisplays,
                        onApplyAllFrame: { applyAllFrame = $0 }
                    )
                    .padding(.top, FloatLayerGeometry.panelTop)
                    .transition(.offset(y: Self.floatHiddenTop - FloatLayerGeometry.panelTop).combined(with: .opacity))
                }
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
            // The shown item can be removed from under the modal (Remove from Wallpaper Library, delete): the
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

    private func modal(for item: LibraryItem, content: WallpaperModalContent, targets: [ModalDisplayTarget]) -> WallpaperModal {
        var modal = WallpaperModal(
            content: content,
            targets: targets,
            actions: actions.actions(for: item),
            requestRename: { requestRename(item) },
            requestDelete: { requestDelete(item) },
            navigation: navigation(for: item),
            windowSize: stage.stageSize,
            // The whole top bar stays clickable: traffic lights and the window drag region live there.
            titlebarInset: DesignTokens.EditDesk.Spacing.topBar,
            onDismiss: dismiss,
            onDrag: handleDrag
        )
        #if !LITE_BUILD
        // Read during `body`, so every byte count the coordinator publishes redraws the status line.
        modal.downloadStatus = actions.downloadStatus(for: item)
        #endif
        return modal
    }

    private func load() async {
        guard let item = requestedItem else {
            if presentedItemID != nil {
                presentedItemID = nil
            }
            return
        }
        var loaded = await actions.content(for: item)
        let preview = ModalGeometry.previewSize
        let scale = NSScreen.main?.backingScaleFactor ?? 2
        loaded.preview = await actions.preview(
            for: item, pixelSize: CGSize(width: preview.width * scale, height: preview.height * scale), scale: scale
        )
        // The item can change under a slow preview decode; a stale load must not replace the newer one.
        guard presentedItemID == item.id else { return }
        #if !LITE_BUILD
        if let id = loaded.workshopID, let known = steamLookups[id] {
            Self.apply(known, to: &loaded)
        }
        #endif
        content = loaded
        #if !LITE_BUILD
        // A first open draws the local rows, then Steam's when it answers. The answer goes into whatever
        // content is current by then: a reload may have replaced `loaded` while Steam was being asked.
        guard let id = loaded.workshopID, steamLookups[id] == nil, let lookup = await steamLookup(id),
              var current = content, current.itemID == item.id else { return }
        Self.apply(lookup, to: &current)
        content = current
        #endif
    }

    #if !LITE_BUILD
    private enum SteamLookup {
        case found(WorkshopQueryItem)
        /// Steam answered, and the item is private, removed or banned.
        case unavailable
    }

    private static func apply(_ lookup: SteamLookup, to content: inout WallpaperModalContent) {
        switch lookup {
        case let .found(steamItem):
            content.mergeSteam(steamItem, now: Date(), locale: AppLanguagePreference.current.locale)
        case .unavailable:
            content.isUnavailableOnSteam = true
        }
    }

    /// nil when Steam could not be asked or did not answer; that is not remembered, so the next open asks again.
    private func steamLookup(_ id: UInt64) async -> SteamLookup? {
        guard let services else { return nil }
        let outcome = await services.itemDetails.load(ids: [id])
        let lookup: SteamLookup? = if let found = outcome.items.first(where: { $0.id == id }) {
            .found(found)
        } else if outcome.failedIDs.contains(id) {
            .unavailable
        } else {
            nil
        }
        if let lookup {
            steamLookups[id] = lookup
        }
        return lookup
    }
    #endif

    private func navigation(for item: LibraryItem) -> ModalNavigation {
        // The shelf's order, so ← → walk the same run the user came from.
        let run = library.visibleItems.map(\.id)
        let index = run.firstIndex(of: presentedItemID ?? item.id)
        return ModalNavigation(
            canGoPrevious: index.map { $0 > 0 } ?? false,
            canGoNext: index.map { $0 + 1 < run.count } ?? false,
            previous: { navigate(by: -1) },
            next: { navigate(by: 1) }
        )
    }

    private func navigate(by offset: Int) {
        let run = library.visibleItems.map(\.id)
        guard let id = presentedItemID, let index = run.firstIndex(of: id),
              run.indices.contains(index + offset) else { return }
        presentedItemID = run[index + offset]
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
            if let target = target(at: point), let item = presentedItem {
                let modalActions = actions.actions(for: item)
                switch target {
                case let .display(id):
                    modalActions.applyTo(id)
                case .allDisplays:
                    modalActions.applyToAllDisplays()
                }
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

    private func target(at point: CGPoint) -> ModalDropTarget? {
        Self.dropTarget(at: point, thumbnails: targetFrames, run: runFrame, applyAll: applyAllFrame)
    }

    private var highlightedDisplay: CGDirectDisplayID? {
        switch dropTarget {
        case let .display(id)?: id
        default: nil
        }
    }

    /// `run` is the thumbnail run's visible box: a thumbnail scrolled out of it takes no drop.
    static func dropTarget(
        at point: CGPoint, thumbnails: [CGDirectDisplayID: CGRect], run: CGRect?, applyAll: CGRect?
    ) -> ModalDropTarget? {
        let display = thumbnails.first { _, rect in
            let visible = run.map { rect.intersection($0) } ?? rect
            return visible.contains(point)
        }
        if let display {
            return .display(display.key)
        }
        return applyAll?.contains(point) == true ? .allDisplays : nil
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
