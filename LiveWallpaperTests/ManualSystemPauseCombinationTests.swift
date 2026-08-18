import AppKit
import Foundation
import LiveWallpaperCore
import Testing

@testable import LiveWallpaper

/// P0 wiring tests: the full {user intent × system gate} grid on a real
/// session, entered in both orders, with every cell asserting the same four
/// outputs — intent, effective profile, summary activity, and the direction
/// the play button would take (`ScreenManager.shouldPauseOnToggle`).
///
/// Driven on `AmbientWallpaperSession`: it is a real production session whose
/// summary carries the three-way mapping (playing / policySuspended / paused)
/// without needing a loaded AVFoundation player underneath.
@MainActor
@Suite("Manual and system pause combinations")
struct ManualSystemPauseCombinationTests {
    private struct Rig {
        let session: AmbientWallpaperSession
        let target: RecordingPerformanceTarget
    }

    private func makeRig() -> Rig {
        let target = RecordingPerformanceTarget()
        let session = AmbientWallpaperSession(
            window: NSWindow(),
            wallpaperType: .html,
            performanceTarget: target
        )
        return Rig(session: session, target: target)
    }

    /// One grid cell: every observable the UI or the toggle reads.
    private func assertCell(
        _ rig: Rig,
        intent: Bool,
        gated: Bool,
        _ comment: Comment
    ) {
        let session = rig.session
        #expect(session.userIntendsToPlay == intent, comment)
        #expect(
            rig.target.applied.last == ((intent && !gated) ? .quality : .suspended),
            comment
        )
        #expect(session.isPlaying == (intent && !gated), comment)
        let expectedActivity: WallpaperSessionActivity =
            !intent ? .paused : (gated ? .policySuspended : .active)
        #expect(session.summary.activity == expectedActivity, comment)
        // The button follows actual playback: it may only mean "pause" while
        // something is really running; in every other cell the tap means play.
        #expect(
            ScreenManager.shouldPauseOnToggle(session) == (intent && !gated),
            comment
        )
    }

    private func setIntent(_ rig: Rig, _ intent: Bool) {
        if intent { rig.session.play() } else { rig.session.pause() }
    }

    private func setGate(_ rig: Rig, closed: Bool) {
        rig.session.applyPerformanceProfile(closed ? .suspended : .quality)
    }

    @Test("Playing with the gate open")
    func playingAndOpen() {
        for intentFirst in [true, false] {
            let rig = makeRig()
            defer { rig.session.cleanup() }
            if intentFirst {
                setIntent(rig, true)
                setGate(rig, closed: false)
            } else {
                setGate(rig, closed: false)
                setIntent(rig, true)
            }
            assertCell(rig, intent: true, gated: false, "order intentFirst=\(intentFirst)")
        }
    }

    @Test("Playing intent under a closed gate is a policy suspend")
    func playingUnderClosedGate() {
        for intentFirst in [true, false] {
            let rig = makeRig()
            defer { rig.session.cleanup() }
            if intentFirst {
                setIntent(rig, true)
                setGate(rig, closed: true)
            } else {
                setGate(rig, closed: true)
                setIntent(rig, true)
            }
            assertCell(rig, intent: true, gated: true, "order intentFirst=\(intentFirst)")
        }
    }

    @Test("A manual pause with the gate open")
    func pausedAndOpen() {
        for intentFirst in [true, false] {
            let rig = makeRig()
            defer { rig.session.cleanup() }
            if intentFirst {
                setIntent(rig, false)
                setGate(rig, closed: false)
            } else {
                setGate(rig, closed: false)
                setIntent(rig, false)
            }
            assertCell(rig, intent: false, gated: false, "order intentFirst=\(intentFirst)")
        }
    }

    @Test("A manual pause stacked with a closed gate reads as a user pause")
    func pausedUnderClosedGate() {
        for intentFirst in [true, false] {
            let rig = makeRig()
            defer { rig.session.cleanup() }
            if intentFirst {
                setIntent(rig, false)
                setGate(rig, closed: true)
            } else {
                setGate(rig, closed: true)
                setIntent(rig, false)
            }
            assertCell(rig, intent: false, gated: true, "order intentFirst=\(intentFirst)")
        }
    }

    @Test("Stacked state, gate lifted first: still the user's pause, then play resumes")
    func stackedReleaseGateFirst() {
        let rig = makeRig()
        defer { rig.session.cleanup() }
        setIntent(rig, false)
        setGate(rig, closed: true)

        setGate(rig, closed: false)
        assertCell(rig, intent: false, gated: false, "gate lifted, pause must hold")

        setIntent(rig, true)
        assertCell(rig, intent: true, gated: false, "play after the gate lifted")
    }

    @Test("Stacked state, play pressed first: intent lands, gate still holds, then lifts")
    func stackedReleasePlayFirst() {
        let rig = makeRig()
        defer { rig.session.cleanup() }
        setIntent(rig, false)
        setGate(rig, closed: true)

        setIntent(rig, true)
        assertCell(rig, intent: true, gated: true, "play pressed under the gate")

        setGate(rig, closed: false)
        assertCell(rig, intent: true, gated: false, "gate lifted after the play press")
    }
}

@MainActor
private final class RecordingPerformanceTarget: WallpaperPerformanceConfigurable {
    private(set) var applied: [WallpaperPerformanceProfile] = []

    func applyPerformanceProfile(_ profile: WallpaperPerformanceProfile) {
        applied.append(profile)
    }
}
