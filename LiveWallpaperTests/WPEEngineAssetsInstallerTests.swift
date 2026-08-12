#if !LITE_BUILD
import Foundation
import Testing
@testable import LiveWallpaper

@Suite("WPE engine-assets install: scripts, version parsing, safe prune")
struct WPEEngineAssetsInstallerTests {
    // MARK: - Build-id parsing

    @Test("ACF buildid is parsed from an appmanifest")
    func parseACFBuildID() {
        let acf = """
        "AppState"
        {
        \t"appid"\t\t"431960"
        \t"installdir"\t\t"wallpaper_engine"
        \t"buildid"\t\t"17654321"
        }
        """
        #expect(SteamCMDDoctorService.parseACFBuildID(acf) == "17654321")
        #expect(SteamCMDDoctorService.parseACFBuildID("no build id here") == nil)
    }

    @Test("Public-branch buildid is parsed, ignoring the beta branch")
    func parsePublicBuildID() {
        let appInfo = """
        "431960"
        {
        \t"depots"
        \t{
        \t\t"branches"
        \t\t{
        \t\t\t"public"
        \t\t\t{
        \t\t\t\t"buildid"\t\t"17654321"
        \t\t\t\t"timeupdated"\t\t"1700000000"
        \t\t\t}
        \t\t\t"beta"
        \t\t\t{
        \t\t\t\t"buildid"\t\t"99999999"
        \t\t\t}
        \t\t}
        \t}
        }
        """
        #expect(SteamCMDDoctorService.parsePublicBuildID(fromAppInfo: appInfo) == "17654321")
        #expect(SteamCMDDoctorService.parsePublicBuildID(fromAppInfo: "garbage") == nil)
    }

    // MARK: - Cross-platform staging (app_update never commits on macOS)


    @Test("Public buildid parse doesn't fall through to a sibling branch")
    func publicBuildIDDoesNotLeakFromSibling() {
        let appInfo = """
        "431960"
        {
        \t"depots"
        \t{
        \t\t"branches"
        \t\t{
        \t\t\t"public"
        \t\t\t{
        \t\t\t\t"description"\t\t"stable"
        \t\t\t}
        \t\t\t"beta"
        \t\t\t{
        \t\t\t\t"buildid"\t\t"99999999"
        \t\t\t}
        \t\t}
        \t}
        }
        """
        #expect(SteamCMDDoctorService.parsePublicBuildID(fromAppInfo: appInfo) == nil)
    }

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


    @Test("Content is complete only when materials/models/shaders are all present")
    func contentCompletenessRequiresFrameworkDirs() throws {
        let fm = FileManager.default
        let root = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
            .appendingPathComponent("Library/Caches/lw-complete-test-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: root) }
        let assets = root.appendingPathComponent("assets", isDirectory: true)
        for sub in ["materials", "models"] {
            try fm.createDirectory(at: assets.appendingPathComponent(sub), withIntermediateDirectories: true)
        }
        #expect(SteamCMDDoctorService.isWPEContentComplete(installRoot: root, fileManager: fm) == false)
        try fm.createDirectory(at: assets.appendingPathComponent("shaders"), withIntermediateDirectories: true)
        #expect(SteamCMDDoctorService.isWPEContentComplete(installRoot: root, fileManager: fm) == true)
    }
}
#endif
