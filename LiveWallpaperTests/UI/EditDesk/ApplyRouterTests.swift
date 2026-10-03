import AppKit
import Foundation
@testable import LiveWallpaper
import LiveWallpaperCore
import Testing

@Suite("Edit Desk apply routing", .serialized)
@MainActor
struct ApplyRouterTests {
    private let manager = ConfirmingWallpaperApplying()
    private let bookmarks = BookmarkStore(persistence: ApplyBookmarkPersistence())

    private func router(sceneCapable: Bool = true) -> ApplyRouter {
        ApplyRouter(manager: manager, bookmarks: bookmarks, sceneCapable: sceneCapable)
    }

    @Test func unresolvableVideoBookmarkFailsBeforeDispatch() async {
        let bookmark = WallpaperBookmark(label: "Missing", content: .video(bookmarkData: Data()))
        let report = await router().apply(.bookmark(bookmark), to: manager.screen)
        #expect(report == ApplyReport(outcome: .failed(.videoBookmarkFailed), exitedSpanMode: false))
        #expect(manager.calls.isEmpty)
        #expect(bookmarks.bookmarks.isEmpty)
    }

    @Test func htmlBookmarkRoutesWithoutResolving() async {
        let bookmark = WallpaperBookmark(label: "Web", content: .html(source: .inline("<p>Saved</p>"), config: .default))
        let report = await router().apply(.bookmark(bookmark), to: manager.screen)
        #expect(report == ApplyReport(outcome: .applied, exitedSpanMode: false))
        #expect(manager.calls == [.bookmark(bookmark)])
    }

    @Test func htmlPreservesConfiguration() async {
        let source = HTMLSource.inline("<p>Wallpaper</p>")
        let report = await router().apply(.html(source), to: manager.screen)
        #expect(report.outcome == .applied)
        #expect(manager.calls == [.html(source)])
        #expect(bookmarks.bookmarks.isEmpty)
    }

    @Test func schemeRoutes() async {
        let scheme = ScreenScheme(name: "Desk", configuration: manager.configuration, overlay: .default)
        let report = await router().apply(.scheme(scheme), to: manager.screen)
        #expect(report.outcome == .applied)
        #expect(manager.calls == [.scheme(scheme)])
    }

    @Test("A scheme repeating the content on screen reads as applied only once the scheme itself is committed", .timeLimit(.minutes(1)))
    func schemeWithShownContentWaitsForItsCommit() async {
        let manager = NeverConfirmingWallpaperApplying()
        var configuration = manager.configuration
        configuration.playbackSpeed = 2
        let scheme = ScreenScheme(name: "Faster", configuration: configuration, overlay: .default)
        let router = ApplyRouter(manager: manager, bookmarks: bookmarks, sceneCapable: true)
        var report: ApplyReport?
        let task = Task { report = await router.apply(.scheme(scheme), to: manager.screen) }
        await waitUntil { manager.calls == [.scheme(scheme)] }
        for _ in 0 ..< 50 {
            await Task.yield()
        }
        #expect(report == nil, "read as applied before the scheme was committed")
        manager.commit(configuration.activeWallpaper)
        await task.value
        #expect(report?.outcome == .applied)
    }

    @Test func spanExitsBeforeApplying() async {
        manager.configuration.videoDisplayMode = .spanAllDisplays
        let source = HTMLSource.inline("<p>Per display</p>")
        let report = await router().apply(.html(source), to: manager.screen)
        #expect(report == ApplyReport(outcome: .applied, exitedSpanMode: true))
        #expect(manager.calls == [.mode(.perDisplay), .html(source)])
    }

    @Test func droppedVideoSavesAndCapturesOnlyOnce() async throws {
        let folder = try fixtureFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("video.mp4")
        try Data([0]).write(to: url)
        let router = router()
        let first = await router.apply(.droppedFile(url), to: manager.screen)
        let second = await router.apply(.droppedFile(url), to: manager.screen)
        #expect(first.outcome == .applied)
        #expect(second.outcome == .applied)
        let bookmark = try #require(bookmarks.bookmarks.first)
        #expect(bookmarks.bookmarks.count == 1)
        guard case let .video(receivedURL, data, entry) = try #require(manager.calls.first) else {
            Issue.record("Expected a video dispatch")
            return
        }
        #expect(receivedURL == url)
        #expect(entry == nil)
        #expect(bookmark.content == .video(bookmarkData: data))
        #expect(manager.calls.count == 2)
        #expect(manager.covers == [bookmark.id])
    }

    @Test func droppedHTMLSavesPreservedConfig() async throws {
        let folder = try fixtureFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("index.html")
        try Data("<p>Local</p>".utf8).write(to: url)
        let config = HTMLConfig(allowJavaScript: false)
        manager.configuration.activeWallpaper = .html(source: .inline("old"), config: config)
        let report = await router().apply(.droppedFile(url), to: manager.screen)
        #expect(report.outcome == .applied)
        guard case let .html(source) = try #require(manager.calls.first) else {
            Issue.record("Expected an HTML dispatch")
            return
        }
        let bookmark = try #require(bookmarks.bookmarks.first)
        #expect(bookmark.content == .html(source: source, config: config))
        #expect(manager.covers == [bookmark.id])
    }

    @Test(.timeLimit(.minutes(1)))
    func droppedVideosQueueAllAndPlayTheFirst() async throws {
        let folder = try fixtureFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let first = folder.appendingPathComponent("first.mp4")
        let second = folder.appendingPathComponent("second.mov")
        for url in [first, second] {
            try Data([0]).write(to: url)
        }
        let intent = try #require(ApplyIntent.drop([first, second]))
        let report = await router().apply(intent, to: manager.screen)
        #expect(report.outcome == .applied)
        #expect(report.queuedVideos == 2)
        guard manager.calls.count == 2, case let .video(played, data, nil) = manager.calls[0],
              case let .queue(entries) = manager.calls[1] else {
            Issue.record("Expected the first video, then the whole drop as the queue: \(manager.calls)")
            return
        }
        #expect(played == first)
        #expect(entries.map(\.title) == ["first.mp4", "second.mov"])
        #expect(entries.first?.content == .video(bookmarkData: data), "the queue starts on the bookmark that is playing")
        #expect(bookmarks.bookmarks.map(\.content) == [.video(bookmarkData: data)], "only the played video joins the library")
    }

    @Test func dropIntentKeepsSingleFilesOnTheOldPath() {
        let video = URL(fileURLWithPath: "/fixture/clip.mp4")
        let page = URL(fileURLWithPath: "/fixture/index.html")
        guard case let .droppedFile(single)? = ApplyIntent.drop([video]),
              case let .droppedFile(mixed)? = ApplyIntent.drop([page, video]) else {
            Issue.record("One video, or a page with one video, must stay a single-file drop")
            return
        }
        #expect(single == video)
        #expect(mixed == page)
        #expect(ApplyIntent.drop([]) == nil)
    }

    @Test("While wallpapers are off an apply reads as saved, not applied")
    func appliedWhileOffSaysSaved() {
        #expect(ApplyOutcome.appliedText(on: "Studio", wallpapersOn: false)
            == String(localized: "Saved to \("Studio"). Wallpapers are turned off.", bundle: .appLanguage))
        #expect(ApplyOutcome.appliedText(on: "Studio") == String(localized: "Applied to \("Studio")", bundle: .appLanguage))
    }

    @Test func missingVideoBookmarkFails() async throws {
        let folder = try fixtureFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("missing/video.mp4")
        let report = await router().apply(.droppedFile(url), to: manager.screen)
        #expect(report.outcome == .failed(.sourceMissing))
        #expect(manager.calls.isEmpty)
        #expect(bookmarks.bookmarks.isEmpty)
    }

    @Test func deletedLibraryVideoSaysMissing() async throws {
        let folder = try fixtureFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("video.mp4")
        try Data([0]).write(to: url)
        let data = try #require(ResourceUtilities.createVideoBookmark(for: url))
        try FileManager.default.removeItem(at: url)
        let bookmark = WallpaperBookmark(label: "Deleted", content: .video(bookmarkData: data))
        let report = await router().apply(.bookmark(bookmark), to: manager.screen)
        #expect(report.outcome == .failed(.sourceMissing), "resolving the deleted file's bookmark: \(resolutionError(data))")
        #expect(manager.calls.isEmpty)
    }

    @Test func appliedWebAddressIsSavedOnce() async throws {
        let url = try #require(URL(string: "https://example.com/wallpaper"))
        let router = router()
        #expect(await router.apply(.html(.url(url)), to: manager.screen).outcome == .applied)
        #expect(await router.apply(.html(.url(url)), to: manager.screen).outcome == .applied)
        let bookmark = try #require(bookmarks.bookmarks.first, "the applied web address was not saved to the library")
        #expect(bookmarks.bookmarks.count == 1)
        #expect(bookmark.label == "example.com")
        #expect(manager.covers == [bookmark.id])
    }

    @Test func confirmationOutlastsPreparation() {
        #expect(ApplyRouter.defaultConfirmationTimeout > ScreenManager.longPreparationTimeout)
    }

    @Test(.timeLimit(.minutes(1)))
    func preparationFailureEndsTheWaitWithItsReason() async {
        let manager = NeverConfirmingWallpaperApplying()
        let router = ApplyRouter(manager: manager, bookmarks: bookmarks, sceneCapable: true, confirmationTimeout: .seconds(2))
        let task = Task { await router.apply(.html(.inline("slow")), to: manager.screen) }
        await waitUntil { !manager.calls.isEmpty }
        manager.failPreparation(reason: "Fixture", on: manager.screen)
        #expect(await task.value.outcome == .prepareFailed(reason: "Fixture", attemptID: nil))
    }

    @Test(.timeLimit(.minutes(1)))
    func anotherDisplaysFailureKeepsWaiting() async {
        let manager = NeverConfirmingWallpaperApplying()
        let router = ApplyRouter(
            manager: manager, bookmarks: bookmarks, sceneCapable: true, confirmationTimeout: .milliseconds(300)
        )
        let task = Task { await router.apply(.html(.inline("slow")), to: manager.screen) }
        await waitUntil { !manager.calls.isEmpty }
        manager.failPreparation(reason: "Fixture", on: manager.secondScreen)
        #expect(await task.value.outcome == .failed(.applyNotConfirmed))
    }

    @Test(.timeLimit(.minutes(1)))
    func earlierPreparationFailureKeepsWaiting() async {
        let manager = NeverConfirmingWallpaperApplying()
        let router = ApplyRouter(
            manager: manager, bookmarks: bookmarks, sceneCapable: true, confirmationTimeout: .milliseconds(300)
        )
        let task = Task { await router.apply(.html(.inline("slow")), to: manager.screen) }
        await waitUntil { !manager.calls.isEmpty }
        manager.failPreparation(reason: "Earlier", on: manager.screen, generation: manager.generation(of: manager.screen) - 1)
        #expect(await task.value.outcome == .failed(.applyNotConfirmed))
    }

    @Test("The screen manager claims a failure only for the preparation it is running now")
    func screenManagerMatchesOnlyItsCurrentPreparation() {
        let screen = Screen(nsScreen: ApplyTestNSScreen())
        let manager = ScreenManager(startupOptions: ScreenManagerStartupOptions(
            restoreSavedWallpapers: false, startAutomation: false,
            powerMonitor: FakePowerMonitor(), fullScreenDetector: FakeFullScreenDetector(),
            playableVideoLoader: FakePlayableVideoLoader(), displayRegistry: FakeDisplayRegistry(screens: [screen]),
            featureCatalog: FeatureCatalog(capabilities: .lite), originReconciler: PreservingOriginReconciler()
        ))
        defer { manager.tearDownForTermination() }
        let earlier = manager.bumpTransition(for: screen.id)
        let current = manager.bumpTransition(for: screen.id)
        let byGeneration = [current, earlier, nil].map {
            manager.isCurrentPreparation(generation: $0, attemptID: nil, on: screen)
        }
        let attempt = manager.wallpaperLoads.begin(for: screen, title: "Scene")
        let byAttempt = [attempt, UUID()].map {
            manager.isCurrentPreparation(generation: current, attemptID: $0, on: screen)
        }
        // Compared as plain Bools: a failure that describes the manager or screen crashes the test host.
        #expect(byGeneration == [true, false, false])
        #expect(byAttempt == [true, false])
    }

    @Test(.timeLimit(.minutes(1)))
    func cancellingDropsTheCandidateAndRestoresSpan() async {
        let manager = NeverConfirmingWallpaperApplying()
        manager.configuration.videoDisplayMode = .spanAllDisplays
        let router = ApplyRouter(manager: manager, bookmarks: bookmarks, sceneCapable: true, confirmationTimeout: .seconds(2))
        let cancellation = ApplyCancellation()
        let task = Task { await router.apply(.html(.inline("slow")), to: manager.screen, cancellation: cancellation) }
        await waitUntil { manager.calls.contains(.html(.inline("slow"))) }
        cancellation.cancel()
        #expect(await task.value == ApplyReport(outcome: .failed(.applyNotConfirmed), exitedSpanMode: false, cancelled: true))
        #expect(manager.cancelledPreparations == [manager.screen.id])
        #expect(manager.configuration.videoDisplayMode == .spanAllDisplays)
    }

    @Test func unsupportedFileFails() async {
        let report = await router().apply(.droppedFile(URL(fileURLWithPath: "/fixture/file.txt")), to: manager.screen)
        #expect(report.outcome == .failed(.unrecognizedDrop))
        #expect(manager.calls.isEmpty)
    }

    @Test func sceneLibraryStartsTheBatchImport() async throws {
        let folder = try fixtureFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let project = folder.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: project.appendingPathComponent("project.json"))
        let imports = LibraryImportLog()
        let router = ApplyRouter(
            manager: manager, bookmarks: bookmarks, sceneCapable: true, importLibrary: { imports.batches.append($0) }
        )
        let report = await router.apply(.droppedFile(folder), to: manager.screen)
        #expect(report.outcome == .importingLibrary)
        #expect(imports.batches == [[folder]])
        #expect(manager.calls.isEmpty, "a library is imported, not applied to the display it was dropped on")
    }

    @Test func sceneWithoutCapabilityFails() async throws {
        let folder = try fixtureFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        try Data("{}".utf8).write(to: folder.appendingPathComponent("project.json"))
        let report = await router(sceneCapable: false).apply(.droppedFile(folder), to: manager.screen)
        #expect(report.outcome == .failed(.sceneUnsupportedInBuild))
        #expect(manager.calls.isEmpty)
        #expect(bookmarks.bookmarks.isEmpty)
    }

    #if !LITE_BUILD
    @Test func sceneRoutes() async {
        let descriptor = SceneDescriptor(workshopID: "42", cacheRelativePath: "42", entryFile: "scene.json", capabilityTier: .imageOnly)
        let report = await router().apply(.scene(descriptor: descriptor, origin: manager.origin), to: manager.screen)
        #expect(report.outcome == .applied)
        #expect(manager.calls == [.scene(descriptor, manager.origin)])
    }

    @Test("A scene with the same identity waits for its own commit")
    func sameSceneIdentityWaitsForCommit() async throws {
        let manager = NeverConfirmingWallpaperApplying()
        let original = try #require(manager.projectContent.sceneDescriptor)
        let updated = original.withPropertyOverrides(["gain": .number(0.75)])
        manager.configuration.activeWallpaper = .scene(original)
        let router = ApplyRouter(manager: manager, bookmarks: bookmarks, sceneCapable: true)
        var report: ApplyReport?
        let task = Task { report = await router.apply(.scene(descriptor: updated, origin: nil), to: manager.screen) }
        await waitUntil { !manager.calls.isEmpty }
        for _ in 0 ..< 50 {
            await Task.yield()
        }
        #expect(report == nil)
        manager.commit(.scene(updated))
        await task.value
        #expect(report?.outcome == .applied)
    }

    @Test("Cancelling an older scene request does not cancel its replacement")
    func sceneCancellationOwnsOnlyItsWork() async throws {
        let manager = NeverConfirmingWallpaperApplying()
        let descriptor = try #require(manager.projectContent.sceneDescriptor)
        let cancellation = ApplyCancellation()
        let router = ApplyRouter(manager: manager, bookmarks: bookmarks, sceneCapable: true)
        let first = Task { await router.apply(.scene(descriptor: descriptor, origin: nil), to: manager.screen, cancellation: cancellation) }
        await waitUntil { manager.sceneTasks.count == 1 }
        let updated = descriptor.withPropertyOverrides(["gain": .number(0.75)])
        let second = Task { await router.apply(.scene(descriptor: updated, origin: nil), to: manager.screen) }
        await waitUntil { manager.sceneTasks.count == 2 }
        cancellation.cancel()
        #expect(await first.value.cancelled)
        #expect(manager.sceneTasks[0].isCancelled)
        #expect(!manager.sceneTasks[1].isCancelled)
        #expect(manager.cancelledPreparations.isEmpty)
        manager.commit(.scene(updated))
        #expect(await second.value.outcome == .applied)
    }

    @Test("A scene deadline cancels its preparing candidate")
    func sceneDeadlineRetiresItsWork() async throws {
        let manager = NeverConfirmingWallpaperApplying()
        let router = ApplyRouter(manager: manager, bookmarks: bookmarks, sceneCapable: true, confirmationTimeout: .milliseconds(30))
        let descriptor = try #require(manager.projectContent.sceneDescriptor)
        let report = await router.apply(.scene(descriptor: descriptor, origin: nil), to: manager.screen)
        #expect(report.outcome == .failed(.applyNotConfirmed))
        #expect(manager.sceneTasks.first?.isCancelled == true)
        #expect(manager.cancelledPreparations.isEmpty)
    }

    @Test("A timed-out scene never installs when its cancellation-ignoring preparation finishes later")
    func lateScenePreparationCannotInstallAfterDeadline() async throws {
        let manager = PreparingSceneWallpaperApplying()
        defer { manager.runtimeManager.tearDownForTermination() }
        let router = ApplyRouter(manager: manager, bookmarks: bookmarks, sceneCapable: true, confirmationTimeout: .milliseconds(30))
        let descriptor = try #require(manager.projectContent.sceneDescriptor)
        let report = await router.apply(.scene(descriptor: descriptor, origin: nil), to: manager.screen)
        #expect(report.outcome == .failed(.applyNotConfirmed))
        #expect(manager.candidate.prepareCallCount == 1)
        manager.candidate.completePreparation(with: .ready)
        await waitUntil { manager.candidate.cleanupCount == 1 }
        for _ in 0 ..< 50 {
            await Task.yield()
        }
        #expect(manager.screen.runtimeSession == nil)
        #expect(manager.commits == 0)
    }

    @Test("An already installed scene is a successful no-op without a configuration write")
    func installedSceneIsNoOp() async {
        let fixture = ApplySceneFixture(id: 0xEDA0_0002)
        defer { fixture.close() }
        let session = ApplySceneSession()
        fixture.screen.installRuntimeSession(session)
        let revision = fixture.manager.configurationRevision(for: fixture.screen)
        let router = ApplyRouter(manager: fixture.manager, bookmarks: bookmarks, sceneCapable: true)
        let report = await router.apply(.scene(descriptor: fixture.descriptor, origin: nil), to: fixture.screen)
        #expect(report.outcome == .applied)
        #expect(fixture.screen.runtimeSession === session)
        #expect(fixture.manager.configurationRevision(for: fixture.screen) == revision)
    }

    @Test("A scene selected while wallpapers are off succeeds as a saved configuration")
    func sceneWhileOffIsSaved() async {
        let fixture = ApplySceneFixture(id: 0xEDA0_0003)
        defer { fixture.close() }
        fixture.manager.wallpapersGloballyEnabled = false
        let updated = fixture.descriptor.withPropertyOverrides(["gain": .number(0.75)])
        let router = ApplyRouter(manager: fixture.manager, bookmarks: bookmarks, sceneCapable: true)
        let report = await router.apply(.scene(descriptor: updated, origin: nil), to: fixture.screen)
        #expect(report.outcome == .applied)
        #expect(fixture.manager.getConfiguration(for: fixture.screen)?.activeWallpaper == .scene(updated))
        #expect(fixture.screen.runtimeSession == nil)
        #expect(fixture.manager.wallpaperLoads.attempt(for: fixture.screen) == nil)
    }

    @Test("A replaced display cannot receive a scene selection")
    func staleSceneTargetIsRejected() async {
        let fixture = ApplySceneFixture(id: 0xEDA0_0004)
        defer { fixture.close() }
        let revision = fixture.manager.configurationRevision(for: fixture.screen)
        fixture.manager.screens = []
        let router = ApplyRouter(manager: fixture.manager, bookmarks: bookmarks, sceneCapable: true)
        let report = await router.apply(.scene(descriptor: fixture.descriptor, origin: nil), to: fixture.screen)
        #expect(report.outcome == .failed(.applyNotConfirmed))
        #expect(fixture.manager.configurationRevision(for: fixture.screen) == revision)
    }

    @Test("Reapplying a stored scene with an unavailable source must not report success", arguments: ["scene", "bookmark", "workshop"])
    func unavailableStoredSceneDoesNotApply(route: String) async throws {
        let fixture = ApplySceneFixture(id: 0xEDA0_0001)
        defer { fixture.close() }
        let (manager, screen, descriptor) = (fixture.manager, fixture.screen, fixture.descriptor)
        let router = ApplyRouter(manager: manager, bookmarks: bookmarks, sceneCapable: true, confirmationTimeout: .seconds(1))
        let intent: ApplyIntent
        switch route {
        case "bookmark":
            intent = .bookmark(WallpaperBookmark(label: "Unavailable scene", content: .scene(descriptor)))
        case "workshop":
            let origin = WPEOrigin(
                workshopID: descriptor.workshopID, title: "Unavailable scene", originalType: .scene,
                sourceFolderBookmark: Data(), cacheRelativePath: nil, previewFileName: nil
            )
            var configuration = try #require(manager.getConfiguration(for: screen))
            configuration.wpeOrigin = origin
            manager.saveConfiguration(configuration)
            intent = .installedWorkshop(WPEHistoryEntry(origin: origin, importedAt: Date()))
        default:
            intent = .scene(descriptor: descriptor, origin: nil)
        }
        let report = await router.apply(intent, to: screen)
        #expect(report.outcome != .applied)
        #expect(screen.runtimeSession == nil)
        #expect(manager.wallpaperLoads.attempt(for: screen)?.phase == .failed)
    }

    @Test func projectRoutes() async {
        let url = URL(fileURLWithPath: "/fixture/project")
        let report = await router().apply(.wpeProjectFolder(url), to: manager.screen)
        #expect(report.outcome == .applied)
        #expect(manager.calls == [.project(url)])
    }

    @Test func droppedProjectRoutes() async throws {
        let folder = try fixtureFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        try Data("{}".utf8).write(to: folder.appendingPathComponent("project.json"))
        let report = await router().apply(.droppedFile(folder), to: manager.screen)
        #expect(report.outcome == .applied)
        #expect(manager.calls == [.project(folder)])
        #expect(bookmarks.bookmarks.isEmpty)
    }

    @Test func workshopRoutes() async {
        let entry = WPEHistoryEntry(origin: manager.origin, importedAt: Date())
        let report = await router().apply(.installedWorkshop(entry), to: manager.screen)
        #expect(report.outcome == .applied)
        #expect(manager.calls == [.workshop(entry)])
    }

    @Test("An installed Workshop item or a project folder picked by the user restarts the rotation countdown")
    func workshopAndProjectRestartRotation() async {
        let entry = WPEHistoryEntry(origin: manager.origin, importedAt: Date())
        _ = await router().apply(.installedWorkshop(entry), to: manager.screen)
        _ = await router().apply(.wpeProjectFolder(URL(fileURLWithPath: "/fixture/project")), to: manager.screen)
        #expect(manager.rotationResets == [manager.screen.id, manager.screen.id])
    }

    @Test("A scheme captured from a span group lands on its display alone")
    func schemeLeavesSpanGroup() throws {
        let fixture = ApplySceneFixture(id: 0xEDA0_0005)
        defer { fixture.close() }
        fixture.manager.wallpapersGloballyEnabled = false
        var scheme = try ScreenScheme(
            name: "Span", configuration: #require(fixture.manager.getConfiguration(for: fixture.screen)), overlay: .default
        )
        scheme.configuration.sceneSpanGroupID = UUID()
        let revision = fixture.manager.configurationRevision(for: fixture.screen)
        fixture.manager.applyScheme(scheme, to: fixture.screen)
        #expect(fixture.manager.configurationRevision(for: fixture.screen) != revision)
        #expect(fixture.manager.getConfiguration(for: fixture.screen)?.sceneSpanGroupID == nil)
    }

    @Test func projectOutcomesMap() async {
        let outcomes: [(ScreenManager.WPEProjectApplyOutcome, ApplyOutcome)] = [
            (.registeredPreset(name: "Evening"), .registeredPreset(name: "Evening")),
            (.unsupported(origin: manager.origin), .failed(.sceneProjectUnsupported)),
            (.rejected(reason: "Missing assets"), .failed(.sceneImportRejected(reason: "Missing assets"))),
        ]
        for (result, expected) in outcomes {
            manager.projectOutcome = result
            let report = await router().apply(.wpeProjectFolder(URL(fileURLWithPath: "/fixture/project")), to: manager.screen)
            #expect(report.outcome == expected)
        }
    }
    #endif

    @Test func awaitAppliedMatchesNotification() async {
        let router = router()
        let content = WallpaperContent.video(bookmarkData: Data([42]))
        let task = Task { await router.awaitApplied(matching: content, on: manager.screen.id, timeout: .seconds(1)) }
        await waitUntil { manager.lookupCount > 0 }
        manager.commit(content)
        #expect(await task.value)
    }

    @Test func awaitAppliedTimesOutIgnoringOtherScreens() async {
        let router = router()
        let content = WallpaperContent.video(bookmarkData: Data([42]))
        let task = Task { await router.awaitApplied(matching: content, on: manager.screen.id, timeout: .milliseconds(30)) }
        await waitUntil { manager.lookupCount > 0 }
        manager.configuration.activeWallpaper = content
        manager.notify(screenID: manager.screen.id &+ 1)
        #expect(await task.value == false)
    }

    @Test func awaitAppliedReturnsImmediatelyForCurrentContent() async {
        #expect(await router().awaitApplied(matching: manager.configuration.activeWallpaper, on: manager.screen.id, timeout: .zero))
    }

    @Test func awaitAppliedStopsWhenScreenDisappears() async {
        let router = router()
        let task = Task { await router.awaitApplied(matching: .video(bookmarkData: Data([42])), on: manager.screen.id, timeout: .seconds(1)) }
        await waitUntil { manager.lookupCount > 0 }
        manager.screenAvailable = false
        manager.notify(screenID: manager.screen.id)
        #expect(await task.value == false)
    }

    @Test func newerContentPreventsCoverCapture() async throws {
        let manager = NeverConfirmingWallpaperApplying()
        let router = ApplyRouter(manager: manager, bookmarks: bookmarks, sceneCapable: true)
        let folder = try fixtureFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("video.mp4")
        try Data([0]).write(to: url)
        let task = Task { await router.apply(.droppedFile(url), to: manager.screen) }
        await waitUntil { !manager.calls.isEmpty }
        #expect(bookmarks.bookmarks.isEmpty)
        manager.commit(.html(source: .inline("replacement"), config: .default))
        #expect(await task.value == ApplyReport(outcome: .failed(.applyNotConfirmed), exitedSpanMode: false))
        #expect(manager.covers.isEmpty)
        #expect(bookmarks.bookmarks.isEmpty)
    }

    @Test func unconfirmedDropRestoresSpanWithoutSaving() async throws {
        let manager = NeverConfirmingWallpaperApplying()
        manager.configuration.videoDisplayMode = .spanAllDisplays
        let router = ApplyRouter(
            manager: manager, bookmarks: bookmarks, sceneCapable: true, confirmationTimeout: .milliseconds(200)
        )
        let folder = try fixtureFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("video.mp4")
        try Data([0]).write(to: url)

        let report = await router.apply(.droppedFile(url), to: manager.screen)

        #expect(report == ApplyReport(outcome: .failed(.applyNotConfirmed), exitedSpanMode: false))
        #expect(bookmarks.bookmarks.isEmpty)
        #expect(manager.covers.isEmpty)
        #expect(manager.configuration.videoDisplayMode == .spanAllDisplays)
        #expect(manager.calls.first == .mode(.perDisplay))
        #expect(manager.calls.last == .mode(.spanAllDisplays))
    }

    @Test func confirmedDropExitsSpanAndSaves() async throws {
        manager.configuration.videoDisplayMode = .spanAllDisplays
        let folder = try fixtureFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("video.mp4")
        try Data([0]).write(to: url)

        let report = await router().apply(.droppedFile(url), to: manager.screen)

        #expect(report == ApplyReport(outcome: .applied, exitedSpanMode: true))
        #expect(bookmarks.bookmarks.count == 1)
        #expect(manager.configuration.videoDisplayMode == .perDisplay)
        #expect(manager.covers == bookmarks.bookmarks.map(\.id))
    }

    @Test func slowConfirmationDoesNotBlockAnotherDisplay() async {
        let manager = NeverConfirmingWallpaperApplying()
        let router = ApplyRouter(manager: manager, bookmarks: bookmarks, sceneCapable: true)
        let slowContent = WallpaperContent.html(source: .inline("slow"), config: .default)
        let fastContent = WallpaperContent.html(source: .inline("fast"), config: .default)
        var slowReport: ApplyReport?
        var fastReport: ApplyReport?
        let slow = Task {
            slowReport = await router.apply(.html(.inline("slow")), to: manager.screen)
        }
        await waitUntil { manager.calls.count == 1 }
        let fast = Task {
            fastReport = await router.apply(.html(.inline("fast")), to: manager.secondScreen)
        }
        await waitUntil { manager.calls.count == 2 }
        manager.commit(fastContent, on: manager.secondScreen)
        await waitUntil { fastReport != nil }
        #expect(fastReport?.outcome == .applied)
        #expect(slowReport == nil)
        manager.commit(slowContent)
        await slow.value
        await fast.value
        #expect(slowReport?.outcome == .applied)
    }

    private func fixtureFolder() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("ApplyRouterTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    private func waitUntil(_ condition: () -> Bool) async {
        let deadline = ContinuousClock.now + .seconds(1)
        while !condition(), ContinuousClock.now < deadline {
            await Task.yield()
        }
        #expect(condition())
    }

    private func resolutionError(_ data: Data) -> String {
        do {
            _ = try SecurityScopedBookmarkResolver.shared.resolveData(data)
            return "resolved"
        } catch {
            let error = error as NSError
            return "\(error.domain) \(error.code)"
        }
    }
}

#if !LITE_BUILD
@MainActor
private final class ApplySceneFixture {
    let screen: Screen
    let manager: ScreenManager
    let descriptor = SceneDescriptor(
        workshopID: "missing-apply-fixture", cacheRelativePath: "missing-apply-fixture", entryFile: "scene.json", capabilityTier: .imageOnly
    )

    init(id: UInt32) {
        let nsScreen = ApplyTestNSScreen()
        nsScreen.displayID = id
        screen = Screen(nsScreen: nsScreen)
        manager = ScreenManager(startupOptions: ScreenManagerStartupOptions(
            restoreSavedWallpapers: false, startAutomation: false,
            powerMonitor: FakePowerMonitor(), fullScreenDetector: FakeFullScreenDetector(),
            playableVideoLoader: FakePlayableVideoLoader(), displayRegistry: FakeDisplayRegistry(screens: [screen]),
            featureCatalog: FeatureCatalog(capabilities: .pro), originReconciler: PreservingOriginReconciler()
        ))
        manager.wallpapersGloballyEnabled = true
        var configuration = ScreenConfiguration(screenID: screen.id, wallpaper: .scene(descriptor))
        configuration.displayFingerprint = screen.displayFingerprint
        manager.saveConfiguration(configuration)
    }

    func close() {
        manager.tearDownForTermination()
        manager.configurationStore.remove(for: screen.id)
    }
}

@MainActor
private final class ApplySceneSession: WallpaperRuntimeSession {
    let wallpaperType: WallpaperType = .scene
    let summary: WallpaperSessionSummary = .notConfigured
    let videoPlayer: WallpaperVideoPlayer? = nil
    let wallpaperWindow: NSWindow? = nil
    func show() {}
    func applyPerformanceProfile(_: WallpaperPerformanceProfile) {}
    func updateFrame(to _: CGRect) {}
    var result: WallpaperPreparationResult? = .ready
    private var continuation: CheckedContinuation<WallpaperPreparationResult, Never>?
    private(set) var prepareCallCount = 0
    private(set) var cleanupCount = 0
    func cleanup() {
        cleanupCount += 1
    }

    func prepareForDisplay(timeout _: Duration) async -> WallpaperPreparationResult {
        prepareCallCount += 1
        if let result {
            return result
        }
        return await withCheckedContinuation { continuation = $0 }
    }

    func completePreparation(with result: WallpaperPreparationResult) {
        self.result = result
        continuation?.resume(returning: result)
        continuation = nil
    }
}

@MainActor
private final class PreparingSceneWallpaperApplying: RecordingWallpaperApplying {
    let candidate: ApplySceneSession = {
        let session = ApplySceneSession()
        session.result = nil
        return session
    }()

    private(set) var commits = 0
    lazy var runtimeManager = ScreenManager(startupOptions: ScreenManagerStartupOptions(
        restoreSavedWallpapers: false, startAutomation: false,
        powerMonitor: FakePowerMonitor(), fullScreenDetector: FakeFullScreenDetector(),
        playableVideoLoader: FakePlayableVideoLoader(), displayRegistry: FakeDisplayRegistry(screens: [screen]),
        featureCatalog: FeatureCatalog(capabilities: .lite), originReconciler: PreservingOriginReconciler()
    ))

    override func beginSceneApply(
        descriptor: SceneDescriptor, origin _: WPEOrigin?, for screen: Screen,
        completion: @escaping @MainActor (ApplyOutcome) -> Void
    ) -> RuntimePreparationWork? {
        runtimeManager.wallpapersGloballyEnabled = true
        let generation = runtimeManager.beginExplicitWallpaperSelection(for: screen)
        return runtimeManager.beginPreparedAmbientSession(
            candidate, for: screen, replacing: nil, generation: generation,
            proposedConfiguration: ScreenConfiguration(screenID: screen.id, wallpaper: .scene(descriptor)),
            expectedConfigurationRevision: runtimeManager.configurationRevision(for: screen), timeout: .seconds(3),
            beforeCommit: { self.commits += 1; return true }, afterCommit: {},
            completion: { result, _ in completion(result == .ready ? .applied : .failed(.applyNotConfirmed)) }
        )
    }
}
#endif

@MainActor
private final class LibraryImportLog {
    var batches: [[URL]] = []
}

@MainActor
private final class ApplyBookmarkPersistence: BookmarkPersisting {
    func load() -> [WallpaperBookmark] {
        []
    }

    func save(_: [WallpaperBookmark]) {}
}

private final class ApplyTestNSScreen: NSScreen {
    var displayID: UInt32 = 1

    override var frame: NSRect {
        NSRect(x: 0, y: 0, width: 800, height: 600)
    }

    override var deviceDescription: [NSDeviceDescriptionKey: Any] {
        [NSDeviceDescriptionKey("NSScreenNumber"): displayID]
    }

    override var localizedName: String {
        "Apply Router Test"
    }
}

@MainActor
private class RecordingWallpaperApplying: WallpaperApplying {
    enum Call: Equatable {
        case bookmark(WallpaperBookmark)
        case video(URL, Data, String?)
        case html(HTMLSource)
        case scheme(ScreenScheme)
        case mode(VideoDisplayMode)
        case queue([WallpaperQueueEntry])
        #if !LITE_BUILD
        case scene(SceneDescriptor, WPEOrigin?)
        case project(URL)
        case workshop(WPEHistoryEntry)
        #endif
    }

    let screen = Screen(nsScreen: ApplyTestNSScreen())
    let secondScreen: Screen = {
        let nsScreen = ApplyTestNSScreen()
        nsScreen.displayID = 2
        return Screen(nsScreen: nsScreen)
    }()

    private lazy var configurations = [
        screen.id: ScreenConfiguration(screenID: screen.id, wallpaper: .video(bookmarkData: Data([0]))),
        secondScreen.id: ScreenConfiguration(screenID: secondScreen.id, wallpaper: .video(bookmarkData: Data([0]))),
    ]
    var configuration: ScreenConfiguration {
        get { configurations[screen.id]! }
        set { configurations[screen.id] = newValue }
    }

    var calls: [Call] = []
    var covers: [UUID] = []
    var cancelledPreparations: [CGDirectDisplayID] = []
    var screenAvailable = true
    var lookupCount = 0
    /// Bumped by every call on a display, the way a real selection bumps its transition.
    private var generations: [CGDirectDisplayID: Int] = [:]
    private var revisions: [CGDirectDisplayID: UInt64] = [:]

    var screens: [Screen] {
        screenAvailable ? [screen, secondScreen] : []
    }

    func screen(withID id: CGDirectDisplayID) -> Screen? {
        lookupCount += 1
        guard screenAvailable else { return nil }
        return [screen, secondScreen].first { $0.id == id }
    }

    func getConfiguration(for screen: Screen) -> ScreenConfiguration? {
        configurations[screen.id]
    }

    func applyBookmark(_ bookmark: WallpaperBookmark, to screen: Screen) {
        record(.bookmark(bookmark), for: screen)
        didDispatch(bookmark.content, origin: bookmark.wpeOrigin, for: screen)
    }

    func setVideo(url: URL, bookmarkData: Data, packageEntryName: String?, for screen: Screen) {
        record(.video(url, bookmarkData, packageEntryName), for: screen)
        didDispatch(.video(bookmarkData: bookmarkData, packageEntryName: packageEntryName), for: screen)
    }

    func setHTMLWallpaperPreservingConfig(source: HTMLSource, for screen: Screen) {
        record(.html(source), for: screen)
        didDispatch(.html(source: source, config: configurations[screen.id]?.htmlConfig ?? .default), for: screen)
    }

    func applyScheme(_ scheme: ScreenScheme, to screen: Screen) {
        record(.scheme(scheme), for: screen)
        didDispatch(scheme.configuration.activeWallpaper, origin: scheme.configuration.wpeOrigin, for: screen)
    }

    func updateVideoDisplayMode(_ mode: VideoDisplayMode, for screen: Screen) {
        record(.mode(mode), for: screen)
        configurations[screen.id]?.videoDisplayMode = mode
    }

    func captureCover(forBookmark id: UUID, from screen: Screen) {
        #expect(screen === self.screen)
        covers.append(id)
    }

    func replaceWallpaperQueue(_ entries: [WallpaperQueueEntry], for screen: Screen) {
        record(.queue(entries), for: screen)
    }

    func cancelPreparation(for screen: Screen) {
        cancelledPreparations.append(screen.id)
    }

    func isCurrentPreparation(generation: Int?, attemptID _: UUID?, on screen: Screen) -> Bool {
        generation == generations[screen.id]
    }

    func generation(of screen: Screen) -> Int {
        generations[screen.id] ?? 0
    }

    #if !LITE_BUILD
    let origin = WPEOrigin(workshopID: "42", title: "Scene", originalType: .scene, sourceFolderBookmark: Data(), cacheRelativePath: nil, previewFileName: nil)
    var projectOutcome: ScreenManager.WPEProjectApplyOutcome?
    let projectContent = WallpaperContent.scene(SceneDescriptor(
        workshopID: "42", cacheRelativePath: "42", entryFile: "scene.json", capabilityTier: .imageOnly
    ))

    var sceneTasks: [Task<Void, Never>] = []
    private var sceneCompletions: [CGDirectDisplayID: @MainActor (ApplyOutcome) -> Void] = [:]

    func beginSceneApply(
        descriptor: SceneDescriptor, origin: WPEOrigin?, for screen: Screen,
        completion: @escaping @MainActor (ApplyOutcome) -> Void
    ) -> RuntimePreparationWork? {
        record(.scene(descriptor, origin), for: screen)
        sceneCompletions[screen.id] = completion
        let work = RuntimePreparationWork()
        let task = Task { do { try await Task.sleep(for: .seconds(60)) } catch {} }
        work.task = task
        sceneTasks.append(task)
        didDispatch(.scene(descriptor), origin: origin, for: screen)
        return work
    }

    func importWallpaperEngineProject(at url: URL, for screen: Screen) async -> ScreenManager.WPEProjectApplyOutcome {
        record(.project(url), for: screen)
        let outcome = projectOutcome ?? .applied(origin: origin)
        if case let .applied(origin) = outcome {
            didDispatch(projectContent, origin: origin, for: screen)
        }
        return outcome
    }

    func activateWPEHistoryEntry(_ entry: WPEHistoryEntry, for screen: Screen) async -> WallpaperFailureSnapshot? {
        record(.workshop(entry), for: screen)
        didDispatch(projectContent, origin: entry.origin, for: screen)
        return nil
    }

    var rotationResets: [CGDirectDisplayID] = []

    func resetRotationClock(for screen: Screen) {
        rotationResets.append(screen.id)
    }
    #endif

    func didDispatch(_: WallpaperContent, origin _: WPEOrigin? = nil, for _: Screen) {}

    func commit(_ content: WallpaperContent, origin: WPEOrigin? = nil, on target: Screen? = nil) {
        let target = target ?? screen
        configurations[target.id]?.activeWallpaper = content
        configurations[target.id]?.wpeOrigin = origin
        revisions[target.id, default: 0] += 1
        notify(screenID: target.id)
        #if !LITE_BUILD
        sceneCompletions.removeValue(forKey: target.id)?(.applied)
        #endif
    }

    func configurationRevision(for screen: Screen) -> UInt64 {
        revisions[screen.id] ?? 0
    }

    func notify(screenID: CGDirectDisplayID) {
        NotificationCenter.default.post(name: .wallpaperConfigurationDidChange, object: nil, userInfo: ["screenID": screenID])
    }

    func failPreparation(reason: String, on target: Screen, generation: Int? = nil) {
        NotificationCenter.default.post(name: .wallpaperPreparationDidFail, object: nil, userInfo: [
            "screenID": target.id, "reason": reason, "generation": generation ?? self.generation(of: target),
        ])
    }

    private func record(_ call: Call, for screen: Screen) {
        #expect(screen === self.screen || screen === secondScreen)
        calls.append(call)
        generations[screen.id, default: 0] += 1
    }
}

@MainActor
private final class NeverConfirmingWallpaperApplying: RecordingWallpaperApplying {}

@MainActor
private final class ConfirmingWallpaperApplying: RecordingWallpaperApplying {
    override func didDispatch(_ content: WallpaperContent, origin: WPEOrigin? = nil, for screen: Screen) {
        Task {
            await Task.yield()
            commit(content, origin: origin, on: screen)
        }
    }
}

@MainActor
@Suite("Edit Desk apply queue")
struct EditDeskApplyQueueTests {
    @MainActor
    private final class Log {
        var entries: [String] = []
    }

    @MainActor
    private final class Gate {
        private var continuation: CheckedContinuation<Void, Never>?
        private var opened = false

        func wait() async {
            guard !opened else { return }
            await withCheckedContinuation { continuation = $0 }
        }

        func open() {
            opened = true
            continuation?.resume()
            continuation = nil
        }
    }

    @MainActor
    private final class TokenBox {
        var token: ApplyCancellation?
    }

    /// Lets queued work run up to its next suspension without tying the test to wall-clock time.
    private func settle(_ isDone: () -> Bool) async {
        for _ in 0 ..< 200 where !isDone() {
            await Task.yield()
        }
    }

    @Test("A slow apply on one display does not hold up another display's")
    func doesNotSerializeAcrossDisplays() async {
        let queue = HomePage.ApplyQueue()
        let gate = Gate()
        let log = Log()
        queue.run(for: 1) { _ in
            await gate.wait()
            log.entries.append("slow")
        }
        queue.run(for: 2) { _ in log.entries.append("fast") }
        await settle { log.entries.contains("fast") }
        #expect(log.entries == ["fast"], "display 2 waited behind the apply still running on display 1")
        gate.open()
        await settle { queue.isIdle }
        #expect(log.entries == ["fast", "slow"])
        #expect(queue.isIdle)
    }

    @Test("A newer request for the same display cancels the one in flight")
    func newestWinsPerDisplay() async {
        let queue = HomePage.ApplyQueue()
        let gate = Gate()
        let log = Log()
        queue.run(for: 1) { _ in
            await gate.wait()
            log.entries.append(Task.isCancelled ? "superseded" : "first")
        }
        queue.run(for: 1) { _ in log.entries.append("second") }
        await settle { log.entries.contains("second") }
        #expect(log.entries == ["second"], "the newer request waited behind the one it supersedes")
        gate.open()
        // The superseded task still runs to completion; it just knows it lost.
        await settle { log.entries.count == 2 }
        #expect(log.entries == ["second", "superseded"])
        #expect(queue.isIdle)
    }

    @Test("A newer request for a display cancels the older one's token; another display's request does not")
    func newerRequestCancelsTheOlderToken() async {
        let queue = HomePage.ApplyQueue()
        let gate = Gate()
        let box = TokenBox()
        queue.run(for: 1) { cancellation in
            box.token = cancellation
            await gate.wait()
        }
        await settle { box.token != nil }
        queue.run(for: 2) { _ in }
        #expect(box.token?.isCancelled == false, "a request for display 2 stopped display 1's preparation")
        queue.run(for: 1) { _ in }
        #expect(box.token?.isCancelled == true, "the superseded apply's candidate is left preparing")
        gate.open()
        await settle { queue.isIdle }
        #expect(queue.isIdle)
    }

    @Test("A display stays in flight until its apply returns, and cancel reaches that apply's token")
    func inFlightUntilFinishedAndCancelReachesTheWork() async {
        let queue = HomePage.ApplyQueue()
        let gate = Gate()
        let box = TokenBox()
        queue.run(for: 1) { cancellation in
            box.token = cancellation
            await gate.wait()
        }
        await settle { box.token != nil }
        #expect(queue.inFlight == [1])
        queue.cancel(1)
        #expect(box.token?.isCancelled == true)
        gate.open()
        await settle { queue.inFlight.isEmpty }
        #expect(queue.inFlight.isEmpty)
    }
}
