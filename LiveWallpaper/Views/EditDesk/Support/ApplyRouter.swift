import CoreGraphics
import Foundation
import LiveWallpaperCore

enum ApplyIntent {
    case bookmark(WallpaperBookmark)
    case video(url: URL, bookmarkData: Data, packageEntryName: String?)
    case html(HTMLSource)
    case droppedFile(URL)
    case scheme(ScreenScheme)
    #if !LITE_BUILD
    case scene(descriptor: SceneDescriptor, origin: WPEOrigin?)
    case wpeProjectFolder(URL)
    case installedWorkshop(WPEHistoryEntry)
    #endif
}

enum ApplyOutcome: Equatable {
    case applied
    case registeredPreset(name: String)
    case failed(DropFailure)
}

struct ApplyReport: Equatable {
    var outcome: ApplyOutcome
    var exitedSpanMode: Bool
}

@MainActor
protocol WallpaperApplying {
    func screen(withID id: CGDirectDisplayID) -> Screen?
    func getConfiguration(for screen: Screen) -> ScreenConfiguration?
    func updateVideoDisplayMode(_ mode: VideoDisplayMode, for screen: Screen)
    func applyBookmark(_ bookmark: WallpaperBookmark, to screen: Screen)
    func setVideo(url: URL, bookmarkData: Data, packageEntryName: String?, for screen: Screen)
    func setHTMLWallpaperPreservingConfig(source: HTMLSource, for screen: Screen)
    func applyScheme(_ scheme: ScreenScheme, to screen: Screen)
    func captureCover(forBookmark id: UUID, from screen: Screen)
    #if !LITE_BUILD
    func setSceneWallpaper(descriptor: SceneDescriptor, origin: WPEOrigin?, for screen: Screen)
    func importWallpaperEngineProject(at folderURL: URL, for screen: Screen) async -> ScreenManager.WPEProjectApplyOutcome
    func activateWPEHistoryEntry(_ entry: WPEHistoryEntry, for screen: Screen) async
    #endif
}

extension ScreenManager: WallpaperApplying {
    func screen(withID id: CGDirectDisplayID) -> Screen? {
        screens.first { $0.id == id }
    }
}

@MainActor
final class ApplyRouter {
    private let manager: any WallpaperApplying
    private let bookmarks: BookmarkStore
    private let sceneCapable: Bool

    init(manager: any WallpaperApplying, bookmarks: BookmarkStore, sceneCapable: Bool) {
        self.manager = manager
        self.bookmarks = bookmarks
        self.sceneCapable = sceneCapable
    }

    func apply(_ intent: ApplyIntent, to screen: Screen) async -> ApplyReport {
        // Span mode is left only once an intent is actually dispatched, so a refused drop changes nothing.
        var exitedSpanMode = false
        let leaveSpanMode = {
            guard self.manager.getConfiguration(for: screen)?.videoDisplayMode == .spanAllDisplays else { return }
            self.manager.updateVideoDisplayMode(.perDisplay, for: screen)
            exitedSpanMode = true
        }
        let outcome: ApplyOutcome
        switch intent {
        case let .bookmark(bookmark):
            // `applyBookmark` returns Void and only logs when a video bookmark no longer resolves.
            if case let .video(bookmarkData, _) = bookmark.content,
               case .failure = SecurityScopedBookmarkResolver.shared.resolve(bookmarkData, target: .transient) {
                outcome = .failed(.videoBookmarkFailed)
            } else {
                leaveSpanMode()
                manager.applyBookmark(bookmark, to: screen)
                outcome = .applied
            }
        case let .video(url, bookmarkData, packageEntryName):
            leaveSpanMode()
            manager.setVideo(url: url, bookmarkData: bookmarkData, packageEntryName: packageEntryName, for: screen)
            outcome = .applied
        case let .html(source):
            leaveSpanMode()
            manager.setHTMLWallpaperPreservingConfig(source: source, for: screen)
            outcome = .applied
        case let .scheme(scheme):
            leaveSpanMode()
            manager.applyScheme(scheme, to: screen)
            outcome = .applied
        case let .droppedFile(url):
            outcome = await applyDroppedFile(url, to: screen, beforeDispatch: leaveSpanMode)
        #if !LITE_BUILD
        case let .scene(descriptor, origin):
            leaveSpanMode()
            manager.setSceneWallpaper(descriptor: descriptor, origin: origin, for: screen)
            outcome = .applied
        case let .wpeProjectFolder(url):
            leaveSpanMode()
            outcome = await applyProject(url, to: screen)
        case let .installedWorkshop(entry):
            leaveSpanMode()
            await manager.activateWPEHistoryEntry(entry, for: screen)
            outcome = .applied
        #endif
        }
        return ApplyReport(outcome: outcome, exitedSpanMode: exitedSpanMode)
    }

    func awaitApplied(matching content: WallpaperContent, on screenID: CGDirectDisplayID, timeout: Duration) async -> Bool {
        let (changes, continuation) = AsyncStream<CGDirectDisplayID?>.makeStream()
        let observer = NotificationCenter.default.addObserver(
            forName: .wallpaperConfigurationDidChange, object: nil, queue: nil
        ) { notification in
            if let id = notification.userInfo?["screenID"] as? CGDirectDisplayID {
                continuation.yield(id)
            }
        }
        defer {
            NotificationCenter.default.removeObserver(observer)
            continuation.finish()
        }
        guard let screen = manager.screen(withID: screenID) else { return false }
        let initialContent = manager.getConfiguration(for: screen)?.activeWallpaper
        if initialContent == content {
            return true
        }
        let deadline = Task {
            do { try await Task.sleep(for: timeout) } catch { return }
            continuation.yield(nil)
        }
        defer { deadline.cancel() }
        for await changedID in changes {
            guard let changedID else { return false }
            guard changedID == screenID else { continue }
            guard let currentScreen = manager.screen(withID: screenID) else { return false }
            let currentContent = manager.getConfiguration(for: currentScreen)?.activeWallpaper
            if currentContent == content {
                return true
            }
            if currentContent != initialContent {
                return false
            }
        }
        return false
    }

    private func applyDroppedFile(_ url: URL, to screen: Screen, beforeDispatch: () -> Void) async -> ApplyOutcome {
        if !sceneCapable,
           WallpaperImportRouter.isWallpaperEngineProjectFolder(url)
           || WallpaperImportRouter.containsWallpaperEngineProjects(url) {
            return .failed(.sceneUnsupportedInBuild)
        }
        switch WallpaperImportRouter.route(url, sceneCapable: sceneCapable) {
        case let .video(videoURL):
            guard let data = ResourceUtilities.createVideoBookmark(for: videoURL) else {
                return .failed(.videoBookmarkFailed)
            }
            beforeDispatch()
            manager.setVideo(url: videoURL, bookmarkData: data, packageEntryName: nil, for: screen)
            saveDroppedContent(.video(bookmarkData: data), from: videoURL, on: screen)
            return .applied
        case let .html(source):
            let config = manager.getConfiguration(for: screen)?.htmlConfig ?? .default
            beforeDispatch()
            manager.setHTMLWallpaperPreservingConfig(source: source, for: screen)
            saveDroppedContent(.html(source: source, config: config), from: url, on: screen)
            return .applied
        case let .sceneProject(folderURL):
            #if !LITE_BUILD
            beforeDispatch()
            return await applyProject(folderURL, to: screen)
            #else
            return .failed(.sceneUnsupportedInBuild)
            #endif
        case .sceneLibrary:
            return .failed(.sceneLibraryDrop)
        case .unsupported:
            return .failed(.unrecognizedDrop)
        }
    }

    private func saveDroppedContent(_ content: WallpaperContent, from url: URL, on screen: Screen) {
        guard bookmarks.equivalentBookmark(content: content) == nil else { return }
        let bookmark = bookmarks.add(label: url.lastPathComponent, content: content, sourceDisplayName: url.lastPathComponent)
        Task {
            // The apply caller may disappear while the renderer is still loading.
            guard await awaitApplied(matching: content, on: screen.id, timeout: .seconds(10)),
                  let currentScreen = manager.screen(withID: screen.id),
                  manager.getConfiguration(for: currentScreen)?.activeWallpaper == content else { return }
            manager.captureCover(forBookmark: bookmark.id, from: currentScreen)
        }
    }

    #if !LITE_BUILD
    private func applyProject(_ url: URL, to screen: Screen) async -> ApplyOutcome {
        switch await manager.importWallpaperEngineProject(at: url, for: screen) {
        case .applied:
            .applied
        case let .registeredPreset(name):
            .registeredPreset(name: name)
        case .unsupported:
            .failed(.sceneProjectUnsupported)
        case let .rejected(reason):
            .failed(.sceneImportRejected(reason: reason))
        }
    }
    #endif
}
