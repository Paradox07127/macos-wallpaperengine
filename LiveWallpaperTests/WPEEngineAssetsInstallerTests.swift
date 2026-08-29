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
            latestBuildID: "11"
        ) == .available(latestBuildID: "11"))
        #expect(WPEEngineAssetsInstaller.UpdateCheckOutcome.resolve(
            installedBuildID: "10",
            latestBuildID: "10"
        ) == .upToDate(buildID: "10"))
        #expect(WPEEngineAssetsInstaller.UpdateCheckOutcome.resolve(
            installedBuildID: nil,
            latestBuildID: "11"
        ) == .unableToCompare)
        #expect(WPEEngineAssetsInstaller.UpdateCheckOutcome.resolve(
            installedBuildID: "10",
            latestBuildID: nil
        ) == .checkFailed)
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
