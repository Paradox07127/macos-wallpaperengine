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
}

extension EditDeskStageModel: DetailStageFlying {}

/// `request` is the router's wish; `shownDisplayID` is what is on screen, flight included.
@MainActor
@Observable
final class DetailTransitionCoordinator {
    enum Phase: Equatable {
        case idle, flyingIn, shown, returning
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
    private var transition: Task<Void, Never>?
    private var generation = 0

    init(stage: any DetailStageFlying, heroFrame: @escaping () -> CGRect) {
        self.stage = stage
        self.heroFrame = heroFrame
    }

    /// The hero is laid out from the window, the flight's destination was a rectangle handed over
    /// once; a resize between the two is what makes the tile arrive somewhere the hero is not.
    func windowDidResize() {
        guard let shownDisplayID, phase == .flyingIn || phase == .shown else { return }
        stage.updateFlightDestination(display: shownDisplayID, to: heroFrame())
    }

    func request(_ target: CGDirectDisplayID?) {
        // Shown or flying in: the running hand-off completes on its own. Returning: the cancelled
        // task never hands the hero over, so the return must finish and the tile fly again.
        if target == shownDisplayID, phase != .returning {
            return
        }
        transition?.cancel()
        generation += 1
        let generation = generation
        busy = true
        transition = Task { @MainActor in
            defer {
                if self.generation == generation {
                    busy = false
                }
            }
            if let current = shownDisplayID {
                phase = .returning
                heroVisible = false
                stage.setTileConcealed(display: current, false)
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
            await stage.flyTile(display: target, to: heroFrame())
            guard !Task.isCancelled else { return }
            // Same turn, no animation: the hero appears as the tile disappears.
            heroVisible = true
            stage.setTileConcealed(display: target, true)
            phase = .shown
        }
    }
}
