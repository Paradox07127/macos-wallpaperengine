import CoreGraphics
import Foundation
@testable import LiveWallpaper
import Testing

@MainActor
@Suite("Edit Desk shelf gestures")
struct ShelfGestureControllerTests {
    /// A reference clock: passing a captured `var` as `inout` as well trips exclusive access.
    private final class Clock {
        var now = 0.0
    }

    /// Drives one trackpad gesture: `steps` events of `deltaY` points, `interval` apart.
    private func flick(
        deltaY: CGFloat, steps: Int, interval: TimeInterval, from start: Double = 0
    ) -> (progress: Double, release: ShelfGestureController.Release?) {
        let clock = Clock()
        let gesture = ShelfGestureController(clock: { clock.now })
        var progress = start
        _ = gesture.scroll(deltaX: 0, deltaY: 0, progress: progress, phase: .began)
        for _ in 0 ..< steps {
            clock.now += interval
            if let next = gesture.scroll(deltaX: 0, deltaY: deltaY, progress: progress, phase: .changed) {
                progress = next
            }
        }
        clock.now += interval
        _ = gesture.scroll(deltaX: 0, deltaY: 0, progress: progress, phase: .ended)
        return (progress, gesture.consumeRelease())
    }

    @Test("The deadband is a 2D radius, and its travel is spent rather than dropped")
    func deadZone() {
        var now = 0.0
        let gesture = ShelfGestureController(clock: { now })
        _ = gesture.scroll(deltaX: 0, deltaY: 0, progress: 0, phase: .began)
        now += 0.008
        #expect(gesture.scroll(deltaX: 0, deltaY: -10, progress: 0, phase: .changed) == nil)
        now += 0.008
        let admitted = gesture.scroll(deltaX: 0, deltaY: -10, progress: 0, phase: .changed)
        // 20pt of travel, all of it applied: not just the 4pt past the threshold.
        #expect(
            admitted.map { abs($0 - 20 / StageGeometry.scrollPointsPerProgress) < 0.0001 } == true,
            Comment(rawValue: "\(String(describing: admitted))")
        )
    }

    @Test("Tracking is 1:1 inside the one-state band and the wall gives almost nothing past it")
    func trackingAndWall() {
        var now = 0.0
        let gesture = ShelfGestureController(clock: { now })
        _ = gesture.scroll(deltaX: 0, deltaY: 0, progress: 1, phase: .began)
        now += 0.008
        // 190pt of a 380pt state is exactly half of it: no gearing, no magnetism.
        #expect(gesture.scroll(deltaX: 0, deltaY: -190, progress: 1, phase: .changed) == 1.5)

        var later = 0.0
        let second = ShelfGestureController(clock: { later })
        _ = second.scroll(deltaX: 0, deltaY: 0, progress: 0, phase: .began)
        later += 0.008
        _ = second.scroll(deltaX: 0, deltaY: -380, progress: 0, phase: .changed)
        later += 0.008
        let walled = second.scroll(deltaX: 0, deltaY: -400, progress: 1, phase: .changed) ?? 0
        #expect(
            walled > 1 && walled <= 1 + StageGeometry.stateWallGive,
            Comment(rawValue: "the wall gave \(walled - 1) of a state")
        )
    }

    @Test("A fast flick carries to the next state even when the finger barely moved")
    func flickProjectsForward() throws {
        let outcome = flick(deltaY: -20, steps: 5, interval: 0.008)
        #expect(
            outcome.progress < StageGeometry.commitFraction,
            Comment(rawValue: "only travelled to \(outcome.progress)")
        )
        let release = try #require(outcome.release)
        #expect(release.target == 1, Comment(rawValue: "\(release)"))
        #expect(release.velocity > StageGeometry.flickVelocity)
    }

    @Test("A slow drag that never commits returns to where it started")
    func slowDragReturns() {
        let outcome = flick(deltaY: -20, steps: 5, interval: 0.25)
        #expect(outcome.progress > 0 && outcome.progress < StageGeometry.commitFraction)
        #expect(outcome.release?.target == 0)
        #expect(abs(outcome.release?.velocity ?? 99) < StageGeometry.flickVelocity)
    }

    @Test("A slow drag past the commit point lands on the next state")
    func slowDragCommits() {
        let outcome = flick(deltaY: -40, steps: 6, interval: 0.25)
        #expect(outcome.progress > StageGeometry.commitFraction, Comment(rawValue: "\(outcome.progress)"))
        #expect(outcome.release?.target == 1)
    }

    @Test("One gesture is one state, and the OS momentum after it is discarded")
    func oneStatePerGesture() {
        var now = 0.0
        let gesture = ShelfGestureController(clock: { now })
        var progress = 0.0
        _ = gesture.scroll(deltaX: 0, deltaY: 0, progress: progress, phase: .began)
        for _ in 0 ..< 20 {
            now += 0.008
            if let next = gesture.scroll(deltaX: 0, deltaY: -120, progress: progress, phase: .changed) {
                progress = next
            }
        }
        #expect(progress <= 1 + StageGeometry.stateWallGive, Comment(rawValue: "one flick reached \(progress)"))
        now += 0.008
        _ = gesture.scroll(deltaX: 0, deltaY: 0, progress: progress, phase: .ended)
        #expect(gesture.consumeRelease()?.target == 1)
        for _ in 0 ..< 10 {
            now += 0.008
            #expect(
                gesture.scroll(deltaX: 0, deltaY: -200, progress: progress, phase: .momentum) == nil,
                "momentum must not push the state on past the landing"
            )
        }
    }

    @Test("A wheel burst with no phases buys one state and snaps on silence")
    func wheelBurst() {
        var now = 0.0
        let gesture = ShelfGestureController(clock: { now })
        var progress = 0.0
        for _ in 0 ..< 20 {
            now += 0.02
            if let next = gesture.scroll(deltaX: 0, deltaY: -24, progress: progress, phase: .changed, precise: false) {
                progress = next
            }
        }
        #expect(progress <= 1 + StageGeometry.stateWallGive, Comment(rawValue: "wheel burst reached \(progress)"))
        #expect(progress > 0.9, "a 20-notch burst has to cover a whole state")
        #expect(gesture.consumeRelease() == nil, "a wheel has no release to project from")
        now += StageGeometry.snapDelay
        #expect(gesture.consumeSnap(progress: progress) == 1)
    }

    @Test("A lone wheel notch commits in its own direction instead of rounding back home")
    func slowWheelCommits() {
        let clock = Clock()
        let gesture = ShelfGestureController(clock: { clock.now })
        var progress = 0.0
        /// A notch is 0.22 of a state: rounding to the nearest used to send every slow scroll home,
        /// so a wheel could never open the shelf. A notch is deliberate, so it commits.
        func notch(_ deltaY: CGFloat) {
            clock.now += 0.2
            if let next = gesture.scroll(deltaX: 0, deltaY: deltaY, progress: progress, phase: .changed, precise: false) {
                progress = next
            }
            clock.now += StageGeometry.snapDelay
            if let snapped = gesture.consumeSnap(progress: progress) {
                progress = Double(snapped)
            }
        }
        notch(-24)
        #expect(progress == 1, Comment(rawValue: "one notch landed on \(progress)"))
        notch(-24)
        #expect(progress == 2, Comment(rawValue: "two notches landed on \(progress)"))
        notch(24)
        #expect(progress == 1, "scrolling back has to walk back down one state at a time")
    }

    @Test("A finger that stops before lifting is not a flick")
    func stillFingerIsNotAFlick() {
        let clock = Clock()
        let gesture = ShelfGestureController(clock: { clock.now })
        var progress = 0.0
        _ = gesture.scroll(deltaX: 0, deltaY: 0, progress: progress, phase: .began)
        for _ in 0 ..< 4 {
            clock.now += 0.008
            if let next = gesture.scroll(deltaX: 0, deltaY: -20, progress: progress, phase: .changed) {
                progress = next
            }
        }
        clock.now += 1
        _ = gesture.scroll(deltaX: 0, deltaY: 0, progress: progress, phase: .ended)
        #expect(gesture.consumeRelease()?.target == 0, "a second of stillness has to bleed the flick away")
    }

    @Test("Shift-held scrolling moves the row whichever axis the delta arrives on")
    func shiftScrollsTheRowOnEitherAxis() {
        let wheelClock = Clock()
        let wheel = ShelfGestureController(clock: { wheelClock.now })
        wheel.rowLimits = -1000 ... 0
        wheelClock.now += 0.008
        // AppKit swaps a shift-held wheel onto the X axis.
        _ = wheel.scroll(deltaX: -60, deltaY: 0, progress: 1, phase: .changed, precise: false, shift: true)
        #expect(wheel.rowOffset < 0, Comment(rawValue: "wheel: \(wheel.rowOffset)"))

        let padClock = Clock()
        let pad = ShelfGestureController(clock: { padClock.now })
        pad.rowLimits = -1000 ... 0
        _ = pad.scroll(deltaX: 0, deltaY: 0, progress: 1, phase: .began)
        padClock.now += 0.008
        // A shift-held trackpad swipe still reports on Y.
        _ = pad.scroll(deltaX: 0, deltaY: -60, progress: 1, phase: .changed, shift: true)
        #expect(pad.rowOffset < 0, Comment(rawValue: "trackpad: \(pad.rowOffset)"))
    }

    @Test("A pause with the fingers still down neither snaps nor refills the one-state budget")
    func pauseMidGestureKeepsTheBudget() {
        var now = 0.0
        let gesture = ShelfGestureController(clock: { now })
        var progress = 0.0
        _ = gesture.scroll(deltaX: 0, deltaY: 0, progress: progress, phase: .began)
        for _ in 0 ..< 6 {
            now += 0.008
            if let next = gesture.scroll(deltaX: 0, deltaY: -120, progress: progress, phase: .changed) {
                progress = next
            }
        }
        now += 1
        #expect(gesture.consumeSnap(progress: progress) == nil, "nothing may snap while the gesture is live")
        for _ in 0 ..< 6 {
            now += 0.008
            if let next = gesture.scroll(deltaX: 0, deltaY: -120, progress: progress, phase: .changed) {
                progress = next
            }
        }
        #expect(
            progress <= 1 + StageGeometry.stateWallGive,
            Comment(rawValue: "the paused gesture pushed on to \(progress)")
        )
    }

    @Test("The axis locks once and stays locked when the finger curls")
    func axisLocks() {
        var now = 0.0
        let gesture = ShelfGestureController(clock: { now })
        gesture.rowLimits = -1000 ... 0
        _ = gesture.scroll(deltaX: 0, deltaY: 0, progress: 1, phase: .began)
        now += 0.008
        #expect(gesture.scroll(deltaX: -30, deltaY: -4, progress: 1, phase: .changed) == nil)
        #expect(gesture.rowOffset < 0, "a sideways start has to scroll the row")
        now += 0.008
        // The finger curls upward at the end of the swipe; the state must not move with it.
        #expect(gesture.scroll(deltaX: 0, deltaY: -200, progress: 1, phase: .changed) == nil)

        var later = 0.0
        let upward = ShelfGestureController(clock: { later })
        upward.rowLimits = -1000 ... 0
        _ = upward.scroll(deltaX: 0, deltaY: 0, progress: 1, phase: .began)
        later += 0.008
        #expect(upward.scroll(deltaX: -4, deltaY: -30, progress: 1, phase: .changed) != nil)
        later += 0.008
        _ = upward.scroll(deltaX: -200, deltaY: 0, progress: 1.1, phase: .changed)
        #expect(upward.rowOffset == 0, "a vertical gesture must never scroll the row")
    }

    @Test("Away from the half-open state the row cannot take the gesture")
    func rowOnlyScrollsWhenTheShelfIsOpen() {
        var now = 0.0
        let gesture = ShelfGestureController(clock: { now })
        gesture.rowLimits = -1000 ... 0
        _ = gesture.scroll(deltaX: 0, deltaY: 0, progress: 0, phase: .began)
        now += 0.008
        _ = gesture.scroll(deltaX: -30, deltaY: -4, progress: 0, phase: .changed)
        #expect(gesture.rowOffset == 0)
    }

    @Test("Row ends stretch and settle back onto a card boundary")
    func rowRubberBand() {
        var now = 0.0
        let gesture = ShelfGestureController(clock: { now })
        gesture.rowLimits = -100 ... 0
        _ = gesture.scroll(deltaX: 0, deltaY: 0, progress: 1, phase: .began)
        now += 0.008
        _ = gesture.scroll(deltaX: 80, deltaY: 0, progress: 1, phase: .changed)
        #expect(gesture.rowOffset > 0 && gesture.rowOffset < StageGeometry.rowStretch)
        #expect(gesture.settleRow(quantum: 48) == 0)

        gesture.reset()
        gesture.rowLimits = -1000 ... 0
        _ = gesture.scroll(deltaX: 0, deltaY: 0, progress: 1, phase: .began)
        now += 0.008
        _ = gesture.scroll(deltaX: -130, deltaY: 0, progress: 1, phase: .changed)
        let settled = gesture.settleRow(quantum: 48)
        #expect(settled.truncatingRemainder(dividingBy: 48) == 0, Comment(rawValue: "\(settled)"))
    }

    @Test("Arrow keys select the next integer state")
    func keys() {
        #expect(ShelfGestureController.keyTarget(up: true, progress: 1) == 2)
        #expect(ShelfGestureController.keyTarget(up: false, progress: 1) == 0)
        #expect(ShelfGestureController.keyTarget(up: true, progress: 0.4) == 1)
        #expect(ShelfGestureController.keyTarget(up: false, progress: 1.6) == 1)
        #expect(ShelfGestureController.keyTarget(up: true, progress: 2) == 2)
    }

    @Test("Dragging starts at six points, never five")
    func dragThreshold() {
        let gesture = ShelfGestureController(clock: { 0 })
        gesture.mouseDown(at: .zero)
        #expect(!gesture.shouldStartDrag(at: CGPoint(x: 3, y: 4)))
        #expect(gesture.shouldStartDrag(at: CGPoint(x: 6, y: 0)))
        gesture.mouseUp()
        #expect(!gesture.shouldStartDrag(at: CGPoint(x: 10, y: 0)))
    }

    @Test("Hit tests use the same geometry as the stage")
    func hitTesting() {
        let size = StageGeometry.designWindow
        let placements = (0 ..< 14).map {
            StageGeometry.cardPlacement(style: .crate, index: $0, count: 14, progress: 2, focus: 0, windowSize: size)
        }
        let cards = placements.map(\.frame)
        let order = placements.map(\.depthOrder)
        #expect(ShelfGestureController.card(at: CGPoint(x: cards[3].midX, y: cards[3].midY), frames: cards, order: order) == 3)
        let arrangement = StageGeometry.arrangement(
            frames: [CGRect(x: 0, y: 0, width: 1920, height: 1080)],
            in: StageGeometry.stageRect(windowSize: size)
        )
        let shell = StageGeometry.shellRect(content: arrangement.contentRects[0], isBuiltin: false)
        #expect(ShelfGestureController.display(at: CGPoint(x: shell.midX, y: shell.midY), frames: [(7, shell)]) == 7)
        #expect(ShelfGestureController.card(at: .zero, frames: cards, order: order) == nil)

        // Tilted row cards overlap; the card to the right lies on top, so the sliver is on the left.
        let row = (0 ..< 14).map {
            StageGeometry.cardPlacement(style: .crate, index: $0, count: 14, progress: 1, focus: 0, windowSize: size)
        }
        let hits = row.map { StageGeometry.hitRect($0, style: .crate) }
        let sliver = CGPoint(x: hits[5].minX + 8, y: hits[5].midY)
        #expect(ShelfGestureController.card(at: sliver, frames: hits, order: row.map(\.depthOrder)) == 5)
    }

    @Test("A gesture caught mid-snap still decides its axis from the state it came down on")
    func axisFromStartState() {
        let clock = Clock()
        let gesture = ShelfGestureController(clock: { clock.now })
        gesture.rowLimits = -600 ... 0
        // Fingers land while the snap to state 1 is still 0.06 short of it.
        var progress = 0.94
        _ = gesture.scroll(deltaX: 0, deltaY: 0, progress: progress, phase: .began)
        clock.now += 0.008
        _ = gesture.scroll(deltaX: -30, deltaY: 0, progress: progress, phase: .changed)
        #expect(gesture.rowOffset < 0, "a sideways swipe on a shelf that has all but landed must scroll the row")

        // The same swipe from a state where the shelf is hidden is vertical: there is no row to scroll.
        let other = ShelfGestureController(clock: { clock.now })
        other.rowLimits = -600 ... 0
        progress = 0.2
        _ = other.scroll(deltaX: 0, deltaY: 0, progress: progress, phase: .began)
        clock.now += 0.008
        _ = other.scroll(deltaX: -30, deltaY: 0, progress: progress, phase: .changed)
        #expect(other.rowOffset == 0)
    }

    @Test("Adopting the frozen row position keeps tracking continuous")
    func adoptRow() {
        let clock = Clock()
        let gesture = ShelfGestureController(clock: { clock.now })
        gesture.rowLimits = -600 ... 0
        _ = gesture.scroll(deltaX: 0, deltaY: 0, progress: 1, phase: .began)
        clock.now += 0.008
        _ = gesture.scroll(deltaX: -200, deltaY: 0, progress: 1, phase: .changed)
        clock.now += 0.008
        _ = gesture.scroll(deltaX: 0, deltaY: 0, progress: 1, phase: .ended)
        let settled = gesture.settleRow(quantum: 48)
        #expect(settled == -192)

        // The spring is still on its way there when the next gesture starts: tracking has to
        // continue from where the row is drawn, not from the target it never reached.
        gesture.adopt(rowOffset: -120)
        #expect(gesture.rowOffset == -120)
        _ = gesture.scroll(deltaX: 0, deltaY: 0, progress: 1, phase: .began)
        clock.now += 0.008
        _ = gesture.scroll(deltaX: -30, deltaY: 0, progress: 1, phase: .changed)
        #expect(gesture.rowOffset == -150)
    }
}
