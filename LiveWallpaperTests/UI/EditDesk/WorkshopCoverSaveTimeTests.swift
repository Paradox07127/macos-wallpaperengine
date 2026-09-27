#if !LITE_BUILD
import CoreGraphics
import Foundation
@testable import LiveWallpaper
import LiveWallpaperCore
import Testing

@MainActor
@Suite("Workshop cover save time")
struct WorkshopCoverSaveTimeTests {
    @Test("Only an import applied since it was made saves a cover: a download or an update leaves the old version running")
    func onlyAnAppliedImportSavesTheCover() {
        let importedAt = Date(timeIntervalSince1970: 1_727_000_000)
        let origin = WPEOrigin(
            workshopID: "3413921910", title: "Meteors", originalType: .scene, sourceFolderBookmark: Data([4]),
            cacheRelativePath: nil, previewFileName: nil
        )
        let scene = SceneDescriptor(workshopID: "3413921910", cacheRelativePath: "3413921910", entryFile: "scene.json", capabilityTier: .imageOnly)
        var configuration = ScreenConfiguration(screenID: 1, wallpaper: .scene(scene))
        configuration.wpeOrigin = origin
        func target(lastUsedAt: Date?) -> WPEHistoryEntry? {
            HomePage.workshopCoverEntry(running: configuration, in: [WPEHistoryEntry(origin: origin, importedAt: importedAt, lastUsedAt: lastUsedAt)])
        }
        #expect(target(lastUsedAt: nil) == nil, "an import not applied yet (a download, an update) saves the running session's frame")
        #expect(target(lastUsedAt: importedAt.addingTimeInterval(-60)) == nil, "an import last applied before it was made saves the running session's frame")
        #expect(target(lastUsedAt: importedAt) != nil, "control: an import applied from the library, which stamps both at once, saves nothing")
        #expect(target(lastUsedAt: importedAt.addingTimeInterval(60)) != nil, "control: an import applied after it was made saves nothing")
    }

    @Test("A capture asked for while a display's switch waits saves when that wait ends, whatever asked for it")
    func aCaptureDuringASwitchsWaitSavesAfterIt() {
        let delay = HomePage.workshopCoverDelay
        let start = ContinuousClock.now
        var notBefore: [CGDirectDisplayID: ContinuousClock.Instant] = [:]
        func saveTime(_ display: CGDirectDisplayID, afterSwitch: Bool, at offset: Duration) -> ContinuousClock.Instant {
            HomePage.workshopCoverSaveTime(on: display, afterSwitch: afterSwitch, at: start + offset, notBefore: &notBefore)
        }
        #expect(saveTime(1, afterSwitch: false, at: .zero) == start, "control: a display that has not switched since the page opened waits")
        #expect(saveTime(1, afterSwitch: true, at: .seconds(1)) == start + .seconds(1) + delay)
        #expect(
            saveTime(1, afterSwitch: false, at: .seconds(4)) == start + .seconds(1) + delay,
            "a recapture 3 s into the switch's wait saves a frame of the opening"
        )
        #expect(saveTime(2, afterSwitch: false, at: .seconds(4)) == start + .seconds(4), "control: the switch holds another display too")
        #expect(saveTime(1, afterSwitch: false, at: .seconds(1) + delay) == start + .seconds(1) + delay, "control: past the wait, a capture still waits")
        #expect(saveTime(1, afterSwitch: true, at: .seconds(30)) == start + .seconds(30) + delay, "a later switch does not start its own wait")
    }

    @Test("HomePage takes each capture's save time from its display's switch record, and nothing else picks a wait")
    func homePageSavesAtTheRecordedTime() throws {
        let code = try RepositoryRoot.source("LiveWallpaper/Views/EditDesk/Shell/HomePage.swift")
            .split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")
        #expect(code.contains("workshopCoverSaveTime(on: id, afterSwitch: crossfade, at: .now, notBefore: &workshopCoverNotBefore)"))
        #expect(code.contains("saveWorkshopCover(for: id, generation: generation, at: saveAt)"))
        let uses = code.components(separatedBy: "workshopCoverDelay").count - 1
        #expect(uses == 2, Comment(rawValue: "workshopCoverDelay is used \(uses) times: a second place picks a save's wait"))
    }
}
#endif
