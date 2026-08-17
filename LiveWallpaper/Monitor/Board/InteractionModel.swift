import Combine
import CoreGraphics
import Foundation
import LiveWallpaperCore

/// Live drag state for the widget under the pointer.
struct MonitorBoardDragState: Equatable {
    var widgetID: UUID
    /// Pointer offset at grab so the ghost tracks 1:1.
    var grabOffset: CGSize
    var footprint: CGSize
    var freeOrigin: CGPoint
    /// nil under ⌘/⌥ (raw drag, no snap).
    var snappedOrigin: CGPoint?
    var guideX: MonitorSnapGuide?
    var guideY: MonitorSnapGuide?
    /// Restore target when the drop finds no legal spot.
    var originAtGrab: CGPoint
    var didMove: Bool

    var ghostOrigin: CGPoint? { snappedOrigin }
}

/// User-facing move/delete commands before mutating the persisted widget array.
enum MonitorBoardPlacementCommand: Equatable {
    case move(id: UUID, pixelOrigin: CGPoint)
    case delete(id: UUID)
}

enum MonitorBoardPlacementDirection {
    case left
    case right
    case up
    case down
}

/// Board placements, edit mode, selection, and in-flight drag for `RootView`.
@MainActor
final class InteractionModel: ObservableObject {
    @Published private(set) var placements: [MonitorWidgetPlacement]
    @Published var isEditing: Bool = false
    @Published var selectedID: UUID?
    @Published private(set) var drag: MonitorBoardDragState?
    @Published var isCatalogOpen: Bool = false
    /// Cleared on edit-exit, drag-start, removal, and empty-space tap.
    @Published var settingsOpenID: UUID?

    @Published var boardSize: CGSize = .zero

    /// Menu-bar avoidance; folded into every `geometry` so clamp/snap/reflow stay below it.
    var topInsetFraction: CGFloat = 0

    var referenceWidth: CGFloat = 0

    /// Committing edits only (drag-end, add, remove, resize) — never per mouse-move.
    var onConfigurationEdited: ((MonitorBoardConfiguration) -> Void)?

    var onEditingChanged: ((Bool) -> Void)?

    private var baseConfiguration: MonitorBoardConfiguration

    init(configuration: MonitorBoardConfiguration) {
        self.baseConfiguration = configuration
        self.placements = configuration.widgets
    }

    var geometry: MonitorBoardGeometry {
        MonitorBoardGeometry(
            boardSize: boardSize,
            referenceWidth: referenceWidth,
            topInsetFraction: topInsetFraction
        )
    }

    // MARK: - External config application

    /// Live config change: cancel in-flight drag; drop selection that no longer exists.
    func apply(configuration: MonitorBoardConfiguration) {
        baseConfiguration = configuration
        placements = configuration.widgets
        drag = nil
        if let selectedID, !placements.contains(where: { $0.id == selectedID }) {
            self.selectedID = nil
        }
        if let settingsOpenID, !placements.contains(where: { $0.id == settingsOpenID }) {
            self.settingsOpenID = nil
        }
        if boardSize != .zero {
            reflow(boardSize: boardSize)
        }
    }

    // MARK: - Geometry helpers

    func footprint(for placement: MonitorWidgetPlacement) -> CGSize {
        geometry.pixelSize(for: placement.kind, size: placement.size)
    }

    func pixelOrigin(for placement: MonitorWidgetPlacement) -> CGPoint {
        LayoutEngine.pixelOrigin(
            normalized: CGPoint(x: placement.x, y: placement.y), boardSize: boardSize
        )
    }

    /// Sibling set the engine sees during drag/resolve (optional exclude).
    private func items(excluding excludedID: UUID?) -> [MonitorBoardItem] {
        placements.compactMap { placement in
            guard placement.id != excludedID else { return nil }
            return MonitorBoardItem(
                id: placement.id,
                rect: CGRect(origin: pixelOrigin(for: placement), size: footprint(for: placement))
            )
        }
    }

    // MARK: - Selection

    func select(_ id: UUID?) {
        selectedID = id
    }

    func setEditing(_ editing: Bool) {
        guard isEditing != editing else { return }
        isEditing = editing
        if !editing {
            selectedID = nil
            isCatalogOpen = false
            settingsOpenID = nil
            drag = nil
        }
        onEditingChanged?(editing)
    }

    // MARK: - Drag lifecycle

    func beginDrag(_ id: UUID, grabOffset: CGSize) {
        guard isEditing, let placement = placements.first(where: { $0.id == id }) else { return }
        select(id)
        isCatalogOpen = false
        settingsOpenID = nil
        let origin = pixelOrigin(for: placement)
        drag = MonitorBoardDragState(
            widgetID: id,
            grabOffset: grabOffset,
            footprint: footprint(for: placement),
            freeOrigin: origin,
            snappedOrigin: nil,
            guideX: nil,
            guideY: nil,
            originAtGrab: origin,
            didMove: false
        )
    }

    /// `bypassSnap` (⌘/⌥): raw drag, no ghost, no guides.
    func updateDrag(pointInBoard point: CGPoint, bypassSnap: Bool) {
        guard var current = drag else { return }
        let free = CGPoint(
            x: point.x - current.grabOffset.width,
            y: point.y - current.grabOffset.height
        )
        if hypot(free.x - current.originAtGrab.x, free.y - current.originAtGrab.y) > 4 {
            current.didMove = true
        }
        current.freeOrigin = free

        if bypassSnap {
            current.snappedOrigin = nil
            current.guideX = nil
            current.guideY = nil
        } else {
            let result = LayoutEngine.snap(
                freeOrigin: free,
                footprint: current.footprint,
                geometry: geometry,
                items: items(excluding: current.widgetID),
                ignoring: current.widgetID
            )
            current.snappedOrigin = result.snapped ? result.origin : nil
            current.guideX = result.guideX
            current.guideY = result.guideY
        }
        drag = current
    }

    func endDrag(bypassSnap: Bool) {
        guard let current = drag else { return }
        drag = nil
        guard current.didMove else { return }

        let target = bypassSnap ? current.freeOrigin : current.snappedOrigin ?? current.freeOrigin
        perform(.move(id: current.widgetID, pixelOrigin: target))
    }

    // MARK: - Add / remove / resize

    @discardableResult
    func perform(_ command: MonitorBoardPlacementCommand) -> Bool {
        switch command {
        case let .move(id, proposedOrigin):
            guard !geometry.isDegenerate,
                  let index = placements.firstIndex(where: { $0.id == id }) else {
                return false
            }
            let placement = placements[index]
            let footprintSize = footprint(for: placement)
            guard let landed = LayoutEngine.land(
                freeOrigin: proposedOrigin,
                snappedOrigin: nil,
                footprint: footprintSize,
                geometry: geometry,
                items: items(excluding: id),
                ignoring: id
            ) else {
                return false
            }
            let normalized = LayoutEngine.normalized(
                pixelOrigin: landed,
                boardSize: boardSize
            )
            guard placement.x != normalized.x || placement.y != normalized.y else {
                return false
            }
            placements[index].x = normalized.x
            placements[index].y = normalized.y
            emitConfiguration()
            return true

        case let .delete(id):
            guard let index = placements.firstIndex(where: { $0.id == id }) else {
                return false
            }
            placements.remove(at: index)
            if selectedID == id { selectedID = nil }
            if settingsOpenID == id { settingsOpenID = nil }
            emitConfiguration()
            return true
        }
    }

    @discardableResult
    func moveWidget(
        id: UUID,
        direction: MonitorBoardPlacementDirection,
        distance: CGFloat = 10
    ) -> Bool {
        guard isEditing,
              distance.isFinite,
              distance > 0,
              let placement = placements.first(where: { $0.id == id }) else {
            return false
        }
        let origin = pixelOrigin(for: placement)
        let delta: CGSize
        switch direction {
        case .left:
            delta = CGSize(width: -distance, height: 0)
        case .right:
            delta = CGSize(width: distance, height: 0)
        case .up:
            delta = CGSize(width: 0, height: -distance)
        case .down:
            delta = CGSize(width: 0, height: distance)
        }
        return perform(.move(
            id: id,
            pixelOrigin: CGPoint(x: origin.x + delta.width, y: origin.y + delta.height)
        ))
    }

    /// Keyboard/VoiceOver share targeted-move; focus alone supplies selected id.
    @discardableResult
    func moveSelectedWidget(
        _ direction: MonitorBoardPlacementDirection,
        distance: CGFloat = 10
    ) -> Bool {
        guard let selectedID else { return false }
        return moveWidget(id: selectedID, direction: direction, distance: distance)
    }

    @discardableResult
    func deleteSelectedWidget() -> Bool {
        guard isEditing, let selectedID else { return false }
        return perform(.delete(id: selectedID))
    }

    /// First-fit free position; false if the board is full.
    @discardableResult
    func addWidget(kind: MonitorWidgetKind) -> Bool {
        guard isEditing else { return false }
        let size = Self.defaultSize(for: kind)
        let footprintSize = geometry.pixelSize(for: kind, size: size)
        guard let origin = LayoutEngine.firstFit(
            footprint: footprintSize, geometry: geometry, items: items(excluding: nil)
        ) else {
            return false
        }
        let normalized = LayoutEngine.normalized(pixelOrigin: origin, boardSize: boardSize)
        let placement = MonitorWidgetPlacement(kind: kind, size: size, x: normalized.x, y: normalized.y)
        placements.append(placement)
        select(placement.id)
        isCatalogOpen = false
        emitConfiguration()
        return true
    }

    /// Settings-card writeback (`onUpdate`).
    func updateWidget(_ updated: MonitorWidgetPlacement) {
        guard let index = placements.firstIndex(where: { $0.id == updated.id }) else { return }
        let current = placements[index]

        if updated.size != current.size {
            var applied = updated
            applied.size = current.size
            applied.x = current.x
            applied.y = current.y
            placements[index] = applied
            if !setSize(updated.id, to: updated.size) {
                emitConfiguration()
            }
            return
        }

        var applied = updated
        applied.x = current.x
        applied.y = current.y
        placements[index] = applied
        emitConfiguration()
    }

    /// Re-fits around the anchor after a size change.
    @discardableResult
    func setSize(_ id: UUID, to size: MonitorWidgetSize) -> Bool {
        guard let index = placements.firstIndex(where: { $0.id == id }) else { return false }
        guard placements[index].kind.allowedSizes.contains(size) else { return false }
        guard placements[index].size != size else { return true }
        let anchor = pixelOrigin(for: placements[index])
        let newFootprint = geometry.pixelSize(for: placements[index].kind, size: size)
        guard let origin = LayoutEngine.refitForSizeChange(
            anchor: anchor, newFootprint: newFootprint, geometry: geometry,
            items: items(excluding: id), ignoring: id
        ) else {
            return false
        }
        let normalized = LayoutEngine.normalized(pixelOrigin: origin, boardSize: boardSize)
        placements[index].size = size
        placements[index].x = normalized.x
        placements[index].y = normalized.y
        emitConfiguration()
        return true
    }

    // MARK: - Reflow on board resize

    func reflow(boardSize newSize: CGSize) {
        boardSize = newSize
        guard !geometry.isDegenerate else { return }
        let geo = geometry

        for index in placements.indices {
            let footprintSize = geo.pixelSize(for: placements[index].kind, size: placements[index].size)
            let px = LayoutEngine.pixelOrigin(
                normalized: CGPoint(x: placements[index].x, y: placements[index].y), boardSize: newSize
            )
            let clamped = geo.clampOrigin(px, footprint: footprintSize)
            let normalized = LayoutEngine.normalized(pixelOrigin: clamped, boardSize: newSize)
            placements[index].x = normalized.x
            placements[index].y = normalized.y
        }

        for index in placements.indices {
            let footprintSize = geo.pixelSize(for: placements[index].kind, size: placements[index].size)
            let px = LayoutEngine.pixelOrigin(
                normalized: CGPoint(x: placements[index].x, y: placements[index].y), boardSize: newSize
            )
            let rect = CGRect(origin: px, size: footprintSize)
            if !LayoutEngine.isLegal(
                rect: rect, geometry: geo, items: items(excluding: placements[index].id),
                ignoring: placements[index].id
            ) {
                if let resolved = LayoutEngine.resolve(
                    origin: px, footprint: footprintSize, geometry: geo,
                    items: items(excluding: placements[index].id), ignoring: placements[index].id,
                    maxDisplacement: .greatestFiniteMagnitude
                ) {
                    let normalized = LayoutEngine.normalized(pixelOrigin: resolved, boardSize: newSize)
                    placements[index].x = normalized.x
                    placements[index].y = normalized.y
                }
            }
        }
    }

    // MARK: - Config emission

    private func emitConfiguration() {
        baseConfiguration.widgets = placements
        onConfigurationEdited?(baseConfiguration)
    }

    /// Small when allowed (agent session/processes prefer medium).
    static func defaultSize(for kind: MonitorWidgetKind) -> MonitorWidgetSize {
        let allowed = kind.allowedSizes
        let prefersMedium: Bool
        switch kind {
        case .fleet, .processes: prefersMedium = true
        default: prefersMedium = false
        }
        if prefersMedium, allowed.contains(.medium) { return .medium }
        if allowed.contains(.small) { return .small }
        return allowed.first ?? .medium
    }
}
