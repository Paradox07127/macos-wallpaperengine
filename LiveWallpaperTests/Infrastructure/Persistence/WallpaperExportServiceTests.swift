import AVFoundation
import Darwin
import Foundation
@testable import LiveWallpaper
import LiveWallpaperCore
import os
import Testing

@MainActor
@Suite("WallpaperExportService")
struct WallpaperExportServiceTests {
    @Test("One stable system choice resolves the latest app selection on each display")
    func selectedWallpaperFollowsEachDisplay() async throws {
        let rig = try makeRig()
        defer { try? FileManager.default.removeItem(at: rig.root.deletingLastPathComponent()) }
        let first = try rig.makeVideoBookmark(named: "first.mp4")
        let second = try rig.makeVideoBookmark(named: "second.mp4")
        let other = try rig.makeVideoBookmark(named: "other.mp4")
        try rig.showSelectedTile(on: [42, 43])
        let coordinator = SystemWallpaperSelectionCoordinator(service: rig.service)
        defer { coordinator.stop() }
        coordinator.follow(ScreenConfiguration(screenID: 42, wallpaper: first.content), title: "First")
        coordinator.follow(ScreenConfiguration(screenID: 42, wallpaper: second.content), title: "Second")
        coordinator.follow(ScreenConfiguration(screenID: 43, wallpaper: other.content), title: "Other")
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(5))
        while clock.now < deadline {
            if let manifest = try? rig.manifestOnDisk(), manifest.displaySelections.count == 2 {
                break
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        let manifest = try rig.manifestOnDisk()
        #expect(manifest.items.count == 2, "superseded pending selection was published")
        #expect(manifest.item(for: SystemWallpaperManifest.selectedChoiceID, displayID: 42)?.title == "Second")
        #expect(manifest.item(for: SystemWallpaperManifest.selectedChoiceID, displayID: 43)?.title == "Other")
        let copy = try #require(manifest.item(for: SystemWallpaperManifest.selectedChoiceID, displayID: 42))
        #expect(try Data(contentsOf: rig.videosDirectory.appendingPathComponent(copy.fileName)) == Data("fake-video-bytes".utf8))
        #expect(manifest.item(for: copy.id)?.id == copy.id, "old per-item choices must still resolve")
    }

    @Test("Web selection waits for an explicitly prepared copy and follows its publication", .timeLimit(.minutes(1)))
    func selectedWebWaitsForPreparedCopy() async throws {
        let rig = try makeRig()
        defer { try? FileManager.default.removeItem(at: rig.root.deletingLastPathComponent()) }
        let content = WallpaperContent.html(source: .inline("<canvas></canvas>"), config: .default)
        try rig.showSelectedTile(on: [42])
        let coordinator = SystemWallpaperSelectionCoordinator(service: rig.service)
        defer { coordinator.stop() }
        coordinator.follow(ScreenConfiguration(screenID: 42, wallpaper: content), title: "Web")
        try await Task.sleep(for: .milliseconds(200))
        #expect(rig.service.lastError == nil, "an unprepared web wallpaper is skipped, not reported")
        #expect(rig.service.items.isEmpty)
        #expect(coordinator.followState.displays[42]?.phase == .needsRecording)
        let key = try WallpaperExportService.sourceKey(for: content)
        let item = SystemWallpaperManifest.Item(id: "prepared-web", title: "Web", fileName: "web.mov", addedAt: Date(), sourceKey: key)
        try FileManager.default.createDirectory(at: rig.root, withIntermediateDirectories: true)
        try SystemWallpaperCoding.encoder.encode(SystemWallpaperManifest(version: 1, items: [item])).write(to: rig.manifestURL)
        rig.service.refresh()
        rig.service.onItemPublished?(key)
        for _ in 0 ..< 100 {
            if try rig.manifestOnDisk().displaySelections["42"] == item.id {
                break
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(try rig.manifestOnDisk().displaySelections["42"] == item.id)
        #expect(coordinator.followState.displays[42]?.phase == .ready(itemID: item.id))
    }

    @Test("The selected tile is followed only on displays where the system shows it")
    func selectionFollowsOnlyShownTile() async throws {
        let rig = try makeRig()
        defer { try? FileManager.default.removeItem(at: rig.root.deletingLastPathComponent()) }
        let elsewhere = try rig.makeVideoBookmark(named: "elsewhere.mp4")
        let shown = try rig.makeVideoBookmark(named: "shown.mp4")
        try rig.showSelectedTile(on: [42])
        let coordinator = SystemWallpaperSelectionCoordinator(service: rig.service)
        defer { coordinator.stop() }
        // The worker takes displays in ascending order, so 41 is decided before 42 lands.
        coordinator.follow(ScreenConfiguration(screenID: 41, wallpaper: elsewhere.content), title: "Elsewhere")
        coordinator.follow(ScreenConfiguration(screenID: 42, wallpaper: shown.content), title: "Shown")
        try await waitUntil { try rig.manifestOnDisk().displaySelections["42"] != nil }
        let manifest = try rig.manifestOnDisk()
        #expect(manifest.displaySelections["41"] == nil, "a display not showing the selected tile was written")
        #expect(manifest.items.map(\.title) == ["Shown"], "a display not showing the selected tile was copied")

        try rig.showSelectedTile(on: [41, 42])
        rig.service.refreshProviderStatus()
        try await waitUntil { try rig.manifestOnDisk().displaySelections["41"] != nil }
        #expect(try rig.manifestOnDisk().item(for: SystemWallpaperManifest.selectedChoiceID, displayID: 41)?.title == "Elsewhere")
    }

    @Test("A superseded follow copy is removed once no display selects it, and added items stay")
    func supersededFollowCopyRemoved() async throws {
        let rig = try makeRig()
        defer { try? FileManager.default.removeItem(at: rig.root.deletingLastPathComponent()) }
        let added = try rig.makeVideoBookmark(named: "added.mp4", label: "Added")
        try await rig.service.publish(bookmark: added)
        let first = try rig.makeVideoBookmark(named: "first.mp4")
        let second = try rig.makeVideoBookmark(named: "second.mp4")
        try rig.showSelectedTile(on: [42])
        let coordinator = SystemWallpaperSelectionCoordinator(service: rig.service)
        defer { coordinator.stop() }
        coordinator.follow(ScreenConfiguration(screenID: 42, wallpaper: first.content), title: "First")
        try await waitUntil { try rig.manifestOnDisk().displaySelections["42"] != nil }
        let firstCopy = try #require(rig.manifestOnDisk().item(for: SystemWallpaperManifest.selectedChoiceID, displayID: 42))
        coordinator.follow(ScreenConfiguration(screenID: 42, wallpaper: second.content), title: "Second")
        try await waitUntil { try rig.manifestOnDisk().displaySelections["42"] != firstCopy.id }
        let manifest = try rig.manifestOnDisk()
        #expect(Set(manifest.items.map(\.title)) == ["Added", "Second"], "the superseded copy is still in the library")
        #expect(!FileManager.default.fileExists(atPath: rig.videosDirectory.appendingPathComponent(firstCopy.fileName).path))
        #expect(rig.service.items == manifest.items)
    }

    @Test("A followed copy is named after the wallpaper, not the display")
    func followedCopyTitle() {
        let video = ScreenConfiguration(screenID: 42, wallpaper: .video(bookmarkData: Data("clip".utf8), packageEntryName: nil))
        let fileName: (Data) -> String? = { _ in "Ocean Waves.mp4" }
        #expect(ScreenManager.systemWallpaperTitle(for: video, libraryBookmarks: [], bookmarkName: fileName) == "Ocean Waves")
        let labelled = WallpaperBookmark(label: "Beach", content: video.activeWallpaper)
        #expect(ScreenManager.systemWallpaperTitle(for: video, libraryBookmarks: [labelled], bookmarkName: fileName) == "Beach")
    }

    @Test("Disk usage counts the files inside published scene bundles")
    func diskUsageCountsSceneBundles() throws {
        let rig = try makeRig()
        defer { try? FileManager.default.removeItem(at: rig.root.deletingLastPathComponent()) }
        let bundle = rig.videosDirectory.appendingPathComponent("live.scene/Assets", isDirectory: true)
        try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
        try Data(count: 4096).write(to: bundle.appendingPathComponent("scene.pkg"))
        let item = SystemWallpaperManifest.Item(id: "live", title: "Live", fileName: "live.scene", addedAt: Self.referenceNow)
        try SystemWallpaperCoding.encoder.encode(SystemWallpaperManifest(version: 1, items: [item])).write(to: rig.manifestURL)
        rig.service.refresh()
        #expect(rig.service.diskUsageBytes >= 4096)
    }

    @Test(arguments: [false, true])
    func foreignProviderNeverRequestsRecovery(running: Bool) throws {
        let expected = SystemWallpaperProviderIdentity(build: "42", bundlePath: "/app/P.appex", pid: 0)
        let rig = try makeRig(expectedProvider: expected, isProviderRunning: { _ in running })
        defer { try? FileManager.default.removeItem(at: rig.root.deletingLastPathComponent()) }
        try rig.writeHeartbeat(.init(timestamp: Self.referenceNow.addingTimeInterval(-600), activeChoiceID: "copy",
                                     provider: .init(build: "41", bundlePath: "/old/P.appex", pid: 123)))
        rig.service.refreshProviderStatus()
        #expect(rig.service.providerIssue == .differentCopy)
    }

    @Test(.timeLimit(.minutes(1)), arguments: [false, true])
    func failedFollowWaitsForExplicitRetry(heartbeat: Bool) async throws {
        let rig = try makeRig()
        defer { try? FileManager.default.removeItem(at: rig.root.deletingLastPathComponent()) }
        let bookmark = try rig.makeVideoBookmark()
        let source = rig.sourceDirectory.appendingPathComponent("clip.mp4")
        try FileManager.default.removeItem(at: source)
        try rig.showSelectedTile(on: [42])
        let coordinator = SystemWallpaperSelectionCoordinator(service: rig.service)
        defer { coordinator.stop() }
        let configuration = ScreenConfiguration(screenID: 42, wallpaper: bookmark.content)
        coordinator.follow(configuration, title: "Retry")
        try await waitUntil { rig.service.lastError != nil }
        #expect(rig.service.lastError != nil)
        try Data("repaired source".utf8).write(to: source)
        if heartbeat {
            rig.service.refreshProviderStatus()
        } else {
            coordinator.follow(configuration, title: "Retry")
        }
        for _ in 0 ..< 20 {
            await Task.yield()
        }
        guard case .failed = coordinator.followState.displays[42]?.phase else {
            Issue.record("a heartbeat or session change must not re-run a failed preparation")
            return
        }
        #expect(rig.service.items.isEmpty)
        coordinator.retry(displayID: 42)
        try await waitUntil { try rig.manifestOnDisk().displaySelections["42"] != nil }
        #expect(rig.service.items.count == 1)
    }

    @Test func removeAllReportsDirectoryLeftovers() throws {
        let rig = try makeRig()
        defer { try? FileManager.default.removeItem(at: rig.root.deletingLastPathComponent()) }
        let directory = rig.videosDirectory.appendingPathComponent("blocked.scene", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.immutable: true], ofItemAtPath: directory.path)
        defer { try? FileManager.default.setAttributes([.immutable: false], ofItemAtPath: directory.path) }
        try rig.service.clearLibrary()
        #expect(rig.service.items.isEmpty)
        #expect(rig.service.lastError?.contains("blocked.scene") == true)
    }

    @Test(.timeLimit(.minutes(1)))
    func followStateIsObservableAndSuccessfulSelectionIsNotRetried() async throws {
        let hook = PublishHook()
        let rig = try makeRig(duringThumbnail: hook)
        defer { try? FileManager.default.removeItem(at: rig.root.deletingLastPathComponent()) }
        let bookmark = try rig.makeVideoBookmark()
        try rig.showSelectedTile(on: [42])
        let coordinator = SystemWallpaperSelectionCoordinator(service: rig.service)
        defer { coordinator.stop() }
        let changed = OSAllocatedUnfairLock(initialState: false)
        withObservationTracking { _ = coordinator.followState } onChange: { changed.withLock { $0 = true } }
        var sawPreparing = false
        hook.run = { sawPreparing = coordinator.followState.displays[42]?.phase == .preparing }
        let configuration = ScreenConfiguration(screenID: 42, wallpaper: bookmark.content)
        coordinator.follow(configuration, title: "Observed")
        #expect(coordinator.followState.displays[42]?.phase == .queued)
        #expect(changed.withLock { $0 })
        try await waitUntil { rig.service.items.count == 1 }
        #expect(sawPreparing)
        let item = try #require(rig.service.items.first)
        #expect(coordinator.followState.displays[42]?.phase == .ready(itemID: item.id))
        #expect(coordinator.followState.displays[42]?.title == "Observed")
        #expect(coordinator.followState.displays[42]?.sourceKey == item.sourceKey)
        let manifest = try Data(contentsOf: rig.manifestURL)
        rig.service.refreshProviderStatus()
        coordinator.follow(configuration, title: "Observed")
        await Task.yield()
        #expect(coordinator.followState.displays[42]?.phase == .ready(itemID: item.id))
        #expect(try Data(contentsOf: rig.manifestURL) == manifest)
    }

    @Test(.timeLimit(.minutes(1)))
    func explicitRetryRequeuesFailedDisplay() async throws {
        let rig = try makeRig()
        defer { try? FileManager.default.removeItem(at: rig.root.deletingLastPathComponent()) }
        let bookmark = try rig.makeVideoBookmark()
        let source = rig.sourceDirectory.appendingPathComponent("clip.mp4")
        try FileManager.default.removeItem(at: source)
        try rig.showSelectedTile(on: [42])
        let coordinator = SystemWallpaperSelectionCoordinator(service: rig.service)
        defer { coordinator.stop() }
        coordinator.follow(ScreenConfiguration(screenID: 42, wallpaper: bookmark.content), title: "Retry")
        try await waitUntil { rig.service.lastError != nil }
        guard case let .failed(message) = coordinator.followState.displays[42]?.phase else {
            Issue.record("Failed preparation must be visible per display")
            return
        }
        #expect(!message.isEmpty)
        try Data("repaired".utf8).write(to: source)
        coordinator.retry(displayID: 42)
        #expect(coordinator.followState.displays[42]?.phase == .queued)
        try await waitUntil { rig.service.items.count == 1 }
        let item = try #require(rig.service.items.first)
        #expect(coordinator.followState.displays[42]?.phase == .ready(itemID: item.id))
    }

    @Test func displayOnAnOldCopyDoesNotShowTheSelectedTile() throws {
        let rig = try makeRig()
        defer { try? FileManager.default.removeItem(at: rig.root.deletingLastPathComponent()) }
        let selected = SystemWallpaperManifest.selectedChoiceID
        try rig.writeHeartbeat(SystemWallpaperHeartbeat(
            timestamp: Self.referenceNow, activeChoiceID: selected, activeChoiceIDs: [selected, "legacy"],
            activeDisplayIDs: [42, 43], selectedTileDisplayIDs: [42]
        ))
        rig.service.refreshProviderStatus()
        #expect(rig.service.showsSelectedTile(on: 42))
        #expect(!rig.service.showsSelectedTile(on: 43), "display 43 plays an old copy chosen in System Settings")
    }

    @Test(.timeLimit(.minutes(1)))
    func cancelledFollowWaitsForExplicitRetry() async throws {
        let copies = OSAllocatedUnfairLock(initialState: 0)
        let rig = try makeRig(copyOperation: { source, destination in
            let attempt = copies.withLock { count in
                count += 1
                return count
            }
            if attempt == 1 {
                throw CancellationError()
            }
            try FileManager.default.copyItem(at: source, to: destination)
        })
        defer { try? FileManager.default.removeItem(at: rig.root.deletingLastPathComponent()) }
        let bookmark = try rig.makeVideoBookmark()
        try rig.showSelectedTile(on: [42])
        let coordinator = SystemWallpaperSelectionCoordinator(service: rig.service)
        defer { coordinator.stop() }
        coordinator.follow(ScreenConfiguration(screenID: 42, wallpaper: bookmark.content), title: "Cancelled")
        try await waitUntil { coordinator.followState.displays[42]?.phase == .cancelled }
        #expect(rig.service.lastError == nil)
        rig.service.refreshProviderStatus()
        for _ in 0 ..< 20 {
            await Task.yield()
        }
        #expect(copies.withLock { $0 } == 1, "a heartbeat must not restart a preparation the user cancelled")
        #expect(coordinator.followState.displays[42]?.phase == .cancelled)
        #expect(rig.service.items.isEmpty)
        coordinator.retry(displayID: 42)
        try await waitUntil { rig.service.items.count == 1 }
        #expect(copies.withLock { $0 } == 2)
    }

    @Test(.timeLimit(.minutes(1)))
    func followUsesPreferencesAndEachDisplaysPixels() async throws {
        let rig = try makeRig()
        defer { try? FileManager.default.removeItem(at: rig.root.deletingLastPathComponent()) }
        let name = "WallpaperExportServiceTests-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set("videoCopy", forKey: SystemWallpaperFollowPreferences.sceneMode)
        defaults.set("p1440", forKey: SystemWallpaperFollowPreferences.resolutionCap)
        defaults.set(60, forKey: SystemWallpaperFollowPreferences.frameRate)
        defaults.set(30, forKey: SystemWallpaperFollowPreferences.loopLength)
        let content = WallpaperContent.scene(.init(workshopID: "123", cacheRelativePath: "wpe-cache/123",
                                                   entryFile: "scene.json", capabilityTier: .imageOnly))
        let key = try WallpaperExportService.sourceKey(for: content)
        var large = SystemWallpaperPreparationOptions()
        large.sceneMode = .videoCopy
        large.size = CGSize(width: 2560, height: 1440)
        large.framesPerSecond = 60
        large.duration = 30
        var small = large
        small.size = CGSize(width: 1280, height: 720)
        let items: [SystemWallpaperManifest.Item] = [
            .init(id: "large", title: "Large", fileName: "large.mov", addedAt: Date(), preparationOptions: large, sourceKey: key),
            .init(id: "small", title: "Small", fileName: "small.mov", addedAt: Date(), preparationOptions: small, sourceKey: key),
        ]
        try rig.showSelectedTile(on: [42, 43])
        try JSONEncoder().encode(SystemWallpaperManifest(version: 1, items: items)).write(to: rig.manifestURL)
        rig.service.refresh()
        let coordinator = SystemWallpaperSelectionCoordinator(service: rig.service, defaults: defaults, displaySize: {
            $0 == 42 ? CGSize(width: 3840, height: 2160) : CGSize(width: 1280, height: 720)
        })
        defer { coordinator.stop() }
        coordinator.follow(ScreenConfiguration(screenID: 42, wallpaper: content), title: "Large")
        coordinator.follow(ScreenConfiguration(screenID: 43, wallpaper: content), title: "Small")
        try await waitUntil { try rig.manifestOnDisk().displaySelections.count == 2 }
        #expect(try rig.manifestOnDisk().displaySelections == ["42": "large", "43": "small"])
        #expect(coordinator.followState.displays[42]?.phase == .ready(itemID: "large"))
        #expect(coordinator.followState.displays[43]?.phase == .ready(itemID: "small"))
        defaults.set(30, forKey: SystemWallpaperFollowPreferences.frameRate)
        large.framesPerSecond = 30
        small.framesPerSecond = 30
        var manifest = try rig.manifestOnDisk()
        manifest.items += [
            .init(id: "large30", title: "Large", fileName: "large30.mov", addedAt: Date(), preparationOptions: large, sourceKey: key),
            .init(id: "small30", title: "Small", fileName: "small30.mov", addedAt: Date(), preparationOptions: small, sourceKey: key),
        ]
        try JSONEncoder().encode(manifest).write(to: rig.manifestURL)
        rig.service.refresh()
        try await waitUntil { try rig.manifestOnDisk().displaySelections["43"] == "small30" }
        #expect(try rig.manifestOnDisk().displaySelections == ["42": "large30", "43": "small30"])
    }

    @Test("A cleared display stays empty on disk instead of falling back to another copy", .timeLimit(.minutes(1)))
    func clearedDisplayDoesNotFallBack() async throws {
        let rig = try makeRig()
        defer { try? FileManager.default.removeItem(at: rig.root.deletingLastPathComponent()) }
        let first = try rig.makeVideoBookmark(named: "first.mp4")
        let other = try rig.makeVideoBookmark(named: "other.mp4")
        try rig.showSelectedTile(on: [42, 43])
        let center = NotificationCenter()
        let coordinator = SystemWallpaperSelectionCoordinator(service: rig.service, notificationCenter: center)
        defer { coordinator.stop() }
        coordinator.follow(ScreenConfiguration(screenID: 42, wallpaper: first.content), title: "First")
        coordinator.follow(ScreenConfiguration(screenID: 43, wallpaper: other.content), title: "Other")
        try await waitUntil { try rig.manifestOnDisk().displaySelections.count == 2 }
        center.post(name: .wallpaperSelectionCleared, object: nil, userInfo: [Notification.clearedDisplayIDKey: UInt32(42)])
        let reloaded = try rig.manifestOnDisk()
        #expect(reloaded.item(for: SystemWallpaperManifest.selectedChoiceID, displayID: 42) == nil,
                "a cleared display resolved another display's or the newest copy")
        #expect(reloaded.isCleared(displayID: 42), "the clear did not survive a reload of the manifest")
        #expect(reloaded.item(for: SystemWallpaperManifest.selectedChoiceID, displayID: 43)?.title == "Other")
        #expect(reloaded.items.map(\.title) == ["Other"], "the cleared display's copy was kept")

        rig.service.refreshProviderStatus()
        for _ in 0 ..< 20 {
            await Task.yield()
        }
        try await Task.sleep(for: .milliseconds(100))
        #expect(try rig.manifestOnDisk().isCleared(displayID: 42), "a heartbeat revived the cleared selection")
        #expect(coordinator.followState.displays[42] == nil)

        coordinator.follow(ScreenConfiguration(screenID: 42, wallpaper: first.content), title: "First")
        try await waitUntil { try rig.manifestOnDisk().displaySelections["42"] != nil }
        let reselected = try rig.manifestOnDisk()
        #expect(!reselected.isCleared(displayID: 42), "selecting again left the clear in place")
        #expect(reselected.item(for: SystemWallpaperManifest.selectedChoiceID, displayID: 42)?.title == "First")
    }

    @Test("Clearing a display drops its queued and in-flight preparations", .timeLimit(.minutes(1)))
    func clearCancelsQueuedAndPreparingSelection() async throws {
        let hook = PublishHook()
        let rig = try makeRig(duringThumbnail: hook)
        defer { try? FileManager.default.removeItem(at: rig.root.deletingLastPathComponent()) }
        let preparing = try rig.makeVideoBookmark(named: "preparing.mp4")
        let queued = try rig.makeVideoBookmark(named: "queued.mp4")
        try rig.showSelectedTile(on: [42, 43])
        let coordinator = SystemWallpaperSelectionCoordinator(service: rig.service, notificationCenter: NotificationCenter())
        defer { coordinator.stop() }
        coordinator.follow(ScreenConfiguration(screenID: 42, wallpaper: preparing.content), title: "Preparing")
        coordinator.follow(ScreenConfiguration(screenID: 43, wallpaper: queued.content), title: "Queued")
        coordinator.clear(displayID: 43)
        hook.run = { coordinator.clear(displayID: 42) }
        try await waitUntil { coordinator.followState.displays.isEmpty && rig.service.preparationProgress == nil }
        try await Task.sleep(for: .milliseconds(100))
        let manifest = try rig.manifestOnDisk()
        #expect(manifest.displaySelections.isEmpty, "a cleared display's preparation still published a selection")
        #expect(manifest.isCleared(displayID: 42) && manifest.isCleared(displayID: 43))

        coordinator.follow(ScreenConfiguration(screenID: 42, wallpaper: preparing.content), title: "Preparing")
        try await waitUntil { try rig.manifestOnDisk().displaySelections["42"] != nil }
        #expect(try rig.manifestOnDisk().item(for: SystemWallpaperManifest.selectedChoiceID, displayID: 42)?.title == "Preparing",
                "the same content could not be selected again after its preparation was cleared")
    }

    @Test("Stopping the follow coordinator is not a clear and writes no tombstone", .timeLimit(.minutes(1)))
    func stoppingFollowWritesNoTombstone() async throws {
        let rig = try makeRig()
        defer { try? FileManager.default.removeItem(at: rig.root.deletingLastPathComponent()) }
        let bookmark = try rig.makeVideoBookmark()
        try rig.showSelectedTile(on: [42])
        let coordinator = SystemWallpaperSelectionCoordinator(service: rig.service, notificationCenter: NotificationCenter())
        coordinator.follow(ScreenConfiguration(screenID: 42, wallpaper: bookmark.content), title: "Kept")
        try await waitUntil { try rig.manifestOnDisk().displaySelections["42"] != nil }
        coordinator.stop()
        let manifest = try rig.manifestOnDisk()
        #expect(manifest.clearedDisplays.isEmpty, "turning following off wrote a clear")
        #expect(manifest.item(for: SystemWallpaperManifest.selectedChoiceID, displayID: 42)?.title == "Kept")
    }

    @Test("A manifest from before display clears decodes as unset, and a clear round-trips")
    func clearedDisplaysDecodeCompatibly() throws {
        let item = #"{"id":"a","title":"A","fileName":"a.mov","addedAt":0}"#
        let legacy = Data(#"{"version":1,"items":[\#(item)],"displaySelections":{"43":"a"}}"#.utf8)
        let old = try SystemWallpaperCoding.decoder.decode(SystemWallpaperManifest.self, from: legacy)
        #expect(old.clearedDisplays.isEmpty)
        #expect(old.item(for: SystemWallpaperManifest.selectedChoiceID, displayID: 42)?.id == "a", "an unset display stopped falling back")
        var cleared = old
        cleared.clearedDisplays["42"] = 3
        let decoded = try SystemWallpaperCoding.decoder.decode(
            SystemWallpaperManifest.self, from: SystemWallpaperCoding.encoder.encode(cleared)
        )
        #expect(decoded.clearedDisplays == ["42": 3])
        #expect(decoded.item(for: SystemWallpaperManifest.selectedChoiceID, displayID: 42) == nil)
    }

    private func waitUntil(_ condition: () throws -> Bool) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(5))
        while clock.now < deadline {
            if (try? condition()) == true {
                return
            }
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    private static let referenceNow = Date(timeIntervalSince1970: 1_760_000_000)

    private struct Rig {
        let service: WallpaperExportService
        let root: URL
        let sourceDirectory: URL

        var manifestURL: URL { root.appendingPathComponent("manifest.json") }
        var heartbeatURL: URL { root.appendingPathComponent("heartbeat.json") }
        var videosDirectory: URL { root.appendingPathComponent("Videos") }

        func makeVideoBookmark(
            named fileName: String = "clip.mp4",
            bytes: Data = Data("fake-video-bytes".utf8),
            label: String = "Sunset"
        ) throws -> WallpaperBookmark {
            let url = sourceDirectory.appendingPathComponent(fileName)
            try bytes.write(to: url)
            // The stub resolver decodes the path back out of the bookmark data.
            return WallpaperBookmark(
                label: label,
                content: .video(bookmarkData: Data(url.path.utf8), packageEntryName: nil)
            )
        }


        func makePackagedVideoBookmark(
            entryName: String = "video.mp4",
            bytes: Data = Data("packaged-video-bytes".utf8),
            label: String = "Workshop Clip"
        ) throws -> (bookmark: WallpaperBookmark, payload: Data) {
            func u32(_ value: UInt32) -> Data {
                withUnsafeBytes(of: value.littleEndian) { Data($0) }
            }
            let magic = "PKGV0001"
            var header = Data()
            header.append(u32(UInt32(magic.utf8.count)))
            header.append(contentsOf: magic.utf8)
            header.append(u32(1))
            let nameBytes = Array(entryName.utf8)
            header.append(u32(UInt32(nameBytes.count)))
            header.append(contentsOf: nameBytes)
            header.append(u32(0))
            header.append(u32(UInt32(bytes.count)))

            let url = sourceDirectory.appendingPathComponent("scene.pkg")
            try (header + bytes).write(to: url)
            return (
                WallpaperBookmark(
                    label: label,
                    content: .video(bookmarkData: Data(url.path.utf8), packageEntryName: entryName)
                ),
                bytes
            )
        }

        func writeHeartbeat(_ heartbeat: SystemWallpaperHeartbeat) throws {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            try JSONEncoder().encode(heartbeat).write(to: heartbeatURL)
        }

        @MainActor
        func showSelectedTile(on displays: [UInt32]) throws {
            try writeHeartbeat(SystemWallpaperHeartbeat(
                timestamp: WallpaperExportServiceTests.referenceNow, activeChoiceID: SystemWallpaperManifest.selectedChoiceID,
                activeChoiceIDs: [SystemWallpaperManifest.selectedChoiceID], activeDisplayIDs: displays,
                selectedTileDisplayIDs: displays
            ))
            service.refreshProviderStatus()
        }

        func manifestOnDisk() throws -> SystemWallpaperManifest {
            try JSONDecoder().decode(SystemWallpaperManifest.self, from: Data(contentsOf: manifestURL))
        }
    }

    /// Fires at the publish's one main-actor yield, between the staged copy and
    /// the commit — the window a concurrent remove has to land in.
    @MainActor
    private final class PublishHook {
        var run: (() -> Void)?
        /// The setup publish a test does first must not trip it.
        func fire() {
            let pending = run
            run = nil
            pending?()
        }
    }

    private func makeRig(
        thumbnailJPEG: Data? = Data([0xFF, 0xD8, 0xFF, 0xE0]),
        now: Date = referenceNow,
        copyOperation: (@Sendable (URL, URL) throws -> Void)? = nil,
        extractionOperation: (@Sendable (URL, String, URL) throws -> Void)? = nil,
        duringThumbnail: PublishHook? = nil,
        expectedProvider: SystemWallpaperProviderIdentity? = nil,
        isProviderRunning: @escaping @Sendable (Int32) -> Bool = { _ in true }
    ) throws -> Rig {
        let base = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("WallpaperExportServiceTests-\(UUID().uuidString)")
        let root = base.appendingPathComponent("SystemWallpaper")
        let sources = base.appendingPathComponent("Sources")
        try FileManager.default.createDirectory(at: sources, withIntermediateDirectories: true)

        let resolver = SecurityScopedBookmarkResolver(
            resolveData: { data in
                guard let path = String(data: data, encoding: .utf8) else {
                    throw CocoaError(.fileReadCorruptFile)
                }
                return (URL(fileURLWithPath: path), false)
            },
            refreshData: { _ in Data() }
        )
        var dependencies = WallpaperExportService.Dependencies(
            sharedRoot: root,
            resolver: resolver,
            now: { now },
            makeThumbnailJPEG: { _ in
                if let duringThumbnail {
                    await MainActor.run { duringThumbnail.fire() }
                }
                return thumbnailJPEG
            },
            copyVideoFile: copyOperation ?? { try FileManager.default.copyItem(at: $0, to: $1) },
            expectedProvider: expectedProvider,
            isProviderRunning: isProviderRunning
        )
        if let extractionOperation {
            dependencies.extractVideoFromPackage = extractionOperation
        }
        let service = WallpaperExportService(dependencies: dependencies)
        return Rig(service: service, root: root, sourceDirectory: sources)
    }

    @Test("Video source admission rejects directories and FIFOs before copying or parsing", arguments: [false, true])
    func nonRegularVideoRejectedBeforeCopy(fifo: Bool) async throws {
        final class Copies: Sendable {
            let paths = OSAllocatedUnfairLock(initialState: [String]())

            func safeCopy(_ source: URL, _ destination: URL) throws {
                paths.withLock { $0.append(source.path) }
                // Never open/copy a special file, even in the unfixed production path.
                guard try source.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else {
                    throw CocoaError(.fileReadUnknown)
                }
                try FileManager.default.copyItem(at: source, to: destination)
            }
        }
        let copies = Copies()
        let rig = try makeRig(
            copyOperation: { try copies.safeCopy($0, $1) },
            extractionOperation: { source, _, destination in try copies.safeCopy(source, destination) }
        )
        defer { try? FileManager.default.removeItem(at: rig.root.deletingLastPathComponent()) }
        let saved = try rig.makeVideoBookmark(bytes: Data("keep".utf8))
        try await rig.service.publish(bookmark: saved)
        let before = try Data(contentsOf: rig.manifestURL)
        let files = try FileManager.default.contentsOfDirectory(atPath: rig.videosDirectory.path).sorted()
        copies.paths.withLock { $0.removeAll() }
        let input = rig.sourceDirectory.appendingPathComponent(fifo ? "pipe.mov" : "directory.mov")
        if fifo {
            #expect(mkfifo(input.path, 0o600) == 0)
        } else {
            try FileManager.default.createDirectory(at: input, withIntermediateDirectories: true)
        }
        await #expect(throws: WallpaperExportService.ServiceError.unsupportedContent) {
            try await rig.service.publish(bookmark: WallpaperBookmark(
                label: "Invalid package", content: .video(bookmarkData: Data(input.path.utf8), packageEntryName: "video.mp4")
            ))
        }
        let copyPaths = copies.paths.withLock { $0 }
        #expect(copyPaths.isEmpty)
        #expect(try Data(contentsOf: rig.manifestURL) == before)
        #expect(try FileManager.default.contentsOfDirectory(atPath: rig.videosDirectory.path).sorted() == files)
        #expect(rig.service.items.count == 1)
        #expect(rig.service.lastError == WallpaperExportService.ServiceError.unsupportedContent.localizedDescription)
    }

    @Test("A selected regular-file symlink publishes independent video bytes")
    func regularTargetSymlinkPublishesIndependentBytes() async throws {
        let rig = try makeRig()
        defer { try? FileManager.default.removeItem(at: rig.root.deletingLastPathComponent()) }
        let bytes = Data("linked-video".utf8)
        let target = rig.sourceDirectory.appendingPathComponent("original.mov")
        try bytes.write(to: target)
        let link = rig.sourceDirectory.appendingPathComponent("selected.mov")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        try await rig.service.publish(bookmark: WallpaperBookmark(
            label: "Selected link", content: .video(bookmarkData: Data(link.path.utf8))
        ))
        let item = try #require(rig.service.items.first)
        let published = try #require(rig.service.videoURL(for: item))
        let isRegular = try published.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile
        #expect(isRegular == true)
        try FileManager.default.removeItem(at: target)
        #expect(try Data(contentsOf: published) == bytes)
    }

    @Test("An atomically written heartbeat reaches the service through the directory watch")
    func atomicHeartbeatWriteReachesTheWatch() async throws {
        let rig = try makeRig()
        defer { try? FileManager.default.removeItem(at: rig.root.deletingLastPathComponent()) }

        rig.service.startObservingSharedRoot()
        defer { rig.service.stopObservingSharedRoot() }
        #expect(rig.service.heartbeat == nil)

        // `.atomic` matches how the appex writes, and it replaces the file by rename:
        // watching the file instead of its directory stops receiving events right here.
        try FileManager.default.createDirectory(at: rig.root, withIntermediateDirectories: true)
        let beat = SystemWallpaperHeartbeat(timestamp: Self.referenceNow, activeChoiceID: "watched")
        try JSONEncoder().encode(beat).write(to: rig.heartbeatURL, options: .atomic)

        var delivered = false
        for _ in 0 ..< 60 where !delivered {
            try await Task.sleep(for: .milliseconds(50))
            delivered = rig.service.heartbeat?.activeChoiceID == "watched"
        }
        #expect(delivered, "the directory watch must deliver an atomically written heartbeat")
    }

    @Test("A failed selected video reports the renderer failure instead of in-use")
    func selectedRendererFailureIsVisible() async throws {
        let rig = try makeRig()
        defer { try? FileManager.default.removeItem(at: rig.root.deletingLastPathComponent()) }
        let bookmark = try rig.makeVideoBookmark(label: "Broken clip")
        try await rig.service.publish(bookmark: bookmark)
        let id = bookmark.id.uuidString
        try rig.writeHeartbeat(SystemWallpaperHeartbeat(timestamp: Self.referenceNow,
                                                        activeChoiceID: id,
                                                        playbackFailures: [id: "video.noFrames"]))
        rig.service.refresh()
        guard case let .failed(message) = rig.service.status else {
            Issue.record("Renderer failure must be surfaced even when the choice is selected")
            return
        }
        #expect(message.contains("video.noFrames"))
        try rig.writeHeartbeat(SystemWallpaperHeartbeat(timestamp: Self.referenceNow, activeChoiceID: id,
                                                        playbackFailures: [:]))
        rig.service.refreshProviderStatus()
        #expect(rig.service.status == .inUse(itemTitle: "Broken clip"))
    }

    @Test("A different provider copy is diagnosed instead of silently ignored")
    func differentProviderCopyIsDiagnosed() throws {
        let expected = SystemWallpaperProviderIdentity(build: "42", bundlePath: "/app/P.appex", pid: 0)
        let rig = try makeRig(expectedProvider: expected)
        defer { try? FileManager.default.removeItem(at: rig.root.deletingLastPathComponent()) }
        try rig.writeHeartbeat(SystemWallpaperHeartbeat(timestamp: Self.referenceNow, activeChoiceID: nil,
                                                        provider: SystemWallpaperProviderIdentity(build: "42", bundlePath: "/old/P.appex", pid: 0)))
        rig.service.refreshProviderStatus()
        #expect(rig.service.providerIssue == .differentCopy)
    }

    @Test("A stopped provider cannot appear in use even while its heartbeat is fresh")
    func stoppedProviderIsDiagnosed() async throws {
        let rig = try makeRig(isProviderRunning: { _ in false })
        defer { try? FileManager.default.removeItem(at: rig.root.deletingLastPathComponent()) }
        let bookmark = try rig.makeVideoBookmark()
        try await rig.service.publish(bookmark: bookmark)
        try rig.writeHeartbeat(SystemWallpaperHeartbeat(timestamp: Self.referenceNow,
                                                        activeChoiceID: bookmark.id.uuidString,
                                                        provider: SystemWallpaperProviderIdentity(build: "42", bundlePath: "/app/P.appex", pid: 123)))
        rig.service.refreshProviderStatus()
        #expect(rig.service.providerIssue == .stopped)
        #expect(!rig.service.isItemInUse(bookmark.id.uuidString))
    }

    @Test("An idle provider may exit without a stopped warning")
    func idleProviderExitIsNotAnError() throws {
        let rig = try makeRig(isProviderRunning: { _ in false })
        defer { try? FileManager.default.removeItem(at: rig.root.deletingLastPathComponent()) }
        try rig.writeHeartbeat(SystemWallpaperHeartbeat(timestamp: Self.referenceNow,
                                                        activeChoiceID: nil, activeChoiceIDs: [],
                                                        provider: SystemWallpaperProviderIdentity(build: "42", bundlePath: "/app/P.appex", pid: 123)))
        rig.service.refreshProviderStatus()
        #expect(rig.service.providerIssue == nil)
    }

    // MARK: - Provider declaration

    @Test("The launch step declares the bundled appex so idle instances elsewhere can retire")
    func launchDeclaresBundledProvider() throws {
        let installed = SystemWallpaperProviderIdentity(
            build: "42", bundlePath: "/Applications/Loomscreen.app/Contents/Extensions/P.appex", pid: 0
        )
        let rig = try makeRig(expectedProvider: installed)
        defer { try? FileManager.default.removeItem(at: rig.root.deletingLastPathComponent()) }
        let file = rig.root.appendingPathComponent("provider.json")
        // Init only reads: the test host is the real app and must not declare itself into the real container.
        #expect(!FileManager.default.fileExists(atPath: file.path))
        rig.service.declareBundledProvider()
        let declared = try SystemWallpaperCoding.decoder.decode(SystemWallpaperProviderIdentity.self, from: Data(contentsOf: file))
        #expect(declared == installed)
    }

    @Test("No bundled appex means no declaration file")
    func launchWithoutProviderDeclaresNothing() throws {
        let rig = try makeRig(expectedProvider: nil)
        defer { try? FileManager.default.removeItem(at: rig.root.deletingLastPathComponent()) }
        rig.service.declareBundledProvider()
        #expect(!FileManager.default.fileExists(atPath: rig.root.appendingPathComponent("provider.json").path))
    }

    // MARK: - Publish

    @Test("Shared removal deletes both files — the path the system's own Remove takes")
    func sharedRemovalDeletesFiles() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("SharedRemoval-\(UUID().uuidString)")
        let videos = root.appendingPathComponent("Videos")
        try FileManager.default.createDirectory(at: videos, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let video = videos.appendingPathComponent("clip.mp4")
        let thumbnail = videos.appendingPathComponent("clip.jpg")
        try Data("v".utf8).write(to: video)
        try Data("t".utf8).write(to: thumbnail)

        let manifest = SystemWallpaperManifest(
            version: SystemWallpaperManifest.currentVersion,
            items: [
                .init(id: "keep", title: "Keep", fileName: "other.mp4", thumbnailFileName: nil, addedAt: Self.referenceNow),
                .init(id: "drop", title: "Drop", fileName: "clip.mp4", thumbnailFileName: "clip.jpg", addedAt: Self.referenceNow)
            ]
        )

        var persisted: SystemWallpaperManifest?
        let updated = try #require(SystemWallpaperLibrary.remove(
            id: "drop", from: manifest, videosDirectory: videos,
            persist: { persisted = $0 }
        ))

        #expect(updated.items.map(\.id) == ["keep"])
        #expect(persisted?.items.map(\.id) == ["keep"], "the shrunk manifest must be persisted")
        #expect(!FileManager.default.fileExists(atPath: video.path), "the video must not be left on disk")
        #expect(!FileManager.default.fileExists(atPath: thumbnail.path), "the thumbnail must not be left on disk")
    }

    @Test("A failed manifest persist deletes nothing — no entry may ever point at a missing file")
    func sharedRemovalKeepsFilesWhenPersistFails() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("SharedRemovalPersistFail-\(UUID().uuidString)")
        let videos = root.appendingPathComponent("Videos")
        try FileManager.default.createDirectory(at: videos, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let video = videos.appendingPathComponent("clip.mp4")
        try Data("v".utf8).write(to: video)
        let manifest = SystemWallpaperManifest(
            version: SystemWallpaperManifest.currentVersion,
            items: [.init(id: "drop", title: "Drop", fileName: "clip.mp4", thumbnailFileName: nil, addedAt: Self.referenceNow)]
        )

        struct Boom: Error {}
        #expect(throws: Boom.self) {
            try SystemWallpaperLibrary.remove(
                id: "drop", from: manifest, videosDirectory: videos,
                persist: { _ in throw Boom() }
            )
        }
        #expect(FileManager.default.fileExists(atPath: video.path),
                "persist failed, so the file must survive")
    }

    @Test("Removing an id that is not in the manifest is a no-op, not an empty rewrite")
    func sharedRemovalIgnoresUnknownID() throws {
        let manifest = SystemWallpaperManifest(
            version: SystemWallpaperManifest.currentVersion,
            items: [.init(id: "keep", title: "Keep", fileName: "a.mp4", thumbnailFileName: nil, addedAt: Self.referenceNow)]
        )
        var persistCalls = 0
        #expect(SystemWallpaperLibrary.remove(
            id: "ghost",
            from: manifest,
            videosDirectory: URL(fileURLWithPath: NSTemporaryDirectory()),
            persist: { _ in persistCalls += 1 }
        ) == nil)
        #expect(persistCalls == 0)
    }

    @Test("The orphan sweep reclaims old unreferenced files and spares young and referenced ones")
    func sweepOrphansReclaimsOldUnreferencedFiles() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("OrphanSweep-\(UUID().uuidString)")
        let videos = root.appendingPathComponent("Videos")
        try FileManager.default.createDirectory(at: videos, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let referenced = videos.appendingPathComponent("keep.mp4")
        let oldOrphan = videos.appendingPathComponent("orphan.mp4")
        let youngOrphan = videos.appendingPathComponent("young.mp4")
        for url in [referenced, oldOrphan, youngOrphan] { try Data("x".utf8).write(to: url) }
        let past = Self.referenceNow.addingTimeInterval(-7200)
        for url in [referenced, oldOrphan] {
            try FileManager.default.setAttributes([.modificationDate: past], ofItemAtPath: url.path)
        }
        let manifest = SystemWallpaperManifest(
            version: SystemWallpaperManifest.currentVersion,
            items: [.init(id: "keep", title: "Keep", fileName: "keep.mp4", thumbnailFileName: nil, addedAt: past)]
        )

        SystemWallpaperLibrary.sweepOrphans(
            manifest: manifest, videosDirectory: videos, now: Self.referenceNow
        )

        #expect(FileManager.default.fileExists(atPath: referenced.path), "referenced files stay")
        #expect(!FileManager.default.fileExists(atPath: oldOrphan.path), "old orphans are reclaimed")
        #expect(FileManager.default.fileExists(atPath: youngOrphan.path),
                "a fresh file may be a publish mid-copy — the age guard spares it")
    }

    @Test("A staging file mid-copy survives the sweep even when the source was old")
    func sweepSparesStagingWithAncientSourceMtime() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("OrphanSweepStaging-\(UUID().uuidString)")
        let videos = root.appendingPathComponent("Videos")
        try FileManager.default.createDirectory(at: videos, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        // `copyItem` carries the source's mtime over, so a staging file for a
        // year-old video reads as ancient the whole time the copy is running.
        let staging = videos.appendingPathComponent(
            SystemWallpaperLibrary.stagingFileName(itemID: "pending", ext: "mp4", now: Self.referenceNow)
        )
        try Data("partial".utf8).write(to: staging)
        try FileManager.default.setAttributes(
            [.modificationDate: Self.referenceNow.addingTimeInterval(-365 * 86400)],
            ofItemAtPath: staging.path
        )

        SystemWallpaperLibrary.sweepOrphans(
            manifest: .empty, videosDirectory: videos, now: Self.referenceNow
        )

        #expect(FileManager.default.fileExists(atPath: staging.path),
                "the sweep must key off the staging file's own age, not the copied mtime")
    }

    @Test("An abandoned staging file is still reclaimed once it is far too old to be live")
    func sweepReclaimsAbandonedStaging() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("OrphanSweepStale-\(UUID().uuidString)")
        let videos = root.appendingPathComponent("Videos")
        try FileManager.default.createDirectory(at: videos, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let staging = videos.appendingPathComponent(
            SystemWallpaperLibrary.stagingFileName(
                itemID: "crashed", ext: "mp4",
                now: Self.referenceNow.addingTimeInterval(-48 * 3600)
            )
        )
        try Data("partial".utf8).write(to: staging)

        SystemWallpaperLibrary.sweepOrphans(
            manifest: .empty, videosDirectory: videos, now: Self.referenceNow
        )

        #expect(!FileManager.default.fileExists(atPath: staging.path),
                "a staging file from two days ago cannot still be copying")
    }

    @Test("The manifest lock fails closed — an unlockable root must not run unserialized")
    func lockFailsClosedRatherThanRunningUnserialized() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("LockFailClosed-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        // A directory where the lock file belongs makes `open(…, O_WRONLY)` fail
        // with EISDIR — the stand-in for a root where the lock cannot be taken.
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("manifest.lock"), withIntermediateDirectories: true
        )

        var ran = false
        #expect(throws: (any Error).self) {
            try SystemWallpaperLock.withExclusiveLock(root: root) { ran = true }
        }
        #expect(!ran, "running the mutation unlocked is the lost update this lock exists to prevent")
    }

    @Test("A corrupt manifest fails the publish instead of rewriting the library away")
    func corruptManifestDoesNotSwallowExistingItems() async throws {
        let rig = try makeRig()
        defer { try? FileManager.default.removeItem(at: rig.root.deletingLastPathComponent()) }
        let bookmark = try rig.makeVideoBookmark(named: "first.mp4", label: "First")
        try await rig.service.publish(bookmark: bookmark)
        let before = try rig.manifestOnDisk()
        #expect(before.items.count == 1)
        let survivingFile = before.items[0].fileName

        try Data("{ not json".utf8).write(to: rig.manifestURL)

        let second = try rig.makeVideoBookmark(named: "second.mp4", label: "Second")
        await #expect(throws: (any Error).self) {
            try await rig.service.publish(bookmark: second)
        }
        #expect(
            FileManager.default.fileExists(
                atPath: rig.root.appendingPathComponent("Videos/\(survivingFile)").path),
            "a corrupt manifest must never turn already-published videos into sweepable orphans"
        )
    }

    /// `chmod 000`: present, but unreadable rather than missing. An atomic write
    /// still succeeds under it, so callers check the manifest, not the write.
    private func denyReads(_ url: URL) throws {
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: url.path)
    }

    private func allowReads(_ url: URL) throws {
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: url.path)
    }

    @Test("A manifest that exists but cannot be read fails the publish like a corrupt one")
    func unreadableManifestFailsPublish() async throws {
        let rig = try makeRig()
        defer { try? FileManager.default.removeItem(at: rig.root.deletingLastPathComponent()) }
        let first = try rig.makeVideoBookmark(named: "first.mp4", label: "First")
        try await rig.service.publish(bookmark: first)
        try denyReads(rig.manifestURL)

        let second = try rig.makeVideoBookmark(named: "second.mp4", label: "Second")
        await #expect(throws: (any Error).self) {
            try await rig.service.publish(bookmark: second)
        }

        try allowReads(rig.manifestURL)
        let manifest = try rig.manifestOnDisk()
        #expect(
            manifest.items.map(\.id) == [first.id.uuidString],
            "an unreadable manifest must not be rewritten from scratch: \(manifest.items.map(\.title))"
        )
    }

    @Test("A republish that fails after the swap restores the video it displaced")
    func failedRepublishRestoresPreviousFiles() async throws {
        let rig = try makeRig()
        defer { try? FileManager.default.removeItem(at: rig.root.deletingLastPathComponent()) }
        let original = Data("original-payload".utf8)
        let first = try rig.makeVideoBookmark(named: "first.mp4", bytes: original, label: "First")
        try await rig.service.publish(bookmark: first)
        let published = rig.videosDirectory.appendingPathComponent("\(first.id.uuidString).mp4")
        let thumbnail = rig.videosDirectory.appendingPathComponent("\(first.id.uuidString).jpg")

        // The manifest read fails after the live copy has already been swapped.
        let replacement = WallpaperBookmark(
            label: "First",
            content: try rig.makeVideoBookmark(
                named: "second.mp4", bytes: Data("replacement-payload".utf8), label: "First"
            ).content,
            id: first.id
        )
        try denyReads(rig.manifestURL)
        await #expect(throws: (any Error).self) {
            try await rig.service.publish(bookmark: replacement)
        }
        try allowReads(rig.manifestURL)

        #expect(
            try Data(contentsOf: published) == original,
            "a failed republish must leave the copy the manifest still points at"
        )
        #expect(FileManager.default.fileExists(atPath: thumbnail.path))
        let leftovers = try FileManager.default
            .contentsOfDirectory(atPath: rig.videosDirectory.path)
            .filter { $0.contains("backup-") }
        #expect(leftovers.isEmpty, "the restore must not leave its backup behind: \(leftovers)")
    }

    @Test("A republish under a new extension keeps the thumbnail the old entry points at")
    func failedRepublishWithNewExtensionKeepsThumbnail() async throws {
        let rig = try makeRig()
        defer { try? FileManager.default.removeItem(at: rig.root.deletingLastPathComponent()) }
        let bookmark = try rig.makeVideoBookmark(named: "first.mp4", bytes: Data("original".utf8))
        try await rig.service.publish(bookmark: bookmark)
        let itemID = bookmark.id.uuidString
        let publishedVideo = rig.videosDirectory.appendingPathComponent("\(itemID).mp4")
        let thumbnail = rig.videosDirectory.appendingPathComponent("\(itemID).jpg")

        // The destination `<id>.mov` does not exist yet, while the thumbnail
        // keeps its one name.
        let replacement = WallpaperBookmark(
            label: "First",
            content: try rig.makeVideoBookmark(
                named: "second.mov", bytes: Data("replacement".utf8)
            ).content,
            id: bookmark.id
        )
        try denyReads(rig.manifestURL)
        await #expect(throws: (any Error).self) {
            try await rig.service.publish(bookmark: replacement)
        }
        try allowReads(rig.manifestURL)

        #expect(FileManager.default.fileExists(atPath: thumbnail.path),
                "the manifest still names this thumbnail — deleting it erases the tile from the panel")
        #expect(try Data(contentsOf: publishedVideo) == Data("original".utf8))
        #expect(!FileManager.default.fileExists(
            atPath: rig.videosDirectory.appendingPathComponent("\(itemID).mov").path),
            "the half-published new copy must be taken back")
    }

    @Test("A republish under a new extension drops the copy the old entry named")
    func republishWithNewExtensionRemovesOldVideo() async throws {
        let rig = try makeRig()
        defer { try? FileManager.default.removeItem(at: rig.root.deletingLastPathComponent()) }
        let bookmark = try rig.makeVideoBookmark(named: "first.mp4", bytes: Data("original".utf8))
        try await rig.service.publish(bookmark: bookmark)
        let itemID = bookmark.id.uuidString

        let replacement = WallpaperBookmark(
            label: "First",
            content: try rig.makeVideoBookmark(
                named: "second.mov", bytes: Data("replacement".utf8)
            ).content,
            id: bookmark.id
        )
        try await rig.service.publish(bookmark: replacement)

        #expect(rig.service.items.map(\.fileName) == ["\(itemID).mov"])
        #expect(!FileManager.default.fileExists(
            atPath: rig.videosDirectory.appendingPathComponent("\(itemID).mp4").path),
            "nothing references the old copy any more, and it is a whole video")
    }

    @Test("A remove that lands mid-publish keeps the entry removed")
    func removeDuringPublishIsNotUndone() async throws {
        let hook = PublishHook()
        let rig = try makeRig(duringThumbnail: hook)
        defer { try? FileManager.default.removeItem(at: rig.root.deletingLastPathComponent()) }
        let bookmark = try rig.makeVideoBookmark(bytes: Data("original".utf8))
        try await rig.service.publish(bookmark: bookmark)
        let itemID = bookmark.id.uuidString

        hook.run = { try? rig.service.remove(itemID: itemID) }
        let replacement = WallpaperBookmark(
            label: "Replacement",
            content: try rig.makeVideoBookmark(
                named: "second.mp4", bytes: Data("replacement".utf8)
            ).content,
            id: bookmark.id
        )
        await #expect(throws: (any Error).self) {
            try await rig.service.publish(bookmark: replacement)
        }

        #expect(rig.service.items.isEmpty, "the removed entry must not come back")
        #expect(try rig.manifestOnDisk().items.isEmpty)
        // No `manifest.lock` term: the lock lives at sharedRoot/manifest.lock, a sibling of
        // Videos/, so filtering for it here would only hide a real leftover of that name.
        let leftovers = try FileManager.default
            .contentsOfDirectory(atPath: rig.videosDirectory.path)
        #expect(leftovers.isEmpty, "nor its files: \(leftovers)")
    }

    @Test("A republish's displaced backup outlives a concurrent sweep")
    func sweepSparesRepublishBackup() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("OrphanSweepBackup-\(UUID().uuidString)")
        let videos = root.appendingPathComponent("Videos")
        try FileManager.default.createDirectory(at: videos, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        // The backup *is* the previously published video, so it carries that
        // file's mtime — months old for anything published a while ago.
        let backup = videos.appendingPathComponent(
            SystemWallpaperLibrary.transientBackupName(
                itemID: "live", ext: "mp4", tag: UUID(), now: Self.referenceNow
            )
        )
        try Data("displaced".utf8).write(to: backup)
        try FileManager.default.setAttributes(
            [.modificationDate: Self.referenceNow.addingTimeInterval(-365 * 86400)],
            ofItemAtPath: backup.path
        )

        SystemWallpaperLibrary.sweepOrphans(
            manifest: .empty, videosDirectory: videos, now: Self.referenceNow
        )

        #expect(FileManager.default.fileExists(atPath: backup.path),
                "sweeping the rollback copy away mid-republish makes the rollback lose the video")
    }

    @Test("Refresh spares a video another instance committed after refresh read the manifest")
    func refreshSweepSparesConcurrentlyCommittedVideo() async throws {
        let rig = try makeRig()
        defer { try? FileManager.default.removeItem(at: rig.root.deletingLastPathComponent()) }
        let bookmark = try rig.makeVideoBookmark()
        try await rig.service.publish(bookmark: bookmark)
        let committed = rig.videosDirectory.appendingPathComponent("\(UUID().uuidString).mp4")
        rig.service.onHeartbeatRefreshed = {
            rig.service.onHeartbeatRefreshed = nil
            try? SystemWallpaperLock.withExclusiveLock(root: rig.root) {
                try Data("other-instance".utf8).write(to: committed)
                try FileManager.default.setAttributes(
                    [.modificationDate: Self.referenceNow.addingTimeInterval(-2 * 3600)],
                    ofItemAtPath: committed.path
                )
                var manifest = try rig.manifestOnDisk()
                var item = try #require(manifest.items.first)
                item.id = committed.deletingPathExtension().lastPathComponent
                item.fileName = committed.lastPathComponent
                manifest.items.append(item)
                try JSONEncoder().encode(manifest).write(to: rig.manifestURL)
            }
        }

        rig.service.refresh()

        #expect(FileManager.default.fileExists(atPath: committed.path),
                "a sweep against the pre-commit manifest deletes the other instance's new video")
    }

    @Test("A manifest entry whose file name escapes Videos/ is dropped at decode")
    func manifestDropsTraversalFileNames() throws {
        let json = """
        {"version":1,"items":[
          {"id":"evil","title":"Evil","fileName":"../../escape.mp4","addedAt":0},
          {"id":"ok","title":"OK","fileName":"fine.mp4","addedAt":0},
          {"id":"evilthumb","title":"T","fileName":"fine2.mp4","thumbnailFileName":"../t.jpg","addedAt":0}
        ]}
        """
        let manifest = try JSONDecoder().decode(SystemWallpaperManifest.self, from: Data(json.utf8))
        #expect(manifest.items.map(\.id) == ["ok"],
                "both the traversal fileName and the traversal thumbnail must be dropped")
    }

    @Test("A Workshop video is sliced out of its package, not copied whole")
    func publishExtractsPackagedVideo() async throws {
        let rig = try makeRig()
        defer { try? FileManager.default.removeItem(at: rig.root.deletingLastPathComponent()) }
        let (bookmark, payload) = try rig.makePackagedVideoBookmark()

        try await rig.service.publish(bookmark: bookmark)

        // Extension comes from the entry inside the package, not from scene.pkg.
        let extracted = rig.videosDirectory.appendingPathComponent("\(bookmark.id.uuidString).mp4")
        #expect(try Data(contentsOf: extracted) == payload)
        let item = try #require(rig.manifestOnDisk().items.first)
        #expect(item.fileName == "\(bookmark.id.uuidString).mp4")
    }

    @Test("A package missing the named video fails instead of publishing an empty file")
    func publishRejectsMissingPackageEntry() async throws {
        let rig = try makeRig()
        defer { try? FileManager.default.removeItem(at: rig.root.deletingLastPathComponent()) }
        let (bookmark, _) = try rig.makePackagedVideoBookmark(entryName: "video.mp4")
        let broken = WallpaperBookmark(
            label: bookmark.label,
            content: .video(
                bookmarkData: Data(rig.sourceDirectory.appendingPathComponent("scene.pkg").path.utf8),
                packageEntryName: "missing.mp4"
            )
        )

        await #expect(throws: (any Error).self) {
            try await rig.service.publish(bookmark: broken)
        }
        #expect(rig.service.items.isEmpty)
        #expect(!FileManager.default.fileExists(
            atPath: rig.videosDirectory.appendingPathComponent("\(broken.id.uuidString).mp4").path
        ))
    }

    @Test("Publish copies the video, writes the thumbnail, and records both in the manifest")
    func publishWritesFilesAndManifest() async throws {
        let rig = try makeRig()
        defer { try? FileManager.default.removeItem(at: rig.root.deletingLastPathComponent()) }
        let bytes = Data("unique-payload-\(UUID())".utf8)
        let bookmark = try rig.makeVideoBookmark(bytes: bytes, label: "Sunset")

        try await rig.service.publish(bookmark: bookmark)

        let copied = rig.videosDirectory.appendingPathComponent("\(bookmark.id.uuidString).mp4")
        #expect(try Data(contentsOf: copied) == bytes)
        let thumbnail = rig.videosDirectory.appendingPathComponent("\(bookmark.id.uuidString).jpg")
        #expect(FileManager.default.fileExists(atPath: thumbnail.path))

        let manifest = try rig.manifestOnDisk()
        #expect(manifest.version == SystemWallpaperManifest.currentVersion)
        let item = try #require(manifest.items.first)
        #expect(item.id == bookmark.id.uuidString)
        #expect(item.title == "Sunset")
        #expect(item.fileName == copied.lastPathComponent)
        #expect(item.thumbnailFileName == thumbnail.lastPathComponent)
        #expect(item.addedAt == Self.referenceNow)

        #expect(rig.service.items == manifest.items)
        #expect(rig.service.isPublished(bookmarkID: bookmark.id))
        #expect(rig.service.diskUsageBytes > 0)
    }

    @Test("A failed thumbnail fails the publish and rolls the copy back — the panel refuses thumbnailless tiles")
    func publishFailsWithoutThumbnail() async throws {
        let rig = try makeRig(thumbnailJPEG: nil)
        defer { try? FileManager.default.removeItem(at: rig.root.deletingLastPathComponent()) }
        let bookmark = try rig.makeVideoBookmark()

        await #expect(throws: WallpaperExportService.ServiceError.thumbnailFailed) {
            try await rig.service.publish(bookmark: bookmark)
        }

        #expect(rig.service.items.isEmpty, "a choice invisible in the panel must not be recorded")
        let leftovers = (try? FileManager.default.contentsOfDirectory(atPath: rig.videosDirectory.path)) ?? []
        #expect(leftovers.filter { !$0.hasPrefix(".") }.isEmpty,
                "the copied video must be rolled back, not stranded: \(leftovers)")
    }

    @Test("A failed republish leaves the published copy playable — the live file is only touched by the atomic swap")
    func republishThumbnailFailureKeepsOldCopy() async throws {
        let rig = try makeRig()
        defer { try? FileManager.default.removeItem(at: rig.root.deletingLastPathComponent()) }
        let bookmark = try rig.makeVideoBookmark(bytes: Data("original-bytes".utf8))
        try await rig.service.publish(bookmark: bookmark)
        let fileName = try #require(rig.service.items.first?.fileName)
        let published = rig.videosDirectory.appendingPathComponent(fileName)

        let failing = WallpaperExportService(dependencies: .init(
            sharedRoot: rig.root,
            resolver: SecurityScopedBookmarkResolver(
                resolveData: { data in
                    guard let path = String(data: data, encoding: .utf8) else {
                        throw CocoaError(.fileReadCorruptFile)
                    }
                    return (URL(fileURLWithPath: path), false)
                },
                refreshData: { _ in Data() }
            ),
            now: { Date(timeIntervalSince1970: 1_760_000_000) },
            makeThumbnailJPEG: { _ in nil }
        ))
        await #expect(throws: WallpaperExportService.ServiceError.thumbnailFailed) {
            try await failing.publish(bookmark: bookmark)
        }

        #expect(FileManager.default.fileExists(atPath: published.path),
                "the already-published video must survive a failed republish")
        #expect(try String(data: Data(contentsOf: published), encoding: .utf8) == "original-bytes")
        #expect(failing.items.map(\.id) == [bookmark.id.uuidString],
                "the manifest entry must still be there and still valid")
    }

    @Test("Publish rejects content that is not a video at all")
    func publishRejectsUnsupportedContent() async throws {
        let rig = try makeRig()
        defer { try? FileManager.default.removeItem(at: rig.root.deletingLastPathComponent()) }
        let web = WallpaperBookmark(
            label: "Web",
            content: .html(source: .file(bookmarkData: Data("x".utf8)), config: .default)
        )
        await #expect(throws: WallpaperExportService.ServiceError.unsupportedContent) {
            try await rig.service.publish(bookmark: web)
        }
        #expect(rig.service.lastError != nil)
        #expect(!FileManager.default.fileExists(atPath: rig.manifestURL.path))
    }


    // MARK: - Remove

    @Test("Remove deletes both files and rewrites the manifest")
    func removeCleansUp() async throws {
        let rig = try makeRig()
        defer { try? FileManager.default.removeItem(at: rig.root.deletingLastPathComponent()) }
        let bookmark = try rig.makeVideoBookmark()
        try await rig.service.publish(bookmark: bookmark)
        let itemID = bookmark.id.uuidString

        try rig.service.remove(itemID: itemID)

        #expect(rig.service.items.isEmpty)
        #expect(try rig.manifestOnDisk().items.isEmpty)
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: rig.videosDirectory.path)
        #expect(leftovers.isEmpty)
        #expect(rig.service.diskUsageBytes == 0)
    }

    @Test("Removing the item the system is playing is allowed — it is the only way out")
    func removeAllowsInUseItem() async throws {
        let rig = try makeRig()
        defer { try? FileManager.default.removeItem(at: rig.root.deletingLastPathComponent()) }
        let bookmark = try rig.makeVideoBookmark()
        try await rig.service.publish(bookmark: bookmark)
        let itemID = bookmark.id.uuidString
        try rig.writeHeartbeat(SystemWallpaperHeartbeat(
            timestamp: Self.referenceNow.addingTimeInterval(-30),
            activeChoiceID: itemID
        ))
        rig.service.refresh()
        #expect(rig.service.isItemInUse(itemID), "precondition: the heartbeat says this one is on screen")

        try rig.service.remove(itemID: itemID)

        #expect(rig.service.items.isEmpty)
        #expect(!FileManager.default.fileExists(
            atPath: rig.videosDirectory.appendingPathComponent("\(itemID).mp4").path
        ))
    }


    // MARK: - Status machine

    @Test("An unhealthy heartbeat reads as system-incompatible")
    func statusSystemIncompatible() async throws {
        let rig = try makeRig()
        defer { try? FileManager.default.removeItem(at: rig.root.deletingLastPathComponent()) }
        let bookmark = try rig.makeVideoBookmark()
        try await rig.service.publish(bookmark: bookmark)
        try rig.writeHeartbeat(SystemWallpaperHeartbeat(
            timestamp: Self.referenceNow.addingTimeInterval(-10),
            activeChoiceID: nil,
            runtimeHealthy: false
        ))
        rig.service.refresh()
        #expect(rig.service.status == .systemIncompatible)
    }

    @Test("An unhealthy verdict from a different OS build is ignored — the layout may be fine after an update")
    func statusIgnoresStaleOSVersionVerdict() async throws {
        let rig = try makeRig()
        defer { try? FileManager.default.removeItem(at: rig.root.deletingLastPathComponent()) }
        let bookmark = try rig.makeVideoBookmark()
        try await rig.service.publish(bookmark: bookmark)
        try rig.writeHeartbeat(SystemWallpaperHeartbeat(
            timestamp: Self.referenceNow.addingTimeInterval(-10),
            activeChoiceID: nil,
            runtimeHealthy: false,
            osVersion: "1.0.0"
        ))
        rig.service.refresh()
        #expect(rig.service.status == .publishedNotSelected)

        try rig.writeHeartbeat(SystemWallpaperHeartbeat(
            timestamp: Self.referenceNow.addingTimeInterval(-10),
            activeChoiceID: nil,
            runtimeHealthy: false,
            osVersion: SystemWallpaperHeartbeat.currentOSVersion()
        ))
        rig.service.refresh()
        #expect(rig.service.status == .systemIncompatible)
    }

    @Test("An unhealthy verdict from an older revision of the layout check is ignored")
    func statusIgnoresStaleRuntimeCheckVerdict() async throws {
        let rig = try makeRig()
        defer { try? FileManager.default.removeItem(at: rig.root.deletingLastPathComponent()) }
        let bookmark = try rig.makeVideoBookmark()
        try await rig.service.publish(bookmark: bookmark)
        try rig.writeHeartbeat(SystemWallpaperHeartbeat(
            timestamp: Self.referenceNow.addingTimeInterval(-10),
            activeChoiceID: nil,
            runtimeHealthy: false,
            osVersion: SystemWallpaperHeartbeat.currentOSVersion(),
            runtimeCheckVersion: SystemWallpaperHeartbeat.currentRuntimeCheckVersion - 1
        ))
        rig.service.refresh()
        #expect(rig.service.status == .publishedNotSelected)
    }

    @Test("A heartbeat written before the check stamp existed still decodes and still counts")
    func heartbeatWithoutRuntimeCheckVersionDecodes() throws {
        let json = """
        {"timestamp":0,"runtimeHealthy":false,"osVersion":"\(SystemWallpaperHeartbeat.currentOSVersion())"}
        """
        let heartbeat = try JSONDecoder().decode(
            SystemWallpaperHeartbeat.self, from: Data(json.utf8)
        )
        #expect(heartbeat.runtimeCheckVersion == nil)
        let stampedAsOne = SystemWallpaperHeartbeat(
            timestamp: heartbeat.timestamp,
            activeChoiceID: nil,
            runtimeHealthy: false,
            osVersion: SystemWallpaperHeartbeat.currentOSVersion(),
            runtimeCheckVersion: 1
        )
        #expect(heartbeat.barsPublishing == stampedAsOne.barsPublishing,
                "an unstamped heartbeat was written by revision 1 and must be read as one")
    }

    @Test("In-use covers every active choice, not just the first display's")
    func isItemInUseChecksAllActiveChoices() async throws {
        let rig = try makeRig()
        defer { try? FileManager.default.removeItem(at: rig.root.deletingLastPathComponent()) }
        let bookmark = try rig.makeVideoBookmark()
        try await rig.service.publish(bookmark: bookmark)
        try rig.writeHeartbeat(SystemWallpaperHeartbeat(
            timestamp: Self.referenceNow.addingTimeInterval(-10),
            activeChoiceID: "other",
            activeChoiceIDs: ["other", bookmark.id.uuidString]
        ))
        rig.service.refresh()
        #expect(rig.service.isItemInUse(bookmark.id.uuidString),
                "the second display's choice must count as in use")
        #expect(!rig.service.isItemInUse("absent"))
    }

    @Test("No items reads as empty")
    func statusEmpty() throws {
        let rig = try makeRig()
        defer { try? FileManager.default.removeItem(at: rig.root.deletingLastPathComponent()) }
        rig.service.refresh()
        #expect(rig.service.status == .empty)
    }

    @Test("Items with a missing, stale, or choiceless heartbeat read as published-not-selected")
    func statusPublishedNotSelected() async throws {
        let rig = try makeRig()
        defer { try? FileManager.default.removeItem(at: rig.root.deletingLastPathComponent()) }
        let bookmark = try rig.makeVideoBookmark()
        try await rig.service.publish(bookmark: bookmark)

        #expect(rig.service.status == .publishedNotSelected)

        try rig.writeHeartbeat(SystemWallpaperHeartbeat(
            timestamp: Self.referenceNow.addingTimeInterval(-10),
            activeChoiceID: nil
        ))
        rig.service.refresh()
        #expect(rig.service.status == .publishedNotSelected)

        try rig.writeHeartbeat(SystemWallpaperHeartbeat(
            timestamp: Self.referenceNow.addingTimeInterval(
                -WallpaperExportService.heartbeatFreshnessInterval - 1
            ),
            activeChoiceID: bookmark.id.uuidString
        ))
        rig.service.refresh()
        #expect(rig.service.status == .publishedNotSelected)
        #expect(!rig.service.isItemInUse(bookmark.id.uuidString))
    }

    @Test("A fresh heartbeat matching an item reads as in-use with its title")
    func statusInUse() async throws {
        let rig = try makeRig()
        defer { try? FileManager.default.removeItem(at: rig.root.deletingLastPathComponent()) }
        let bookmark = try rig.makeVideoBookmark(label: "Aurora")
        try await rig.service.publish(bookmark: bookmark)
        try rig.writeHeartbeat(SystemWallpaperHeartbeat(
            timestamp: Self.referenceNow.addingTimeInterval(-60),
            activeChoiceID: bookmark.id.uuidString
        ))
        rig.service.refresh()
        #expect(rig.service.status == .inUse(itemTitle: "Aurora"))
    }

    @Test("A fresh healthy beat reports in-use only for the installed appex", arguments: [("41", false), ("42", true)])
    func healthyHeartbeatRequiresInstalledProvider(build: String, expectedInUse: Bool) async throws {
        let installed = SystemWallpaperProviderIdentity(
            build: "42",
            bundlePath: "/Applications/Loomscreen.app/Contents/Extensions/P.appex",
            pid: 0
        )
        let rig = try makeRig(expectedProvider: installed)
        defer { try? FileManager.default.removeItem(at: rig.root.deletingLastPathComponent()) }
        let bookmark = try rig.makeVideoBookmark(label: "Aurora")
        try await rig.service.publish(bookmark: bookmark)
        try rig.writeHeartbeat(SystemWallpaperHeartbeat(
            timestamp: Self.referenceNow.addingTimeInterval(-60),
            activeChoiceID: bookmark.id.uuidString,
            provider: SystemWallpaperProviderIdentity(
                build: build,
                bundlePath: installed.bundlePath,
                pid: 999
            )
        ))
        rig.service.refresh()
        #expect(rig.service.status == (expectedInUse ? .inUse(itemTitle: "Aurora") : .publishedNotSelected))
        #expect(rig.service.isItemInUse(bookmark.id.uuidString) == expectedInUse)
    }

    @Test("An unhealthy verdict bars publishing only for the installed appex", arguments: [("41", false), ("42", true)])
    func unhealthyHeartbeatRequiresInstalledProvider(build: String, expectedIncompatible: Bool) async throws {
        let installed = SystemWallpaperProviderIdentity(
            build: "42",
            bundlePath: "/Applications/Loomscreen.app/Contents/Extensions/P.appex",
            pid: 0
        )
        let rig = try makeRig(expectedProvider: installed)
        defer { try? FileManager.default.removeItem(at: rig.root.deletingLastPathComponent()) }
        let bookmark = try rig.makeVideoBookmark(label: "Aurora")
        try await rig.service.publish(bookmark: bookmark)
        try rig.writeHeartbeat(SystemWallpaperHeartbeat(
            timestamp: Self.referenceNow.addingTimeInterval(-60),
            activeChoiceID: nil,
            runtimeHealthy: false,
            provider: SystemWallpaperProviderIdentity(
                build: build,
                bundlePath: installed.bundlePath,
                pid: 999
            )
        ))
        rig.service.refresh()
        #expect((rig.service.status == .systemIncompatible) == expectedIncompatible)
    }

    @Test("A failed operation surfaces as failed until dismissed")
    func statusFailedOverlay() async throws {
        let rig = try makeRig()
        defer { try? FileManager.default.removeItem(at: rig.root.deletingLastPathComponent()) }
        let packaged = WallpaperBookmark(
            label: "Packed",
            content: .video(bookmarkData: Data("x".utf8), packageEntryName: "inner.mp4")
        )
        _ = try? await rig.service.publish(bookmark: packaged)
        guard case .failed = rig.service.status else {
            Issue.record("Expected .failed, got \(rig.service.status)")
            return
        }
        rig.service.clearLastError()
        #expect(rig.service.status == .empty)
    }

    @Test("A closed add sheet can report a mixed batch failure on the destination page")
    func closedSheetBatchFailure() async throws {
        let rig = try makeRig()
        defer { try? FileManager.default.removeItem(at: rig.root.deletingLastPathComponent()) }
        let invalid = WallpaperBookmark(label: "Missing", content: .video(bookmarkData: Data("missing".utf8), packageEntryName: "clip.mp4"))
        var failures: [String] = []
        do {
            _ = try await rig.service.publish(bookmark: invalid)
        } catch {
            failures.append(error.localizedDescription)
        }
        _ = try await rig.service.publish(bookmark: rig.makeVideoBookmark())
        #expect(rig.service.lastError == nil)
        #expect(!failures.isEmpty)
        rig.service.reportPublishFailures(failures)
        rig.service.refresh()
        #expect(rig.service.items.count == 1)
        #expect(rig.service.status == .failed(failures.joined(separator: "\n")))
        rig.service.clearLastError()
        #expect(rig.service.lastError == nil)
    }

    // MARK: - Corruption tolerance

    @Test("A corrupt manifest is refused, not treated as an empty library")
    func corruptManifestIsRefused() async throws {
        let rig = try makeRig()
        defer { try? FileManager.default.removeItem(at: rig.root.deletingLastPathComponent()) }
        try FileManager.default.createDirectory(at: rig.root, withIntermediateDirectories: true)
        try Data("{not json]".utf8).write(to: rig.manifestURL)

        rig.service.refresh()
        #expect(rig.service.items.isEmpty)
        #expect(rig.service.lastError != nil, "a damaged index must not look like an empty library")

        let bookmark = try rig.makeVideoBookmark()
        await #expect(throws: WallpaperExportService.ServiceError.manifestUnreadable) {
            try await rig.service.publish(bookmark: bookmark)
        }
        #expect(
            (try? Data(contentsOf: rig.manifestURL)) == Data("{not json]".utf8),
            "the damaged file is left exactly as found so it can be recovered"
        )
    }

    @Test("Republishing the same bookmark replaces its item instead of duplicating it")
    func republishReplaces() async throws {
        let rig = try makeRig()
        defer { try? FileManager.default.removeItem(at: rig.root.deletingLastPathComponent()) }
        let bookmark = try rig.makeVideoBookmark(label: "First")
        try await rig.service.publish(bookmark: bookmark)
        var renamed = bookmark
        renamed.label = "Second"
        try await rig.service.publish(bookmark: renamed)

        #expect(rig.service.items.count == 1)
        #expect(rig.service.items.first?.title == "Second")
    }

    /// Uses the live dependencies, not the stub every other test here uses:
    /// AVFoundation types a file by its extension, so the staging name matters.
    @Test("A staged copy is still a video AVFoundation can open")
    func stagedCopyKeepsAThumbnailableExtension() async throws {
        let staging = SystemWallpaperLibrary.stagingFileName(
            itemID: "thumbnailable", ext: "mp4", now: Self.referenceNow
        )
        #expect((staging as NSString).pathExtension == "mp4")
        #expect(SystemWallpaperLibrary.stagingCreation(fileName: staging) == Self.referenceNow)

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let video = directory.appendingPathComponent(staging)
        try Self.writeSingleFrameVideo(to: video)

        let jpeg = await WallpaperExportService.Dependencies.live().makeThumbnailJPEG(video)
        #expect(jpeg != nil)
    }

    private static func writeSingleFrameVideo(to url: URL) throws {
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: 160,
            AVVideoHeightKey: 90
        ])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input, sourcePixelBufferAttributes: nil
        )
        writer.add(input)
        writer.startWriting()
        writer.startSession(atSourceTime: .zero)

        var pixelBuffer: CVPixelBuffer?
        CVPixelBufferCreate(kCFAllocatorDefault, 160, 90, kCVPixelFormatType_32ARGB, nil, &pixelBuffer)
        if let pixelBuffer {
            CVPixelBufferLockBaseAddress(pixelBuffer, [])
            memset(CVPixelBufferGetBaseAddress(pixelBuffer), 0x40, CVPixelBufferGetDataSize(pixelBuffer))
            CVPixelBufferUnlockBaseAddress(pixelBuffer, [])
            // Two seconds long: the generator samples at 0.5s.
            adaptor.append(pixelBuffer, withPresentationTime: .zero)
            adaptor.append(pixelBuffer, withPresentationTime: CMTime(seconds: 2, preferredTimescale: 600))
        }
        input.markAsFinished()
        let done = DispatchSemaphore(value: 0)
        writer.finishWriting { done.signal() }
        done.wait()
    }
}
