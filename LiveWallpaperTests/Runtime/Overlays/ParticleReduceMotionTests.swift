import AppKit
@testable import LiveWallpaper
import LiveWallpaperCore
import QuartzCore
import XCTest

/// The environment particle layer answers to two independent gates: the wallpaper
/// runtime's own suspend, and the system "Reduce motion" switch.
///
/// They used to share one `Bool`, so whichever wrote last won — a runtime resume after a
/// wake would restart snow that Reduce Motion had stopped. They are separate reasons on
/// one set now, and the tests below drive them in both orders because that is the whole
/// point: nothing in the type system says a `Bool` cannot be written by two owners.
final class ParticleReduceMotionTests: XCTestCase {
    private static let frame = CGRect(x: 0, y: 0, width: 200, height: 200)

    /// `[]` cannot be written against an `Optional` expected value, and an absent host is a
    /// different failure from a host with no reasons — so unwrap first.
    @MainActor
    private func reasons(
        _ controller: EnvironmentOverlayController, _ screenID: CGDirectDisplayID
    ) throws -> ParticleSuspensionReasons {
        try XCTUnwrap(controller.debugSuspensionReasons(screenID: screenID))
    }

    /// The real notification AppKit sends when an Accessibility display switch moves.
    /// Posted rather than simulated so the observer registration itself is under test.
    @MainActor
    private func postAccessibilityDisplayOptionsChange() {
        NSWorkspace.shared.notificationCenter.post(
            name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
            object: nil
        )
    }

    // MARK: - The state table

    @MainActor
    func testParticlesRunOnlyWhenNeitherReasonIsRaised() throws {
        let view = ParticleOverlayView(frame: Self.frame)
        view.setEffect(.snow, density: 1)

        // off / off
        XCTAssertFalse(view.isSuspended)
        XCTAssertEqual(try XCTUnwrap(view.debugEmitterState).speed, 1)
        XCTAssertFalse(try XCTUnwrap(view.debugEmitterState).isHidden)

        // runtime on / reduce motion off
        view.setSuspended(true, for: .runtime)
        XCTAssertTrue(view.isSuspended)
        XCTAssertEqual(try XCTUnwrap(view.debugEmitterState).speed, 0)
        XCTAssertTrue(try XCTUnwrap(view.debugEmitterState).isHidden)

        // runtime on / reduce motion on
        view.setSuspended(true, for: .reduceMotion)
        XCTAssertTrue(view.isSuspended)
        XCTAssertEqual(view.suspensionReasons, [.runtime, .reduceMotion])
        XCTAssertEqual(try XCTUnwrap(view.debugEmitterState).speed, 0)

        // runtime off / reduce motion on
        view.setSuspended(false, for: .runtime)
        XCTAssertTrue(view.isSuspended, "a runtime resume lifted the Reduce Motion pause")
        XCTAssertEqual(view.suspensionReasons, .reduceMotion)
        XCTAssertEqual(try XCTUnwrap(view.debugEmitterState).speed, 0)

        // off / off again
        view.setSuspended(false, for: .reduceMotion)
        XCTAssertFalse(view.isSuspended)
        XCTAssertEqual(view.suspensionReasons, [])
        XCTAssertEqual(try XCTUnwrap(view.debugEmitterState).speed, 1)
        XCTAssertFalse(try XCTUnwrap(view.debugEmitterState).isHidden)
    }

    @MainActor
    func testEitherOrderOfRaisingAndDroppingReasonsKeepsParticlesPaused() throws {
        for (first, second) in [
            (ParticleSuspensionReasons.runtime, ParticleSuspensionReasons.reduceMotion),
            (ParticleSuspensionReasons.reduceMotion, ParticleSuspensionReasons.runtime),
        ] {
            let view = ParticleOverlayView(frame: Self.frame)
            view.setEffect(.rain, density: 1)

            view.setSuspended(true, for: first)
            view.setSuspended(true, for: second)
            view.setSuspended(false, for: first)
            XCTAssertTrue(
                view.isSuspended,
                "dropping \(first) first restarted the particles while \(second) still held"
            )
            XCTAssertEqual(try XCTUnwrap(view.debugEmitterState).speed, 0)

            view.setSuspended(false, for: second)
            XCTAssertFalse(view.isSuspended)
            XCTAssertEqual(try XCTUnwrap(view.debugEmitterState).speed, 1)
        }
    }

    // MARK: - Resume does not fast-forward

    /// `beginTime` is pushed forward by the length of the pause, so the emitter picks up
    /// where it stopped instead of spraying everything it would have emitted meanwhile.
    /// The compensation has to cover the whole stacked pause, not just the last reason.
    @MainActor
    func testResumeCompensatesForTheWholeStackedPause() throws {
        let view = ParticleOverlayView(frame: Self.frame)
        view.setEffect(.rain, density: 1)
        // A fresh emitter already reports beginTime ≈ CACurrentMediaTime() (measured:
        // 21569.54 on a machine 6 hours up), so it is a time base, not a duration. The
        // invariant is the delta: b1 = now_resume - (now_pause - b0), so b1 - b0 is the
        // pause length exactly, on the first cycle and every one after it.
        let baseline = try XCTUnwrap(view.debugEmitterState).beginTime

        let pauseStart = CACurrentMediaTime()
        view.setSuspended(true, for: .runtime)
        Thread.sleep(forTimeInterval: 0.05)
        view.setSuspended(true, for: .reduceMotion)
        Thread.sleep(forTimeInterval: 0.05)

        view.setSuspended(false, for: .runtime)
        XCTAssertEqual(
            try XCTUnwrap(view.debugEmitterState).speed, 0,
            "the emitter restarted while Reduce Motion still held it"
        )
        Thread.sleep(forTimeInterval: 0.05)

        view.setSuspended(false, for: .reduceMotion)
        let pauseDuration = CACurrentMediaTime() - pauseStart
        let state = try XCTUnwrap(view.debugEmitterState)
        XCTAssertEqual(state.speed, 1)
        XCTAssertFalse(state.isHidden)
        XCTAssertGreaterThan(
            state.beginTime - baseline, 0.1,
            "beginTime was not pushed past the pause — the emitter will fast-forward"
        )
        XCTAssertEqual(state.beginTime - baseline, pauseDuration, accuracy: 0.05)
    }

    // MARK: - The system switch

    @MainActor
    func testAccessibilityNotificationSuspendsAndResumesLiveOverlays() throws {
        let controller = EnvironmentOverlayController()
        let screenID = CGDirectDisplayID(1)
        defer { controller.teardownAll() }

        // Pinned rather than read: whether the machine running this has Reduce Motion on is
        // not something the test may depend on.
        controller.reduceMotionOverride = false
        controller.apply(effect: .snow, density: 1, screenID: screenID, screenFrame: Self.frame)
        XCTAssertEqual(try reasons(controller, screenID), [])

        // Writing the override alone changes nothing: the notification is what applies it,
        // so this also proves the observer — not some read on the next unrelated call — did
        // the work below.
        controller.reduceMotionOverride = true
        XCTAssertEqual(try reasons(controller, screenID), [])

        postAccessibilityDisplayOptionsChange()
        XCTAssertEqual(try reasons(controller, screenID), .reduceMotion)

        controller.reduceMotionOverride = false
        postAccessibilityDisplayOptionsChange()
        XCTAssertEqual(try reasons(controller, screenID), [])
    }

    @MainActor
    func testRuntimeResumeLeavesAReduceMotionPauseStanding() throws {
        let controller = EnvironmentOverlayController()
        let screenID = CGDirectDisplayID(1)
        defer { controller.teardownAll() }

        controller.apply(effect: .snow, density: 1, screenID: screenID, screenFrame: Self.frame)
        controller.reduceMotionOverride = true
        postAccessibilityDisplayOptionsChange()

        controller.setRuntimeSuspended(true, screenID: screenID)
        XCTAssertEqual(try reasons(controller, screenID), [.runtime, .reduceMotion])

        controller.setRuntimeSuspended(false, screenID: screenID)
        XCTAssertEqual(
            try reasons(controller, screenID), .reduceMotion,
            "the runtime resume also cleared the Reduce Motion pause"
        )
    }

    /// An overlay built while the switch is already on must start paused — nothing will
    /// post a notification just because a new display arrived.
    @MainActor
    func testOverlayCreatedWhileReduceMotionIsOnStartsPaused() throws {
        let controller = EnvironmentOverlayController()
        let screenID = CGDirectDisplayID(1)
        defer { controller.teardownAll() }

        controller.reduceMotionOverride = true
        controller.apply(effect: .snow, density: 1, screenID: screenID, screenFrame: Self.frame)

        XCTAssertEqual(try reasons(controller, screenID), .reduceMotion)
    }

    // MARK: - Observer lifetime

    @MainActor
    func testTeardownStopsWatchingTheAccessibilitySetting() {
        let controller = EnvironmentOverlayController()
        let screenID = CGDirectDisplayID(1)

        controller.apply(effect: .snow, density: 1, screenID: screenID, screenFrame: Self.frame)
        XCTAssertTrue(controller.debugIsWatchingReduceMotion)

        controller.teardownAll()
        XCTAssertFalse(controller.debugIsWatchingReduceMotion)

        controller.reduceMotionOverride = true
        postAccessibilityDisplayOptionsChange()
        XCTAssertNil(
            controller.debugSuspensionReasons(screenID: screenID),
            "a torn-down display still answered the accessibility notification"
        )
    }

    @MainActor
    func testDroppingTheLastDisplayStopsWatchingTheAccessibilitySetting() {
        let controller = EnvironmentOverlayController()
        defer { controller.teardownAll() }

        controller.apply(
            effect: .snow, density: 1, screenID: CGDirectDisplayID(1), screenFrame: Self.frame
        )
        controller.apply(
            effect: .snow, density: 1, screenID: CGDirectDisplayID(2), screenFrame: Self.frame
        )

        controller.retainOnly([CGDirectDisplayID(1)])
        XCTAssertTrue(
            controller.debugIsWatchingReduceMotion,
            "the watcher stopped while a display still had particles"
        )

        controller.retainOnly([])
        XCTAssertFalse(controller.debugIsWatchingReduceMotion)
    }
}
