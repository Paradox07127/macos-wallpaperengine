import CoreGraphics
import Foundation
import Observation

/// The stage half of the detail handshake, so the coordinator can be driven headless.
@MainActor
protocol DetailStageFlying: AnyObject {
    func flyTile(display: CGDirectDisplayID, to rectInWindow: CGRect) async
    func updateFlightDestination(display: CGDirectDisplayID, to rectInWindow: CGRect)
    func returnTile(display: CGDirectDisplayID) async
    func setTileConcealed(display: CGDirectDisplayID, _ concealed: Bool)
    func setDetailCovering(_ covering: Bool)
}

extension EditDeskStageModel: DetailStageFlying {}

/// `request` is the router's wish; `shownDisplayID` is what is on screen, flight included.
@MainActor
@Observable
final class DetailTransitionCoordinator {
    enum Phase: Equatable {
        case idle, flyingIn, shown, switching, returning
    }

    private(set) var shownDisplayID: CGDirectDisplayID?
    private(set) var heroVisible = false
    private(set) var phase: Phase = .idle
    /// True from a request until its tile is home or its hero has taken over.
    private(set) var busy = false
    /// Runs synchronously once `shownDisplayID` moves to a display, before its flight.
    @ObservationIgnored var onShow: (CGDirectDisplayID) -> Void = { _ in }
    /// Runs once the previous display's tile is home and its state can be dropped.
    @ObservationIgnored var onRelease: () -> Void = {}

    private let stage: any DetailStageFlying
    private let heroFrame: () -> CGRect
    private let usesMeasuredFrame: Bool
    private var measuredFrame: (display: CGDirectDisplayID, rect: CGRect)?
    private var layoutWaiter: (display: CGDirectDisplayID, continuation: CheckedContinuation<CGRect?, Never>)?
    private var transition: Task<Void, Never>?
    private var generation = 0

    init(stage: any DetailStageFlying, usesMeasuredFrame: Bool = false, heroFrame: @escaping () -> CGRect) {
        self.stage = stage
        self.usesMeasuredFrame = usesMeasuredFrame
        self.heroFrame = heroFrame
    }

    /// SwiftUI reports the actual laid-out preview, including the live inspector width. Both
    /// ends of the shared element now use window coordinates instead of duplicating layout math.
    func heroDidLayout(display: CGDirectDisplayID, frame: CGRect) {
        guard display == shownDisplayID, frame.width > 0, frame.height > 0,
              !frame.isInfinite, !frame.isNull else { return }
        measuredFrame = (display, frame)
        if let waiter = layoutWaiter, waiter.display == display {
            layoutWaiter = nil
            waiter.continuation.resume(returning: frame)
        }
        if phase == .flyingIn || phase == .shown || phase == .switching {
            stage.updateFlightDestination(display: display, to: frame)
        }
    }

    private func destination(for display: CGDirectDisplayID) async -> CGRect? {
        guard usesMeasuredFrame else { return heroFrame() }
        if let measuredFrame, measuredFrame.display == display {
            return measuredFrame.rect
        }
        return await withCheckedContinuation { layoutWaiter = (display, $0) }
    }

    /// The hero is laid out from the window, the flight's destination was a rectangle handed over
    /// once; a resize between the two is what makes the tile arrive somewhere the hero is not.
    func windowDidResize() {
        guard !usesMeasuredFrame, let shownDisplayID, phase == .flyingIn || phase == .shown else { return }
        stage.updateFlightDestination(display: shownDisplayID, to: heroFrame())
    }

    func request(_ target: CGDirectDisplayID?) {
        // Shown or flying in: the running hand-off completes on its own. Returning: the cancelled
        // task never hands the hero over, so the return must finish and the tile fly again.
        if target == shownDisplayID, phase != .returning {
            return
        }
        transition?.cancel()
        layoutWaiter?.continuation.resume(returning: nil)
        layoutWaiter = nil
        if target != shownDisplayID {
            measuredFrame = nil
        }
        generation += 1
        let generation = generation
        busy = true
        let directSwitch = target != nil && heroVisible
        let previous = shownDisplayID
        if directSwitch, let target {
            shownDisplayID = target
            phase = .switching
            onShow(target)
        }
        transition = Task { @MainActor in
            defer {
                if self.generation == generation {
                    busy = false
                }
            }
            if directSwitch, let target {
                if let previous {
                    await stage.returnTile(display: previous)
                }
                guard !Task.isCancelled else { return }
                guard let destination = await destination(for: target), !Task.isCancelled else { return }
                await stage.flyTile(display: target, to: destination)
                guard !Task.isCancelled else { return }
                stage.setTileConcealed(display: target, true)
                phase = .shown
                return
            }
            if let current = shownDisplayID {
                phase = .returning
                heroVisible = false
                stage.setTileConcealed(display: current, false)
                stage.setDetailCovering(false)
                await stage.returnTile(display: current)
                guard !Task.isCancelled else { return }
                shownDisplayID = nil
                onRelease()
            }
            guard let target else {
                phase = .idle
                return
            }
            shownDisplayID = target
            phase = .flyingIn
            heroVisible = false
            onShow(target)
            guard let destination = await destination(for: target), !Task.isCancelled else { return }
            await stage.flyTile(display: target, to: destination)
            guard !Task.isCancelled else { return }
            // Same turn, no animation: the hero appears as the tile and the stage under the page disappear.
            heroVisible = true
            stage.setTileConcealed(display: target, true)
            stage.setDetailCovering(true)
            phase = .shown
        }
    }
}
