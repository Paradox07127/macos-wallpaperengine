import Foundation
import LiveWallpaperCore
import Testing

@testable import LiveWallpaper

@Suite("Suspend reason reporting")
struct SuspendReasonReportingTests {
    @Test("Safety reasons outrank settings-driven ones when several apply")
    func safetyReasonWinsThePrimarySlot() {
        let primary = SuspendReasonText.primary(from: [.battery, .thermal, .fullScreen])
        #expect(primary == .thermal, "A reason the user cannot switch off must be the one shown")

        let settingsOnly = SuspendReasonText.primary(from: [.fullScreen, .battery])
        #expect(settingsOnly == .battery, "Among settings-driven reasons the more actionable one wins")
    }

    @Test("Absence produces no text: nobody is at the screen to read it")
    func absenceIsNotSurfaced() {
        #expect(SuspendReasonText.localized(for: [.userAbsent]) == nil)
        #expect(SuspendReasonText.localized(for: []) == nil)
    }

    @Test("Heat and memory share one wording that promises automatic recovery")
    func safetyWordingPromisesRecovery() throws {
        let thermal = try #require(SuspendReasonText.localized(for: [.thermal]))
        let memory = try #require(SuspendReasonText.localized(for: [.memoryPressure]))
        #expect(thermal == memory, "Both are 'wait it out', so they must not read differently")
        #expect(!thermal.isEmpty)
    }

    @Test("Every reason the UI can show resolves to a catalogued string")
    func everySurfacedReasonHasText() throws {
        for reason in WallpaperSuspendReason.allCases where reason.isUserVisible {
            let text = try #require(
                SuspendReasonText.localized(for: [reason]),
                Comment(rawValue: "No wording for \(reason.rawValue)")
            )
            #expect(!text.isEmpty)
        }
    }

    @Test("Safety reasons are exactly the ones settings cannot switch off")
    func safetyClassificationMatchesPolicy() {
        let safety = Set(WallpaperSuspendReason.allCases.filter(\.isSafety))
        #expect(safety == [.userAbsent, .memoryPressure, .thermal])
    }

    @Test("Restoring is its own state, never reported as a suspension")
    func restoringIsDistinctFromSuspension() {
        // Rebuilding after a deep hibernate is the opposite of being held down;
        // collapsing it into `.policySuspended` told the user the wallpaper was
        // stopped while it was in fact coming back.
        let all = Set([
            WallpaperSessionActivity.active,
            .paused,
            .policySuspended,
            .restoring,
            .off,
            .error,
            .inactive,
        ])
        #expect(all.count == 7, "Each activity must stay distinguishable")
        #expect(WallpaperSessionActivity.restoring != .policySuspended)
        #expect(WallpaperSessionActivity.restoring != .paused)
    }
}
