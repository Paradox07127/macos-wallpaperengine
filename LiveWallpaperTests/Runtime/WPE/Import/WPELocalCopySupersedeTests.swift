#if !LITE_BUILD
import AppKit
import Foundation
@testable import LiveWallpaper
import LiveWallpaperCore
import Testing

@Suite("A local copy shadowed by its Steam item", .serialized) @MainActor
struct WPELocalCopySupersedeTests {
    private static let controlScreenID: CGDirectDisplayID = 0xEDA0_5E02

    @Test("Superseding moves every reference to the Steam item and drops only the local copy's history entry")
    func supersedeRepointsReferences() async throws {
        let fixture = try SupersedeFixture()
        defer { fixture.discard() }
        try await withHeadlessManager(fixture) { manager, screen in
            let localEntry = WallpaperQueueEntry(title: "Lunar Tear", content: fixture.localContent, origin: fixture.local.origin)
            var configuration = fixture.configuration(on: screen)
            configuration.wallpaperQueue = [localEntry]
            configuration.scheduleSlots = [ScheduleSlot(startHour: 0, endHour: 12, label: "Morning", wallpaper: localEntry)]
            manager.saveConfiguration(configuration)
            var control = ScreenConfiguration(screenID: Self.controlScreenID, videoBookmarkData: fixture.steamVideoBookmark)
            control.wpeOrigin = fixture.steam.origin
            manager.saveConfiguration(control)
            let controlRevision = manager.configurationStore.revision(for: Self.controlScreenID)
            let bookmark = BookmarkStore.shared.add(label: "Saved", content: fixture.localContent, wpeOrigin: fixture.local.origin)
            defer { BookmarkStore.shared.remove(bookmark.id) }

            #expect(manager.supersedeLocalCopiesWithSteam() == 1)

            let settings = SettingsManager.shared.loadGlobalSettings()
            #expect(settings.recentWPEImports.map(\.origin) == [fixture.steam.origin])
            #expect(settings.recentWPEImports.first?.lastUsedAt == fixture.local.lastUsedAt)
            #expect(settings.deletedWorkshopIDs.isEmpty)

            let after = try #require(manager.configurationStore.get(for: screen.id))
            #expect(after.wpeOrigin == fixture.steam.origin)
            #expect(fixture.isSteamVideo(after.activeWallpaper))
            #expect(fixture.isSteamVideo(after.savedVideoBookmarkData.map { .video(bookmarkData: $0) }))
            #expect(after.wallpaperQueue?.map(\.id) == [localEntry.id])
            #expect(after.wallpaperQueue?.first?.origin == fixture.steam.origin)
            #expect(fixture.isSteamVideo(after.wallpaperQueue?.first?.content))
            #expect(after.scheduleSlots?.first?.wallpaper?.origin == fixture.steam.origin)
            #expect(fixture.isSteamVideo(after.scheduleSlots?.first?.wallpaper?.content))

            let savedBookmark = try #require(BookmarkStore.shared.bookmarks.first { $0.id == bookmark.id })
            #expect(savedBookmark.wpeOrigin == fixture.steam.origin)
            #expect(fixture.isSteamVideo(savedBookmark.content))

            // Control: a display already on the Steam item is not rewritten.
            #expect(manager.configurationStore.revision(for: Self.controlScreenID) == controlRevision)
            #expect(manager.configurationStore.get(for: Self.controlScreenID)?.activeWallpaper == control.activeWallpaper)
        }
    }

    @Test("Without the Steam item's folder on disk the local copy stays as it is")
    func missingSteamFolderChangesNothing() async throws {
        let fixture = try SupersedeFixture()
        defer { fixture.discard() }
        try await withHeadlessManager(fixture) { manager, screen in
            let configuration = fixture.configuration(on: screen)
            manager.saveConfiguration(configuration)
            try FileManager.default.removeItem(at: fixture.steamFolder)
            let before = SettingsManager.shared.loadGlobalSettings().recentWPEImports

            #expect(manager.supersedeLocalCopiesWithSteam() == 0)

            #expect(SettingsManager.shared.loadGlobalSettings().recentWPEImports == before)
            let after = try #require(manager.configurationStore.get(for: screen.id))
            #expect(after.wpeOrigin == fixture.local.origin)
            #expect(after.activeWallpaper == configuration.activeWallpaper)
        }
    }

    @Test("A second pass finds nothing left to supersede and writes nothing")
    func secondPassIsANoOp() async throws {
        let fixture = try SupersedeFixture()
        defer { fixture.discard() }
        try await withHeadlessManager(fixture) { manager, screen in
            manager.saveConfiguration(fixture.configuration(on: screen))
            #expect(manager.supersedeLocalCopiesWithSteam() == 1)
            let settings = SettingsManager.shared.loadGlobalSettings().recentWPEImports
            let revision = manager.configurationStore.revision(for: screen.id)

            #expect(manager.supersedeLocalCopiesWithSteam() == 0)

            #expect(SettingsManager.shared.loadGlobalSettings().recentWPEImports == settings)
            #expect(manager.configurationStore.revision(for: screen.id) == revision)
        }
    }

    @Test("A display in a scene span keeps its span group when its content moves to the Steam item")
    func spanGroupSurvives() async throws {
        let fixture = try SupersedeFixture()
        defer { fixture.discard() }
        try await withHeadlessManager(fixture) { manager, screen in
            let spanGroup = UUID()
            var configuration = fixture.configuration(on: screen)
            configuration.sceneSpanGroupID = spanGroup
            manager.saveConfiguration(configuration)

            #expect(manager.supersedeLocalCopiesWithSteam() == 1)

            let after = try #require(manager.configurationStore.get(for: screen.id))
            #expect(after.wpeOrigin == fixture.steam.origin)
            #expect(after.sceneSpanGroupID == spanGroup)
        }
    }

    @Test("A history change supersedes a local copy once the manager observes history", .timeLimit(.minutes(1)))
    func historyChangeSupersedes() async throws {
        let fixture = try SupersedeFixture()
        defer { fixture.discard() }
        try await withHeadlessManager(fixture) { manager, screen in
            manager.saveConfiguration(fixture.configuration(on: screen))
            manager.observeWPEHistoryForSupersede()

            NotificationCenter.default.post(name: .wpeHistoryDidChange, object: nil)
            var polls = 0
            while SettingsManager.shared.loadGlobalSettings().recentWPEImports.count > 1, polls < 200 {
                polls += 1
                try await Task.sleep(for: .milliseconds(10))
            }

            #expect(SettingsManager.shared.loadGlobalSettings().recentWPEImports.map(\.origin) == [fixture.steam.origin])
            #expect(manager.configurationStore.get(for: screen.id)?.wpeOrigin == fixture.steam.origin)
        }
    }

    private func withHeadlessManager(_ fixture: SupersedeFixture, _ body: (ScreenManager, Screen) async throws -> Void) async throws {
        let defaults = UserDefaults.standard
        let keys = ["screenConfigurations", "globalSettings"]
        let previousValues = keys.reduce(into: [String: Any]()) { result, key in
            result[key] = defaults.object(forKey: key)
        }
        SettingsManager.shared.cleanAllSettings(applyLoginSetting: false)
        defer {
            SettingsManager.shared.cleanAllSettings(applyLoginSetting: false)
            for key in keys {
                if let value = previousValues[key] {
                    defaults.set(value, forKey: key)
                } else {
                    defaults.removeObject(forKey: key)
                }
            }
        }
        SettingsManager.shared.recordWPEImport(fixture.steam)
        SettingsManager.shared.recordWPEImport(fixture.local)

        let screen = Screen(nsScreen: SupersedeTestNSScreen())
        let manager = ScreenManager(startupOptions: ScreenManagerStartupOptions(
            restoreSavedWallpapers: false, startAutomation: false,
            powerMonitor: FakePowerMonitor(), fullScreenDetector: FakeFullScreenDetector(),
            playableVideoLoader: FakePlayableVideoLoader(), displayRegistry: FakeDisplayRegistry(screens: [screen]),
            featureCatalog: FeatureCatalog(capabilities: .pro), originReconciler: PreservingOriginReconciler()
        ))
        defer {
            manager.tearDownForTermination()
            manager.configurationStore.remove(for: screen.id)
            manager.configurationStore.remove(for: Self.controlScreenID)
        }
        try await body(manager, screen)
    }
}

/// A Steam item and a local copy of its folder that still carries the Steam item's id, both recorded in history.
@MainActor
private struct SupersedeFixture {
    let workshopID = "2585024298"
    let root: URL
    let steamFolder: URL
    let steam: WPEHistoryEntry
    let local: WPEHistoryEntry
    let localContent: WallpaperContent
    let steamVideoBookmark: Data

    init() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("WPELocalCopySupersede-\(UUID().uuidString)", isDirectory: true)
        self.root = root
        func folder(_ relativePath: String) throws -> URL {
            let folder = root.appendingPathComponent(relativePath, isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try Data([0x00]).write(to: folder.appendingPathComponent("video.mp4"))
            return folder
        }
        func entry(_ folder: URL, importedAt: Double, lastUsedAt: Double?) throws -> WPEHistoryEntry {
            try WPEHistoryEntry(
                origin: WPEOrigin(
                    workshopID: "2585024298", title: "Lunar Tear [4K]", originalType: .video,
                    sourceFolderBookmark: #require(ResourceUtilities.createBookmark(for: folder)),
                    cacheRelativePath: "wpe-cache/2585024298", previewFileName: nil,
                    entryFile: "video.mp4", resourceLocation: .sourceFolder
                ),
                importedAt: Date(timeIntervalSince1970: importedAt),
                lastUsedAt: lastUsedAt.map { Date(timeIntervalSince1970: $0) }
            )
        }
        steamFolder = try folder("steamapps/workshop/content/431960/\(workshopID)")
        let localFolder = try folder("Wallpapers/edit")
        steam = try entry(steamFolder, importedAt: 1, lastUsedAt: nil)
        local = try entry(localFolder, importedAt: 2, lastUsedAt: 100)
        localContent = try .video(bookmarkData: #require(
            ResourceUtilities.createBookmark(for: localFolder.appendingPathComponent("video.mp4"))
        ))
        steamVideoBookmark = try #require(ResourceUtilities.createBookmark(for: steamFolder.appendingPathComponent("video.mp4")))
    }

    func configuration(on screen: Screen) -> ScreenConfiguration {
        var configuration = ScreenConfiguration(screenID: screen.id, videoBookmarkData: localContent.activeVideoBookmarkData ?? Data())
        configuration.displayFingerprint = screen.displayFingerprint
        configuration.wpeOrigin = local.origin
        return configuration
    }

    func isSteamVideo(_ content: WallpaperContent?) -> Bool {
        guard let data = content?.activeVideoBookmarkData,
              let path = URL.resourceValues(forKeys: [.pathKey], fromBookmarkData: data)?.path else { return false }
        let expected = steamFolder.appendingPathComponent("video.mp4")
        return URL(fileURLWithPath: path).resolvingSymlinksInPath().path == expected.resolvingSymlinksInPath().path
    }

    func discard() {
        try? FileManager.default.removeItem(at: root)
    }
}

private final class SupersedeTestNSScreen: NSScreen {
    override var frame: NSRect {
        NSRect(x: 0, y: 0, width: 800, height: 600)
    }

    override var deviceDescription: [NSDeviceDescriptionKey: Any] {
        [NSDeviceDescriptionKey("NSScreenNumber"): UInt32(0xEDA0_5E01)]
    }

    override var localizedName: String {
        "Local Copy Supersede Test"
    }
}
#endif
