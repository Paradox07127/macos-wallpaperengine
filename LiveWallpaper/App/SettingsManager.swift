import Foundation
import CoreGraphics
import AppKit
import AVFoundation
import LiveWallpaperCore
import ServiceManagement

@MainActor
final class SettingsManager {
    static let shared = SettingsManager()

    private var cachedGlobalSettings: GlobalSettings?
    private var cachedConfigurations: [ScreenConfiguration]?
    private var cachedWallpaperBookmarks: [WallpaperBookmark]?

    /// Three big JSON blobs that used to live in `UserDefaults`.
    private let screenConfigStore: AtomicFileStore<[ScreenConfiguration]>
    private let globalSettingsStore: AtomicFileStore<GlobalSettings>
    private let wallpaperBookmarksStore: AtomicFileStore<[WallpaperBookmark]>
    let bookmarkResolver: SecurityScopedBookmarkResolver
    private let loginItemController = LoginItemController()
    let persistWPEBookmarkOwnerRefresh: @MainActor (WPEOrigin, Data) -> Void
    private let defaults: UserDefaults

    /// Serial off-MainActor writer for all three file stores (configs, global settings, bookmarks).
    private let configurationPersistenceActor: WallpaperPersistenceActor

    /// Per-store monotonic counters: the actor drops any submission whose generation is older than the last it committed, so a stale in-flight write can't overwrite a newer MainActor mutation (or resurrect a reset).
    private var configurationWriteGeneration: UInt64 = 0
    private var globalSettingsWriteGeneration: UInt64 = 0
    private var bookmarksWriteGeneration: UInt64 = 0

    private enum Keys {
        static let screenConfigurations = "screenConfigurations"
        static let globalSettings = "globalSettings"
        static let lastUsedDirectory = "lastUsedDirectory"
        static let aerialsDirectoryBookmark = "AerialsLibrary.DirectoryBookmark"
        static let bookmarks = "WallpaperBookmarks.v1"
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

    /// Current in-blob schema revision.
    private static let currentBlobSchemaVersion = 1

    init(
        directory: ConfigurationDirectory = ConfigurationDirectory(),
        defaults: UserDefaults = .appScoped(),
        bookmarkResolver: SecurityScopedBookmarkResolver = .shared,
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
            fileURL: directory.url(for: .screenConfigurations)
        )
        self.screenConfigStore = screenConfigStore
        let globalSettingsStore = AtomicFileStore<GlobalSettings>(
            fileURL: directory.url(for: .globalSettings)
        )
        let wallpaperBookmarksStore = AtomicFileStore<[WallpaperBookmark]>(
            fileURL: directory.url(for: .wallpaperBookmarks)
        )
        self.globalSettingsStore = globalSettingsStore
        self.wallpaperBookmarksStore = wallpaperBookmarksStore
        self.bookmarkResolver = bookmarkResolver
        self.persistWPEBookmarkOwnerRefresh = persistWPEBookmarkOwnerRefresh
        self.defaults = defaults
        self.configurationPersistenceActor = WallpaperPersistenceActor(
            store: screenConfigStore,
            globalSettingsStore: globalSettingsStore,
            bookmarksStore: wallpaperBookmarksStore
        )

        migrateLegacyUserDefaultsIfNeeded()
        stampBlobSchemaVersionIfNeeded()
    }

    // MARK: - Screen Configurations

    func saveConfiguration(_ configuration: ScreenConfiguration) {
        var configs = loadConfigurations()
        if let index = configs.firstIndex(where: { $0.screenID == configuration.screenID }) {
            configs[index] = configuration
        } else {
            configs.append(configuration)
        }
        persistConfigurations(configs)
    }

    func replaceAllConfigurations(_ configurations: [ScreenConfiguration]) {
        persistConfigurations(configurations)
    }

    /// Adds or replaces a preset in the library. Workshop presets key on their
    /// own workshop id, so a re-download updates in place.
    ///
    /// `clearsDeleteTombstone`: same rule as `recordWPEImport` — `true` only
    /// for an explicit user re-acquire, never for the passive library scan.
    /// `thenPersist` is awaited after the library is written and *before*
    /// observers are told about it. A caller that must also update a descriptor — saving
    /// over the applied preset clears the increment it just absorbed — has no
    /// safe order without this: notifying first lets
    /// `handleScenePresetLibraryChange` republish {new snapshot + the old
    /// increment still on disk} in a Task that races the caller's own write,
    /// and persisting first is worse, because `refreshingPresetSnapshot` drops
    /// a preset id the library does not have yet.
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
        // A re-download brings Steam's title back, but the name is the one part
        // of a Workshop preset the user owns — `renameScenePreset` treats it as
        // a local label. Refreshing values while keeping the stored name is what
        // makes "update in place" not mean "undo the rename".
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
        // Awaited, not fired: the hook's whole job is to get the descriptor on
        // disk before observers are told the library moved. A non-awaited hook
        // returned while its own write was still in flight, so the notification
        // below could republish {new snapshot + the old increment} and win.
        await thenPersist?()
        reconcileScenePresetSnapshots()
    }

    /// Drops a preset from the library. Configurations pointing at it fall back
    /// to their own increment on the next reconcile — `refreshingScenePresets`
    /// treats a missing id as "no preset", so nothing is left applying values
    /// that no longer exist.
    func removeScenePreset(id: String) {
        var settings = loadGlobalSettings()
        guard let removed = settings.scenePresets.removeValue(forKey: id) else { return }
        // A downloaded preset's folder stays in the SteamCMD download tree, and
        // the library scan walks that tree. Without a tombstone the next visit
        // to the Workshop pane re-registers what was just deleted.
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

    /// The locally saved preset a "save as" would replace, matched on the
    /// trimmed display name within one base wallpaper. Without this, saving the
    /// same name twice produces two entries the picker cannot tell apart.
    ///
    /// Workshop presets are deliberately excluded: their id *is* their workshop
    /// id, so reusing it would overwrite a downloaded item with local values
    /// and the next re-download would silently undo the user's work.
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

    /// Re-maps every cached configuration's preset snapshot against the current
    /// library — in memory, not by dropping the cache, which would force a
    /// synchronous main-actor disk read on the next access. Two callers: the
    /// incremental path (`registerScenePreset`) and configuration import, which
    /// replaces `scenePresets` wholesale through `saveGlobalSettings`. The disk
    /// copies stay stale until the next `loadConfigurations`, which reconciles
    /// on read.
    func reconcileScenePresetSnapshots() {
        let library = loadGlobalSettings().scenePresets
        cachedConfigurations = cachedConfigurations?.map {
            $0.refreshingScenePresets(in: library)
        }
        // `WallpaperConfigurationStore` keeps its own per-display copies, read
        // through this type once and then served from there. Without this the
        // renderer keeps the old snapshot until relaunch, and the next save
        // writes the stale values back to disk.
        NotificationCenter.default.post(name: .scenePresetLibraryDidChange, object: nil)
    }

    func loadConfigurations() -> [ScreenConfiguration] {
        if let cached = cachedConfigurations { return cached }
        // Preset values ride along inside each descriptor so the renderer can
        // stay ignorant of the library; this is where they get reconciled with
        // what the library actually holds now.
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

    /// Updates the in-memory cache synchronously so MainActor readers observe
    /// the new value before this function returns; disk write is queued async.
    private func persistConfigurations(_ configs: [ScreenConfiguration]) {
        configurationWriteGeneration &+= 1
        let generation = configurationWriteGeneration
        cachedConfigurations = configs
        Task { [weak self, configurationPersistenceActor] in
            do {
                try await configurationPersistenceActor.write(configs, generation: generation)
            } catch {
                await MainActor.run {
                    guard let self,
                          self.configurationWriteGeneration == generation else { return }
                    Logger.error(
                        "Failed to persist screen configurations: \(error.localizedDescription)",
                        category: .settings
                    )
                    self.cachedConfigurations = nil
                }
            }
        }
    }

    /// Drains every store routed through the persistence actor before exit so the last MainActor commits (global settings, bookmarks, screen configs) are durable.
    func flushPendingConfigurationWrites() async {
        configurationWriteGeneration &+= 1
        let configGeneration = configurationWriteGeneration
        do {
            try await configurationPersistenceActor.write(loadConfigurations(), generation: configGeneration)
        } catch {
            Logger.error(
                "Final configuration flush failed: \(error.localizedDescription)",
                category: .settings
            )
        }

        if let settings = cachedGlobalSettings {
            globalSettingsWriteGeneration &+= 1
            let generation = globalSettingsWriteGeneration
            do {
                try await configurationPersistenceActor.writeGlobalSettings(settings, generation: generation)
            } catch {
                Logger.error("Final global-settings flush failed: \(error.localizedDescription)", category: .settings)
            }
        }

        if let bookmarks = cachedWallpaperBookmarks {
            bookmarksWriteGeneration &+= 1
            let generation = bookmarksWriteGeneration
            do {
                try await configurationPersistenceActor.writeBookmarks(bookmarks, generation: generation)
            } catch {
                Logger.error("Final bookmarks flush failed: \(error.localizedDescription)", category: .settings)
            }
        }
    }
    
    // MARK: - Global Settings

    /// Updates memory synchronously and queues the disk write off the main actor.
    func saveGlobalSettings(_ settings: GlobalSettings) {
        let previousStartOnLogin = cachedGlobalSettings?.startOnLogin ?? loadGlobalSettings().startOnLogin
        cachedGlobalSettings = settings
        if previousStartOnLogin != settings.startOnLogin {
            loginItemController.apply(startOnLogin: settings.startOnLogin)
        }

        globalSettingsWriteGeneration &+= 1
        let generation = globalSettingsWriteGeneration
        Task { [weak self, configurationPersistenceActor] in
            do {
                try await configurationPersistenceActor.writeGlobalSettings(settings, generation: generation)
                Logger.settingsChanged(setting: "globalSettings", value: "Updated global settings")
            } catch {
                await MainActor.run {
                    guard let self,
                          self.globalSettingsWriteGeneration == generation else { return }
                    Logger.error("Failed to persist global settings: \(error.localizedDescription)", category: .settings)
                    self.cachedGlobalSettings = nil
                }
            }
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

    func loadScreenNames() -> [String: String] {
        loadGlobalSettings().screenNames
    }

    func saveScreenNames(_ names: [String: String]) {
        var settings = loadGlobalSettings()
        settings.screenNames = names
        saveGlobalSettings(settings)
    }

    // MARK: - Wallpaper Engine History (managed library, LRU-bounded)

    /// Upper bound on the managed library.
    static let maxRecentWPEImports = 200

    /// `clearsDeleteTombstone`: pass `true` ONLY for an explicit user re-acquire
    /// (Browse re-download, a pasted-link download, or picking a library folder
    /// with the toolbar's add button).
    func recordWPEImport(
        _ entry: WPEHistoryEntry,
        clearsDeleteTombstone: Bool = false,
        preservesHistory: Bool = false
    ) {
        var settings = loadGlobalSettings()
        var entry = entry
        let previous = settings.recentWPEImports.first {
            $0.origin.workshopID == entry.origin.workshopID
        }
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
        var recent = settings.recentWPEImports.filter {
            $0.origin.workshopID != entry.origin.workshopID
        }
        recent.insert(entry, at: 0)
        if recent.count > Self.maxRecentWPEImports {
            recent = Array(recent.prefix(Self.maxRecentWPEImports))
        }
        settings.recentWPEImports = recent
        if clearsDeleteTombstone {
            settings.deletedWorkshopIDs.removeAll { $0 == entry.origin.workshopID }
        }
        saveGlobalSettings(settings)
        NotificationCenter.default.post(name: .wpeHistoryDidChange, object: nil)
    }

    /// Backfills a single import's measured folder size.
    func updateWPEImportSize(workshopID: String, sizeBytes: Int64) {
        var settings = loadGlobalSettings()
        guard let index = settings.recentWPEImports.firstIndex(where: {
            $0.origin.workshopID == workshopID
        }), settings.recentWPEImports[index].sizeBytes == nil else { return }
        settings.recentWPEImports[index].sizeBytes = sizeBytes
        saveGlobalSettings(settings)
    }

    /// Persists a refreshed source-folder bookmark into every matching WPE history row.
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

    /// SKU-neutral equivalent of `WPEPathSafety.isSafeWorkshopID` (which is Pro-only): rejects empty, `.`/`..`, and any separator so a persisted tombstone can never carry an escape-capable component.
    private static func isSafeWorkshopIDComponent(_ value: String) -> Bool {
        !value.isEmpty
            && value != "."
            && value != ".."
            && !value.contains("/")
            && !value.contains("\\")
            && !value.contains("..")
    }

    /// Records that the user deleted `workshopID`, so the auto-import scan won't resurrect it from a still-present SteamCMD download or library-folder copy.
    func recordWPEDeleteTombstone(workshopID: String) {
        // Validate persisted tombstones here because the Pro-only path validator is unavailable to Lite.
        var settings = loadGlobalSettings()
        guard Self.insertDeleteTombstone(workshopID: workshopID, into: &settings) else { return }
        saveGlobalSettings(settings)
    }

    /// Atomic compare-and-remove for confirmation UIs that captured a concrete library entry.
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
        settings.recentWPEImports.remove(at: index)
        if recordingDeleteTombstone {
            _ = Self.insertDeleteTombstone(workshopID: workshopID, into: &settings)
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
        guard isSafeWorkshopIDComponent(workshopID),
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
        cachedConfigurations = configs
        persistConfigurations(configs)
    }

    func cleanAllSettings(applyLoginSetting: Bool = true) {
        cachedGlobalSettings = GlobalSettings()
        cachedConfigurations = []
        cachedWallpaperBookmarks = []

        // Route deletes through the same serial actor with bumped generations so an in-flight async write (older generation) can't resurrect the file after the reset.
        configurationWriteGeneration &+= 1
        globalSettingsWriteGeneration &+= 1
        bookmarksWriteGeneration &+= 1
        let configGeneration = configurationWriteGeneration
        let globalGeneration = globalSettingsWriteGeneration
        let bookmarksGeneration = bookmarksWriteGeneration
        Task { [configurationPersistenceActor] in
            await configurationPersistenceActor.delete(generation: configGeneration)
            await configurationPersistenceActor.deleteGlobalSettings(generation: globalGeneration)
            await configurationPersistenceActor.deleteBookmarks(generation: bookmarksGeneration)
        }

        defaults.removeObject(forKey: Keys.screenConfigurations)
        defaults.removeObject(forKey: Keys.globalSettings)
        defaults.removeObject(forKey: Keys.aerialsDirectoryBookmark)
        defaults.removeObject(forKey: Keys.bookmarks)
        defaults.removeObject(forKey: Keys.trustedHosts)
        defaults.removeObject(forKey: Keys.wpeEngineAssetsRootBookmark)
        defaults.removeObject(forKey: Keys.appLanguage)
        defaults.removeObject(forKey: Keys.wpeEngineAssetsManagedBuildID)
        defaults.removeObject(forKey: Keys.configMigrationVersion)
        defaults.removeObject(forKey: Keys.blobSchemaVersion)
        // Keys owned by other components; literals on purpose (see their owners).
        defaults.removeObject(forKey: "WPELibrary.RootBookmark.v1")          // WPEDependencyMountResolver
        defaults.removeObject(forKey: "loomscreen.sidebar.displayOrder.v1")  // SidebarDisplayOrder.preferencesKey
        defaults.removeObject(forKey: "monitor.source.claude.bookmark")      // SourceAuthorization
        defaults.removeObject(forKey: "monitor.source.codex.bookmark")       // SourceAuthorization

        BookmarkStore.shared.resetAfterSettingsCleared()
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

    /// Reads the last-stamped in-blob schema version and advances it to `currentBlobSchemaVersion`.
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
        bookmarksWriteGeneration &+= 1
        let generation = bookmarksWriteGeneration
        Task { [weak self, configurationPersistenceActor] in
            do {
                try await configurationPersistenceActor.writeBookmarks(bookmarks, generation: generation)
            } catch {
                await MainActor.run {
                    guard let self,
                          self.bookmarksWriteGeneration == generation else { return }
                    Logger.error("Failed to persist wallpaper bookmarks: \(error.localizedDescription)", category: .settings)
                    self.cachedWallpaperBookmarks = nil
                }
            }
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

// MARK: - URL Extension
extension URL {
    var exists: Bool {
        FileManager.default.fileExists(atPath: path(percentEncoded: false))
    }
}
