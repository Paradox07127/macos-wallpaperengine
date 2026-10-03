import AppKit
import Foundation
@testable import LiveWallpaper
import LiveWallpaperCore
import Testing

@Suite("Wallpaper automation manual rotation reset")
@MainActor
struct WallpaperAutomationRotationResetTests {
    private struct Outcome {
        var rotationsAt31: Int
        var rotationsAt59_5: Int
    }

    @Test("Manual apply restarts the rotation countdown", .timeLimit(.minutes(1)))
    func manualApplyRestartsCountdown() async throws {
        let outcome = try #require(await runTimeline(resetAtMinute: 29.5))
        #expect(outcome.rotationsAt31 == 0)
        #expect(outcome.rotationsAt59_5 == 1)
    }

    @Test("Without a manual apply the original countdown fires", .timeLimit(.minutes(1)))
    func countdownFiresWithoutReset() async throws {
        let outcome = try #require(await runTimeline(resetAtMinute: nil))
        #expect(outcome.rotationsAt31 == 1)
    }

    @Test("Applying a scheme restarts the rotation countdown")
    func schemeApplyRestartsCountdown() throws {
        let source = try RepositoryRoot.source("LiveWallpaper/App/ScreenManager+Schemes.swift")
        let start = try #require(source.range(of: "func applyScheme(")?.lowerBound)
        let dispatch = try #require(source.range(of: "restoreWallpaperSession(", range: start ..< source.endIndex)?.lowerBound)
        #expect(source[start ..< dispatch].contains("automationCoordinator.resetRotationClock(for: screen.id)"))
    }

    private func runTimeline(resetAtMinute: Double?) async -> Outcome? {
        guard let nsScreen = NSScreen.screens.first else {
            Issue.record("No NSScreen available for test")
            return nil
        }
        let screen = Screen(nsScreen: nsScreen)
        let ticks = AsyncStream<Date>.makeStream()
        let coordinator = WallpaperAutomationCoordinator(tickStreamFactory: { ticks.stream })
        let configuration = ScreenConfiguration(
            screenID: screen.id,
            videoBookmarkData: Data([0x01]),
            playlistBookmarks: [Data([0x02])],
            playlistRotationMinutes: 30
        )
        var rotations = 0
        coordinator.start(
            screenProvider: { [screen] },
            configurationProvider: { _ in configuration },
            scheduleHandler: { _ in },
            playlistHandler: { _ in rotations += 1 },
            runInitialScheduleCheck: false
        )
        defer { coordinator.stop() }

        let t0 = Date(timeIntervalSince1970: 1000)
        func tick(atMinute minute: Double) async {
            let now = t0.addingTimeInterval(minute * 60)
            ticks.continuation.yield(now)
            // processTick runs synchronously on the main actor, so the handler has run once currentTime moves.
            while coordinator.currentTime != now {
                await Task.yield()
            }
        }

        await tick(atMinute: 0)
        if let resetAtMinute {
            coordinator.resetRotationClock(for: screen.id, at: t0.addingTimeInterval(resetAtMinute * 60))
        }
        await tick(atMinute: 31)
        let at31 = rotations
        await tick(atMinute: 59.5)
        return Outcome(rotationsAt31: at31, rotationsAt59_5: rotations)
    }
}
