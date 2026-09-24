import AppKit
import CoreGraphics
import Foundation
import LiveWallpaperCore
import Observation

/// What undo needs from `ScreenManager` besides applying.
@MainActor
protocol UndoRestoring: WallpaperApplying {
    /// Commits `configuration`, and `overlay` with it when set, the way an explicit pick does.
    func restoreRecordedConfiguration(
        _ configuration: ScreenConfiguration, overlay: MonitorOverlayConfiguration?, on screen: Screen
    )
    func clearWallpaperForScreen(_ screen: Screen)
    func monitorOverlay(for screen: Screen) -> MonitorOverlayConfiguration
    func setMonitorOverlayBoard(_ board: MonitorBoardConfiguration, for screen: Screen)
    func updateSceneDescriptor(_ descriptor: SceneDescriptor, for screen: Screen) async
    func automaticSwitchMark(for fingerprint: String) -> AutomaticSwitchMark?
}

/// The Edit Desk window's undo history: what each change replaced, put back through the product restore path.
/// Commands run one at a time. Text fields keep their own undo in the window's `UndoManager`.
@MainActor
@Observable
final class EditDeskUndoStack {
    enum Action: Equatable {
        case applyWallpaper, applyToAllDisplays, clearWallpaper, resetDisplaySettings
        case removeFromSaved, renameWallpaper, removeWidget, changePreset, resetSceneSettings

        var name: String {
            switch self {
            case .applyWallpaper:
                String(
                    localized: "Apply Wallpaper", bundle: .appLanguage,
                    comment: "Name of an undoable step in the Edit Desk: a wallpaper was applied to a display."
                )
            case .applyToAllDisplays:
                String(localized: "Apply to All Displays", bundle: .appLanguage)
            case .clearWallpaper:
                String(localized: "Clear Wallpaper", bundle: .appLanguage)
            case .resetDisplaySettings:
                String(
                    localized: "Reset Display Settings", bundle: .appLanguage,
                    comment: "Name of an undoable step in the Edit Desk: a display's settings went back to the defaults."
                )
            case .removeFromSaved:
                String(localized: "Remove from Wallpaper Library", bundle: .appLanguage)
            case .renameWallpaper:
                String(
                    localized: "Rename Wallpaper", bundle: .appLanguage,
                    comment: "Title of the alert that renames a Wallpaper Library entry, and the name of that undoable step."
                )
            case .removeWidget:
                String(localized: "Remove Widget", bundle: .appLanguage)
            case .changePreset:
                String(
                    localized: "Change Preset", bundle: .appLanguage,
                    comment: "Name of an undoable step in the Edit Desk: a scene's preset was changed, or set to none."
                )
            case .resetSceneSettings:
                String(
                    localized: "Reset Scene Settings", bundle: .appLanguage,
                    comment: "Name of an undoable step in the Edit Desk: a scene's custom settings were reset."
                )
            }
        }
    }

    /// What running a step changes.
    enum Change {
        /// Each display's whole configuration.
        case displays([Display])
        /// Puts the entry back at `index`; a nil index takes it out again.
        case bookmark(WallpaperBookmark, index: Int?)
        /// Gives the entry with this ID this label.
        case bookmarkLabel(id: UUID, label: String)
        case widgets(WidgetEdit)
        case scene(SceneEdit)
    }

    /// Widgets on one display's overlay board.
    struct WidgetEdit {
        let fingerprint: String
        let name: String
        /// Each widget with the board index it goes back to.
        let widgets: [(placement: MonitorWidgetPlacement, index: Int)]
        /// True puts the widgets back; false takes them off again.
        let inserts: Bool
        /// Lands the editor's debounced board edit first, which would otherwise write over this change.
        let flush: @MainActor () async -> Void
    }

    /// The scene descriptor on one display.
    struct SceneEdit {
        let fingerprint: String
        let name: String
        /// What running the step commits.
        let descriptor: SceneDescriptor
        /// `AutomaticSwitchMark.serial` when recorded; nil when the display had none.
        let switchSerial: Int?
        /// Lands the settings owner's pending edit first, which would otherwise write over this change.
        let flush: @MainActor () async -> Void
    }

    /// One display's side of a step.
    struct Display: Equatable {
        let fingerprint: String
        let name: String
        /// What running the step commits; nil clears the display.
        let configuration: ScreenConfiguration?
        /// Committed with `configuration`; nil leaves the display's overlay alone.
        let overlay: MonitorOverlayConfiguration?
        /// The content right after the change; anything else there means the step no longer fits this display.
        var shown: WallpaperContent?
        /// `AutomaticSwitchMark.serial` right after the change; nil when the display had none.
        var switchSerial: Int?
    }

    struct Step: Identifiable {
        let id: UUID
        let action: Action
        let change: Change
    }

    struct Outcome: Equatable {
        enum Reason: Equatable {
            case disconnected
            case automaticSwitch(AutomaticSwitchMark.Source)
            case changedAfterward
        }

        struct Skipped: Equatable {
            let name: String
            let reason: Reason
        }

        let stepID: UUID
        let isRedo: Bool
        let action: Action
        /// Names of the displays put back, or of the Wallpaper Library entry.
        let restored: [String]
        let skipped: [Skipped]
        /// Names of the displays whose restore was not confirmed in time.
        let failed: [String]
    }

    static let limit = 20

    private(set) var undoSteps: [Step] = []
    private(set) var redoSteps: [Step] = []
    /// Posts the line announcing a step a `record…` call added, with that step's Undo button.
    @ObservationIgnored var onRecord: (@MainActor (_ text: String, _ stepID: UUID) -> Void)?
    @ObservationIgnored private let manager: any UndoRestoring
    @ObservationIgnored private let router: ApplyRouter
    @ObservationIgnored private let bookmarks: BookmarkStore
    /// Displays named by recordings that have not settled them yet; an undo waits for these.
    @ObservationIgnored private var unsettledDisplays = 0
    /// Moves with every recorded step and with `removeAll`; an undo that sees it move keeps its result off the redo stack.
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var lastCommand: Task<Outcome?, Never>?
    @ObservationIgnored private var settleWaiter: CheckedContinuation<Void, Never>?

    /// `router` confirms each restore as it confirms an apply, with the same timeout.
    init(manager: any UndoRestoring, router: ApplyRouter, bookmarks: BookmarkStore) {
        self.manager = manager
        self.router = router
        self.bookmarks = bookmarks
    }

    /// Covers of Wallpaper Library entries a step can still bring back; the cover sweep has to keep them.
    var retainedCoverFileNames: Set<String> {
        Set((undoSteps + redoSteps).compactMap { step in
            guard case let .bookmark(bookmark, _) = step.change else { return nil }
            return bookmark.coverFileName
        })
    }

    /// Snapshots `displays` before a change; `includesOverlay` snapshots their overlays too, which a scheme replaces.
    func begin(_ action: Action, displays: [Screen], includesOverlay: Bool = false) -> UndoRecording {
        let recording = UndoRecording(stack: self, action: action, displays: displays.map { screen in
            (screen.id, Display(
                fingerprint: screen.displayFingerprint, name: screen.name,
                configuration: manager.getConfiguration(for: screen),
                overlay: includesOverlay ? manager.monitorOverlay(for: screen) : nil
            ))
        })
        unsettledDisplays += recording.outstanding.count
        return recording
    }

    /// Puts back the newest step; nothing happens when `stepID` is given and is no longer the newest.
    @discardableResult
    func undo(expecting stepID: UUID? = nil) async -> Outcome? {
        await enqueue { await self.run(isRedo: false, expecting: stepID) }
    }

    @discardableResult
    func redo() async -> Outcome? {
        await enqueue { await self.run(isRedo: true, expecting: nil) }
    }

    func removeAll() {
        undoSteps.removeAll()
        redoSteps.removeAll()
        generation += 1
    }

    // MARK: Recording changes that are already done

    /// `bookmark` and `index` as they were before the entry left the Wallpaper Library.
    func recordRemoval(of bookmark: WallpaperBookmark, at index: Int) {
        record(.removeFromSaved, .bookmark(bookmark, index: index), announcing: String(
            localized: "Removed from Wallpaper Library", bundle: .appLanguage,
            comment: "Toast after an entry left the Wallpaper Library in the Edit Desk; it offers Undo."
        ))
    }

    /// `bookmark` as it was before the rename.
    func recordRename(of bookmark: WallpaperBookmark) {
        record(.renameWallpaper, .bookmarkLabel(id: bookmark.id, label: bookmark.label), announcing: String(
            localized: "Wallpaper renamed", bundle: .appLanguage,
            comment: "Toast after a Wallpaper Library entry was renamed in the Edit Desk; it offers Undo."
        ))
    }

    /// Widgets just taken off `screen`'s board, each with its index there.
    func recordRemoval(
        of widgets: [(placement: MonitorWidgetPlacement, index: Int)], from screen: Screen,
        flush: @escaping @MainActor () async -> Void
    ) {
        let edit = WidgetEdit(
            fingerprint: screen.displayFingerprint, name: screen.name, widgets: widgets, inserts: true, flush: flush
        )
        record(.removeWidget, .widgets(edit), announcing: String(
            localized: "Widget removed", bundle: .appLanguage,
            comment: "Toast after a widget was removed from a display's overlay in the Edit Desk; it offers Undo."
        ))
    }

    /// A `.changePreset` or `.resetSceneSettings` on `screen` once it has landed; `before` is the descriptor it replaced.
    func recordSceneChange(
        _ action: Action, from before: SceneDescriptor, on screen: Screen, flush: @escaping @MainActor () async -> Void
    ) {
        let edit = SceneEdit(
            fingerprint: screen.displayFingerprint, name: screen.name, descriptor: before,
            switchSerial: manager.automaticSwitchMark(for: screen.displayFingerprint)?.serial, flush: flush
        )
        let text = action == .resetSceneSettings
            ? String(
                localized: "Scene settings reset", bundle: .appLanguage,
                comment: "Toast after a scene's custom settings were reset in the Edit Desk; it offers Undo."
            )
            : String(
                localized: "Preset changed", bundle: .appLanguage,
                comment: "Toast after a scene's preset was changed, or set to none, in the Edit Desk; it offers Undo."
            )
        record(action, .scene(edit), announcing: text)
    }

    private func record(_ action: Action, _ change: Change, announcing text: String) {
        let step = Step(id: UUID(), action: action, change: change)
        append(step)
        onRecord?(text, step.id)
    }

    // MARK: Recording

    fileprivate func settle(_ recording: UndoRecording, _ displayID: CGDirectDisplayID, applied: Bool) -> UUID? {
        guard recording.outstanding.remove(displayID) != nil else { return nil }
        unsettledDisplays -= 1
        defer {
            if unsettledDisplays == 0 {
                settleWaiter?.resume()
                settleWaiter = nil
            }
        }
        if applied, let index = recording.displays.firstIndex(where: { $0.id == displayID }),
           let screen = manager.screen(withID: displayID) {
            recording.displays[index].state.shown = manager.getConfiguration(for: screen)?.activeWallpaper
            recording.displays[index].state.switchSerial = manager.automaticSwitchMark(for: screen.displayFingerprint)?.serial
            recording.landed.insert(displayID)
        }
        guard recording.outstanding.isEmpty else { return nil }
        return finish(recording)
    }

    fileprivate func settle(_ recording: UndoRecording, showing content: WallpaperContent?) async -> UUID? {
        // All waits start now: a preparation failure is posted once, so a wait that started after it would sit out the timeout.
        let waits = recording.outstanding.map { displayID in
            (displayID, Task { await confirm(content, on: displayID) })
        }
        var stepID: UUID?
        for (displayID, wait) in waits {
            stepID = await settle(recording, displayID, applied: wait.value) ?? stepID
        }
        return stepID
    }

    private func confirm(_ content: WallpaperContent?, on displayID: CGDirectDisplayID) async -> Bool {
        guard let content else {
            return manager.screen(withID: displayID).map { manager.getConfiguration(for: $0) == nil } ?? false
        }
        return await router.awaitApplied(matching: content, on: displayID, timeout: router.confirmationTimeout)
    }

    private func finish(_ recording: UndoRecording) -> UUID? {
        let displays = recording.displays.filter { recording.landed.contains($0.id) }.map(\.state)
        guard !displays.isEmpty else { return nil }
        append(Step(id: recording.id, action: recording.action, change: .displays(displays)))
        return recording.id
    }

    private func append(_ step: Step) {
        push(step)
        redoSteps.removeAll()
        generation += 1
    }

    // MARK: Commands

    private func enqueue(_ command: @escaping @MainActor @Sendable () async -> Outcome?) async -> Outcome? {
        let previous = lastCommand
        let task = Task { @MainActor in
            _ = await previous?.value
            return await command()
        }
        lastCommand = task
        return await task.value
    }

    private func run(isRedo: Bool, expecting stepID: UUID?) async -> Outcome? {
        await waitForPendingRecordings()
        guard let step = isRedo ? redoSteps.last : undoSteps.last, stepID == nil || stepID == step.id else { return nil }
        if isRedo {
            redoSteps.removeLast()
        } else {
            undoSteps.removeLast()
        }
        let startGeneration = generation
        let ran = switch step.change {
        case let .displays(displays):
            await restore(displays)
        case let .bookmark(bookmark, index):
            restore(bookmark, at: index)
        case let .bookmarkLabel(id, label):
            relabel(id, to: label)
        case let .widgets(edit):
            await restore(edit)
        case let .scene(edit):
            await restore(edit)
        }
        if let change = ran.inverse {
            let inverse = Step(id: UUID(), action: step.action, change: change)
            if isRedo {
                push(inverse)
            } else if generation == startGeneration {
                redoSteps.append(inverse)
            }
        }
        return Outcome(
            stepID: step.id, isRedo: isRedo, action: step.action, restored: ran.restored, skipped: ran.skipped,
            failed: ran.failed
        )
    }

    /// What running a step did: the change that reverses it, and what its outcome reports.
    private struct Ran {
        var inverse: Change?
        var restored: [String] = []
        var skipped: [Outcome.Skipped] = []
        var failed: [String] = []
    }

    /// By fingerprint: a reconnected display can come back under another display ID.
    private func connectedScreen(_ fingerprint: String) -> Screen? {
        manager.screens.first { $0.displayFingerprint == fingerprint }
    }

    private func restore(_ displays: [Display]) async -> Ran {
        var ran = Ran()
        var replaced: [Display] = []
        for display in displays {
            guard let screen = connectedScreen(display.fingerprint) else {
                ran.skipped.append(.init(name: display.name, reason: .disconnected))
                continue
            }
            if let mark = manager.automaticSwitchMark(for: display.fingerprint), mark.serial != display.switchSerial {
                ran.skipped.append(.init(name: screen.name, reason: .automaticSwitch(mark.source)))
                continue
            }
            let current = manager.getConfiguration(for: screen)
            guard !ApplyRouter.changedAway(current?.activeWallpaper, from: display.shown) else {
                ran.skipped.append(.init(name: screen.name, reason: .changedAfterward))
                continue
            }
            var inverse = Display(
                fingerprint: display.fingerprint, name: screen.name, configuration: current,
                overlay: display.overlay == nil ? nil : manager.monitorOverlay(for: screen)
            )
            guard await restore(display, on: screen) else {
                ran.failed.append(screen.name)
                continue
            }
            inverse.shown = manager.getConfiguration(for: screen)?.activeWallpaper
            inverse.switchSerial = manager.automaticSwitchMark(for: display.fingerprint)?.serial
            replaced.append(inverse)
            ran.restored.append(screen.name)
        }
        ran.inverse = replaced.isEmpty ? nil : .displays(replaced)
        return ran
    }

    private func restore(_ bookmark: WallpaperBookmark, at index: Int?) -> Ran {
        guard let index else {
            guard let at = bookmarks.bookmarks.firstIndex(where: { $0.id == bookmark.id }) else {
                return Ran(skipped: [.init(name: bookmark.label, reason: .changedAfterward)])
            }
            let current = bookmarks.bookmarks[at]
            bookmarks.remove(current.id)
            return Ran(inverse: .bookmark(current, index: at), restored: [current.label])
        }
        // An entry already back under its ID counts as restored: `insert` leaves it where it is.
        bookmarks.insert(bookmark, at: index)
        return Ran(inverse: .bookmark(bookmark, index: nil), restored: [bookmark.label])
    }

    private func relabel(_ id: UUID, to label: String) -> Ran {
        guard let current = bookmarks.bookmarks.first(where: { $0.id == id }) else {
            return Ran(skipped: [.init(name: label, reason: .changedAfterward)])
        }
        bookmarks.rename(id, to: label)
        return Ran(inverse: .bookmarkLabel(id: id, label: current.label), restored: [label])
    }

    private func restore(_ edit: WidgetEdit) async -> Ran {
        guard let screen = connectedScreen(edit.fingerprint) else {
            return Ran(skipped: [.init(name: edit.name, reason: .disconnected)])
        }
        await edit.flush()
        var board = manager.monitorOverlay(for: screen).board
        var changed: [(placement: MonitorWidgetPlacement, index: Int)] = []
        if edit.inserts {
            // Ascending, so each widget lands at the index it had while the ones before it were there.
            for widget in edit.widgets.sorted(by: { $0.index < $1.index })
                where !board.widgets.contains(where: { $0.id == widget.placement.id }) {
                board.widgets.insert(widget.placement, at: min(widget.index, board.widgets.count))
                changed.append(widget)
            }
        } else {
            changed = edit.widgets.compactMap { widget in
                board.widgets.firstIndex { $0.id == widget.placement.id }.map { (placement: board.widgets[$0], index: $0) }
            }
            for index in changed.map(\.index).sorted(by: >) {
                board.widgets.remove(at: index)
            }
        }
        guard !changed.isEmpty else {
            return Ran(skipped: [.init(name: screen.name, reason: .changedAfterward)])
        }
        manager.setMonitorOverlayBoard(board, for: screen)
        let inverse = WidgetEdit(
            fingerprint: edit.fingerprint, name: screen.name, widgets: changed, inserts: !edit.inserts, flush: edit.flush
        )
        return Ran(inverse: .widgets(inverse), restored: [screen.name])
    }

    private func restore(_ edit: SceneEdit) async -> Ran {
        guard let screen = connectedScreen(edit.fingerprint) else {
            return Ran(skipped: [.init(name: edit.name, reason: .disconnected)])
        }
        if let mark = manager.automaticSwitchMark(for: edit.fingerprint), mark.serial != edit.switchSerial {
            return Ran(skipped: [.init(name: screen.name, reason: .automaticSwitch(mark.source))])
        }
        guard activeScene(on: screen)?.workshopID == edit.descriptor.workshopID else {
            return Ran(skipped: [.init(name: screen.name, reason: .changedAfterward)])
        }
        await edit.flush()
        guard let replaced = activeScene(on: screen), replaced.workshopID == edit.descriptor.workshopID else {
            return Ran(skipped: [.init(name: screen.name, reason: .changedAfterward)])
        }
        await manager.updateSceneDescriptor(edit.descriptor, for: screen)
        let inverse = SceneEdit(
            fingerprint: edit.fingerprint, name: screen.name, descriptor: replaced,
            switchSerial: manager.automaticSwitchMark(for: edit.fingerprint)?.serial, flush: edit.flush
        )
        return Ran(inverse: .scene(inverse), restored: [screen.name])
    }

    private func activeScene(on screen: Screen) -> SceneDescriptor? {
        guard case let .scene(descriptor)? = manager.getConfiguration(for: screen)?.activeWallpaper else { return nil }
        return descriptor
    }

    private func restore(_ display: Display, on screen: Screen) async -> Bool {
        guard let configuration = display.configuration else {
            manager.clearWallpaperForScreen(screen)
            return true
        }
        manager.restoreRecordedConfiguration(
            configuration.reboundToDisplay(screen.id, fingerprint: screen.displayFingerprint),
            overlay: display.overlay, on: screen
        )
        return await router.awaitApplied(
            matching: configuration.activeWallpaper, on: screen.id, timeout: router.confirmationTimeout
        )
    }

    /// An undo pressed while a change is still settling undoes that change, so it waits for it, up to one confirmation.
    private func waitForPendingRecordings() async {
        guard unsettledDisplays > 0 else { return }
        let deadline = Task { @MainActor [weak self, timeout = router.confirmationTimeout] in
            do {
                try await Task.sleep(for: timeout)
            } catch {
                return
            }
            // Cancelled once its wait ends; the waiter here now can only be the next command's.
            guard !Task.isCancelled else { return }
            self?.settleWaiter?.resume()
            self?.settleWaiter = nil
        }
        await withCheckedContinuation { settleWaiter = $0 }
        deadline.cancel()
    }

    private func push(_ step: Step) {
        undoSteps.append(step)
        if undoSteps.count > Self.limit {
            undoSteps.removeFirst(undoSteps.count - Self.limit)
        }
    }
}

extension EditDeskUndoStack.Outcome {
    /// The toasts that report this outcome, in posting order.
    var notices: [(text: String, style: EditDeskToastCenter.Toast.Style)] {
        var notices: [(text: String, style: EditDeskToastCenter.Toast.Style)] = []
        if !restored.isEmpty {
            let text = isRedo
                ? String(
                    localized: "Redone: \(action.name)", bundle: .appLanguage,
                    comment: "Toast after Redo in the Edit Desk. Placeholder is the name of the step, such as Apply Wallpaper."
                )
                : String(
                    localized: "Undone: \(action.name)", bundle: .appLanguage,
                    comment: "Toast after Undo in the Edit Desk. Placeholder is the name of the step, such as Apply Wallpaper."
                )
            notices.append((text, .success))
        }
        if skipped.count > 1 {
            notices.append((String(
                localized: "Skipped \(skipped.count) displays that changed afterward.", bundle: .appLanguage,
                comment: "Toast after Undo or Redo left several displays alone because they changed later. Placeholder is the count."
            ), .info))
        } else if let skip = skipped.first {
            notices.append((skip.text, .info))
        }
        for name in failed {
            notices.append((String(
                localized: "Couldn’t restore \(name).", bundle: .appLanguage,
                comment: "Toast when Undo or Redo could not bring a display's wallpaper back. Placeholder is a display name."
            ), .failure))
        }
        return notices
    }
}

extension EditDeskUndoStack.Outcome.Skipped {
    var text: String {
        switch reason {
        case .disconnected:
            String(
                localized: "\(name) isn’t connected. Skipped.", bundle: .appLanguage,
                comment: "Toast when Undo or Redo left a display alone because it is unplugged. Placeholder is a display name."
            )
        case .automaticSwitch(.schedule):
            String(
                localized: "\(name) was changed by the schedule afterward. Skipped.", bundle: .appLanguage,
                comment: "Toast when Undo or Redo left a display alone because its schedule switched the wallpaper later. Placeholder is a display name."
            )
        case .automaticSwitch(.playlist):
            String(
                localized: "\(name) was switched by the playlist afterward. Skipped.", bundle: .appLanguage,
                comment: "Toast when Undo or Redo left a display alone because its playlist moved on later. Placeholder is a display name."
            )
        case .changedAfterward:
            String(
                localized: "\(name) was changed afterward. Skipped.", bundle: .appLanguage,
                comment: "Toast when Undo or Redo left a display alone because its wallpaper was changed later. Placeholder is a display name."
            )
        }
    }
}

/// A change under way. Each display it names settles once; the change becomes a step when any display took it.
@MainActor
final class UndoRecording {
    let id = UUID()
    fileprivate let action: EditDeskUndoStack.Action
    fileprivate var displays: [(id: CGDirectDisplayID, state: EditDeskUndoStack.Display)]
    fileprivate var outstanding: Set<CGDirectDisplayID>
    fileprivate var landed: Set<CGDirectDisplayID> = []
    private let stack: EditDeskUndoStack

    fileprivate init(
        stack: EditDeskUndoStack, action: EditDeskUndoStack.Action,
        displays: [(id: CGDirectDisplayID, state: EditDeskUndoStack.Display)]
    ) {
        self.stack = stack
        self.action = action
        self.displays = displays
        outstanding = Set(displays.map(\.id))
    }

    /// The call that settles the last display returns the step's ID, when any display took the change.
    @discardableResult
    func settle(_ displayID: CGDirectDisplayID, applied: Bool) -> UUID? {
        stack.settle(self, displayID, applied: applied)
    }

    /// Settles every display once it shows `content` (nil: has no configuration) or the confirmation times out.
    func settle(showing content: WallpaperContent?) async -> UUID? {
        await stack.settle(self, showing: content)
    }

    /// Settles as `settle(showing:)` does, then posts `text` with an Undo button for the step.
    func announce(_ text: String, showing content: WallpaperContent?, to toasts: EditDeskToastCenter) {
        Task {
            guard let stepID = await settle(showing: content) else { return }
            toasts.post(text, style: .success, undoStepID: stepID)
        }
    }
}

/// Where ⌘Z and ⇧⌘Z go: a text field being edited keeps its own undo, and a sheet, panel or popover
/// that is key takes neither from the window behind it.
enum EditDeskUndoKeyRoute: Equatable {
    case text, stack, ignore

    /// `keyWindowIsMain`: the key window is also the main window, the Edit Desk's own.
    static func route(firstResponder: NSResponder?, keyWindowIsMain: Bool) -> EditDeskUndoKeyRoute {
        if firstResponder is NSText {
            return .text
        }
        return keyWindowIsMain ? .stack : .ignore
    }
}
