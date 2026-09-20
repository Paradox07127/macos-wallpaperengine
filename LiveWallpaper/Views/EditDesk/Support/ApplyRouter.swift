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
    var screens: [Screen] { get }
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
    private let confirmationTimeout: Duration

    /// The default timeout is long enough for a first frame to be prepared; past it the apply is
    /// reported as unconfirmed.
    init(
        manager: any WallpaperApplying, bookmarks: BookmarkStore, sceneCapable: Bool,
        confirmationTimeout: Duration = .seconds(10)
    ) {
        self.manager = manager
        self.bookmarks = bookmarks
        self.sceneCapable = sceneCapable
        self.confirmationTimeout = confirmationTimeout
    }

    func apply(_ intent: ApplyIntent, to screen: Screen) async -> ApplyReport {
        let previousMode = manager.getConfiguration(for: screen)?.videoDisplayMode
        let contentsBefore = contentsByScreen()
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
                outcome = await applyConfirmed(bookmark.content, to: screen) {
                    manager.applyBookmark(bookmark, to: screen)
                }
            }
        case let .video(url, bookmarkData, packageEntryName):
            leaveSpanMode()
            outcome = await applyConfirmed(.video(bookmarkData: bookmarkData, packageEntryName: packageEntryName), to: screen) {
                manager.setVideo(url: url, bookmarkData: bookmarkData, packageEntryName: packageEntryName, for: screen)
            }
        case let .html(source):
            leaveSpanMode()
            let config = manager.getConfiguration(for: screen)?.htmlConfig ?? .default
            outcome = await applyConfirmed(.html(source: source, config: config), to: screen) {
                manager.setHTMLWallpaperPreservingConfig(source: source, for: screen)
            }
        case let .scheme(scheme):
            leaveSpanMode()
            outcome = await applyConfirmed(scheme.configuration.activeWallpaper, to: screen) {
                manager.applyScheme(scheme, to: screen)
            }
        case let .droppedFile(url):
            outcome = await applyDroppedFile(url, to: screen, beforeDispatch: leaveSpanMode)
        #if !LITE_BUILD
        case let .scene(descriptor, origin):
            leaveSpanMode()
            outcome = await applyConfirmed(.scene(descriptor), to: screen) {
                manager.setSceneWallpaper(descriptor: descriptor, origin: origin, for: screen)
            }
        case let .wpeProjectFolder(url):
            leaveSpanMode()
            outcome = await applyProject(url, to: screen)
        case let .installedWorkshop(entry):
            leaveSpanMode()
            outcome = await awaitApplied(
                matching: { self.matches(entry.origin, configuration: $0) },
                on: screen.id, timeout: confirmationTimeout,
                dispatch: {
                    await manager.activateWPEHistoryEntry(entry, for: screen)
                    return nil
                }
            )
        #endif
        }
        // Re-entering span copies this screen's wallpaper across the others, so it is only safe
        // while nothing else has changed anywhere and this request is still the current one.
        if outcome != .applied, exitedSpanMode, let previousMode,
           !Task.isCancelled, contentsByScreen() == contentsBefore {
            manager.updateVideoDisplayMode(previousMode, for: screen)
            exitedSpanMode = false
        }
        return ApplyReport(outcome: outcome, exitedSpanMode: exitedSpanMode)
    }

    private func contentsByScreen() -> [CGDirectDisplayID: WallpaperContent?] {
        Dictionary(uniqueKeysWithValues: manager.screens.map { ($0.id, manager.getConfiguration(for: $0)?.activeWallpaper) })
    }

    /// The manager may store a refreshed video bookmark or a normalised HTML config for the same
    /// wallpaper, so confirmation compares what identifies the content, not the bytes.
    static func contentMatches(_ current: WallpaperContent?, _ intended: WallpaperContent) -> Bool {
        switch (current, intended) {
        case let (.video(currentData, currentEntry)?, .video(intendedData, intendedEntry)):
            currentEntry == intendedEntry
                && (currentData == intendedData || sameResolvedFile(currentData, intendedData))
        case let (.html(currentSource, _)?, .html(intendedSource, _)):
            currentSource == intendedSource
        case let (.scene(currentScene)?, .scene(intendedScene)):
            currentScene.workshopID == intendedScene.workshopID && currentScene.presetID == intendedScene.presetID
        default:
            false
        }
    }

    private static func changedAway(_ current: WallpaperContent?, from initial: WallpaperContent?) -> Bool {
        switch (current, initial) {
        case (nil, nil): false
        case (nil, .some), (.some, nil): true
        case let (current?, initial?): !contentMatches(current, initial)
        }
    }

    /// Two bookmarks that resolve to the same file are the same wallpaper; data that resolves to
    /// nothing matches nothing.
    private static func sameResolvedFile(_ lhs: Data, _ rhs: Data) -> Bool {
        guard let left = resolvedPath(lhs), let right = resolvedPath(rhs) else { return false }
        return left == right
    }

    private static func resolvedPath(_ bookmarkData: Data) -> String? {
        try? SecurityScopedBookmarkResolver.shared.resolve(bookmarkData, target: .transient).get().url.path
    }

    func awaitApplied(matching content: WallpaperContent, on screenID: CGDirectDisplayID, timeout: Duration) async -> Bool {
        await awaitApplied(
            matching: { Self.contentMatches($0.activeWallpaper, content) }, on: screenID, timeout: timeout, dispatch: { nil }
        ) == .applied
    }

    private func applyConfirmed(_ content: WallpaperContent, to screen: Screen, dispatch: () -> Void) async -> ApplyOutcome {
        await awaitApplied(
            matching: { Self.contentMatches($0.activeWallpaper, content) }, on: screen.id, timeout: confirmationTimeout,
            dispatch: {
                dispatch()
                return nil
            }
        )
    }

    private func awaitApplied(
        matching matches: (ScreenConfiguration) -> Bool,
        on screenID: CGDirectDisplayID,
        timeout: Duration,
        dispatch: @MainActor () async -> ApplyOutcome?
    ) async -> ApplyOutcome {
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
        guard let screen = manager.screen(withID: screenID) else { return .failed(.applyNotConfirmed) }
        let initialContent = manager.getConfiguration(for: screen)?.activeWallpaper
        // Subscribe and remember the old content before dispatch, including asynchronous WPE imports.
        if let outcome = await dispatch() {
            return outcome
        }
        guard !Task.isCancelled, let currentScreen = manager.screen(withID: screenID) else {
            return .failed(.applyNotConfirmed)
        }
        let configuration = manager.getConfiguration(for: currentScreen)
        if let configuration, matches(configuration) {
            return .applied
        }
        if Self.changedAway(configuration?.activeWallpaper, from: initialContent) {
            return .failed(.applyNotConfirmed)
        }
        let deadline = Task {
            do { try await Task.sleep(for: timeout) } catch { return }
            continuation.yield(nil)
        }
        defer { deadline.cancel() }
        for await changedID in changes {
            guard !Task.isCancelled, let changedID else { return .failed(.applyNotConfirmed) }
            guard changedID == screenID else { continue }
            guard let currentScreen = manager.screen(withID: screenID) else { return .failed(.applyNotConfirmed) }
            let configuration = manager.getConfiguration(for: currentScreen)
            if let configuration, matches(configuration) {
                return .applied
            }
            if Self.changedAway(configuration?.activeWallpaper, from: initialContent) {
                return .failed(.applyNotConfirmed)
            }
        }
        return .failed(.applyNotConfirmed)
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
            let content = WallpaperContent.video(bookmarkData: data)
            let outcome = await applyConfirmed(content, to: screen) {
                manager.setVideo(url: videoURL, bookmarkData: data, packageEntryName: nil, for: screen)
            }
            if outcome == .applied {
                saveDroppedContent(content, from: videoURL, on: screen)
            }
            return outcome
        case let .html(source):
            let config = manager.getConfiguration(for: screen)?.htmlConfig ?? .default
            beforeDispatch()
            let content = WallpaperContent.html(source: source, config: config)
            let outcome = await applyConfirmed(content, to: screen) {
                manager.setHTMLWallpaperPreservingConfig(source: source, for: screen)
            }
            if outcome == .applied {
                saveDroppedContent(content, from: url, on: screen)
            }
            return outcome
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
        // Same loose identity as the confirmation: a re-drop of the same file must not save twice.
        guard !bookmarks.bookmarks.contains(where: { Self.contentMatches($0.content, content) }) else { return }
        let bookmark = bookmarks.add(label: url.lastPathComponent, content: content, sourceDisplayName: url.lastPathComponent)
        manager.captureCover(forBookmark: bookmark.id, from: screen)
    }

    #if !LITE_BUILD
    private func applyProject(_ url: URL, to screen: Screen) async -> ApplyOutcome {
        var origin: WPEOrigin?
        return await awaitApplied(
            matching: { configuration in
                guard let origin else { return false }
                return self.matches(origin, configuration: configuration)
            },
            on: screen.id, timeout: confirmationTimeout,
            dispatch: {
                switch await manager.importWallpaperEngineProject(at: url, for: screen) {
                case let .applied(appliedOrigin):
                    origin = appliedOrigin
                    return nil
                case let .registeredPreset(name):
                    return .registeredPreset(name: name)
                case .unsupported:
                    return .failed(.sceneProjectUnsupported)
                case let .rejected(reason):
                    return .failed(.sceneImportRejected(reason: reason))
                }
            }
        )
    }

    private func matches(_ origin: WPEOrigin, configuration: ScreenConfiguration) -> Bool {
        // Imports expose their origin, not the prepared content; the origin is committed with that content.
        guard configuration.wpeOrigin?.workshopID == origin.workshopID else { return false }
        switch (origin.originalType, configuration.activeWallpaper) {
        case let (.scene, .scene(descriptor)):
            return descriptor.workshopID == origin.workshopID
        case (.video, .video), (.web, .html):
            return true
        default:
            return false
        }
    }
    #endif
}
