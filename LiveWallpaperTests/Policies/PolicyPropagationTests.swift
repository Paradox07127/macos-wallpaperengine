import AppKit
import Foundation
import LiveWallpaperCore
import Testing

@testable import LiveWallpaper

/// P0 wiring tests: a policy profile handed to a real session must actually
/// reach the resource that plays, and must never touch the user's intent.
/// Video is observed through the player's own drive flags (`loadImmediately:
/// false` keeps AVFoundation out of the loop); HTML through the effective
/// profile the session pushes at its performance target.
@MainActor
@Suite("Policy propagation into real sessions")
struct PolicyPropagationTests {
    private func makeVideoRig() -> (session: VideoWallpaperSession, player: WallpaperVideoPlayer) {
        let player = WallpaperVideoPlayer(
            url: URL(fileURLWithPath: "/tmp/policy-propagation-\(UUID().uuidString).mov"),
            frame: CGRect(x: 0, y: 0, width: 100, height: 100),
            loadImmediately: false
        )
        return (VideoWallpaperSession(player: player), player)
    }

    @Test("A suspended video session stops its player and keeps intent")
    func videoSuspendActuallyStopsThePlayer() {
        let (session, player) = makeVideoRig()
        defer { session.cleanup() }

        session.applyPerformanceProfile(.quality)
        #expect(player.shouldAutoplayWhenReady)
        #expect(!player.isSuspended)

        session.applyPerformanceProfile(.suspended)

        #expect(!player.shouldAutoplayWhenReady, "The session must drive the player to pause, not just flag itself")
        #expect(player.isSuspended, "Resource depth must follow the suspend")
        #expect(player.particleEffectsSuspended, "Particles ride the policy profile")
        #expect(!session.isPlaying)
        #expect(session.userIntendsToPlay, "Policy must never rewrite intent")
    }

    @Test("Quality restores a suspended video session")
    func videoQualityRestoresTheDrive() {
        let (session, player) = makeVideoRig()
        defer { session.cleanup() }

        session.applyPerformanceProfile(.suspended)
        session.applyPerformanceProfile(.quality)

        #expect(player.shouldAutoplayWhenReady, "Recovery must re-arm playback")
        #expect(!player.isSuspended)
        #expect(!player.particleEffectsSuspended)
        #expect(session.userIntendsToPlay)
    }

    @Test("Quality respects a video session's manual pause")
    func videoQualityRespectsIntent() {
        let (session, player) = makeVideoRig()
        defer { session.cleanup() }

        session.pause()
        session.applyPerformanceProfile(.suspended)
        session.applyPerformanceProfile(.quality)

        #expect(!session.userIntendsToPlay)
        #expect(!player.shouldAutoplayWhenReady, "A lifted gate must not overrule the user's pause")
        #expect(!player.particleEffectsSuspended, "A manual pause leaves particles running")
    }

    @Test("An HTML session folds the suspend into its renderer and keeps intent")
    func htmlSuspendReachesTheRenderer() {
        let target = RecordingPerformanceTarget()
        let session = AmbientWallpaperSession(
            window: NSWindow(),
            wallpaperType: .html,
            performanceTarget: target
        )
        defer { session.cleanup() }

        session.applyPerformanceProfile(.suspended)
        #expect(target.applied.last == .suspended, "The renderer must actually stop")
        #expect(session.userIntendsToPlay, "Policy must never rewrite intent")
        #expect(!session.isPlaying)

        session.applyPerformanceProfile(.quality)
        #expect(target.applied.last == .quality)
        #expect(session.isPlaying)

        // And a lifted gate still respects a manual pause.
        session.pause()
        session.applyPerformanceProfile(.quality)
        #expect(target.applied.last == .suspended, "Effective output folds intent, not just policy")
        #expect(!session.userIntendsToPlay)
    }
}

@MainActor
private final class RecordingPerformanceTarget: WallpaperPerformanceConfigurable {
    private(set) var applied: [WallpaperPerformanceProfile] = []

    func applyPerformanceProfile(_ profile: WallpaperPerformanceProfile) {
        applied.append(profile)
    }
}
