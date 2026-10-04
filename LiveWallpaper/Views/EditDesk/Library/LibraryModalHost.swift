import CoreGraphics
import LiveWallpaperCore
import SwiftUI

/// S4 + S5 over the home page: opens the modal for one library item, and draws the float strip and
/// ghost of `drag`, whether the modal's preview or a grid tile started it.
struct LibraryModalHost: View {
    let library: SavedLibraryModel
    let stage: EditDeskStageModel
    let drag: LibraryDragController
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
    /// Displays whose newest cover capture has landed: only their covers show what runs there now.
    var currentCovers: Set<CGDirectDisplayID> = []
    /// Opens a display's detail page; the modal closes first.
    let showDisplay: @MainActor (CGDirectDisplayID) -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.displayScale) private var displayScale
    @State private var content: WallpaperModalContent?
    #if !LITE_BUILD
    @Environment(WorkshopServices.self) private var services: WorkshopServices?
    /// What Steam answered per Workshop ID this session, so paging back and reloads ask it once.
    @State private var steamLookups: [UInt64: SteamLookup] = [:]
    #endif

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
                modal(for: item, content: content, targets: targets(for: item))
            }
            LibraryDragOverlay(
                drag: drag, targets: drag.payload?.item.map { targets(for: $0) } ?? [], windowWidth: stage.stageSize.width
            )
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .animation(DesignTokens.motion(reduceMotion, .spring(response: 0.45, dampingFraction: 0.82)), value: presentedItemID != nil)
        .onChange(of: presentedItemID, initial: true) { _, id in
            if id == nil {
                content = nil
                drag.clear()
            }
        }
        .onChange(of: reduceMotion, initial: true) { drag.reduceMotion = reduceMotion }
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

    private func targets(for item: LibraryItem) -> [ModalDisplayTarget] {
        actions.targets(for: item, covers: covers, preferred: preferredTarget).map { target in
            var target = target
            target.isPreparing = applying.contains(target.id)
            return target
        }
    }

    private func modal(for item: LibraryItem, content: WallpaperModalContent, targets: [ModalDisplayTarget]) -> WallpaperModal {
        var itemActions = actions.actions(for: item)
        itemActions.showDisplay = { id in
            dismiss()
            showDisplay(id)
        }
        var modal = WallpaperModal(
            content: content,
            targets: targets,
            actions: itemActions,
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
        // Read with `item` and `currentCovers`, before any await: a cover landing meanwhile can show another wallpaper.
        let liveStill = ModalActions.liveStill(showingOn: item.onDisplays, covers: covers, current: currentCovers)
        var loaded = await actions.content(for: item)
        let preview = ModalGeometry.previewSize
        loaded.preview = await actions.preview(
            for: item, box: CGSize(width: preview.width * displayScale, height: preview.height * displayScale), liveStill: liveStill
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

    /// No `watchesEscape`: the modal's own Escape cancels its gesture, and a monitor here would swallow that key first.
    private func handleDrag(_ phase: ModalDragPhase) {
        switch phase {
        case let .began(point):
            guard let item = presentedItem else { return }
            drag.begin(.init(item: item, image: content?.preview, actions: actions.actions(for: item)), at: point)
        case let .moved(point):
            drag.move(to: point)
        case let .ended(point):
            drag.end(at: point)
        case .cancelled:
            drag.clear()
        }
    }
}
