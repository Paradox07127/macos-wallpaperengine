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
        // No lookup at all means the connector never answered, which is a
        // different sentence from "Steam answered with something unusable".
        #expect(WPEEngineAssetsInstaller.UpdateCheckOutcome.resolve(
            installedBuildID: "10",
            lookup: nil
        ) == .checkFailed(.notRun))
    }

    @Test("Each failed lookup keeps its own reason instead of sharing one sentence")
    func failedLookupsKeepDistinctReasons() {
        let expected: [(SteamEngineBuildLookup.Outcome, WPEEngineAssetsInstaller.UpdateCheckOutcome.CheckFailure)] = [
            (.timedOut, .timedOut),
            (.steamCMDUnavailable, .steamCMDUnavailable),
            (.unrecognized, .unparsedOutput),
            (.steamUnreachable, .steamUnreachable),
        ]
        for (outcome, failure) in expected {
            #expect(WPEEngineAssetsInstaller.UpdateCheckOutcome.resolve(
                installedBuildID: "10",
                lookup: .failed(outcome)
            ) == .checkFailed(failure))
        }
    }

    @Test("An unknown installed build offers Update instead of a dead end")
    @MainActor
    func unknownInstalledBuildOffersUpdate() async {
        let installer = WPEEngineAssetsInstaller(
            managedStateForTesting: (hasManagedInstall: true, installedBuildID: nil)
        )
        installer.checkForUpdate(binaryResolvable: true, fetchLatestBuildID: { _ in .found("11") })
        while installer.isBusy { await Task.yield() }

        #expect(installer.updateCheckOutcome == .unableToCompare)
        #expect(installer.latestBuildID == "11")
        #expect(installer.updateAvailable)
    }

    // MARK: - Update must run SteamCMD, not re-link the folder already on disk

    private actor Flag {
        var raised = false

        func raise() {
            raised = true
        }
    }

    /// A Steam library that already holds a populated
    /// `steamapps/common/wallpaper_engine/assets/` — the state every Update starts from.
    @MainActor
    private func makeDoctorWithInstallOnDisk(function: String = #function) throws -> SteamCMDDoctorService {
        let scratch = try TestScratch.defaultsSuite(
            prefix: "LiveWallpaperTests.WPEEngineAssetsInstaller", function: function
        )
        let doctor = SteamCMDDoctorService(defaults: scratch.defaults)
        let steamRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("WPEEngineAssetsInstaller-\(UUID().uuidString)", isDirectory: true)
        let assets = WPEEngineAssetsLibrary.sharedLibraryInstallRoot(steamRoot: steamRoot)
            .appendingPathComponent("assets", isDirectory: true)
        try FileManager.default.createDirectory(at: assets, withIntermediateDirectories: true)
        try Data().write(to: assets.appendingPathComponent("shaders.txt"))
        doctor.workdirBookmarkData = try steamRoot.bookmarkData()
        doctor.binaryPath = "/tmp/steamcmd"
        doctor.username = "someone"
        return doctor
    }

    @Test("Update with a managed install on disk runs SteamCMD instead of re-linking the folder")
    @MainActor
    func updateWithManagedInstallReachesConnector() async throws {
        let doctor = try makeDoctorWithInstallOnDisk()
        let installer = WPEEngineAssetsInstaller(
            managedStateForTesting: (hasManagedInstall: true, installedBuildID: nil)
        )
        let installCalled = Flag()
        installer.download(using: doctor) { _, _, _, _ in
            await installCalled.raise()
            return nil
        }
        while installer.isBusy {
            await Task.yield()
        }

        #expect(await installCalled.raised)
    }

    @Test("Control: a first download links the folder already on disk without running SteamCMD")
    @MainActor
    func firstDownloadAdoptsInstallOnDisk() async throws {
        let doctor = try makeDoctorWithInstallOnDisk()
        let installer = WPEEngineAssetsInstaller(
            managedStateForTesting: (hasManagedInstall: false, installedBuildID: nil)
        )
        defer {
            SettingsManager.shared.clearWPEEngineAssetsBookmark()
            SettingsManager.shared.wpeEngineAssetsManagedBuildID = nil
        }
        let installCalled = Flag()
        installer.download(using: doctor) { _, _, _, _ in
            await installCalled.raise()
            return nil
        }
        while installer.isBusy {
            await Task.yield()
        }

        #expect(await !installCalled.raised)
        #expect(installer.hasManagedInstall)
    }

    @Test("A newer public build is reported as available")
    @MainActor
    func newerBuildIsReportedAvailable() async {
        let installer = WPEEngineAssetsInstaller(
            managedStateForTesting: (hasManagedInstall: true, installedBuildID: "10")
        )
        installer.checkForUpdate(binaryResolvable: true, fetchLatestBuildID: { _ in .found("11") })
        while installer.isBusy {
            await Task.yield()
        }

        #expect(installer.updateCheckOutcome == .available(latestBuildID: "11"))
        #expect(installer.updateAvailable)
    }

    // MARK: - Stuck-busy regression: a failed precondition must never leave `.checking`

    @Test("Update check without a resolvable binary leaves the installer idle, not stuck busy")
    @MainActor
    func updateCheckWithoutBinaryDoesNotStayBusy() {
        let installer = WPEEngineAssetsInstaller(
            managedStateForTesting: (hasManagedInstall: true, installedBuildID: "10")
        )
        installer.checkForUpdate(binaryResolvable: false) { _ in nil }
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
        installer.checkForUpdate(binaryResolvable: true) { _ in
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
