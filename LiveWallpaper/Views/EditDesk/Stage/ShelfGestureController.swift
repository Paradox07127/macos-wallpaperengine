import CoreGraphics
import Foundation

/// Trackpad model for the three-state stage: 1:1 tracking while the fingers are down, a landing
/// state projected from release velocity, and a stiff wall that keeps one gesture to one state.
@MainActor
final class ShelfGestureController {
    enum Phase {
        case began, changed, ended, momentum, momentumEnded
    }

    enum Axis {
        case undecided, vertical, horizontal
    }

    /// What the stage should do once the fingers leave: spring to `target`, seeded with the speed
    /// the gesture actually had, so a flick lands fast and a slow drag lands slowly.
    struct Release: Equatable {
        var target: Int
        /// States per second at the moment of release.
        var velocity: Double
    }

    private let clock: () -> TimeInterval
    private var travel = CGPoint.zero
    private var axis = Axis.undecided
    private var rawRowOffset: CGFloat = 0
    /// Rest state the live gesture started from; it may not travel more than one state either way.
    private var anchor: Double?
    /// State the fingers came down on. A snap still in flight leaves `progress` between states, and
    /// deciding the axis from that value locks every catch-and-swipe into the vertical axis.
    private var startState: Int?
    /// True between `.began` and `.ended`: while the fingers are down nothing may snap.
    private var touching = false
    private var lastEventTime: TimeInterval?
    private var smoothedVelocity = 0.0
    /// Signed state-travel of the current wheel burst; trackpad gestures release instead.
    private var wheelTravel = 0.0
    private var downPoint: CGPoint?
    private(set) var pendingRelease: Release?
    private(set) var snapDeadline: TimeInterval?
    private(set) var rowOffset: CGFloat = 0
    var rowLimits: ClosedRange<CGFloat> = 0 ... 0

    init(clock: @escaping () -> TimeInterval) {
        self.clock = clock
    }

    /// Returns the progress the stage should jump to, or nil when this event does not move it.
    /// `precise` is `NSEvent.hasPreciseScrollingDeltas`: a wheel notch has to buy far more state
    /// than a trackpad point, or the wheel needs sixteen clicks per state.
    func scroll(
        deltaX: CGFloat, deltaY: CGFloat, progress: Double,
        phase: Phase, precise: Bool = true, shift: Bool = false
    ) -> Double? {
        switch phase {
        case .began:
            travel = .zero
            axis = .undecided
            anchor = nil
            startState = StageGeometry.snapTarget(for: progress)
            touching = true
            snapDeadline = nil
            pendingRelease = nil
            lastEventTime = clock()
            smoothedVelocity = 0
            return nil
        case .ended:
            touching = false
            if axis == .vertical, let base = anchor {
                // A finger that stops before lifting is not a flick, however fast it was moving a
                // second ago: decay the sample by how long it has been still.
                let still = lastEventTime.map { max(0, clock() - $0) } ?? 0
                let velocity = smoothedVelocity * exp(-still / StageGeometry.velocityWindow)
                pendingRelease = Self.landing(from: progress, base: base, velocity: velocity)
                snapDeadline = nil
            } else {
                snapDeadline = clock() + StageGeometry.snapDelay
            }
            return nil
        case .momentumEnded:
            touching = false
            axis = .undecided
            snapDeadline = clock() + StageGeometry.snapDelay
            return nil
        case .momentum:
            // The OS momentum curve is built for infinite documents; fed into a state transition it
            // fights the landing spring. The row still wants it, so only the state axis drops it.
            guard axis != .vertical else { return nil }
        case .changed:
            break
        }

        let pointsPerState = precise ? StageGeometry.scrollPointsPerProgress : StageGeometry.wheelPointsPerProgress
        if touching {
            trackVelocity(deltaY: deltaY, pointsPerState: pointsPerState)
        }
        // A pause with the fingers still down must not snap: that would end the gesture early and
        // hand the next push a fresh one-state budget.
        snapDeadline = touching ? nil : clock() + StageGeometry.snapDelay

        var stepX = deltaX
        var stepY = deltaY
        if axis == .undecided {
            travel.x += deltaX
            travel.y += deltaY
            axis = Self.lock(travel: travel, canScrollRow: (startState ?? StageGeometry.snapTarget(for: progress)) == 1, shift: shift)
            guard axis != .undecided else { return nil }
            // The deadband's travel is spent on the axis that won it, so the lock does not land as
            // a notch: dropping it makes the first 16pt of every gesture disappear.
            stepX = travel.x
            stepY = travel.y
        }

        if axis == .horizontal {
            // A shift-held wheel arrives on X (AppKit swaps it), a shift-held trackpad swipe on Y.
            rawRowOffset += shift && abs(stepY) > abs(stepX) ? stepY : stepX
            rowOffset = Self.rubberBand(rawRowOffset, limits: rowLimits)
            return nil
        }

        let base = anchor ?? Double(StageGeometry.snapTarget(for: progress))
        anchor = base
        if !touching {
            wheelTravel -= Double(stepY / pointsPerState)
        }
        let moved = progress - Double(stepY / pointsPerState)
        return StageGeometry.clampProgress(Self.wall(moved, within: (base - 1) ... (base + 1)))
    }

    /// Release velocity has to come from a window, not the last event: fingers decelerate as they
    /// leave the glass, so the final delta is near zero and the landing would always crawl.
    private func trackVelocity(deltaY: CGFloat, pointsPerState: CGFloat) {
        let now = clock()
        defer { lastEventTime = now }
        guard let last = lastEventTime, now > last else { return }
        let step = now - last
        let instant = -Double(deltaY / pointsPerState) / step
        let weight = 1 - exp(-step / StageGeometry.velocityWindow)
        smoothedVelocity += (instant - smoothedVelocity) * weight
    }

    static func landing(from progress: Double, base: Double, velocity: Double) -> Release {
        let up = min(base + 1, StageGeometry.progressRange.upperBound)
        let down = max(base - 1, StageGeometry.progressRange.lowerBound)
        let target: Double = if velocity >= StageGeometry.flickVelocity, progress > base - 0.08 {
            up
        } else if velocity <= -StageGeometry.flickVelocity, progress < base + 0.08 {
            down
        } else if progress >= base + StageGeometry.commitFraction {
            up
        } else if progress <= base - StageGeometry.commitFraction {
            down
        } else {
            base
        }
        return Release(target: Int(target.rounded()), velocity: velocity)
    }

    /// 2D deadband then a hard lock: an unlocked gesture jerks the row sideways when the finger
    /// curls at the end of a vertical flick.
    private static func lock(travel: CGPoint, canScrollRow: Bool, shift: Bool) -> Axis {
        if shift {
            return canScrollRow ? .horizontal : .vertical
        }
        let reach = hypot(travel.x, travel.y)
        guard reach >= StageGeometry.scrollDeadZone else { return .undecided }
        guard canScrollRow else { return .vertical }
        if abs(travel.y) > 1.5 * abs(travel.x) {
            return .vertical
        }
        if abs(travel.x) > 1.2 * abs(travel.y) {
            return .horizontal
        }
        guard reach >= StageGeometry.scrollDeadZone * 1.5 else { return .undecided }
        return abs(travel.x) > abs(travel.y) ? .horizontal : .vertical
    }

    func consumeRelease() -> Release? {
        defer { pendingRelease = nil }
        return pendingRelease
    }

    /// A wheel burst commits in the direction it travelled, not by where it happened to stop: one
    /// notch is 0.22 of a state, so rounding to the nearest sent every slow scroll straight back.
    func consumeSnap(progress: Double) -> Int? {
        guard let snapDeadline, clock() >= snapDeadline else { return nil }
        self.snapDeadline = nil
        let base = anchor
        let moved = wheelTravel
        travel = .zero
        axis = .undecided
        anchor = nil
        startState = nil
        wheelTravel = 0
        guard let base, abs(moved) >= StageGeometry.wheelCommit else {
            return StageGeometry.snapTarget(for: progress)
        }
        let target = moved > 0 ? base + 1 : base - 1
        return Int(StageGeometry.clampProgress(target).rounded())
    }

    /// `quantum` > 0 lands the row on a whole slot so the cards come to rest aligned.
    func settleRow(quantum: CGFloat = 0) -> CGFloat {
        var settled = min(max(rawRowOffset, rowLimits.lowerBound), rowLimits.upperBound)
        if quantum > 0 {
            settled = min(max((settled / quantum).rounded() * quantum, rowLimits.lowerBound), rowLimits.upperBound)
        }
        rawRowOffset = settled
        rowOffset = settled
        return rowOffset
    }

    /// Takes over from where the row spring was stopped, so tracking continues from the position on
    /// screen instead of the settle target the spring had not reached yet.
    func adopt(rowOffset value: CGFloat) {
        rawRowOffset = value
        rowOffset = value
    }

    func reset() {
        travel = .zero
        axis = .undecided
        rawRowOffset = 0
        rowOffset = 0
        snapDeadline = nil
        anchor = nil
        startState = nil
        touching = false
        wheelTravel = 0
        pendingRelease = nil
        lastEventTime = nil
        smoothedVelocity = 0
        downPoint = nil
    }

    static func keyTarget(up: Bool, progress: Double) -> Int {
        Int(StageGeometry.clampProgress(up ? floor(progress) + 1 : ceil(progress) - 1))
    }

    func mouseDown(at point: CGPoint) {
        downPoint = point
    }

    func shouldStartDrag(at point: CGPoint) -> Bool {
        guard let downPoint else { return false }
        return hypot(point.x - downPoint.x, point.y - downPoint.y) >= StageGeometry.dragThreshold
    }

    func mouseUp() {
        downPoint = nil
    }

    /// Row cards overlap, so the hit is the one drawn on top at that point — the one the user can
    /// actually see there. `order` is each card's `depthOrder`, index breaking ties.
    static func card(at point: CGPoint, frames: [CGRect], order: [CGFloat]) -> Int? {
        frames.indices
            .filter { frames[$0].contains(point) }
            .max { (order[$0], $0) < (order[$1], $1) }
    }

    static func display(at point: CGPoint, frames: [(StageDisplay.ID, CGRect)]) -> StageDisplay.ID? {
        frames.first { $0.1.contains(point) }?.0
    }

    /// Stiff wall at the one-state band: it may give a few points so the gesture does not feel
    /// blocked, but never enough for the next state's layout to start.
    private static func wall(_ value: Double, within limits: ClosedRange<Double>) -> Double {
        let edge = min(max(value, limits.lowerBound), limits.upperBound)
        let excess = value - edge
        guard excess != 0 else { return value }
        let give = StageGeometry.stateWallGive
        return edge + (excess < 0 ? -1 : 1) * give * abs(excess) / (abs(excess) + StageGeometry.stateWallStiffness)
    }

    private static func rubberBand(_ value: CGFloat, limits: ClosedRange<CGFloat>) -> CGFloat {
        let edge = min(max(value, limits.lowerBound), limits.upperBound)
        let excess = value - edge
        // UIScrollView's constant: initial slope 120/220 ≈ 0.55, saturating near 120pt.
        let maximum = StageGeometry.rowStretch
        let stiffness = StageGeometry.rowStretchStiffness
        return edge + (excess < 0 ? -1 : 1) * maximum * (1 - 1 / (1 + abs(excess) / stiffness))
    }
}
