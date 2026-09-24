import Foundation
import Testing

@Suite("Settings confirmations — source contract")
struct SettingsConfirmationSourceTests {
    @Test("Workshop actions with a cost ask for confirmation first")
    func costlyWorkshopActionsConfirmFirst() throws {
        let stagedActions = [
            "LiveWallpaper/Views/Settings/WorkshopAPIKeySection.swift": "PendingDestructive(.forgetSteamWebAPIKey",
            "LiveWallpaper/Views/Settings/WorkshopConnectionSetup.swift": "PendingDestructive(.removeManagedSteamCMD",
        ]
        for (path, pending) in stagedActions {
            let source = try RepositoryRoot.source(path)
            let stagesConfirmation = source.contains(pending)
            let presentsConfirmation = source.contains(".confirmDestructive($pendingDestructive)")
            #expect(stagesConfirmation, "\(path) runs the action without staging a confirmation")
            #expect(presentsConfirmation, "\(path) stages a confirmation that nothing presents")
        }
    }

    @Test("The Add Video sheet hangs on a level that a status change does not tear down")
    func addVideoSheetOutlivesStatusChanges() throws {
        let source = try RepositoryRoot.source("LiveWallpaper/Views/Settings/SystemWallpaperSettingsView.swift")
        let embedsStatusBoundMenu = source.contains("SystemWallpaperAddMenu(")
        let presentsSheet = source.contains(".sheet(isPresented:")
        let hostsAddSheet = source.contains("SystemWallpaperAddSheet(")
        #expect(!embedsStatusBoundMenu, "the .empty branch embeds a menu that owns the sheet, so the first successful publish tears it down")
        #expect(presentsSheet, "the settings page presents no sheet of its own")
        #expect(hostsAddSheet, "the settings page's sheet does not host SystemWallpaperAddSheet")
    }
}
