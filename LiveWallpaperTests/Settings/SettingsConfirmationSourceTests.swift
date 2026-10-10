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

    @Test("The project settings card confirms before it turns on web interaction")
    func projectSettingsEnableConfirmsFirst() throws {
        let card = try RepositoryRoot.source("LiveWallpaper/Views/ScreenDetail/ProjectSettingsCard.swift")
        let playback = try RepositoryRoot.source("LiveWallpaper/Views/ScreenDetail/PlaybackControls.swift")
        // The alert's own Enable button can come first in the file, so the slice starts at the gate's notice.
        let gate = try Self.slice(card, from: "Interaction is off; mouse options may not respond.", to: "Divider()")
        let sliceFound = gate.contains("Button(\"Enable\")")
        let checksAcknowledgement = gate.contains("webInteractionAcknowledged")
        let presentsConfirmation = card.contains(".alert(\"Enable Wallpaper Interaction?\"")
        let playbackConfirms = playback.contains("pendingInteraction = .html")
        #expect(sliceFound, "the slice no longer covers the card's Enable button")
        #expect(checksAcknowledgement, "Enable turns on web interaction without the first-use confirmation")
        #expect(presentsConfirmation, "the card never presents the interaction confirmation")
        #expect(playbackConfirms, "control: the playback web Interaction switch no longer stages its confirmation")
    }

    private static func slice(_ source: String, from start: String, to end: String) throws -> String {
        let startRange = try #require(source.range(of: start))
        let endRange = try #require(source.range(of: end, range: startRange.upperBound ..< source.endIndex))
        return String(source[startRange.lowerBound ..< endRange.lowerBound])
    }
}
