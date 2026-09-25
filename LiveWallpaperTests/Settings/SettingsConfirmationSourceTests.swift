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

    @Test("The Add Video sheet cannot be closed while it publishes")
    func addVideoSheetStaysOpenWhilePublishing() throws {
        let source = try RepositoryRoot.source("LiveWallpaper/Views/SystemWallpaper/SystemWallpaperAddSheet.swift")
        let footer = try Self.slice(source, from: "SheetFooterBar(", to: ".frame(width:")
        let chooseFiles = try Self.slice(source, from: "private var chooseFilesRow", to: "private func toggle")
        let footerLocks = footer.contains(".disabled(isPublishing)")
        let chooseFilesLocks = chooseFiles.contains(".disabled(isPublishing)")
        let addStaysGated = footer.contains("primaryDisabled: selection.isEmpty || isPublishing")
        #expect(footerLocks, "Cancel and its Esc shortcut close the sheet mid-publish, so later failures have nowhere to show")
        #expect(chooseFilesLocks, "Choose Files closes the sheet mid-publish, so later failures have nowhere to show")
        #expect(addStaysGated, "Add can start a second publish while one is running")
    }

    @Test("Both Copy buttons in Settings tell VoiceOver the copy happened")
    func copyButtonsAnnounceSuccess() throws {
        let about = try RepositoryRoot.source("LiveWallpaper/Views/Settings/AboutTab.swift")
        let advanced = try RepositoryRoot.source("LiveWallpaper/Views/Settings/AdvancedSection.swift")
        let copyVersion = try Self.slice(about, from: "struct CopyVersionButton", to: "struct AboutAction")
        let summaryStart = try #require(advanced.range(of: "struct CopyDiagnosticSummaryButton"))
        let copySummary = advanced[summaryStart.lowerBound...]
        let announcement = "AccessibilityNotification.Announcement("
        let versionSliceFound = copyVersion.contains(".accessibilityLabel(Text(\"Copy version\"))")
        let summarySliceFound = copySummary.contains("\"Copy diagnostic summary\"")
        let versionAnnounces = copyVersion.contains(announcement)
        let summaryAnnounces = copySummary.contains(announcement)
        #expect(versionSliceFound, "the slice no longer covers the Copy version button")
        #expect(summarySliceFound, "the slice no longer covers the Copy diagnostic summary button")
        #expect(versionAnnounces, "Copy version only swaps its icon, so VoiceOver hears nothing after copying")
        #expect(summaryAnnounces, "Copy diagnostic summary only changes its visible title, so VoiceOver hears nothing after copying")
    }

    private static func slice(_ source: String, from start: String, to end: String) throws -> String {
        let startRange = try #require(source.range(of: start))
        let endRange = try #require(source.range(of: end, range: startRange.upperBound ..< source.endIndex))
        return String(source[startRange.lowerBound ..< endRange.lowerBound])
    }
}
