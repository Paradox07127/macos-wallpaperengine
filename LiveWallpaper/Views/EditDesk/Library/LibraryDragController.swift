import AppKit
import CoreGraphics
import LiveWallpaperCore
import SwiftUI

/// A library wallpaper on its way to a display, from the modal's preview or a grid tile: the ghost's state, the
/// drop's hit test and the apply. Points are in `EditDeskCoordinateSpace.name`, which `HomePage` defines.
@MainActor
@Observable
final class LibraryDragController {
    /// What a drag carries: the row, the picture its ghost wears and the actions its drop applies with.
    struct Payload {
        let item: LibraryItem
        let image: CGImage?
        let actions: WallpaperModalActions
    }

    /// nil while no drag shows.
    private(set) var payload: Payload?
    /// The ghost's centre; nil while no drag shows.
    private(set) var point: CGPoint?
    private(set) var target: ModalDropTarget?
    /// Every change runs the ghost's MOTION 9 miss shake once.
    private(set) var shakeTrigger = 0
    /// Reduce Motion where the strip and ghost are drawn; kept current by their host.
    @ObservationIgnored var reduceMotion = false
    @ObservationIgnored var thumbnailFrames: [CGDirectDisplayID: CGRect] = [:]
    /// The thumbnail run's visible box; a thumbnail scrolled out of it is not a drop target.
    @ObservationIgnored var runFrame: CGRect?
    @ObservationIgnored var applyAllFrame: CGRect?
    @ObservationIgnored private var endTask: Task<Void, Never>?
    /// Set by Escape; the rest of that gesture's events are ignored until its release.
    @ObservationIgnored private var cancelled = false
    @ObservationIgnored private var escapeMonitor: Any?

    /// `watchesEscape`: the source has no Escape of its own, so the drag takes the key and the pointer while it runs.
    func begin(_ payload: Payload, at point: CGPoint, watchesEscape: Bool = false) {
        endTask?.cancel()
        stopWatchingEscape()
        cancelled = false
        self.payload = payload
        withAnimation(DesignTokens.motion(reduceMotion, .spring(response: 0.25, dampingFraction: 0.82))) {
            self.point = point
        }
        target = dropTarget(at: point)
        if watchesEscape {
            watchEscape()
        }
    }

    func move(to point: CGPoint) {
        guard !cancelled else { return }
        self.point = point
        target = dropTarget(at: point)
    }

    func end(at point: CGPoint) {
        stopWatchingEscape()
        guard !cancelled else {
            cancelled = false
            return
        }
        if let target = dropTarget(at: point), let payload {
            switch target {
            case let .display(id):
                payload.actions.applyTo(id)
            case .allDisplays:
                payload.actions.applyToAllDisplays()
            }
            clear()
        } else {
            // MOTION 9: a miss shakes the ghost before it goes.
            shakeTrigger += 1
            endTask = Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(320))
                guard !Task.isCancelled else { return }
                clear()
            }
        }
    }

    /// The strip and ghost go now, and nothing the same gesture reports afterwards applies.
    func cancel() {
        cancelled = true
        clear()
    }

    func clear() {
        stopWatchingEscape()
        endTask?.cancel()
        endTask = nil
        withAnimation(DesignTokens.motion(reduceMotion, .spring(response: 0.25, dampingFraction: 0.82))) {
            point = nil
            target = nil
            payload = nil
        }
    }

    private func dropTarget(at point: CGPoint) -> ModalDropTarget? {
        Self.dropTarget(at: point, thumbnails: thumbnailFrames, run: runFrame, applyAll: applyAllFrame)
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

    /// A local monitor sees the key before the library page's own Escape, which would leave the library.
    private func watchEscape() {
        NSCursor.closedHand.push()
        escapeMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard event.keyCode == 53 else { return event }
            let consumed = MainActor.assumeIsolated { () -> Bool in
                guard let self, self.point != nil, !self.cancelled else { return false }
                self.cancel()
                return true
            }
            return consumed ? nil : event
        }
    }

    private func stopWatchingEscape() {
        guard let escapeMonitor else { return }
        NSEvent.removeMonitor(escapeMonitor)
        self.escapeMonitor = nil
        NSCursor.pop()
    }
}

/// SCREENS S5 and MOTION 7–9 for a `LibraryDragController`: while a drag runs the strip hangs under the window's
/// top and the ghost follows the pointer. `targets` are the displays the dragged row can go to.
struct LibraryDragOverlay: View {
    let drag: LibraryDragController
    let targets: [ModalDisplayTarget]
    let windowWidth: CGFloat

    /// SCREENS.md S5: the strip enters from −130 above its resting top.
    private static let floatHiddenTop: CGFloat = -130

    var body: some View {
        if drag.point != nil {
            DisplayFloatLayer(
                targets: targets,
                highlighted: highlightedDisplay,
                windowWidth: windowWidth,
                onTargetFrame: { drag.thumbnailFrames[$0.id] = $0.rect },
                onRunFrame: { drag.runFrame = $0 },
                applyAllHighlighted: drag.target == .allDisplays,
                onApplyAllFrame: { drag.applyAllFrame = $0 }
            )
            .padding(.top, FloatLayerGeometry.panelTop)
            .transition(.offset(y: Self.floatHiddenTop - FloatLayerGeometry.panelTop).combined(with: .opacity))
        }
        if let point = drag.point {
            ModalDragGhost(image: drag.payload?.image, isOverTarget: drag.target != nil, shakeTrigger: drag.shakeTrigger)
                .position(point)
        }
    }

    private var highlightedDisplay: CGDirectDisplayID? {
        switch drag.target {
        case let .display(id)?: id
        default: nil
        }
    }
}

extension View {
    /// Drags a grid tile toward the displays past MOTION 7's 6pt; a shorter press stays the tile's click.
    /// `payload` is read when the drag starts; nil starts none.
    func libraryDragSource(
        _ drag: LibraryDragController, enabled: Bool, payload: @escaping @MainActor () -> LibraryDragController.Payload?
    ) -> some View {
        modifier(LibraryDragSource(drag: drag, enabled: enabled, payload: payload))
    }
}

private struct LibraryDragSource: ViewModifier {
    let drag: LibraryDragController
    let enabled: Bool
    let payload: @MainActor () -> LibraryDragController.Payload?
    /// This view's gesture started the drag running now.
    @State private var isDragging = false

    func body(content: Content) -> some View {
        content
            // MOTION 7 asks for .3 under the ghost; the modal's preview dims to the same step.
            .opacity(isDragging && drag.payload != nil ? DesignTokens.Opacity.quietStroke : 1)
            // High priority: a drag that ends back on the tile must not also count as a click.
            .highPriorityGesture(gesture, including: enabled ? .all : .subviews)
            // Scrolled out of a lazy grid or unmounted with its page, the gesture never reports its end.
            .onDisappear {
                if isDragging {
                    isDragging = false
                    drag.cancel()
                }
            }
    }

    private var gesture: some Gesture {
        DragGesture(minimumDistance: 6, coordinateSpace: .named(EditDeskCoordinateSpace.name))
            .onChanged { value in
                if isDragging {
                    drag.move(to: value.location)
                } else if let payload = payload() {
                    isDragging = true
                    drag.begin(payload, at: value.location, watchesEscape: true)
                }
            }
            .onEnded { value in
                guard isDragging else { return }
                isDragging = false
                drag.end(at: value.location)
            }
    }
}
