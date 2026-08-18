import AppKit
import Foundation
import LiveWallpaperCore
import Testing

@testable import LiveWallpaper

private final class FakeUserPresenceProbe: UserPresenceProbing, @unchecked Sendable {
    // Mutated only from the @MainActor test body before each read; no concurrent access.
    var displayAsleep = false
    var mainDisplayActive = true
    var lockState = ScreenLockState.unlocked

    func isAnyDisplayAsleep() -> Bool { displayAsleep }
    func isMainDisplayActive() -> Bool { mainDisplayActive }
    func screenLockState() -> ScreenLockState { lockState }
}

@MainActor
@Suite("Stale user absence revalidation")
struct UserAbsenceRevalidationTests {
    private func makeManager(probe: FakeUserPresenceProbe) -> ScreenManager {
        ScreenManager(startupOptions: ScreenManagerStartupOptions(
            restoreSavedWallpapers: false,
            startAutomation: false,
            fullScreenDetector: FakeFullScreenDetector(),
            userPresenceProbe: probe,
            absenceRevalidationGrace: .zero,
            featureCatalog: FeatureCatalog(capabilities: .pro)
        ))
    }

    @Test("A display-sleep absence that outlived its wake notification is cleared")
    func staleDisplaySleepAbsenceIsCleared() {
        let probe = FakeUserPresenceProbe()
        let manager = makeManager(probe: probe)

        // The wake notification never arrived, so the reason is still set while
        // the display is in fact awake.
        manager.userAbsenceReasons.insert(.displaySleep)
        probe.displayAsleep = false

        manager.revalidateUserAbsence()

        #expect(!manager.isUserAbsent, "An awake display must not stay marked absent")
    }

    @Test("A lock absence is cleared only when the session and the display agree")
    func staleLockAbsenceNeedsCorroboration() {
        let probe = FakeUserPresenceProbe()
        let manager = makeManager(probe: probe)

        manager.userAbsenceReasons.insert(.screenLocked)
        probe.lockState = .unlocked
        probe.mainDisplayActive = false

        manager.revalidateUserAbsence()
        #expect(manager.isUserAbsent, "An inactive display must not corroborate an unlock")

        probe.mainDisplayActive = true
        manager.revalidateUserAbsence()
        #expect(!manager.isUserAbsent, "Session unlocked plus an active display must clear it")
    }

    @Test("An unreadable lock state leaves the absence alone")
    func unknownLockStateIsNotTreatedAsUnlocked() {
        let probe = FakeUserPresenceProbe()
        let manager = makeManager(probe: probe)

        manager.userAbsenceReasons.insert(.screenLocked)
        probe.lockState = .unknown

        manager.revalidateUserAbsence()

        #expect(manager.isUserAbsent, "`unknown` must never be read as `unlocked`")
    }

    @Test("A real lock is never cleared, and system sleep is never revalidated")
    func genuineAbsencesSurvive() {
        let probe = FakeUserPresenceProbe()
        let manager = makeManager(probe: probe)

        manager.userAbsenceReasons.insert(.screenLocked)
        probe.lockState = .locked
        manager.revalidateUserAbsence()
        #expect(manager.isUserAbsent, "A locked session must stay absent")

        manager.userAbsenceReasons = [.systemSleep]
        probe.lockState = .unlocked
        manager.revalidateUserAbsence()
        #expect(manager.isUserAbsent, "System sleep is only ever lifted by its wake notification")
    }

    @Test("A just-recorded absence is not second-guessed by a lagging probe")
    func freshAbsenceSurvivesTheGracePeriod() {
        let probe = FakeUserPresenceProbe()
        // Production-like grace: the notification beats CoreGraphics.
        let manager = ScreenManager(startupOptions: ScreenManagerStartupOptions(
            restoreSavedWallpapers: false,
            startAutomation: false,
            fullScreenDetector: FakeFullScreenDetector(),
            userPresenceProbe: probe,
            absenceRevalidationGrace: .seconds(10),
            featureCatalog: FeatureCatalog(capabilities: .pro)
        ))

        // Exactly what handleDisplaySleep does: record, then refresh policy —
        // which revalidates in the same call stack.
        manager.userAbsenceReasons.insert(.displaySleep)
        manager.absenceMarkedAt[.displaySleep] = ContinuousClock.now
        probe.displayAsleep = false  // CoreGraphics has not caught up yet

        manager.revalidateUserAbsence()

        #expect(
            manager.isUserAbsent,
            "A lagging probe must not clear an absence that was just recorded"
        )
    }

    @Test("Once settled, the same lagging-probe reading does clear it")
    func settledAbsenceIsStillCleared() {
        let probe = FakeUserPresenceProbe()
        let manager = makeManager(probe: probe)  // grace .zero == already settled

        manager.userAbsenceReasons.insert(.displaySleep)
        manager.absenceMarkedAt[.displaySleep] = ContinuousClock.now
        probe.displayAsleep = false

        manager.revalidateUserAbsence()

        #expect(!manager.isUserAbsent, "Past the grace period the probe is authoritative")
    }

    /// Source-pinned rather than behavioural: a partially-asleep multi-display
    /// rig is the only state that separates the two APIs, and it cannot be
    /// constructed in-process. `CGGetActiveDisplayList` excludes asleep
    /// displays by definition, so searching it for one never matches — probed
    /// live on a sleeping Mac: active 0, online 2, main isAsleep 1.
    @Test("The sleep probe enumerates online displays, never the active list")
    func sleepProbeUsesOnlineDisplayList() throws {
        let source = try RepositoryRoot.source(
            "LiveWallpaper/Infrastructure/Platform/UserPresenceProbe.swift"
        )
        #expect(source.contains("CGGetOnlineDisplayList"))
        #expect(
            !source.contains("CGGetActiveDisplayList("),
            "Active displays are awake by definition; that list can never contain a sleeping display"
        )
    }
}
