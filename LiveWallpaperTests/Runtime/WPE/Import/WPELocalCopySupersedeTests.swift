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

            let superseded = manager.supersedeLocalCopiesWithSteam()
            #expect(superseded == 1)

            let settings = SettingsManager.shared.loadGlobalSettings()
            #expect(settings.recentWPEImports.map(\.origin) == [fixture.steam.origin])
            #expect(settings.recentWPEImports.first?.lastUsedAt == fixture.local.lastUsedAt)
            #expect(settings.deletedWorkshopIDs.isEmpty)

            let stored = manager.configurationStore.get(for: screen.id)
            let after = try #require(stored)
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
            let controlRevisionAfter = manager.configurationStore.revision(for: Self.controlScreenID)
            let controlWallpaperAfter = manager.configurationStore.get(for: Self.controlScreenID)?.activeWallpaper
            #expect(controlRevisionAfter == controlRevision)
            #expect(controlWallpaperAfter == control.activeWallpaper)
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

            let superseded = manager.supersedeLocalCopiesWithSteam()
            #expect(superseded == 0)

            let history = SettingsManager.shared.loadGlobalSettings().recentWPEImports
            #expect(history == before)
            let stored = manager.configurationStore.get(for: screen.id)
            let after = try #require(stored)
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
            let firstPass = manager.supersedeLocalCopiesWithSteam()
            #expect(firstPass == 1)
            let settings = SettingsManager.shared.loadGlobalSettings().recentWPEImports
            let revision = manager.configurationStore.revision(for: screen.id)

            let secondPass = manager.supersedeLocalCopiesWithSteam()
            #expect(secondPass == 0)

            let history = SettingsManager.shared.loadGlobalSettings().recentWPEImports
            let revisionAfter = manager.configurationStore.revision(for: screen.id)
            #expect(history == settings)
            #expect(revisionAfter == revision)
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

            let superseded = manager.supersedeLocalCopiesWithSteam()
            #expect(superseded == 1)

            let stored = manager.configurationStore.get(for: screen.id)
            let after = try #require(stored)
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

            let history = SettingsManager.shared.loadGlobalSettings().recentWPEImports.map(\.origin)
            let activeOrigin = manager.configurationStore.get(for: screen.id)?.wpeOrigin
            #expect(history == [fixture.steam.origin])
            #expect(activeOrigin == fixture.steam.origin)
        }
    }

    @Test("An HTML page keeps its settings when its content moves to the Steam item")
    func htmlSettingsSurvive() async throws {
        let fixture = try SupersedeFixture(type: .web)
        defer { fixture.discard() }
        try await withHeadlessManager(fixture) { manager, screen in
            let edited = HTMLConfig(
                allowJavaScript: false, allowMouseInteraction: true, customCSS: "body { opacity: 0.5 }",
                muteAudio: true, audioVolume: 0.25, refreshIntervalSeconds: 60, transformScale: 1.5,
                cspEnforcementEnabled: true,
                wallpaperEngineProjectProperties: ["schemecolor": .string("0 0 1")]
            )
            let localContent = WallpaperContent.html(source: fixture.localHTMLSource, config: edited)
            let localEntry = WallpaperQueueEntry(title: "Lunar Tear", content: localContent, origin: fixture.local.origin)
            var configuration = fixture.configuration(on: screen, content: localContent)
            configuration.wallpaperQueue = [localEntry]
            manager.saveConfiguration(configuration)
            let bookmark = BookmarkStore.shared.add(label: "Saved", content: localContent, wpeOrigin: fixture.local.origin)
            defer { BookmarkStore.shared.remove(bookmark.id) }

            let superseded = manager.supersedeLocalCopiesWithSteam()
            #expect(superseded == 1)

            let stored = manager.configurationStore.get(for: screen.id)
            let after = try #require(stored)
            let savedBookmark = try #require(BookmarkStore.shared.bookmarks.first { $0.id == bookmark.id })
            for content in [after.activeWallpaper, after.wallpaperQueue?.first?.content, savedBookmark.content] {
                let (source, config) = try #require(fixture.steamHTML(content))
                #expect(config.allowJavaScript == false)
                #expect(config.cspEnforcementEnabled == true)
                #expect(config.allowMouseInteraction == true)
                #expect(config.customCSS == edited.customCSS)
                #expect(config.muteAudio == true)
                #expect(config.audioVolume == edited.audioVolume)
                #expect(config.refreshIntervalSeconds == edited.refreshIntervalSeconds)
                #expect(config.transformScale == edited.transformScale)
                let projectKey = WallpaperEngineProjectIdentity.key(source: source)
                #expect(config.projectWallpaperEngineProperties(forProjectKey: projectKey) == ["schemecolor": .string("0 0 1")])
            }
        }
    }

    @Test("A display playing the local page is rebuilt as a page, not handed to the video path")
    func htmlDisplayReloadsByType() async throws {
        let fixture = try SupersedeFixture(type: .web)
        defer { fixture.discard() }
        try await withHeadlessManager(fixture) { manager, screen in
            let localContent = WallpaperContent.html(source: fixture.localHTMLSource, config: .default)
            manager.saveConfiguration(fixture.configuration(on: screen, content: localContent))
            let generation = manager.bumpTransition(for: screen.id)

            let superseded = manager.supersedeLocalCopiesWithSteam()
            #expect(superseded == 1)

            let reloaded = !manager.isCurrentTransition(generation, for: screen.id)
            let reportedFailure = manager.transientRuntimeErrors[screen.id] != nil
            #expect(reloaded, "the display was never reloaded")
            #expect(!reportedFailure, "the page was sent down the video-only path")
        }
    }

    @Test("A display that only queues the local copy is saved but keeps playing what it plays")
    func queueOnlyDisplayIsNotReloaded() async throws {
        let fixture = try SupersedeFixture()
        defer { fixture.discard() }
        try await withHeadlessManager(fixture) { manager, screen in
            let localEntry = WallpaperQueueEntry(title: "Lunar Tear", content: fixture.localContent, origin: fixture.local.origin)
            var configuration = ScreenConfiguration(screenID: screen.id, videoBookmarkData: fixture.steamVideoBookmark)
            configuration.displayFingerprint = screen.displayFingerprint
            configuration.wallpaperQueue = [localEntry]
            manager.saveConfiguration(configuration)
            let session = SupersedeTestSession()
            screen.installRuntimeSession(session)
            let revision = manager.configurationStore.revision(for: screen.id)
            let generation = manager.bumpTransition(for: screen.id)

            let superseded = manager.supersedeLocalCopiesWithSteam()
            #expect(superseded == 1)

            let revisionAfter = manager.configurationStore.revision(for: screen.id)
            let queuedOrigin = manager.configurationStore.get(for: screen.id)?.wallpaperQueue?.first?.origin
            let rebuilt = !manager.isCurrentTransition(generation, for: screen.id)
            let keptSession = screen.runtimeSession.map { ObjectIdentifier($0 as AnyObject) } == ObjectIdentifier(session)
            let cleanups = session.cleanupCount
            #expect(revisionAfter == revision + 1)
            #expect(queuedOrigin == fixture.steam.origin)
            #expect(!rebuilt, "an unchanged display was rebuilt")
            #expect(keptSession)
            #expect(cleanups == 0)
        }
    }

    @Test("An unplayable Steam item still replaces a local copy nothing points at")
    func unplayableSteamReplacesUnreferencedCopy() async throws {
        let fixture = try SupersedeFixture(steamEntryFile: "missing.mp4")
        defer { fixture.discard() }
        try await withHeadlessManager(fixture) { manager, _ in
            let superseded = manager.supersedeLocalCopiesWithSteam()
            #expect(superseded == 1)

            let history = SettingsManager.shared.loadGlobalSettings().recentWPEImports.map(\.origin)
            #expect(history == [fixture.steam.origin])
        }
    }

    @Test("An unplayable Steam item leaves a referenced local copy and its references alone")
    func unplayableSteamKeepsReferencedCopy() async throws {
        let fixture = try SupersedeFixture(steamEntryFile: "missing.mp4")
        defer { fixture.discard() }
        try await withHeadlessManager(fixture) { manager, screen in
            let configuration = fixture.configuration(on: screen)
            manager.saveConfiguration(configuration)
            let before = SettingsManager.shared.loadGlobalSettings().recentWPEImports

            let superseded = manager.supersedeLocalCopiesWithSteam()
            #expect(superseded == 0)

            let history = SettingsManager.shared.loadGlobalSettings().recentWPEImports
            #expect(history == before)
            let stored = manager.configurationStore.get(for: screen.id)
            let after = try #require(stored)
            #expect(after.wpeOrigin == fixture.local.origin)
            #expect(after.activeWallpaper == configuration.activeWallpaper)
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
    let localHTMLSource: HTMLSource
    let steamVideoBookmark: Data

    /// `steamEntryFile` names a file the Steam folder lacks, so the Steam item's content can't be rebuilt.
    init(type: WPEType = .video, steamEntryFile: String? = nil) throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("WPELocalCopySupersede-\(UUID().uuidString)", isDirectory: true)
        self.root = root
        let entryFile = type == .web ? "index.html" : "video.mp4"
        func folder(_ relativePath: String) throws -> URL {
            let folder = root.appendingPathComponent(relativePath, isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try Data("<html></html>".utf8).write(to: folder.appendingPathComponent(entryFile))
            return folder
        }
        func entry(_ folder: URL, entryFile: String, importedAt: Double, lastUsedAt: Double?) throws -> WPEHistoryEntry {
            try WPEHistoryEntry(
                origin: WPEOrigin(
                    workshopID: "2585024298", title: "Lunar Tear [4K]", originalType: type,
                    sourceFolderBookmark: #require(ResourceUtilities.createBookmark(for: folder)),
                    cacheRelativePath: "wpe-cache/2585024298", previewFileName: nil,
                    entryFile: entryFile, resourceLocation: .sourceFolder
                ),
                importedAt: Date(timeIntervalSince1970: importedAt),
                lastUsedAt: lastUsedAt.map { Date(timeIntervalSince1970: $0) }
            )
        }
        steamFolder = try folder("steamapps/workshop/content/431960/\(workshopID)")
        let localFolder = try folder("Wallpapers/edit")
        steam = try entry(steamFolder, entryFile: steamEntryFile ?? entryFile, importedAt: 1, lastUsedAt: nil)
        local = try entry(localFolder, entryFile: entryFile, importedAt: 2, lastUsedAt: 100)
        localContent = try .video(bookmarkData: #require(
            ResourceUtilities.createBookmark(for: localFolder.appendingPathComponent(entryFile))
        ))
        localHTMLSource = try .folder(bookmarkData: #require(ResourceUtilities.createBookmark(for: localFolder)), indexFileName: entryFile)
        steamVideoBookmark = try #require(ResourceUtilities.createBookmark(for: steamFolder.appendingPathComponent(entryFile)))
    }

    func configuration(on screen: Screen, content: WallpaperContent? = nil) -> ScreenConfiguration {
        var configuration = content.map { ScreenConfiguration(screenID: screen.id, wallpaper: $0) }
            ?? ScreenConfiguration(screenID: screen.id, videoBookmarkData: localContent.activeVideoBookmarkData ?? Data())
        configuration.displayFingerprint = screen.displayFingerprint
        configuration.wpeOrigin = local.origin
        return configuration
    }

    /// The page's source and settings when `content` is a page served from the Steam folder.
    func steamHTML(_ content: WallpaperContent?) -> (HTMLSource, HTMLConfig)? {
        guard case let .html(source, config)? = content, case let .folder(data, _) = source,
              let path = URL.resourceValues(forKeys: [.pathKey], fromBookmarkData: data)?.path,
              URL(fileURLWithPath: path).resolvingSymlinksInPath().path == steamFolder.resolvingSymlinksInPath().path
        else { return nil }
        return (source, config)
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

private final class SupersedeTestSession: WallpaperRuntimeSession {
    private(set) var cleanupCount = 0

    var wallpaperType: WallpaperType {
        .video
    }

    var summary: WallpaperSessionSummary {
        WallpaperSessionSummary(wallpaperType: .video, activity: .active, supportsPlaybackControl: false, subtitle: nil)
    }

    var videoPlayer: WallpaperVideoPlayer? {
        nil
    }

    var wallpaperWindow: NSWindow? {
        nil
    }

    func show() {}
    func applyPerformanceProfile(_: WallpaperPerformanceProfile) {}
    func updateFrame(to _: CGRect) {}
    func prepareForDisplay(timeout _: Duration) async -> WallpaperPreparationResult {
        .ready
    }

    func cleanup() {
        cleanupCount += 1
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

    /// AppKit traps reading this from a screen with no real display behind it; a page session asks for it.
    override var maximumFramesPerSecond: Int {
        60
    }
}
#endif
