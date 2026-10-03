import AppKit
import CoreGraphics
import Foundation
@testable import LiveWallpaper
import LiveWallpaperCore
import Testing

@Suite("Display configuration commands")
@MainActor
struct DisplayConfigurationControllerTests {
    @Test("Direct and playback saves hold manual choices to the same real schedule boundary")
    func savesShareSchedulePolicy() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(secondsFromGMT: 0))
        let beforeBoundary = try #require(calendar.date(from: DateComponents(year: 2026, month: 9, day: 27, hour: 10, minute: 59)))
        let boundary = try #require(calendar.date(from: DateComponents(year: 2026, month: 9, day: 27, hour: 11)))
        let nextBoundary = try #require(calendar.date(from: DateComponents(year: 2026, month: 9, day: 28, hour: 10)))
        var now = beforeBoundary
        let persistence = ConfigurationMemory()
        let store = WallpaperConfigurationStore(persistence: persistence)
        let controller = DisplayConfigurationController(
            store: store, bookmarkDisplayNameCache: BookmarkDisplayNameCache(),
            releaseRuntimeSession: { _ in }, notifyWallpaperSessionChanged: {},
            advanceSceneMutationIntent: { _ in }, now: { now }, calendar: { calendar },
            notificationCenter: NotificationCenter()
        )
        let playback = makePlayback(store: store, commands: controller)
        let planned = WallpaperQueueEntry(title: "Planned", content: .html(source: .inline("planned"), config: .default))
        var prior = ScreenConfiguration(screenID: 101, wallpaper: planned.content)
        prior.wallpaperMode = .schedule
        prior.scheduleSlots = [ScheduleSlot(startHour: 10, endHour: 11, label: "Morning", wallpaper: planned)]
        var other = prior
        other.screenID = 102
        persistence.replaceAllConfigurations([prior, other])
        var direct = prior
        direct.activeWallpaper = .html(source: .inline("manual"), config: .default)
        var viaPlayback = direct
        viaPlayback.screenID = 102
        controller.save(direct)
        playback.save(viaPlayback)
        #expect(store.get(for: 101)?.scheduleSettledUntil == boundary)
        #expect(store.get(for: 102)?.scheduleSettledUntil == boundary)
        // A stale same-content edit must retain the claim, without extending it.
        playback.save(viaPlayback)
        #expect(store.get(for: 102)?.scheduleSettledUntil == boundary)
        now = boundary.addingTimeInterval(60)
        direct.activeWallpaper = .html(source: .inline("next-manual"), config: .default)
        viaPlayback = direct
        viaPlayback.screenID = 102
        controller.save(direct)
        playback.save(viaPlayback)
        #expect(store.get(for: 101)?.scheduleSettledUntil == nextBoundary)
        #expect(store.get(for: 102)?.scheduleSettledUntil == nextBoundary)
    }

    @Test("Intent invalidates before revision and one deferred notification observes the committed value")
    func commitOrderAndOneNotification() async throws {
        let persistence = ConfigurationMemory()
        let store = WallpaperConfigurationStore(persistence: persistence)
        let center = NotificationCenter()
        let events = Events()
        let screenID: CGDirectDisplayID = 201
        persistence.onSave = { _ in events.values.append("persist:\(store.revision(for: screenID))") }
        let controller = DisplayConfigurationController(
            store: store, bookmarkDisplayNameCache: BookmarkDisplayNameCache(),
            releaseRuntimeSession: { _ in }, notifyWallpaperSessionChanged: {},
            advanceSceneMutationIntent: { id in events.values.append("intent:\(store.revision(for: id))") },
            notificationCenter: center
        )
        let token = center.addObserver(forName: .wallpaperConfigurationDidChange, object: nil, queue: nil) { notification in
            guard let id = notification.userInfo?["screenID"] as? CGDirectDisplayID else { return }
            MainActor.assumeIsolated {
                events.values.append("notify:\(store.revision(for: id))")
                events.notifications += 1
                events.notifiedVolumes.append(store.get(for: id)?.videoVolume)
            }
        }
        defer { center.removeObserver(token) }
        var config = ScreenConfiguration(screenID: screenID, wallpaper: .html(source: .inline("a"), config: .default))
        config.videoVolume = 0.37
        makePlayback(store: store, commands: controller).save(config)
        #expect(events.values == ["intent:0", "persist:1"])
        try await settleNotifications(events, expected: 1)
        #expect(events.values == ["intent:0", "persist:1", "notify:1"])
        #expect(events.notifiedVolumes == [0.37])
        #expect(persistence.saves == 1)
    }

    @Test("Both save paths prime every video name retained by the configuration")
    func savedVideoNamesArePrimed() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        func bookmark(_ name: String) throws -> Data {
            let url = directory.appendingPathComponent(name)
            try Data().write(to: url)
            return try url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
        }
        let active = try bookmark("active.mov")
        let queued = try bookmark("queued.mov")
        let persistence = ConfigurationMemory()
        let store = WallpaperConfigurationStore(persistence: persistence)
        let cache = BookmarkDisplayNameCache()
        let controller = DisplayConfigurationController(
            store: store, bookmarkDisplayNameCache: cache,
            releaseRuntimeSession: { _ in }, notifyWallpaperSessionChanged: {},
            advanceSceneMutationIntent: { _ in }, notificationCenter: NotificationCenter()
        )
        var config = ScreenConfiguration(screenID: 301, videoBookmarkData: active)
        config.wallpaperQueue = [WallpaperQueueEntry(title: "Queued", content: .video(bookmarkData: queued))]
        makePlayback(store: store, commands: controller).save(config)
        #expect(cache.name(for: active) == "active.mov")
        #expect(cache.name(for: queued) == "queued.mov")
        cache.record(active, name: "User title")
        controller.save(config)
        #expect(cache.name(for: active) == "User title")
        #expect(cache.name(for: queued) == "queued.mov")
    }

    @Test("Remove advances revision once, clears the store and emits one deferred change")
    func removeHasOneCommittedChange() async throws {
        let persistence = ConfigurationMemory()
        let store = WallpaperConfigurationStore(persistence: persistence)
        let center = NotificationCenter()
        let events = Events()
        let id: CGDirectDisplayID = 401
        persistence.replaceAllConfigurations([ScreenConfiguration(screenID: id, wallpaper: .html(source: .inline("old"), config: .default))])
        _ = store.get(for: id)
        var releases = 0
        var sessionNotifications = 0
        var intents = 0
        let controller = DisplayConfigurationController(
            store: store, bookmarkDisplayNameCache: BookmarkDisplayNameCache(),
            releaseRuntimeSession: { _ in releases += 1 },
            notifyWallpaperSessionChanged: { sessionNotifications += 1 },
            advanceSceneMutationIntent: { _ in intents += 1 }, notificationCenter: center
        )
        let token = center.addObserver(forName: .wallpaperConfigurationDidChange, object: nil, queue: nil) { notification in
            guard let screenID = notification.userInfo?["screenID"] as? CGDirectDisplayID, screenID == id else { return }
            MainActor.assumeIsolated {
                events.notifications += 1
                events.values.append(store.get(for: id) == nil ? "removed" : "present")
            }
        }
        defer { center.removeObserver(token) }
        makePlayback(store: store, commands: controller).removeConfiguration(for: id)
        #expect(store.get(for: id) == nil)
        #expect(store.revision(for: id) == 1)
        #expect(persistence.removes == 1)
        #expect(events.notifications == 0)
        try await settleNotifications(events, expected: 1)
        #expect(events.values == ["removed"])
        #expect(intents == 0)
        #expect(releases == 0)
        #expect(sessionNotifications == 0)
    }

    #if !LITE_BUILD
    @Test("Scene span audio edits propagate to members while independent scenes retain their settings")
    func sceneSpanAudioOwnership() throws {
        let displays = (0 ..< 3).map { index -> Screen in
            let screen = SpanAudioTestScreen()
            screen.index = index
            return Screen(nsScreen: screen)
        }
        let descriptor = SceneDescriptor(workshopID: "span-audio", cacheRelativePath: "wpe-cache/span-audio", entryFile: "scene.json", capabilityTier: .imageOnly)
        let groupID = UUID()
        let persistence = ConfigurationMemory()
        persistence.values = displays.enumerated().map { index, screen in
            var configuration = ScreenConfiguration(screenID: screen.id, wallpaper: .scene(descriptor))
            configuration.displayFingerprint = screen.displayFingerprint
            configuration.sceneSpanGroupID = index < 2 ? groupID : nil
            configuration.muted = true
            configuration.videoVolume = 0.25
            return configuration
        }
        let store = WallpaperConfigurationStore(persistence: persistence)
        _ = store.loadAll()
        let playback = makePlayback(store: store, commands: DisplayConfigurationTestSupport.commands(for: store), screens: displays)
        playback.updateMuted(false, for: displays[1])
        playback.updateVideoVolume(0.75, for: displays[1])
        for screen in displays.prefix(2) {
            let configuration = try #require(store.get(for: screen.id, fingerprint: screen.displayFingerprint))
            #expect(!configuration.muted)
            #expect(configuration.videoVolume == 0.75)
        }
        #expect(store.get(for: displays[2].id)?.muted == true)
        #expect(store.get(for: displays[2].id)?.videoVolume == 0.25)
    }

    @Test("Scene span audio and fit edits reach a disconnected member's stored configuration")
    func sceneSpanEditsReachDisconnectedMember() throws {
        let displays = (0 ..< 2).map { index -> Screen in
            let screen = SpanAudioTestScreen()
            screen.index = index
            return Screen(nsScreen: screen)
        }
        let descriptor = SceneDescriptor(workshopID: "span-offline", cacheRelativePath: "wpe-cache/span-offline", entryFile: "scene.json", capabilityTier: .imageOnly)
        let groupID = UUID()
        let persistence = ConfigurationMemory()
        persistence.values = displays.map { screen in
            var configuration = ScreenConfiguration(screenID: screen.id, wallpaper: .scene(descriptor))
            configuration.displayFingerprint = screen.displayFingerprint
            configuration.sceneSpanGroupID = groupID
            configuration.muted = false
            configuration.videoVolume = 0.25
            configuration.fitMode = .aspectFill
            return configuration
        }
        let store = WallpaperConfigurationStore(persistence: persistence)
        _ = store.loadAll()
        let playback = makePlayback(store: store, commands: DisplayConfigurationTestSupport.commands(for: store), screens: [displays[0]])
        playback.updateMuted(true, for: displays[0])
        playback.updateVideoVolume(0.75, for: displays[0])
        playback.updateSceneFitMode(.aspectFit, for: displays[0])
        let offline = try #require(store.get(for: displays[1].id))
        #expect(offline.muted)
        #expect(offline.videoVolume == 0.75)
        #expect(offline.fitMode == .aspectFit)
    }
    #endif

    private func makePlayback(store: WallpaperConfigurationStore, commands: any DisplayConfigurationCommitting, screens: [Screen] = []) -> PlaybackCoordinator {
        PlaybackCoordinator(
            configurationStore: store, configurationCommands: commands,
            playableVideoLoader: FakePlayableVideoLoader(),
            applyPolicy: { _ in }, applyVideoEffects: { _, _ in },
            refreshRateLookup: { _ in 60 }, screensProvider: { screens },
            markSessionStateChanged: {}, releaseRuntimeSession: { _ in },
            notifyWallpaperSessionChanged: {}, originReconciler: PreservingOriginReconciler()
        )
    }

    private func settleNotifications(_ events: Events, expected: Int) async throws {
        let deadline = ContinuousClock.now + .seconds(1)
        while events.notifications < expected, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(1))
        }
        try await Task.sleep(for: .milliseconds(10))
        #expect(events.notifications == expected)
    }
}

@MainActor
private final class Events {
    var values: [String] = []
    var notifications = 0
    var notifiedVolumes: [Double?] = []
}

@MainActor
private final class ConfigurationMemory: ScreenConfigurationPersisting {
    var values: [ScreenConfiguration] = []
    var saves = 0
    var removes = 0
    var onSave: ((ScreenConfiguration) -> Void)?
    func getConfiguration(for screenID: CGDirectDisplayID) -> ScreenConfiguration? {
        values.first { $0.screenID == screenID }
    }

    func saveConfiguration(_ configuration: ScreenConfiguration) {
        values.removeAll { $0.screenID == configuration.screenID }
        values.append(configuration)
        saves += 1
        onSave?(configuration)
    }

    func cleanSettingsForScreen(_ screenID: CGDirectDisplayID) {
        values.removeAll { $0.screenID == screenID }
        removes += 1
    }

    func loadConfigurations() -> [ScreenConfiguration] {
        values
    }

    func replaceAllConfigurations(_ configurations: [ScreenConfiguration]) {
        values = configurations
    }
}

private final class SpanAudioTestScreen: NSScreen {
    var index = 0
    override var frame: NSRect {
        NSRect(x: index * 800, y: 0, width: 800, height: 600)
    }

    override var deviceDescription: [NSDeviceDescriptionKey: Any] {
        [:]
    }

    override var localizedName: String {
        "Span audio test \(index)"
    }

    override var debugDescription: String {
        localizedName
    }
}
