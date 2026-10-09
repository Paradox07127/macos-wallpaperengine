import Foundation
import CoreGraphics
import LiveWallpaperCore
import Observation

/// Metadata only. The existing SettingsManager caches own the latest snapshots.
enum SettingsPersistenceDomain: CaseIterable, Hashable {
    case configurations, globalSettings, bookmarks, schemes
}

@MainActor
@Observable
final class SettingsPersistenceStatus {
    enum Phase: Equatable {
        case saving(previousError: String?)
        case failed(String)
        case saved

        var error: String? {
            switch self {
            case let .saving(error): error
            case let .failed(error): error
            case .saved: nil
            }
        }
    }

    private(set) var phases: [SettingsPersistenceDomain: Phase] = [:]
    var hasUnsavedChanges: Bool {
        phases.values.contains { $0 != .saved }
    }

    var hasFailure: Bool {
        phases.values.contains { $0.error != nil }
    }

    var isSaving: Bool {
        phases.values.contains {
            if case .saving = $0 {
                true
            } else {
                false
            }
        }
    }

    fileprivate func began(_ domain: SettingsPersistenceDomain) {
        phases[domain] = .saving(previousError: phases[domain]?.error)
    }

    fileprivate func completed(_ domain: SettingsPersistenceDomain, error: String?) {
        phases[domain] = error.map(Phase.failed) ?? .saved
    }

    /// Reset intentionally discards prior edits; this does not attest deletion success.
    fileprivate func discardedPriorEditsForReset() {
        phases.removeAll()
    }
}

@MainActor
final class SettingsManager {
    static let shared = SettingsManager()

    private var cachedGlobalSettings: GlobalSettings?
    private var cachedConfigurations: [ScreenConfiguration]? {
        didSet {
            guard let oldValue, oldValue != cachedConfigurations else { return }
            let before = Dictionary(grouping: oldValue, by: \.screenID)
            let after = Dictionary(grouping: cachedConfigurations ?? [], by: \.screenID)
            for id in Set(before.keys).union(after.keys) where before[id] != after[id] {
                configurationMemoryRevisions[id, default: 0] &+= 1
            }
        }
    }

    // Memory changes fence prepared work; disk retries/generations do not.
    private var configurationMemoryRevisions: [CGDirectDisplayID: UInt64] = [:]
    private var cachedWallpaperBookmarks: [WallpaperBookmark]?
    private var cachedScreenSchemes: [ScreenScheme]?

    private let screenConfigStore: AtomicFileStore<[ScreenConfiguration]>
    private let globalSettingsStore: AtomicFileStore<GlobalSettings>
    private let wallpaperBookmarksStore: AtomicFileStore<[WallpaperBookmark]>
    private let screenSchemesStore: AtomicFileStore<[ScreenScheme]>
    let bookmarkResolver: SecurityScopedBookmarkResolver
    let bookmarkVolumeIsUnavailable: (Data) -> Bool
    private let loginItemController = LoginItemController()
    let persistWPEBookmarkOwnerRefresh: @MainActor (WPEOrigin, Data) -> Void
    private let defaults: UserDefaults

    private let configurationPersistenceActor: WallpaperPersistenceActor
    let persistenceStatus = SettingsPersistenceStatus()
    private var pendingWriteTasks: [SettingsPersistenceDomain: Task<Void, Never>] = [:]

    /// Per-store monotonic counters: the actor drops any submission whose generation is older than the last it committed, so a stale in-flight write can't overwrite a newer MainActor mutation (or resurrect a reset).
    private var configurationWriteGeneration: UInt64 = 0
    private var globalSettingsWriteGeneration: UInt64 = 0
    private var bookmarksWriteGeneration: UInt64 = 0
    private var schemesWriteGeneration: UInt64 = 0

    private enum Keys {
        static let screenConfigurations = "screenConfigurations"
        static let globalSettings = "globalSettings"
        static let lastUsedDirectory = "lastUsedDirectory"
        static let aerialsDirectoryBookmark = "AerialsLibrary.DirectoryBookmark"
        static let bookmarks = "WallpaperBookmarks.v1"
        static let screenSchemes = "ScreenSchemes.v1"
        static let trustedHosts = "TrustedHTMLHosts.v1"
        static let wpeEngineAssetsRootBookmark = "WPEEngineAssets.RootBookmark.v1"
        /// Set only when the engine assets came from the in-app SteamCMD download (the pruned container install).
        static let wpeEngineAssetsManagedBuildID = "WPEEngineAssets.ManagedBuildID.v1"
        static let appLanguage = AppLanguagePreference.storageKey
        /// Bumped each time we successfully migrate a blob out of UserDefaults into the file store.
        static let configMigrationVersion = "Settings.MigrationVersion"
        /// Separate from `configMigrationVersion` (that one only gates the one-time UserDefaults→file move).
        static let blobSchemaVersion = "Settings.BlobSchemaVersion"
    }

    /// Current migration revision. Bump when introducing a new file-backed
    /// store or schema change so the migration path re-runs on next launch.
    private static let currentMigrationVersion = 1

    private static let currentBlobSchemaVersion = 1

    init(
        directory: ConfigurationDirectory = ConfigurationDirectory(),
        defaults: UserDefaults = .appScoped(),
        fileManager: FileManager = .default,
        bookmarkResolver: SecurityScopedBookmarkResolver = .shared,
        bookmarkVolumeIsUnavailable: @escaping (Data) -> Bool = SettingsManager.isBookmarkVolumeUnavailable,
        persistWPEBookmarkOwnerRefresh: @MainActor @escaping (WPEOrigin, Data) -> Void = {
            origin, refreshed in
            _ = BookmarkStore.shared.replaceWPEOriginBookmark(
                workshopID: origin.workshopID,
                matching: origin.sourceFolderBookmark,
                with: refreshed
            )
        }
    ) {
        let screenConfigStore = AtomicFileStore<[ScreenConfiguration]>(
            fileURL: directory.url(for: .screenConfigurations), fileManager: fileManager
        )
        self.screenConfigStore = screenConfigStore
        let globalSettingsStore = AtomicFileStore<GlobalSettings>(
            fileURL: directory.url(for: .globalSettings), fileManager: fileManager
        )
        let wallpaperBookmarksStore = AtomicFileStore<[WallpaperBookmark]>(
            fileURL: directory.url(for: .wallpaperBookmarks), fileManager: fileManager
        )
        let screenSchemesStore = AtomicFileStore<[ScreenScheme]>(
            fileURL: directory.url(for: .screenSchemes), fileManager: fileManager
        )
        self.globalSettingsStore = globalSettingsStore
        self.wallpaperBookmarksStore = wallpaperBookmarksStore
        self.screenSchemesStore = screenSchemesStore
        self.bookmarkResolver = bookmarkResolver
        self.bookmarkVolumeIsUnavailable = bookmarkVolumeIsUnavailable
        self.persistWPEBookmarkOwnerRefresh = persistWPEBookmarkOwnerRefresh
        self.defaults = defaults
        self.configurationPersistenceActor = WallpaperPersistenceActor(
            store: screenConfigStore,
            globalSettingsStore: globalSettingsStore,
            bookmarksStore: wallpaperBookmarksStore,
            schemesStore: screenSchemesStore
        )

        migrateLegacyUserDefaultsIfNeeded()
        stampBlobSchemaVersionIfNeeded()
        migrateLegacyWeatherOverlaysIfNeeded()
    }

    // MARK: - Screen Configurations

    func saveConfiguration(_ configuration: ScreenConfiguration) {
        var configs = loadConfigurations()
        // Several offline panels share the parked screenID; only the fingerprint tells their rows apart.
        let isParked = configuration.screenID == WallpaperConfigurationStore.parkedScreenID
        if let index = configs.firstIndex(where: {
            $0.screenID == configuration.screenID
                && (!isParked || $0.displayFingerprint == configuration.displayFingerprint)
        }) {
            configs[index] = configuration
        } else {
            configs.append(configuration)
        }
        persistConfigurations(configs)
    }

    func replaceAllConfigurations(_ configurations: [ScreenConfiguration]) {
        persistConfigurations(configurations)
    }

    /// clearsDeleteTombstone: true only for an explicit user re-acquire, never for the passive library scan.
    /// thenPersist is awaited after the library is written and before observers are told about it.
    func registerScenePreset(
        _ preset: ScenePreset,
        clearsDeleteTombstone: Bool = false,
        thenPersist: (() async -> Void)? = nil
    ) async {
        var settings = loadGlobalSettings()
        var changed = false
        if clearsDeleteTombstone, case .workshop(let workshopID) = preset.source {
            let kept = settings.deletedWorkshopIDs.filter { $0 != workshopID }
            if kept.count != settings.deletedWorkshopIDs.count {
                settings.deletedWorkshopIDs = kept
                changed = true
            }
        }
        // A re-download brings Steam's title back, but the name is the one part of a Workshop preset the user owns. Refreshing values while keeping the stored name is what makes update-in-place not undo the rename.
        var incoming = preset
        if let stored = settings.scenePresets[preset.id], stored.hasUserAssignedName {
            incoming = incoming.renamed(to: stored.name)
        }
        if settings.scenePresets[incoming.id] != incoming {
            settings.scenePresets[incoming.id] = incoming
            changed = true
        }
        guard changed else {
            await thenPersist?()
            return
        }
        saveGlobalSettings(settings)
        // Awaited, not fired: a non-awaited hook returned while its own write was still in flight, so the notification below could republish {new snapshot + the old increment} and win.
        await thenPersist?()
        reconcileScenePresetSnapshots()
    }

    func removeScenePreset(id: String) {
        var settings = loadGlobalSettings()
        guard let removed = settings.scenePresets.removeValue(forKey: id) else { return }
        // A downloaded preset's folder stays in the SteamCMD download tree, and the library scan walks that tree. Without a tombstone the next visit to the Workshop pane re-registers what was just deleted.
        if case .workshop(let workshopID) = removed.source {
            _ = Self.insertDeleteTombstone(workshopID: workshopID, into: &settings)
        }
        saveGlobalSettings(settings)
        reconcileScenePresetSnapshots()
    }

    /// Renames in place. The id is what configurations point at, so this never
    /// touches the pointer — only the label.
    func renameScenePreset(id: String, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        var settings = loadGlobalSettings()
        guard let preset = settings.scenePresets[id], !trimmed.isEmpty, preset.name != trimmed else {
            return
        }
        settings.scenePresets[id] = preset.renamed(to: trimmed)
        saveGlobalSettings(settings)
        reconcileScenePresetSnapshots()
    }

    /// Matched on the trimmed display name within one base wallpaper. Workshop presets are excluded: their id is their workshop id, so reusing it would overwrite a downloaded item.
    func existingLocalScenePreset(named name: String, baseWorkshopID: String) -> ScenePreset? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return loadGlobalSettings().scenePresets.values.first {
            $0.source == .local
                && $0.baseWorkshopID == baseWorkshopID
                && $0.name.trimmingCharacters(in: .whitespacesAndNewlines)
                    .localizedCaseInsensitiveCompare(trimmed) == .orderedSame
        }
    }

    /// userInfo key of `.scenePresetLibraryDidChange`: `[CGDirectDisplayID: SceneDescriptor]`, each display's active scene before the reconcile.
    static let previousSceneDescriptorsKey = "previousSceneDescriptors"

    func reconcileScenePresetSnapshots() {
        let library = loadGlobalSettings().scenePresets
        // Collected first: once the cache is rewritten, every reader already sees the reconciled descriptors.
        var previous: [CGDirectDisplayID: SceneDescriptor] = [:]
        for configuration in cachedConfigurations ?? [] {
            if case let .scene(descriptor) = configuration.activeWallpaper {
                previous[configuration.screenID] = descriptor
            }
        }
        cachedConfigurations = cachedConfigurations?.map {
            $0.refreshingScenePresets(in: library)
        }
        // Running scene sessions still render the old snapshot until an observer hands them the reconciled descriptor.
        NotificationCenter.default.post(
            name: .scenePresetLibraryDidChange, object: nil, userInfo: [Self.previousSceneDescriptorsKey: previous]
        )
    }

    func loadConfigurations() -> [ScreenConfiguration] {
        if let cached = cachedConfigurations { return cached }
        let library = loadGlobalSettings().scenePresets
        let configs = (screenConfigStore.read() ?? []).map {
            $0.refreshingScenePresets(in: library)
        }
        cachedConfigurations = configs
        return configs
    }

    func getConfiguration(for screenID: CGDirectDisplayID) -> ScreenConfiguration? {
        loadConfigurations().first { $0.screenID == screenID }
    }

    func configurationMemoryRevision(for screenID: CGDirectDisplayID) -> UInt64 {
        _ = loadConfigurations() // Establish the snapshot before issuing a prepare fence.
        return configurationMemoryRevisions[screenID] ?? 0
    }

    /// Updates the in-memory cache synchronously so MainActor readers observe
    /// the new value before this function returns; disk write is queued async.
    private func persistConfigurations(_ configs: [ScreenConfiguration]) {
        cachedConfigurations = configs
        queueWrite(.configurations) { actor, generation in
            try await actor.write(configs, generation: generation)
        }
    }

    private func generation(for domain: SettingsPersistenceDomain, advance: Bool = false) -> UInt64 {
        switch domain {
        case .configurations:
            if advance {
                configurationWriteGeneration &+= 1
            }
            return configurationWriteGeneration
        case .globalSettings:
            if advance {
                globalSettingsWriteGeneration &+= 1
            }
            return globalSettingsWriteGeneration
        case .bookmarks:
            if advance {
                bookmarksWriteGeneration &+= 1
            }
            return bookmarksWriteGeneration
        case .schemes:
            if advance {
                schemesWriteGeneration &+= 1
            }
            return schemesWriteGeneration
        }
    }

    private func queueWrite(
        _ domain: SettingsPersistenceDomain,
        operation: @escaping @Sendable (WallpaperPersistenceActor, UInt64) async throws -> Void
    ) {
        let generation = generation(for: domain, advance: true)
        persistenceStatus.began(domain)
        pendingWriteTasks[domain] = Task { [weak self, configurationPersistenceActor] in
            let failure: String?
            do {
                try await operation(configurationPersistenceActor, generation)
                failure = nil
            } catch {
                failure = LogPrivacyRedactor.scrub(error.localizedDescription)
            }
            // A completion from an older write must not clear a newer dirty value or error.
            guard let self, self.generation(for: domain) == generation else { return }
            persistenceStatus.completed(domain, error: failure)
            pendingWriteTasks.removeValue(forKey: domain)
            if let failure {
                Logger.error("Failed to persist \(String(describing: domain)): \(failure)", category: .settings)
            }
        }
    }

    /// Wait only for submissions present at entry; no sleeps or polling are needed by callers/tests.
    /// A later edit may still be pending, which persistenceStatus continues to report honestly.
    func waitForPendingWrites() async {
        let tasks = Array(pendingWriteTasks.values)
        for task in tasks {
            await task.value
        }
    }

    /// Retry current snapshots, never re-read old disk data over a failed in-memory edit.
    /// Capture all submissions in one MainActor turn before yielding. The return is false
    /// if a failed or newer in-flight submission remains; callers must not call that durable.
    @discardableResult
    func flushPendingWrites() async -> Bool {
        persistConfigurations(loadConfigurations())
        if let settings = cachedGlobalSettings {
            queueWrite(.globalSettings) { actor, generation in
                try await actor.writeGlobalSettings(settings, generation: generation)
            }
        }
        if let bookmarks = cachedWallpaperBookmarks {
            queueWrite(.bookmarks) { actor, generation in
                try await actor.writeBookmarks(bookmarks, generation: generation)
            }
        }
        if let schemes = cachedScreenSchemes {
            queueWrite(.schemes) { actor, generation in
                try await actor.writeSchemes(schemes, generation: generation)
            }
        }
        await waitForPendingWrites()
        return !persistenceStatus.hasUnsavedChanges
    }

    // MARK: - Global Settings

    func saveGlobalSettings(_ settings: GlobalSettings) {
        let previousStartOnLogin = cachedGlobalSettings?.startOnLogin ?? loadGlobalSettings().startOnLogin
        cachedGlobalSettings = settings
        if previousStartOnLogin != settings.startOnLogin {
            loginItemController.apply(startOnLogin: settings.startOnLogin)
        }

        queueWrite(.globalSettings) { actor, generation in
            try await actor.writeGlobalSettings(settings, generation: generation)
        }
    }

    func loadGlobalSettings() -> GlobalSettings {
        if let cached = cachedGlobalSettings { return cached }
        let settings = globalSettingsStore.read() ?? GlobalSettings()
        cachedGlobalSettings = settings
        return settings
    }

    func loadDisplayDefaults() -> DisplayDefaults {
        loadGlobalSettings().displayDefaults
    }

    func saveDisplayDefaults(_ displayDefaults: DisplayDefaults) {
        var settings = loadGlobalSettings()
        settings.displayDefaults = displayDefaults
        saveGlobalSettings(settings)
    }

    func loadMonitorOverlays() -> [String: MonitorOverlayConfiguration] {
        loadGlobalSettings().monitorOverlays
    }

    func saveMonitorOverlays(_ overlays: [String: MonitorOverlayConfiguration]) {
        var settings = loadGlobalSettings()
        settings.monitorOverlays = overlays
        saveGlobalSettings(settings)
    }

    func loadWeatherOverlays() -> [String: WeatherOverlayConfiguration] {
        loadGlobalSettings().weatherOverlays
    }

    func saveWeatherOverlays(_ overlays: [String: WeatherOverlayConfiguration]) {
        var settings = loadGlobalSettings()
        settings.weatherOverlays = overlays
        saveGlobalSettings(settings)
    }

    func loadScreenNames() -> [String: String] {
        loadGlobalSettings().screenNames
    }

    func saveScreenNames(_ names: [String: String]) {
        var settings = loadGlobalSettings()
        settings.screenNames = names
        saveGlobalSettings(settings)
    }

    // MARK: - Wallpaper Engine History (managed library)

    /// clearsDeleteTombstone: pass true only for an explicit user re-acquire (Browse re-download, a pasted-link download, or picking a library folder with the toolbar's add button).
    func recordWPEImport(
        _ entry: WPEHistoryEntry,
        clearsDeleteTombstone: Bool = false,
        preservesHistory: Bool = false
    ) {
        var settings = loadGlobalSettings()
        var entry = entry
        let entryOrigin = entry.origin
        let isSameItem = { (other: WPEHistoryEntry) in Self.isSameWPEItem(entryOrigin, other.origin) }
        let previous = settings.recentWPEImports.first(where: isSameItem)
        if entry.sizeBytes == nil {
            entry.sizeBytes = previous?.sizeBytes
        }
        // Relink keeps importedAt/lastUsed (update badge uses remoteEpoch > importedAt).
        // Genuine re-import restamps importedAt for matchingImportedAt delete identity.
        if preservesHistory, let previous {
            entry = WPEHistoryEntry(
                origin: entry.origin,
                importedAt: previous.importedAt,
                lastUsedAt: entry.lastUsedAt ?? previous.lastUsedAt,
                sizeBytes: entry.sizeBytes
            )
        }
        var recent = settings.recentWPEImports.filter { !isSameItem($0) }
        recent.insert(entry, at: 0)
        settings.recentWPEImports = recent
        if clearsDeleteTombstone {
            settings.deletedWorkshopIDs.removeAll { $0 == entry.origin.workshopID }
        }
        saveGlobalSettings(settings)
        NotificationCenter.default.post(name: .wpeHistoryDidChange, object: nil)
    }

    /// A Steam folder id alone decides sameness (a manifest's id can name another folder's item);
    /// a local copy whose manifest still names a Steam item is a different entry from that item.
    static func isSameWPEItem(_ lhs: WPEOrigin, _ rhs: WPEOrigin) -> Bool {
        switch (steamFolderItemID(lhs), steamFolderItemID(rhs)) {
        case let (lhsFolderID?, rhsFolderID?):
            lhsFolderID == rhsFolderID
        case (nil, nil):
            lhs.workshopID == rhs.workshopID
        default:
            false
        }
    }

    /// The entry already holding `workshopID` from another folder that still exists; nil when there is none or
    /// when `sourceFolder` is already some entry's folder (a refresh). An entry whose folder no longer resolves never conflicts.
    /// `folders` nil resolves each entry as it is reached.
    func conflictingWPEImport(workshopID: String, sourceFolder: URL, folders: WPESourceFolderPaths? = nil) -> WPEHistoryEntry? {
        let recent = loadGlobalSettings().recentWPEImports
        let sameID = recent.filter { $0.origin.workshopID == workshopID }
        guard !sameID.isEmpty else { return nil }
        let folders = folders ?? WPESourceFolderPaths(settings: self)
        let target = Self.normalizedFolderPath(sourceFolder)
        var conflict: WPEHistoryEntry?
        // Same-id entries first so a rescan of an imported item stops at its own entry without resolving the rest.
        for entry in sameID + recent.filter({ $0.origin.workshopID != workshopID }) {
            guard let folder = folders.path(of: entry) else { continue }
            if folder == target {
                return nil
            }
            if conflict == nil, entry.origin.workshopID == workshopID {
                conflict = entry
            }
        }
        return conflict
    }

    /// Each local copy paired with a Steam item of the same Workshop id whose folder is still on disk.
    func localCopiesShadowedBySteam(folders: WPESourceFolderPaths? = nil) -> [(local: WPEHistoryEntry, steam: WPEHistoryEntry)] {
        let recent = loadGlobalSettings().recentWPEImports
        let folders = folders ?? WPESourceFolderPaths(settings: self)
        return recent.compactMap { local in
            guard Self.steamFolderItemID(local.origin) == nil,
                  let steam = recent.first(where: {
                      $0.origin.workshopID == local.origin.workshopID
                          && Self.steamFolderItemID($0.origin) != nil
                          && folders.path(of: $0) != nil
                  }) else { return nil }
            return (local, steam)
        }
    }

    /// Resolves every current history entry's bookmark once, for one scan to share.
    func sourceFolderPaths() -> WPESourceFolderPaths {
        let folders = WPESourceFolderPaths(settings: self)
        for entry in loadGlobalSettings().recentWPEImports {
            _ = folders.path(of: entry)
        }
        return folders
    }

    /// Unlike `removeWPEImport`, leaves the delete tombstones alone: the item stays in the library as `replacement`.
    func replaceWPEImport(_ old: WPEHistoryEntry, with replacement: WPEHistoryEntry) {
        func isEntry(_ target: WPEHistoryEntry) -> (WPEHistoryEntry) -> Bool {
            {
                $0.origin.workshopID == target.origin.workshopID && $0.importedAt == target.importedAt
                    && $0.origin.sourceFolderBookmark == target.origin.sourceFolderBookmark
            }
        }
        var settings = loadGlobalSettings()
        guard let oldIndex = settings.recentWPEImports.firstIndex(where: isEntry(old)) else { return }
        let removed = settings.recentWPEImports.remove(at: oldIndex)
        if let index = settings.recentWPEImports.firstIndex(where: isEntry(replacement)) {
            let kept = settings.recentWPEImports[index].lastUsedAt
            settings.recentWPEImports[index].lastUsedAt = [kept, removed.lastUsedAt].compactMap(\.self).max()
        } else {
            var entry = replacement
            entry.lastUsedAt = [replacement.lastUsedAt, removed.lastUsedAt].compactMap(\.self).max()
            settings.recentWPEImports.insert(entry, at: oldIndex)
        }
        saveGlobalSettings(settings)
        NotificationCenter.default.post(name: .wpeHistoryDidChange, object: nil)
    }

    func existingSourceFolderPath(of origin: WPEOrigin) -> String? {
        guard case let .success(resolved) = bookmarkResolver.resolve(origin.sourceFolderBookmark, target: .transient) else { return nil }
        return SecurityScopedBookmarkResolver.withScopedAccess(resolved.url) { _ in
            FileManager.default.fileExists(atPath: resolved.url.path(percentEncoded: false))
                ? Self.normalizedFolderPath(resolved.url)
                : nil
        }
    }

    private static func normalizedFolderPath(_ url: URL) -> String {
        url.standardizedFileURL.resolvingSymlinksInPath().path
    }

    private static func steamFolderItemID(_ origin: WPEOrigin) -> String? {
        #if LITE_BUILD
        return nil
        #else
        return origin.steamFolderItemID
        #endif
    }

    func updateWPEImportSize(workshopID: String, matchingImportedAt importedAt: Date, sizeBytes: Int64) {
        var settings = loadGlobalSettings()
        guard let index = settings.recentWPEImports.firstIndex(where: {
            $0.origin.workshopID == workshopID && $0.importedAt == importedAt
        }), settings.recentWPEImports[index].sizeBytes == nil else { return }
        settings.recentWPEImports[index].sizeBytes = sizeBytes
        saveGlobalSettings(settings)
    }

    @discardableResult
    func replaceWPEHistorySourceBookmark(
        workshopID: String,
        matching original: Data,
        with refreshed: Data
    ) -> Bool {
        var settings = loadGlobalSettings()
        var didReplace = false
        for index in settings.recentWPEImports.indices {
            guard let updated = settings.recentWPEImports[index]
                .replacingSourceFolderBookmark(
                    workshopID: workshopID,
                    matching: original,
                    with: refreshed
                ) else { continue }
            settings.recentWPEImports[index] = updated
            didReplace = true
        }
        guard didReplace else { return false }
        saveGlobalSettings(settings)
        NotificationCenter.default.post(name: .wpeHistoryDidChange, object: nil)
        return true
    }

    /// Upper bound on the delete-tombstone list.
    static let maxDeletedWorkshopTombstones = 500

    /// SKU-neutral equivalent of `WPEPathSafety.isSafeProjectID` (which is Pro-only): rejects empty, `.`/`..`, and any separator so a persisted tombstone can never carry an escape-capable component.
    private static func isSafeProjectIDComponent(_ value: String) -> Bool {
        !value.isEmpty
            && value != "."
            && value != ".."
            && !value.contains("/")
            && !value.contains("\\")
    }

    func recordWPEDeleteTombstone(workshopID: String) {
        // Validate persisted tombstones here because the Pro-only path validator is unavailable to Lite.
        var settings = loadGlobalSettings()
        guard Self.insertDeleteTombstone(workshopID: workshopID, into: &settings) else { return }
        saveGlobalSettings(settings)
    }

    @discardableResult
    func removeWPEImport(
        workshopID: String,
        matchingImportedAt importedAt: Date,
        recordingDeleteTombstone: Bool = true
    ) -> Bool {
        var settings = loadGlobalSettings()
        guard let index = settings.recentWPEImports.firstIndex(where: {
            $0.origin.workshopID == workshopID && $0.importedAt == importedAt
        }) else { return false }
        let removed = settings.recentWPEImports.remove(at: index)
        // The download scan checks tombstones against Steam folder names only, so an entry outside
        // Steam's layout has no download to suppress; its manifest id may name a Steam item still installed.
        if recordingDeleteTombstone, let tombstone = Self.steamFolderItemID(removed.origin) {
            _ = Self.insertDeleteTombstone(workshopID: tombstone, into: &settings)
        }
        saveGlobalSettings(settings)
        NotificationCenter.default.post(name: .wpeHistoryDidChange, object: nil)
        return true
    }

    func removeWPEImport(workshopID: String) {
        var settings = loadGlobalSettings()
        let previous = settings.recentWPEImports
        settings.recentWPEImports.removeAll { $0.origin.workshopID == workshopID }
        guard settings.recentWPEImports != previous else { return }
        saveGlobalSettings(settings)
        NotificationCenter.default.post(name: .wpeHistoryDidChange, object: nil)
    }


    @discardableResult
    private static func insertDeleteTombstone(
        workshopID: String,
        into settings: inout GlobalSettings
    ) -> Bool {
        guard isSafeProjectIDComponent(workshopID),
              !settings.deletedWorkshopIDs.contains(workshopID) else { return false }
        settings.deletedWorkshopIDs.insert(workshopID, at: 0)
        if settings.deletedWorkshopIDs.count > maxDeletedWorkshopTombstones {
            settings.deletedWorkshopIDs = Array(
                settings.deletedWorkshopIDs.prefix(maxDeletedWorkshopTombstones)
            )
        }
        return true
    }

    // MARK: - Wallpaper Engine Assets Root Bookmark

    func saveWPEEngineAssetsBookmark(_ bookmark: Data) {
        defaults.set(bookmark, forKey: Keys.wpeEngineAssetsRootBookmark)
        NotificationCenter.default.post(name: .wpeEngineAssetsBookmarkDidChange, object: nil)
    }

    func loadWPEEngineAssetsBookmark() -> Data? {
        defaults.data(forKey: Keys.wpeEngineAssetsRootBookmark)
    }

    func clearWPEEngineAssetsBookmark() {
        defaults.removeObject(forKey: Keys.wpeEngineAssetsRootBookmark)
        NotificationCenter.default.post(name: .wpeEngineAssetsBookmarkDidChange, object: nil)
    }

    /// Steam `buildid` of the in-app-downloaded engine assets, or nil when no managed install is present.
    var wpeEngineAssetsManagedBuildID: String? {
        get { defaults.string(forKey: Keys.wpeEngineAssetsManagedBuildID) }
        set {
            if let newValue, !newValue.isEmpty {
                defaults.set(newValue, forKey: Keys.wpeEngineAssetsManagedBuildID)
            } else {
                defaults.removeObject(forKey: Keys.wpeEngineAssetsManagedBuildID)
            }
            NotificationCenter.default.post(name: .wpeEngineAssetsBookmarkDidChange, object: nil)
        }
    }

    // MARK: - Clean Settings

    func cleanSettingsForScreen(_ screenID: CGDirectDisplayID) {
        var configs = loadConfigurations()
        configs.removeAll { $0.screenID == screenID }
        persistConfigurations(configs)
    }

    func cleanAllSettings(applyLoginSetting: Bool = true) {
        cachedGlobalSettings = GlobalSettings()
        cachedConfigurations = []
        cachedWallpaperBookmarks = []
        cachedScreenSchemes = []

        persistenceStatus.discardedPriorEditsForReset()
        pendingWriteTasks.removeAll()
        // Do not cancel older writes: the bumped generations below fence actor ordering.
        // Route deletes through the same serial actor with bumped generations so an in-flight async write (older generation) can't resurrect the file after the reset.
        configurationWriteGeneration &+= 1
        globalSettingsWriteGeneration &+= 1
        bookmarksWriteGeneration &+= 1
        schemesWriteGeneration &+= 1
        let configGeneration = configurationWriteGeneration
        let globalGeneration = globalSettingsWriteGeneration
        let bookmarksGeneration = bookmarksWriteGeneration
        let schemesGeneration = schemesWriteGeneration
        Task { [configurationPersistenceActor] in
            await configurationPersistenceActor.delete(generation: configGeneration)
            await configurationPersistenceActor.deleteGlobalSettings(generation: globalGeneration)
            await configurationPersistenceActor.deleteBookmarks(generation: bookmarksGeneration)
            await configurationPersistenceActor.deleteSchemes(generation: schemesGeneration)
        }

        defaults.removeObject(forKey: Keys.screenConfigurations)
        defaults.removeObject(forKey: Keys.globalSettings)
        defaults.removeObject(forKey: Keys.aerialsDirectoryBookmark)
        defaults.removeObject(forKey: Keys.bookmarks)
        defaults.removeObject(forKey: Keys.screenSchemes)
        defaults.removeObject(forKey: Keys.trustedHosts)
        defaults.removeObject(forKey: Keys.wpeEngineAssetsRootBookmark)
        defaults.removeObject(forKey: Keys.appLanguage)
        defaults.removeObject(forKey: Keys.wpeEngineAssetsManagedBuildID)
        defaults.removeObject(forKey: Keys.configMigrationVersion)
        defaults.removeObject(forKey: Keys.blobSchemaVersion)
        // WPELibrary.RootBookmark.v1 has no owner: delete it and sharedManagerIsIsolatedFromStandardDefaults passes for the wrong reason.
        defaults.removeObject(forKey: "WPELibrary.RootBookmark.v1")
        defaults.removeObject(forKey: "loomscreen.sidebar.displayOrder.v1") // no reader left; stale value only
        defaults.removeObject(forKey: WallpaperTransitionChoice.defaultsKey)
        defaults.removeObject(forKey: WallpaperOpeningChoice.defaultsKey)
        defaults.removeObject(forKey: "monitor.source.claude.bookmark")      // SourceAuthorization
        defaults.removeObject(forKey: "monitor.source.codex.bookmark")       // SourceAuthorization
        defaults.removeObject(forKey: "loomscreen.savedLibrary.selectedTab.v1") // Saved page tab; nothing reads it now

        defaults.removeObject(forKey: WorkshopBookmarkStore.preferencesKey)
        defaults.removeObject(forKey: LibraryBookmarkStore.preferencesKey)
        defaults.removeObject(forKey: SavedLibraryModel.bookmarksMigratedKey)
        LibraryBookmarkStore.shared.resetAfterSettingsCleared()
        #if !LITE_BUILD
        WorkshopBookmarkStore.shared.resetAfterSettingsCleared()
        #endif
        BookmarkStore.shared.resetAfterSettingsCleared()
        SchemeStore.shared.resetAfterSettingsCleared()
        // The archives are gone, so every cover file they named is orphaned.
        WallpaperCoverStore.shared.removeAll()
        TrustedHostStore.shared.resetAfterSettingsCleared()
        if applyLoginSetting {
            loginItemController.apply(startOnLogin: false)
        }
    }

    // MARK: - Legacy Migration

    private func migrateLegacyUserDefaultsIfNeeded() {
        let storedVersion = defaults.integer(forKey: Keys.configMigrationVersion)
        guard storedVersion < Self.currentMigrationVersion else { return }

        var allSucceeded = true
        allSucceeded = seedStoreFromUserDefaults(
            store: screenConfigStore,
            legacyKey: Keys.screenConfigurations,
            label: "screenConfigurations"
        ) && allSucceeded
        allSucceeded = seedStoreFromUserDefaults(
            store: globalSettingsStore,
            legacyKey: Keys.globalSettings,
            label: "globalSettings"
        ) && allSucceeded
        allSucceeded = seedStoreFromUserDefaults(
            store: wallpaperBookmarksStore,
            legacyKey: Keys.bookmarks,
            label: "wallpaperBookmarks"
        ) && allSucceeded

        guard allSucceeded else {
            Logger.error(
                "SettingsManager migration v\(Self.currentMigrationVersion) DID NOT complete cleanly; will retry on next launch",
                category: .settings
            )
            return
        }

        defaults.set(Self.currentMigrationVersion, forKey: Keys.configMigrationVersion)
        Logger.info(
            "SettingsManager migration v\(Self.currentMigrationVersion) complete",
            category: .settings
        )
    }

    /// Returns `true` if the seed step succeeded — either the legacy blob was absent (nothing to do) or it was successfully written to the file store.
    private func seedStoreFromUserDefaults<V: Codable>(
        store: AtomicFileStore<V>,
        legacyKey: String,
        label: String
    ) -> Bool {
        guard !store.hasPersistedValue else { return true }
        guard let data = defaults.data(forKey: legacyKey) else { return true }
        do {
            try store.writeRaw(data)
            Logger.info(
                "Migrated \(label) from UserDefaults → file (\(data.count) bytes)",
                category: .settings
            )
            return true
        } catch {
            Logger.error(
                "Failed to migrate \(label): \(error.localizedDescription)",
                category: .settings
            )
            return false
        }
    }

    /// Also run after a backup import: an older `.lwconfig` still carries weather on its configurations.
    func migrateLegacyWeatherOverlaysIfNeeded() {
        var settings = loadGlobalSettings()
        guard let migrated = WeatherOverlayConfiguration.migratingLegacy(
            configurations: loadConfigurations(),
            into: settings.weatherOverlays
        ) else { return }
        settings.weatherOverlays = migrated
        saveGlobalSettings(settings)
        Logger.info("Copied legacy weather layers out of display configurations", category: .settings)
    }

    private func stampBlobSchemaVersionIfNeeded() {
        let storedVersion = defaults.integer(forKey: Keys.blobSchemaVersion)
        guard storedVersion < Self.currentBlobSchemaVersion else { return }
        defaults.set(Self.currentBlobSchemaVersion, forKey: Keys.blobSchemaVersion)
    }

    // MARK: - User Preferences

    func saveLastUsedDirectory(_ url: URL) {
        defaults.set(url.path(percentEncoded: false), forKey: Keys.lastUsedDirectory)
    }

    func getLastUsedDirectory() -> URL? {
        guard let path = defaults.string(forKey: Keys.lastUsedDirectory) else {
            return nil
        }
        let url = URL(fileURLWithPath: path)
        if url.exists {
            return url
        }
        Logger.info("Last used directory no longer exists: \(path)", category: .fileAccess)
        return nil
    }

    // MARK: - Apple Aerials Library

    func saveAerialsDirectoryBookmark(_ bookmarkData: Data) {
        defaults.set(bookmarkData, forKey: Keys.aerialsDirectoryBookmark)
    }

    func loadAerialsDirectoryBookmark() -> Data? {
        defaults.data(forKey: Keys.aerialsDirectoryBookmark)
    }

    func clearAerialsDirectoryBookmark() {
        defaults.removeObject(forKey: Keys.aerialsDirectoryBookmark)
    }

    // MARK: - Wallpaper Bookmarks

    func loadWallpaperBookmarks() -> [WallpaperBookmark] {
        if let cached = cachedWallpaperBookmarks { return cached }
        let bookmarks = wallpaperBookmarksStore.read() ?? []
        cachedWallpaperBookmarks = bookmarks
        return bookmarks
    }

    /// Cache is updated synchronously (so a subsequent `loadWallpaperBookmarks`
    /// can't read the not-yet-flushed disk copy); the write is queued async.
    func saveWallpaperBookmarks(_ bookmarks: [WallpaperBookmark]) {
        cachedWallpaperBookmarks = bookmarks
        queueWrite(.bookmarks) { actor, generation in
            try await actor.writeBookmarks(bookmarks, generation: generation)
        }
    }

    // MARK: - Screen Schemes

    func loadScreenSchemes() -> [ScreenScheme] {
        if let cached = cachedScreenSchemes {
            return cached
        }
        let schemes = screenSchemesStore.read() ?? []
        cachedScreenSchemes = schemes
        return schemes
    }

    func saveScreenSchemes(_ schemes: [ScreenScheme]) {
        cachedScreenSchemes = schemes
        queueWrite(.schemes) { actor, generation in
            try await actor.writeSchemes(schemes, generation: generation)
        }
    }

    // MARK: - Trusted HTML Hosts

    func loadTrustedHosts() -> [String] {
        defaults.stringArray(forKey: Keys.trustedHosts) ?? []
    }

    func saveTrustedHosts(_ hosts: [String]) {
        defaults.set(hosts, forKey: Keys.trustedHosts)
    }
}

/// History entries' existing folder paths, each entry's bookmark resolved at most once; holds paths, never resolved URLs.
@MainActor
final class WPESourceFolderPaths {
    private struct Key: Hashable {
        let workshopID: String
        let importedAt: Date
        let bookmark: Data
    }

    private let settings: SettingsManager
    /// A nil value is an entry whose folder is gone or whose bookmark no longer resolves.
    private var paths: [Key: String?] = [:]

    init(settings: SettingsManager) {
        self.settings = settings
    }

    func path(of entry: WPEHistoryEntry) -> String? {
        let key = Key(workshopID: entry.origin.workshopID, importedAt: entry.importedAt, bookmark: entry.origin.sourceFolderBookmark)
        if let known = paths[key] {
            return known
        }
        let path = settings.existingSourceFolderPath(of: entry.origin)
        paths.updateValue(path, forKey: key)
        return path
    }
}

// MARK: - URL Extension
extension URL {
    var exists: Bool {
        FileManager.default.fileExists(atPath: path(percentEncoded: false))
    }
}
