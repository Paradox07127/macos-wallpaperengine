#if !LITE_BUILD
import Foundation
import Testing
@testable import LiveWallpaper

@Suite("WPE engine-assets install: scripts, version parsing, safe prune")
struct WPEEngineAssetsInstallerTests {
    // MARK: - Cross-platform staging (app_update never commits on macOS)

    @Test("Update check outcome distinguishes available, up-to-date, and failed checks")
    func updateCheckOutcomeHasStableSettingsStates() {
        #expect(WPEEngineAssetsInstaller.UpdateCheckOutcome.resolve(
            installedBuildID: "10",
            lookup: .found("11")
        ) == .available(latestBuildID: "11"))
        #expect(WPEEngineAssetsInstaller.UpdateCheckOutcome.resolve(
            installedBuildID: "10",
            lookup: .found("10")
        ) == .upToDate(buildID: "10"))
        #expect(WPEEngineAssetsInstaller.UpdateCheckOutcome.resolve(
            installedBuildID: nil,
            lookup: .found("11")
        ) == .unableToCompare)
        #expect(WPEEngineAssetsInstaller.UpdateCheckOutcome.resolve(
            installedBuildID: "10",
            lookup: nil
        ) == .checkFailed)
    }

    /// An expired Steam session used to arrive as a bare nil build id and was
    /// rendered as "SteamCMD did not return the latest Wallpaper Engine build"
    /// — a sentence with no next step, next to an account row still showing
    /// green.
    @Test("A refused Steam session is reported as a sign-in problem, not a failed check")
    func expiredSessionIsDistinguishedFromAFailedCheck() {
        #expect(WPEEngineAssetsInstaller.UpdateCheckOutcome.resolve(
            installedBuildID: "10",
            lookup: .failed(.loginRequired)
        ) == .loginRequired)
        // Control: the other three failures stay a plain failed check, so the
        // sign-in copy is not shown for problems signing in cannot fix.
        for outcome in [SteamEngineBuildLookup.Outcome.timedOut, .steamCMDUnavailable, .unrecognized] {
            #expect(WPEEngineAssetsInstaller.UpdateCheckOutcome.resolve(
                installedBuildID: "10",
                lookup: .failed(outcome)
            ) == .checkFailed)
        }
    }

    @Test("A refused session demotes the cached-login verdict")
    @MainActor
    func expiredSessionNotifiesTheCaller() async {
        let installer = WPEEngineAssetsInstaller(
            managedStateForTesting: (hasManagedInstall: true, installedBuildID: "10")
        )
        var demoted = false
        installer.checkForUpdate(
            account: "steamuser",
            binaryResolvable: true,
            fetchLatestBuildID: { _, _ in .failed(.loginRequired) },
            onLoginRequired: { demoted = true }
        )
        while installer.isBusy { await Task.yield() }

        #expect(installer.updateCheckOutcome == .loginRequired)
        #expect(demoted, "the account row keeps a stale green unless the probe is knocked back")
        #expect(installer.updateAvailable == false)
    }

    @Test("Control: a successful check does not demote the cached-login verdict")
    @MainActor
    func successfulCheckDoesNotDemote() async {
        let installer = WPEEngineAssetsInstaller(
            managedStateForTesting: (hasManagedInstall: true, installedBuildID: "10")
        )
        var demoted = false
        installer.checkForUpdate(
            account: "steamuser",
            binaryResolvable: true,
            fetchLatestBuildID: { _, _ in .found("11") },
            onLoginRequired: { demoted = true }
        )
        while installer.isBusy { await Task.yield() }

        #expect(installer.updateCheckOutcome == .available(latestBuildID: "11"))
        #expect(!demoted)
    }

    // MARK: - Stuck-busy regression: a failed precondition must never leave `.checking`

    @Test("Update check without a Steam account leaves the installer idle, not stuck busy")
    @MainActor
    func updateCheckWithoutAccountDoesNotStayBusy() {
        let installer = WPEEngineAssetsInstaller(
            managedStateForTesting: (hasManagedInstall: true, installedBuildID: "10")
        )
        installer.checkForUpdate(account: nil, binaryResolvable: true) { _, _ in nil }
        #expect(installer.isBusy == false)
        #expect(installer.phase == .idle)
        #expect(installer.updateCheckOutcome == .notChecked)
    }

    @Test("Update check without a resolvable binary leaves the installer idle, not stuck busy")
    @MainActor
    func updateCheckWithoutBinaryDoesNotStayBusy() {
        let installer = WPEEngineAssetsInstaller(
            managedStateForTesting: (hasManagedInstall: true, installedBuildID: "10")
        )
        installer.checkForUpdate(account: "steamuser", binaryResolvable: false) { _, _ in nil }
        #expect(installer.isBusy == false)
        #expect(installer.phase == .idle)
        #expect(installer.updateCheckOutcome == .notChecked)
    }

    @Test("Control: satisfied preconditions do enter .checking, and cancel restores idle")
    @MainActor
    func updateCheckWithSatisfiedPreconditionsGoesBusyAndCancelRecovers() {
        let installer = WPEEngineAssetsInstaller(
            managedStateForTesting: (hasManagedInstall: true, installedBuildID: "10")
        )
        installer.checkForUpdate(account: "steamuser", binaryResolvable: true) { _, _ in
            // Never resolves within the test; cancel() must be what recovers.
            try? await Task.sleep(nanoseconds: 60_000_000_000)
            return nil
        }
        #expect(installer.isBusy)
        #expect(installer.phase == .checking)
        #expect(installer.updateCheckOutcome == .checking)

        installer.cancel()
        #expect(installer.isBusy == false)
        #expect(installer.phase == .idle)
        #expect(installer.updateCheckOutcome == .notChecked)
    }
}
#endif
