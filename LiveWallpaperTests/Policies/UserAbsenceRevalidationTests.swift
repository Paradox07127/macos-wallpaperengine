import AppKit
import Foundation
import LiveWallpaperCore
import Testing

@testable import LiveWallpaper

private final class FakeUserPresenceProbe: UserPresenceProbing, @unchecked Sendable {
    // Mutated only from the @MainActor test body before each read; no concurrent access.
    var allDisplaysAsleep = false
    var mainDisplayActive = true
    var lockState = ScreenLockState.unlocked

    func areAllDisplaysAsleep() -> Bool { allDisplaysAsleep }
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

        manager.userAbsenceReasons.insert(.displaySleep)
        probe.allDisplaysAsleep = false

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

        manager.userAbsenceReasons.insert(.displaySleep)
        manager.absenceMarkedAt[.displaySleep] = ContinuousClock.now
        probe.allDisplaysAsleep = false  // CoreGraphics has not caught up yet

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
        probe.allDisplaysAsleep = false

        manager.revalidateUserAbsence()

        #expect(!manager.isUserAbsent, "Past the grace period the probe is authoritative")
    }

    @Test("An absence whose only policy refresh fell inside the grace window is still cleared")
    func absenceSkippedInsideGraceIsRecheckedWithoutFurtherEvents() async throws {
        let probe = FakeUserPresenceProbe()
        let manager = ScreenManager(startupOptions: ScreenManagerStartupOptions(
            restoreSavedWallpapers: false,
            startAutomation: false,
            fullScreenDetector: FakeFullScreenDetector(),
            userPresenceProbe: probe,
            absenceRevalidationGrace: .milliseconds(200),
            absenceRevalidationPollInterval: .milliseconds(50),
            featureCatalog: FeatureCatalog(capabilities: .pro)
        ))
        // The display never actually slept — or its wake notification was lost.
        probe.allDisplaysAsleep = false

        // The only event in this test: one policy refresh, which lands inside the grace
        // window and skips revalidation. Nothing else ever pokes the manager.
        manager.setUserAbsence(.displaySleep, present: true)
        #expect(manager.isUserAbsent, "the grace window has to protect a just-recorded absence")

        let deadline = ContinuousClock.now + .seconds(5)
        while ContinuousClock.now < deadline, manager.isUserAbsent {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(
            !manager.isUserAbsent,
            "an absence skipped inside the grace window was never re-checked, so it pinned every wallpaper suspended"
        )
    }

    /// Source-pinned: the partially-asleep multi-display state that separates the two
    /// APIs cannot be constructed in-process.
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

    /// Folding with `contains` instead would let a permanently dark second display —
    /// an unplugged TV, a closed-lid external — hold the safety net off forever.
    @Test("The sleep probe demands that every online display be asleep")
    func sleepProbeRequiresEveryDisplayAsleep() throws {
        let source = try RepositoryRoot.source(
            "LiveWallpaper/Infrastructure/Platform/UserPresenceProbe.swift"
        )
        #expect(source.contains("allSatisfy { CGDisplayIsAsleep($0) != 0 }"))
        #expect(
            !source.contains("contains { CGDisplayIsAsleep"),
            "One sleeping display among awake ones is not an absence, and that display may never wake"
        )
    }
}
