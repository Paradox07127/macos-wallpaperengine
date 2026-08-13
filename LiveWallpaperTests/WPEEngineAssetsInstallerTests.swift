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
}
#endif
