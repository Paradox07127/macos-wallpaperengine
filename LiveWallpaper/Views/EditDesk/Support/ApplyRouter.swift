import CoreGraphics
import Foundation
import LiveWallpaperCore

enum ApplyIntent {
    case bookmark(WallpaperBookmark)
    case html(HTMLSource)
    case droppedFile(URL)
    /// Two or more videos from one drop, in drop order; built by `drop(_:)`.
    case droppedVideos([URL])
    case scheme(ScreenScheme)
    #if !LITE_BUILD
    case scene(descriptor: SceneDescriptor, origin: WPEOrigin?)
    case wpeProjectFolder(URL)
    case installedWorkshop(WPEHistoryEntry)
    #endif

    /// Reads a drop the way the old detail page did: two or more videos become a playlist, anything
    /// else goes by its first file. nil for an empty drop.
    @MainActor
    static func drop(_ urls: [URL]) -> ApplyIntent? {
        guard let first = urls.first else { return nil }
        let videos = urls.filter(ResourceUtilities.isSupportedVideoURL)
        return videos.count > 1 ? .droppedVideos(videos) : .droppedFile(first)
    }
}

enum ApplyOutcome: Equatable {
    case applied
    case registeredPreset(name: String)
    case failed(DropFailure)
    /// `reason` is already localized; `attemptID` is set for a Pro scene attempt, which raises its own failure card.
    case prepareFailed(reason: String, attemptID: UUID?)
    /// A Wallpaper Engine library went to the batch import, which reports on its own card; no display changed.
    case importingLibrary

    static func registeredPresetText(_ name: String) -> String {
        String(
            localized: "Added “\(name)” to Presets. The wallpaper wasn't changed.", bundle: .appLanguage,
            comment: "Toast after a dropped Wallpaper Engine preset joined the preset library. Placeholder is the preset name."
        )
    }

    /// `wallpapersOn` is the master switch: while it is off an apply only saves, and the desktop stays as it is.
    static func appliedText(on screenName: String, wallpapersOn: Bool = true) -> String {
        guard wallpapersOn else {
            return String(
                localized: "Saved to \(screenName). Wallpapers are turned off.", bundle: .appLanguage,
                comment: "Toast after a wallpaper was saved to a display while the master switch keeps every wallpaper off. Placeholder is a display name."
            )
        }
        return String(
            localized: "Applied to \(screenName)", bundle: .appLanguage,
            comment: "Toast after a wallpaper reached a display. Placeholder is a display name."
        )
    }

    static func appliedToAllText(wallpapersOn: Bool) -> String {
        guard wallpapersOn else {
            return String(
                localized: "Saved to all displays. Wallpapers are turned off.", bundle: .appLanguage,
                comment: "Toast after one wallpaper was saved to every display while the master switch keeps every wallpaper off."
            )
        }
        return String(
            localized: "Applied to all displays", bundle: .appLanguage,
            comment: "Toast after one wallpaper went on every display at once in the Edit Desk; it offers Undo."
        )
    }
}

struct ApplyReport: Equatable {
    var outcome: ApplyOutcome
    var exitedSpanMode: Bool
    /// The user cancelled while it prepared; `outcome` then reads as not applied.
    var cancelled = false
    /// How many videos a multi-video drop made the display's playlist; nil for every other apply.
    var queuedVideos: Int?
    /// The undo step this apply was recorded as; nil when it was not recorded.
    var undoStepID: UUID?
}

@MainActor
final class ApplyCancellation {
    private(set) var isCancelled = false
    /// Set by the router while it waits; runs once, on the first `cancel()`.
    var onCancel: (() -> Void)?

    func cancel() {
        guard !isCancelled else { return }
        isCancelled = true
        onCancel?()
        onCancel = nil
    }
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
    func replaceWallpaperQueue(_ entries: [WallpaperQueueEntry], for screen: Screen)
    /// Drops the candidate still preparing on `screen`; the wallpaper already there stays.
    func cancelPreparation(for screen: Screen)
    /// Whether a `.wallpaperPreparationDidFail` names the preparation `screen` is running now.
    func isCurrentPreparation(generation: Int?, attemptID: UUID?, on screen: Screen) -> Bool
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

    func cancelPreparation(for screen: Screen) {
        beginExplicitWallpaperSelection(for: screen)
    }

    func isCurrentPreparation(generation: Int?, attemptID: UUID?, on screen: Screen) -> Bool {
        if let attemptID {
            return wallpaperLoads.attempt(for: screen)?.id == attemptID
        }
        return generation.map { isCurrentTransition($0, for: screen.id) } ?? false
    }
}

@MainActor
final class ApplyRouter {
    private let manager: any WallpaperApplying
    private let bookmarks: BookmarkStore
    private let sceneCapable: Bool
    let confirmationTimeout: Duration
    private let importLibrary: @MainActor ([URL]) -> Void

    /// Past the longest preparation, leaving time to build the session and validate a video.
    nonisolated static let defaultConfirmationTimeout = ScreenManager.longPreparationTimeout + .seconds(8)

    /// The default timeout is long enough for a first frame to be prepared; past it the apply is
    /// reported as unconfirmed.
    init(
        manager: any WallpaperApplying, bookmarks: BookmarkStore, sceneCapable: Bool,
        confirmationTimeout: Duration = ApplyRouter.defaultConfirmationTimeout,
        importLibrary: @escaping @MainActor ([URL]) -> Void = ApplyRouter.importWorkshopLibrary
    ) {
        self.manager = manager
        self.bookmarks = bookmarks
        self.sceneCapable = sceneCapable
        self.confirmationTimeout = confirmationTimeout
        self.importLibrary = importLibrary
    }

    /// Lite never calls it: without scenes a library drop is refused before routing.
    static func importWorkshopLibrary(_ folders: [URL]) {
        #if !LITE_BUILD
        WorkshopFolderImportCoordinator.shared.importProjects(from: folders)
        #endif
    }

    func apply(_ intent: ApplyIntent, to screen: Screen, cancellation: ApplyCancellation? = nil) async -> ApplyReport {
        let previousMode = manager.getConfiguration(for: screen)?.videoDisplayMode
        let contentsBefore = contentsByScreen()
        var exitedSpanMode = false
        var queuedVideos: Int?
        let leaveSpanMode = {
            guard self.manager.getConfiguration(for: screen)?.videoDisplayMode == .spanAllDisplays else { return }
            self.manager.updateVideoDisplayMode(.perDisplay, for: screen)
            exitedSpanMode = true
        }
        let outcome: ApplyOutcome
        switch intent {
        case let .bookmark(bookmark):
            // `applyBookmark` returns Void and only logs when a video bookmark no longer resolves.
            if let failure = Self.sourceFailure(of: bookmark.content) {
                outcome = .failed(failure)
            } else {
                leaveSpanMode()
                outcome = await applyConfirmed(bookmark.content, to: screen, cancellation: cancellation) {
                    manager.applyBookmark(bookmark, to: screen)
                }
            }
        case let .html(source):
            leaveSpanMode()
            let config = manager.getConfiguration(for: screen)?.htmlConfig ?? .default
            let content = WallpaperContent.html(source: source, config: config)
            outcome = await applyConfirmed(content, to: screen, cancellation: cancellation) {
                manager.setHTMLWallpaperPreservingConfig(source: source, for: screen)
            }
            switch (outcome, source) {
            case (.applied, .url), (.applied, .file), (.applied, .folder):
                saveApplied(content, label: source.displayName, on: screen)
            default:
                break
            }
        case let .scheme(scheme):
            leaveSpanMode()
            outcome = await applyConfirmed(scheme.configuration.activeWallpaper, to: screen, cancellation: cancellation) {
                manager.applyScheme(scheme, to: screen)
            }
        case let .droppedFile(url):
            outcome = await applyDroppedFile(url, to: screen, cancellation: cancellation, beforeDispatch: leaveSpanMode)
        case let .droppedVideos(videos):
            let dropped = await applyDroppedVideos(videos, to: screen, cancellation: cancellation, beforeDispatch: leaveSpanMode)
            outcome = dropped.outcome
            queuedVideos = dropped.queued
        #if !LITE_BUILD
        case let .scene(descriptor, origin):
            leaveSpanMode()
            outcome = await applyConfirmed(.scene(descriptor), to: screen, cancellation: cancellation) {
                manager.setSceneWallpaper(descriptor: descriptor, origin: origin, for: screen)
            }
        case let .wpeProjectFolder(url):
            leaveSpanMode()
            outcome = await applyProject(url, to: screen, cancellation: cancellation)
        case let .installedWorkshop(entry):
            leaveSpanMode()
            outcome = await awaitApplied(
                matching: { self.matches(entry.origin, configuration: $0) },
                on: screen.id, timeout: confirmationTimeout, cancellation: cancellation,
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
        return ApplyReport(
            outcome: outcome, exitedSpanMode: exitedSpanMode, cancelled: cancellation?.isCancelled == true && outcome != .applied,
            queuedVideos: queuedVideos
        )
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

    static func changedAway(_ current: WallpaperContent?, from initial: WallpaperContent?) -> Bool {
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

    static func resolvedPath(_ bookmarkData: Data) -> String? {
        try? SecurityScopedBookmarkResolver.shared.resolve(bookmarkData, target: .transient).get().url.path
    }

    func awaitApplied(matching content: WallpaperContent, on screenID: CGDirectDisplayID, timeout: Duration) async -> Bool {
        await awaitApplied(
            matching: { Self.contentMatches($0.activeWallpaper, content) }, on: screenID, timeout: timeout, dispatch: { nil }
        ) == .applied
    }

    private func applyConfirmed(
        _ content: WallpaperContent, to screen: Screen, cancellation: ApplyCancellation?, dispatch: () -> Void
    ) async -> ApplyOutcome {
        await awaitApplied(
            matching: { Self.contentMatches($0.activeWallpaper, content) }, on: screen.id, timeout: confirmationTimeout,
            cancellation: cancellation,
            dispatch: {
                dispatch()
                return nil
            }
        )
    }

    private enum WaitEvent {
        case configurationChanged(CGDirectDisplayID)
        case preparationFailed(CGDirectDisplayID, reason: String, generation: Int?, attemptID: UUID?)
        case cancelled
        case deadline
    }

    private func awaitApplied(
        matching matches: (ScreenConfiguration) -> Bool,
        on screenID: CGDirectDisplayID,
        timeout: Duration,
        cancellation: ApplyCancellation? = nil,
        dispatch: @MainActor () async -> ApplyOutcome?
    ) async -> ApplyOutcome {
        let (events, continuation) = AsyncStream<WaitEvent>.makeStream()
        let observers = [
            NotificationCenter.default.addObserver(
                forName: .wallpaperConfigurationDidChange, object: nil, queue: nil
            ) { notification in
                if let id = notification.userInfo?["screenID"] as? CGDirectDisplayID {
                    continuation.yield(.configurationChanged(id))
                }
            },
            NotificationCenter.default.addObserver(
                forName: .wallpaperPreparationDidFail, object: nil, queue: nil
            ) { notification in
                if let id = notification.userInfo?["screenID"] as? CGDirectDisplayID,
                   let reason = notification.userInfo?["reason"] as? String {
                    continuation.yield(.preparationFailed(
                        id, reason: reason, generation: notification.userInfo?["generation"] as? Int,
                        attemptID: notification.userInfo?["attemptID"] as? UUID
                    ))
                }
            },
        ]
        defer {
            for observer in observers {
                NotificationCenter.default.removeObserver(observer)
            }
            continuation.finish()
        }
        guard let screen = manager.screen(withID: screenID), cancellation?.isCancelled != true else {
            return .failed(.applyNotConfirmed)
        }
        cancellation?.onCancel = { [manager] in
            manager.cancelPreparation(for: screen)
            continuation.yield(.cancelled)
        }
        defer { cancellation?.onCancel = nil }
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
        if cancellation?.isCancelled == true || Self.changedAway(configuration?.activeWallpaper, from: initialContent) {
            return .failed(.applyNotConfirmed)
        }
        let deadline = Task {
            do { try await Task.sleep(for: timeout) } catch { return }
            continuation.yield(.deadline)
        }
        defer { deadline.cancel() }
        for await event in events {
            guard !Task.isCancelled else { return .failed(.applyNotConfirmed) }
            let failure: ApplyOutcome?
            switch event {
            case .deadline:
                return .failed(.applyNotConfirmed)
            case .cancelled:
                failure = .failed(.applyNotConfirmed)
            case let .configurationChanged(id):
                guard id == screenID else { continue }
                failure = nil
            case let .preparationFailed(id, reason, generation, attemptID):
                guard id == screenID, let current = manager.screen(withID: screenID),
                      manager.isCurrentPreparation(generation: generation, attemptID: attemptID, on: current) else { continue }
                failure = .prepareFailed(reason: reason, attemptID: attemptID)
            }
            guard let currentScreen = manager.screen(withID: screenID) else { return .failed(.applyNotConfirmed) }
            let configuration = manager.getConfiguration(for: currentScreen)
            if let configuration, matches(configuration) {
                return .applied
            }
            if Self.changedAway(configuration?.activeWallpaper, from: initialContent) {
                return .failed(.applyNotConfirmed)
            }
            if let failure {
                return failure
            }
        }
        return .failed(.applyNotConfirmed)
    }

    private func applyDroppedFile(
        _ url: URL, to screen: Screen, cancellation: ApplyCancellation?, beforeDispatch: () -> Void
    ) async -> ApplyOutcome {
        if !sceneCapable,
           WallpaperImportRouter.isWallpaperEngineProjectFolder(url)
           || WallpaperImportRouter.containsWallpaperEngineProjects(url) {
            return .failed(.sceneUnsupportedInBuild)
        }
        switch WallpaperImportRouter.route(url, sceneCapable: sceneCapable) {
        case let .video(videoURL):
            guard let data = ResourceUtilities.createVideoBookmark(for: videoURL) else {
                return .failed(FileManager.default.fileExists(atPath: videoURL.path(percentEncoded: false)) ? .videoBookmarkFailed : .sourceMissing)
            }
            beforeDispatch()
            let content = WallpaperContent.video(bookmarkData: data)
            let outcome = await applyConfirmed(content, to: screen, cancellation: cancellation) {
                manager.setVideo(url: videoURL, bookmarkData: data, packageEntryName: nil, for: screen)
            }
            if outcome == .applied {
                saveApplied(content, label: videoURL.lastPathComponent, on: screen)
            }
            return outcome
        case let .html(source):
            let config = manager.getConfiguration(for: screen)?.htmlConfig ?? .default
            beforeDispatch()
            let content = WallpaperContent.html(source: source, config: config)
            let outcome = await applyConfirmed(content, to: screen, cancellation: cancellation) {
                manager.setHTMLWallpaperPreservingConfig(source: source, for: screen)
            }
            if outcome == .applied {
                saveApplied(content, label: url.lastPathComponent, on: screen)
            }
            return outcome
        case let .sceneProject(folderURL):
            #if !LITE_BUILD
            beforeDispatch()
            return await applyProject(folderURL, to: screen, cancellation: cancellation)
            #else
            return .failed(.sceneUnsupportedInBuild)
            #endif
        case let .sceneLibrary(folderURL):
            importLibrary([folderURL])
            return .importingLibrary
        case .unsupported:
            return .failed(.unrecognizedDrop)
        }
    }

    /// The first video plays at once; once it is confirmed the whole drop becomes the display's
    /// playlist in drop order. Without a bookmark for every file only the first file is applied.
    private func applyDroppedVideos(
        _ videos: [URL], to screen: Screen, cancellation: ApplyCancellation?, beforeDispatch: () -> Void
    ) async -> (outcome: ApplyOutcome, queued: Int?) {
        let bookmarks = videos.compactMap { ResourceUtilities.createVideoBookmark(for: $0) }
        guard let first = bookmarks.first, bookmarks.count == videos.count else {
            return await (applyDroppedFile(videos[0], to: screen, cancellation: cancellation, beforeDispatch: beforeDispatch), nil)
        }
        beforeDispatch()
        let content = WallpaperContent.video(bookmarkData: first)
        let outcome = await applyConfirmed(content, to: screen, cancellation: cancellation) {
            manager.setVideo(url: videos[0], bookmarkData: first, packageEntryName: nil, for: screen)
        }
        guard outcome == .applied else { return (outcome, nil) }
        saveApplied(content, label: videos[0].lastPathComponent, on: screen)
        manager.replaceWallpaperQueue(
            zip(videos, bookmarks).map { WallpaperQueueEntry(title: $0.lastPathComponent, content: .video(bookmarkData: $1)) },
            for: screen
        )
        return (outcome, videos.count)
    }

    private func saveApplied(_ content: WallpaperContent, label: String, on screen: Screen) {
        guard let bookmark = Self.saveIfNew(content, label: label, in: bookmarks) else { return }
        manager.captureCover(forBookmark: bookmark.id, from: screen)
    }

    /// nil when the library already holds this content.
    @discardableResult
    static func saveIfNew(_ content: WallpaperContent, label: String, in bookmarks: BookmarkStore) -> WallpaperBookmark? {
        // Same loose identity as the confirmation: a re-drop of the same file must not save twice.
        guard !bookmarks.bookmarks.contains(where: { contentMatches($0.content, content) }) else { return nil }
        return bookmarks.add(label: label, content: content, sourceDisplayName: label)
    }

    /// nil when the saved file is readable, and for content whose source the runtime reports itself.
    private static func sourceFailure(of content: WallpaperContent) -> DropFailure? {
        switch content {
        case let .video(bookmarkData, _):
            sourceFailure(bookmarkData, denied: .videoBookmarkFailed)
        case let .html(source, _):
            source.localBookmarkData.flatMap { sourceFailure($0, denied: .htmlBookmarkFailed) }
        case .scene:
            nil
        }
    }

    private static func sourceFailure(_ bookmarkData: Data, denied: DropFailure) -> DropFailure? {
        let url: URL
        do {
            (url, _) = try SecurityScopedBookmarkResolver.shared.resolveData(bookmarkData)
        } catch {
            let error = error as NSError
            let isMissing = error.domain == NSCocoaErrorDomain
                && [NSFileNoSuchFileError, NSFileReadNoSuchFileError].contains(error.code)
            return isMissing ? .sourceMissing : denied
        }
        // Without the scope a sandboxed existence check cannot tell a missing file from a forbidden one.
        return SecurityScopedBookmarkResolver.withScopedAccess(url) { didStart in
            if FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) {
                nil
            } else {
                didStart ? .sourceMissing : denied
            }
        }
    }

    #if !LITE_BUILD
    private func applyProject(_ url: URL, to screen: Screen, cancellation: ApplyCancellation?) async -> ApplyOutcome {
        var origin: WPEOrigin?
        return await awaitApplied(
            matching: { configuration in
                guard let origin else { return false }
                return self.matches(origin, configuration: configuration)
            },
            on: screen.id, timeout: confirmationTimeout, cancellation: cancellation,
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
