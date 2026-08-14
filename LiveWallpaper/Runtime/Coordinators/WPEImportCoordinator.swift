#if !LITE_BUILD
import CoreGraphics
import Foundation
import LiveWallpaperCore

/// Wallpaper Engine import flow on top of tracker + import service / cache resolver.
@MainActor
final class WPEImportCoordinator {
    typealias ImportOperation = @MainActor (URL) async throws -> WallpaperEngineImportService.ImportResult

    enum PreparationOutcome: Sendable, Equatable {
        case ready(content: WallpaperContent, origin: WPEOrigin)
        case unsupported(origin: WPEOrigin)
        /// A Workshop preset item: registered into the library, nothing to show
        /// on a screen. Success — must not travel down the rejection path.
        case registeredPreset(name: String)
        case rejected(reason: String)
    }

    enum ApplyOutcome: Sendable, Equatable {
        case applied(origin: WPEOrigin)
        case unsupported(origin: WPEOrigin)
        /// The folder was a preset, not a wallpaper: it joined the library's
        /// preset menu and no screen changed. Callers that gate on "a wallpaper
        /// is now set" must not treat this as `applied`.
        case registeredPreset(name: String)
        case rejected(reason: String)
    }

    private let importOperation: ImportOperation
    private let cachedContentResolver: WPECachedContentResolver
    private let tracker: WPEImportTracker
    private let configurationStore: WallpaperConfigurationStore
    private let bookmarkResolver: SecurityScopedBookmarkResolver
    private let saveConfiguration: @MainActor (ScreenConfiguration) -> Void
    private let restoreWallpaperSession: @MainActor (
        Screen,
        ScreenConfiguration,
        Bool,
        @MainActor @escaping () -> Bool
    ) -> Void
    private let recordImport: @MainActor (WPEHistoryEntry) -> Void
    private let persistOriginBookmarkRefresh: @MainActor (WPEOrigin, Data) -> Void
    private let isLifecycleActive: @MainActor () -> Bool
    private let notifyImportCompleted: @MainActor (CGDirectDisplayID, WPEType, String) -> Void

    init(
        importService: WallpaperEngineImportService = WallpaperEngineImportService(),
        cachedContentResolver: WPECachedContentResolver = WPECachedContentResolver(),
        tracker: WPEImportTracker,
        configurationStore: WallpaperConfigurationStore,
        bookmarkResolver: SecurityScopedBookmarkResolver = .shared,
        saveConfiguration: @MainActor @escaping (ScreenConfiguration) -> Void,
        restoreWallpaperSession: @MainActor @escaping (
            Screen,
            ScreenConfiguration,
            Bool,
            @MainActor @escaping () -> Bool
        ) -> Void,
        importOperation: ImportOperation? = nil,
        recordImport: @MainActor @escaping (WPEHistoryEntry) -> Void = {
            SettingsManager.shared.recordWPEImport($0)
        },
        persistOriginBookmarkRefresh: @MainActor @escaping (WPEOrigin, Data) -> Void = {
            origin, refreshed in
            _ = SettingsManager.shared.replaceWPEHistorySourceBookmark(
                workshopID: origin.workshopID,
                matching: origin.sourceFolderBookmark,
                with: refreshed
            )
        },
        isLifecycleActive: @MainActor @escaping () -> Bool = { true },
        notifyImportCompleted: @MainActor @escaping (CGDirectDisplayID, WPEType, String) -> Void = {
            screenID, type, workshopID in
            NotificationCenter.default.post(
                name: .wpeImportDidComplete,
                object: nil,
                userInfo: [
                    "screenID": screenID,
                    "type": type.rawValue,
                    "workshopID": workshopID,
                ]
            )
        }
    ) {
        self.importOperation = importOperation ?? { [importService] folderURL in
            try await importService.importProject(folder: folderURL)
        }
        self.cachedContentResolver = cachedContentResolver
        self.tracker = tracker
        self.configurationStore = configurationStore
        self.bookmarkResolver = bookmarkResolver
        self.saveConfiguration = saveConfiguration
        self.restoreWallpaperSession = restoreWallpaperSession
        self.recordImport = recordImport
        self.persistOriginBookmarkRefresh = persistOriginBookmarkRefresh
        self.isLifecycleActive = isLifecycleActive
        self.notifyImportCompleted = notifyImportCompleted
    }

    // MARK: - Public orchestration

    func prepareProject(at folderURL: URL) async -> PreparationOutcome {
        do {
            let result = try await importOperation(folderURL)
            switch result {
            case .ready(let content, let origin):
                return .ready(content: content, origin: origin)
            case .unsupported(let origin):
                return .unsupported(origin: origin)
            case .workshopPreset(let preset):
                // Not applicable to a screen: a preset has no wallpaper of its
                // own. Registering it is the whole action, and the user aimed a
                // picker or a drop at it, so it lifts any delete tombstone.
                await SettingsManager.shared.registerScenePreset(preset, clearsDeleteTombstone: true)
                return .registeredPreset(name: preset.name)
            case .rejected(let reason):
                return .rejected(reason: reason)
            }
        } catch {
            return .rejected(reason: error.localizedDescription)
        }
    }

    @discardableResult
    func importProject(at folderURL: URL, for screen: Screen) async -> ApplyOutcome {
        guard isLifecycleActive(), !tracker.isTerminated else {
            return .rejected(reason: "Application terminating")
        }
        let generation = tracker.bumpGeneration(for: screen.id)
        return await importProject(
            at: folderURL,
            for: screen,
            expectedGeneration: generation
        )
    }

    private func importProject(
        at folderURL: URL,
        for screen: Screen,
        expectedGeneration generation: Int
    ) async -> ApplyOutcome {
        let outcome = await prepareProject(at: folderURL)
        guard isLifecycleActive(), tracker.isCurrentGeneration(generation, for: screen.id) else {
            return .rejected(reason: "Action superseded")
        }

        switch outcome {
        case .ready(let content, let origin):
            let now = Date()
            applyReady(
                content,
                origin: origin,
                importedAt: now,
                lastUsedAt: now,
                expectedGeneration: generation,
                for: screen
            )
            return .applied(origin: origin)

        case .unsupported(let origin):
            recordImport(WPEHistoryEntry(origin: origin, importedAt: Date(), lastUsedAt: nil))
            postDidComplete(
                screenID: screen.id,
                type: origin.originalType,
                workshopID: origin.workshopID
            )
            tracker.clearError(for: screen.id)
            return .unsupported(origin: origin)

        case .registeredPreset(let name):
            tracker.clearError(for: screen.id)
            return .registeredPreset(name: name)

        case .rejected(let reason):
            tracker.recordError(.wpePackageInvalid(reason), for: screen.id)
            return .rejected(reason: reason)
        }
    }

    func activateHistoryEntry(_ entry: WPEHistoryEntry, for screen: Screen) async {
        guard isLifecycleActive(), !tracker.isTerminated else { return }
        let generation = tracker.bumpGeneration(for: screen.id)
        do {
            let resolved = try bookmarkResolver
                .resolve(entry.origin.sourceFolderBookmark, target: .transient).get()
            let effectiveEntry: WPEHistoryEntry
            if resolved.didRefresh,
               let refreshed = entry.replacingSourceFolderBookmark(
                workshopID: entry.origin.workshopID,
                matching: entry.origin.sourceFolderBookmark,
                with: resolved.bookmarkData
               ) {
                persistOriginBookmarkRefresh(entry.origin, resolved.bookmarkData)
                effectiveEntry = refreshed
            } else {
                effectiveEntry = entry
            }
            let folderURL = resolved.url
            let didStartScope = folderURL.startAccessingSecurityScopedResource()
            defer {
                if didStartScope {
                    folderURL.stopAccessingSecurityScopedResource()
                }
            }

            guard didStartScope || FileManager.default.fileExists(atPath: folderURL.path) else {
                if applyCachedHistoryEntry(
                    effectiveEntry,
                    expectedGeneration: generation,
                    for: screen
                ) {
                    return
                }
                tracker.recordError(.fileAccessDenied(entry.origin.title), for: screen.id)
                return
            }

            tracker.clearError(for: screen.id)
            _ = await importProject(
                at: folderURL,
                for: screen,
                expectedGeneration: generation
            )
            guard isLifecycleActive(),
                  tracker.isCurrentGeneration(generation, for: screen.id) else {
                return
            }
            if tracker.error(for: screen.id) != nil {
                _ = applyCachedHistoryEntry(
                    effectiveEntry,
                    expectedGeneration: generation,
                    for: screen
                )
            }
        } catch {
            guard isLifecycleActive(),
                  tracker.isCurrentGeneration(generation, for: screen.id) else {
                return
            }
            if applyCachedHistoryEntry(
                entry,
                expectedGeneration: generation,
                for: screen
            ) {
                return
            }
            tracker.recordError(.wpeImportFailed(error.localizedDescription), for: screen.id)
        }
    }

    func removeWorkshop(workshopID: String) {
        guard isLifecycleActive(), !tracker.isTerminated else { return }
        SettingsManager.shared.removeWPEImport(workshopID: workshopID)
        // Tombstone so auto-import can't resurrect from a still-present Steam copy.
        SettingsManager.shared.recordWPEDeleteTombstone(workshopID: workshopID)

        clearRemovedWorkshopReferences(workshopID: workshopID)
    }

    func clearRemovedWorkshopReferences(workshopID: String) {
        guard isLifecycleActive(), !tracker.isTerminated else { return }
        for var config in configurationStore.loadAll() where config.wpeOrigin?.workshopID == workshopID {
            config.wpeOrigin = nil
            saveConfiguration(config)
        }
    }

    // MARK: - Private helpers

    private func postDidComplete(
        screenID: CGDirectDisplayID,
        type: WPEType,
        workshopID: String
    ) {
        guard isLifecycleActive(), !tracker.isTerminated else { return }
        notifyImportCompleted(screenID, type, workshopID)
    }

    private func applyReady(
        _ content: WallpaperContent,
        origin: WPEOrigin,
        importedAt: Date,
        lastUsedAt: Date?,
        expectedGeneration: Int,
        for screen: Screen
    ) {
        guard isLifecycleActive(),
              tracker.isCurrentGeneration(expectedGeneration, for: screen.id) else {
            return
        }
        recordImport(WPEHistoryEntry(origin: origin, importedAt: importedAt, lastUsedAt: lastUsedAt))

        var config = configurationStore.get(for: screen.id, fingerprint: screen.displayFingerprint) ?? ScreenConfiguration(
            screenID: screen.id,
            wallpaper: content
        ).applyingDisplayDefaults(SettingsManager.shared.loadDisplayDefaults())
        config.activeWallpaper = content
        if case .html(let source, let htmlConfig) = content {
            config.savedHTMLSource = source
            config.savedHTMLConfig = htmlConfig
        } else if case .video(let bookmarkData, let packageEntryName) = content {
            config.savedVideoBookmarkData = bookmarkData
            config.savedVideoPackageEntryName = packageEntryName
        }
        config.wpeOrigin = origin
        restoreWallpaperSession(screen, config, false) { [weak self] in
            guard let self,
                  self.isLifecycleActive(),
                  self.tracker.isCurrentGeneration(
                    expectedGeneration,
                    for: screen.id
                  ) else {
                return false
            }
            self.saveConfiguration(config)
            self.postDidComplete(
                screenID: screen.id,
                type: origin.originalType,
                workshopID: origin.workshopID
            )
            self.tracker.clearError(for: screen.id)
            return true
        }
    }

    @discardableResult
    private func applyCachedHistoryEntry(
        _ entry: WPEHistoryEntry,
        expectedGeneration: Int,
        for screen: Screen
    ) -> Bool {
        guard isLifecycleActive(),
              tracker.isCurrentGeneration(expectedGeneration, for: screen.id) else {
            return false
        }
        guard let content = cachedContentResolver.content(for: entry.origin) else {
            return false
        }
        applyReady(
            content,
            origin: entry.origin,
            importedAt: entry.importedAt,
            lastUsedAt: Date(),
            expectedGeneration: expectedGeneration,
            for: screen
        )
        return true
    }
}
#endif
