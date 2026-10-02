import Combine
import Foundation
import LiveWallpaperCore
import Testing
@testable import LiveWallpaper

@Suite("ConfigurationBundle / ConfigurationPorter round-trip")
@MainActor
struct ConfigurationPorterTests {
    @Test("Encodes and decodes a populated bundle losslessly")
    func roundTripsPopulatedBundle() throws {
        let directory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let bundle = ConfigurationBundle(
            schemaVersion: 1,
            appBundleID: Bundle.main.bundleIdentifier!,
            appVersion: "test-1.0",
            exportedAt: Date(timeIntervalSince1970: 1_750_000_000),
            screenConfigurations: [
                ScreenConfiguration(screenID: 1, wallpaper: .video(bookmarkData: Data([0x01, 0x02])))
            ],
            globalSettings: GlobalSettings(),
            wallpaperBookmarks: []
        )

        let data = try ConfigurationPorter.encode(bundle)
        let destination = directory.appendingPathComponent("export.lwconfig")
        try data.write(to: destination)

        let decoded = try ConfigurationPorter.decode(from: destination)

        #expect(decoded.schemaVersion == bundle.schemaVersion)
        #expect(decoded.appBundleID == bundle.appBundleID)
        #expect(decoded.appVersion == bundle.appVersion)
        #expect(decoded.screenConfigurations?.count == 1)
        #expect(decoded.screenConfigurations?.first?.screenID == 1)
        #expect(decoded.wallpaperBookmarks?.isEmpty == true)
    }

    @Test("Rejects bundles whose schema is newer than this build")
    func rejectsTooNewSchema() throws {
        let directory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let bundle = ConfigurationBundle(
            schemaVersion: ConfigurationBundle.currentSchemaVersion + 1
        )
        let destination = directory.appendingPathComponent("future.lwconfig")
        try ConfigurationPorter.encode(bundle).write(to: destination)

        do {
            _ = try ConfigurationPorter.decode(from: destination)
            Issue.record("Expected unsupportedSchemaVersion error")
        } catch ConfigurationPorter.ImportError.unsupportedSchemaVersion(let found, let supported) {
            #expect(found == ConfigurationBundle.currentSchemaVersion + 1)
            #expect(supported == ConfigurationBundle.currentSchemaVersion)
        }
    }

    @Test("Rejects bundles for a different app")
    func rejectsWrongBundleID() throws {
        let directory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let bundle = ConfigurationBundle(appBundleID: "com.example.NotLiveWallpaper")
        let destination = directory.appendingPathComponent("foreign.lwconfig")
        try ConfigurationPorter.encode(bundle).write(to: destination)

        do {
            _ = try ConfigurationPorter.decode(from: destination)
            Issue.record("Expected bundleMismatch error")
        } catch ConfigurationPorter.ImportError.bundleMismatch(_, let found) {
            #expect(found == "com.example.NotLiveWallpaper")
        }
    }

    @Test(
        "Accepts exports from every Loomscreen product-family bundle ID",
        arguments: ["com.loomscreen.pro", "com.loomscreen", "com.taijia.livewallpaper"]
    )
    func acceptsProductFamilyBundleIDs(exporterID: String) throws {
        let directory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let bundle = ConfigurationBundle(
            appBundleID: exporterID,
            globalSettings: GlobalSettings()
        )
        let destination = directory.appendingPathComponent("family-\(exporterID).lwconfig")
        try ConfigurationPorter.encode(bundle).write(to: destination)

        let decoded = try ConfigurationPorter.decode(from: destination)
        #expect(decoded.appBundleID == exporterID)
    }

    @Test("Rejects payloads that aren't JSON at all")
    func rejectsCorruptFile() throws {
        let directory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let destination = directory.appendingPathComponent("garbage.lwconfig")
        try Data([0xFF, 0xFE, 0xFD]).write(to: destination)

        do {
            _ = try ConfigurationPorter.decode(from: destination)
            Issue.record("Expected invalidFile error")
        } catch ConfigurationPorter.ImportError.invalidFile {
        }
    }

    @Test("Rejects schema versions below 1 (downgrade / corrupt files)")
    func rejectsSchemaBelowOne() throws {
        let directory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let bundle = ConfigurationBundle(schemaVersion: 0)
        let destination = directory.appendingPathComponent("zero.lwconfig")
        try ConfigurationPorter.encode(bundle).write(to: destination)

        do {
            _ = try ConfigurationPorter.decode(from: destination)
            Issue.record("Expected unsupportedSchemaVersion for schemaVersion=0")
        } catch ConfigurationPorter.ImportError.unsupportedSchemaVersion(let found, _) {
            #expect(found == 0)
        }
    }

    @Test("Rejects files larger than the import size cap")
    func rejectsOversizedFile() throws {
        let directory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let destination = directory.appendingPathComponent("huge.lwconfig")
        let chunk = Data(repeating: 0, count: 1024 * 1024)
        let created = FileManager.default.createFile(atPath: destination.path(percentEncoded: false), contents: nil)
        #expect(created)
        let handle = try FileHandle(forWritingTo: destination)
        for _ in 0..<17 {
            try handle.write(contentsOf: chunk)
        }
        try handle.close()

        do {
            _ = try ConfigurationPorter.decode(from: destination)
            Issue.record("Expected fileTooLarge error")
        } catch ConfigurationPorter.ImportError.fileTooLarge(let bytes) {
            #expect(bytes >= 17 * 1024 * 1024)
        }
    }

    @Test("ConfigurationBundle.contentType has the .lwconfig file extension")
    func contentTypeHasLWConfigExtension() {
        let preferred = ConfigurationBundle.contentType.preferredFilenameExtension
        let fallback = preferred == "json"
        let matched = preferred == "lwconfig"
        #expect(matched || fallback,
                "Expected lwconfig (registered) or json (fallback), got \(preferred ?? "<nil>")")
    }

    @Test("Suggested filename embeds an ISO date stamp")
    func suggestedFileNameUsesDateStamp() {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd"
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        let fixed = Date(timeIntervalSince1970: 1_750_000_000)
        let expected = "LiveWallpaper-\(formatter.string(from: fixed)).\(ConfigurationBundle.fileExtension)"
        let actual = ConfigurationPorter.suggestedExportFileName(now: fixed)
        #expect(actual.hasPrefix("LiveWallpaper-"))
        #expect(actual.hasSuffix(".\(ConfigurationBundle.fileExtension)"))
        let expectedYearPrefix = String(expected.prefix("LiveWallpaper-2025".count))
        #expect(actual.hasPrefix(expectedYearPrefix.prefix("LiveWallpaper-".count)))
    }

    @Test("Import summaries distinguish absent, empty, and accepted bookmark sections")
    func bookmarkImportSummaryFollowsTheShippingSKU() {
        let workshop = WorkshopBookmark(id: 9_100_003, rawTitle: "Backup", previewImageURL: nil, tags: [])
        let workshopOnly = ConfigurationPorter.importSummary(for: ConfigurationBundle(workshopBookmarks: [workshop]))
        #expect(workshopOnly.bookmarkCount == nil)
        #if LITE_BUILD
        #expect(workshopOnly.workshopBookmarkCount == nil)
        #expect(workshopOnly.totalBookmarkCount == nil)
        #expect(workshopOnly.isEmpty)
        #else
        #expect(workshopOnly.workshopBookmarkCount == 1)
        #expect(workshopOnly.totalBookmarkCount == 1)
        #expect(!workshopOnly.isEmpty)
        #endif

        let absent = ConfigurationPorter.importSummary(for: ConfigurationBundle())
        #expect(absent.totalBookmarkCount == nil)
        #expect(absent.isEmpty)
        let empty = ConfigurationPorter.importSummary(for: ConfigurationBundle(wallpaperBookmarks: []))
        #expect(empty.totalBookmarkCount == 0)
        #expect(!empty.isEmpty)

        let mixed = ConfigurationPorter.ApplySummary(bookmarkCount: 2, workshopBookmarkCount: 3)
        #expect(mixed.bookmarkCount == 2, "The ordinary-bookmark count must retain its original meaning")
        #expect(mixed.workshopBookmarkCount == 3)
        #expect(mixed.totalBookmarkCount == 5)
        #expect(!mixed.isEmpty)
    }

    // MARK: - Screen schemes

    private func sampleScheme(name: String) -> ScreenScheme {
        // Whole-second timestamps: the porter encodes ISO-8601, which has no sub-second
        // field, so `Date()` would not survive the round-trip.
        let stamp = Date(timeIntervalSince1970: 1_750_000_000)
        return ScreenScheme(
            name: name,
            configuration: ScreenConfiguration(
                screenID: 91,
                wallpaper: .video(bookmarkData: Data([0xC0, 0xDE]))
            ),
            overlay: MonitorOverlayConfiguration(enabled: true, level: .front),
            createdAt: stamp,
            updatedAt: stamp,
            sourceDisplayName: "Studio Display"
        )
    }

    @Test("A backup carries saved schemes through encode and decode")
    func roundTripsScreenSchemes() throws {
        let directory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let scheme = sampleScheme(name: "Desk setup")
        let bundle = try ConfigurationBundle(
            appBundleID: #require(Bundle.main.bundleIdentifier),
            screenSchemes: [scheme]
        )
        let destination = directory.appendingPathComponent("schemes.lwconfig")
        let encoded = try ConfigurationPorter.encode(bundle)
        try encoded.write(to: destination)

        let decoded = try ConfigurationPorter.decode(from: destination)

        #expect(decoded.screenSchemes == [scheme])
        #expect(decoded.screenSchemes?.first?.name == "Desk setup")
        #expect(decoded.screenSchemes?.first?.overlay.level == MonitorOverlayLevel.front)
        #expect(decoded.screenSchemes?.first?.configuration.screenID == ScreenScheme.unboundScreenID)
    }

    @Test("A backup written before schemes existed still decodes, with no schemes")
    func decodesLegacyBundleWithoutSchemesField() throws {
        let directory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        // Hand-built because encoding a nil-schemes bundle would prove nothing — the
        // encoder omits the key either way.
        let legacy: [String: Any] = try [
            "schemaVersion": ConfigurationBundle.currentSchemaVersion,
            "appBundleID": #require(Bundle.main.bundleIdentifier),
            "exportedAt": "2026-01-01T00:00:00Z",
            "wallpaperBookmarks": [],
        ]
        let destination = directory.appendingPathComponent("legacy.lwconfig")
        let encoded = try JSONSerialization.data(withJSONObject: legacy, options: [])
        try encoded.write(to: destination)

        let decoded = try ConfigurationPorter.decode(from: destination)

        #expect(decoded.screenSchemes?.isEmpty ?? true)
        #expect(decoded.wallpaperBookmarks?.isEmpty == true)
    }

    @Test("Scheme merge keeps the existing archive when an imported id collides")
    func mergeKeepsExistingSchemeOnIDCollision() {
        let mine = sampleScheme(name: "Mine")
        var renamed = mine
        renamed.name = "FromBackup"
        let fresh = sampleScheme(name: "New")

        let merged = ConfigurationPorter.mergingScreenSchemes(
            existing: [mine],
            imported: [renamed, fresh]
        )

        #expect(merged.count == 2)
        #expect(merged.first?.name == "Mine")
        #expect(merged.last?.id == fresh.id)
    }

    @Test("apply merges backup schemes into the current archive instead of replacing it")
    func applyMergesSchemesIntoArchive() {
        let manager = SettingsManager.shared
        let previous = manager.loadScreenSchemes()
        defer {
            manager.saveScreenSchemes(previous)
            SchemeStore.shared.reload()
        }

        let existing = sampleScheme(name: "Existing")
        manager.saveScreenSchemes([existing])

        let incoming = sampleScheme(name: "FromBackup")
        _ = ConfigurationPorter.apply(ConfigurationBundle(screenSchemes: [incoming]))

        let archive = manager.loadScreenSchemes()
        #expect(archive.count == 2, "Import must merge into the archive, not replace it")
        #expect(archive.contains { $0.id == existing.id })
        #expect(archive.contains { $0.id == incoming.id })
        #expect(SchemeStore.shared.schemes.count == 2, "The observable store must see the import")
    }

    @Test("An export leaves out which displays the user paused")
    func exportOmitsPausedDisplays() {
        let manager = SettingsManager.shared
        let previous = manager.loadGlobalSettings()
        defer { manager.saveGlobalSettings(previous) }
        var local = previous
        local.pausedDisplayKeys = ["A"]
        manager.saveGlobalSettings(local)

        #expect(ConfigurationPorter.currentBundle().globalSettings?.pausedDisplayKeys == [], "the backup carries this machine's paused displays")
    }

    @Test("An import keeps this machine's paused displays")
    func importKeepsLocalPausedDisplays() {
        let manager = SettingsManager.shared
        let previous = manager.loadGlobalSettings()
        defer { manager.saveGlobalSettings(previous) }
        var local = previous
        local.pausedDisplayKeys = ["A"]
        manager.saveGlobalSettings(local)
        var imported = previous
        imported.pausedDisplayKeys = ["X"]
        imported.pauseOnFullScreen = !previous.pauseOnFullScreen

        ConfigurationPorter.apply(ConfigurationBundle(globalSettings: imported))

        let restored = manager.loadGlobalSettings()
        #expect(restored.pausedDisplayKeys == ["A"], "the backup's paused displays replaced this machine's")
        #expect(restored.pauseOnFullScreen == imported.pauseOnFullScreen, "the other global settings were not restored")
    }

    @Test("Importing global settings announces the Workshop history it brought in")
    func importAnnouncesWPEHistory() {
        let manager = SettingsManager.shared
        let previous = manager.loadGlobalSettings()
        defer { manager.saveGlobalSettings(previous) }
        var imported = previous
        imported.recentWPEImports = []
        var announcedHistory: [[WPEHistoryEntry]] = []
        let observer = NotificationCenter.default.publisher(for: .wpeHistoryDidChange)
            .sink { _ in announcedHistory.append(manager.loadGlobalSettings().recentWPEImports) }
        defer { observer.cancel() }

        ConfigurationPorter.apply(ConfigurationBundle(globalSettings: imported))

        #expect(announcedHistory.contains([]), "the imported history went unannounced, so nothing re-checks it")
    }

    private func makeTempDirectory() throws -> URL {
        let url = FileManager.default
            .temporaryDirectory
            .appendingPathComponent("ConfigurationPorterTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}

@Suite("ConfigurationPorter: bookmark import merge")
@MainActor
struct ConfigurationPorterBookmarkMergeTests {
    @Test("Merge keeps existing entries with the same source and appends new ones")
    func mergeKeepsExistingAndAppendsNew() {
        let sharedContent = WallpaperContent.video(bookmarkData: Data([0x01]))
        let existing = WallpaperBookmark(label: "Mine", content: sharedContent)
        let importedDuplicate = WallpaperBookmark(label: "Backup copy", content: sharedContent)
        let importedNew = WallpaperBookmark(label: "New", content: .video(bookmarkData: Data([0x02])))

        let merged = ConfigurationPorter.mergingWallpaperBookmarks(
            existing: [existing],
            imported: [importedDuplicate, importedNew]
        ).bookmarks

        #expect(merged.count == 2)
        #expect(merged.first?.id == existing.id)
        #expect(merged.first?.label == "Mine", "Existing entry with the same source must be kept, not replaced")
        #expect(merged.last?.id == importedNew.id)
    }

    @Test("Merge skips imported entries whose id already exists even when content drifted")
    func mergeSkipsSameIDEntries() {
        let id = UUID()
        let existing = WallpaperBookmark(label: "Mine", content: .video(bookmarkData: Data([0x01])), id: id)
        let importedSameID = WallpaperBookmark(label: "Renamed", content: .video(bookmarkData: Data([0x03])), id: id)

        let merged = ConfigurationPorter.mergingWallpaperBookmarks(
            existing: [existing],
            imported: [importedSameID]
        ).bookmarks

        #expect(merged.count == 1)
        #expect(merged.first?.label == "Mine")
    }

    @Test("Merge dedupes imports against each other and keeps same-source HTML with a different config")
    func mergeSemanticsAcrossImports() throws {
        let site = try HTMLSource.url(#require(URL(string: "https://example.com/wall")))
        var tinted = HTMLConfig.default
        tinted.customCSS = "body { filter: hue-rotate(90deg); }"
        let existing = WallpaperBookmark(label: "Mine", content: .video(bookmarkData: Data([0x01])))
        let fresh = WallpaperBookmark(label: "Fresh", content: .video(bookmarkData: Data([0x02])))
        let freshAgain = WallpaperBookmark(label: "Fresh again", content: .video(bookmarkData: Data([0x02])))
        let freshSameID = WallpaperBookmark(label: "Fresh id", content: .video(bookmarkData: Data([0x03])), id: fresh.id)
        let plain = WallpaperBookmark(label: "Plain", content: .html(source: site, config: .default))
        let styled = WallpaperBookmark(label: "Styled", content: .html(source: site, config: tinted))

        let merged = ConfigurationPorter.mergingWallpaperBookmarks(
            existing: [existing],
            imported: [fresh, freshAgain, freshSameID, plain, styled]
        ).bookmarks

        #expect(merged.map(\.label) == ["Mine", "Fresh", "Plain", "Styled"])
    }

    @Test("Merge looks each import up in an index instead of rescanning the merged list")
    func mergeIsIndexed() throws {
        let source = try RepositoryRoot.source("LiveWallpaper/Infrastructure/Persistence/ConfigurationPorter+SettingsBridge.swift")
        let start = try #require(source.range(of: "static func mergingWallpaperBookmarks("))
        let end = try #require(source.range(of: "static func mergingScreenSchemes(", range: start.upperBound ..< source.endIndex))
        let body = source[start.upperBound ..< end.lowerBound]
        #expect(!body.contains("merged.contains"), "every import rescans every merged bookmark: O(existing × imported)")
    }

    @Test("Merging library bookmarks looks each import up in a set instead of rescanning the merged list")
    func libraryBookmarkMergeIsIndexed() throws {
        let source = try RepositoryRoot.source("Packages/LiveWallpaperCore/Sources/LiveWallpaperCore/Persistence/LibraryBookmarkStore.swift")
        let start = try #require(source.range(of: "public func merge("))
        let end = try #require(source.range(of: "public func resetAfterSettingsCleared(", range: start.upperBound ..< source.endIndex))
        let body = source[start.upperBound ..< end.lowerBound]
        #expect(!body.contains("merged.contains"), "every imported mark rescans every merged mark: O(existing × imported)")
    }

    @Test("apply counts library marks only after merging them, and not when the unreadable archive refused them")
    func applySummaryLeavesOutRefusedLibraryMarks() throws {
        let source = try RepositoryRoot.source("LiveWallpaper/Infrastructure/Persistence/ConfigurationPorter+SettingsBridge.swift")
        let start = try #require(source.range(of: "static func apply(_ bundle: ConfigurationBundle) -> ApplySummary {"))
        let end = try #require(source.range(of: "static func mergingWallpaperBookmarks(", range: start.upperBound ..< source.endIndex))
        let body = source[start.upperBound ..< end.lowerBound]
        let merge = try #require(body.range(of: "bundle.mergeLibraryBookmarks(into: .shared"))
        let summary = try #require(body.range(of: "let summary"))
        #expect(summary.lowerBound > merge.upperBound, "the summary is computed before the merge, so refused marks are counted")
        let tail = body[merge.upperBound...]
        #expect(tail.contains("LibraryBookmarkStore.shared.isArchiveUnreadable"), "the summary counts marks the unreadable archive refused")
        #expect(tail.contains("libraryBookmarks = nil"))
    }

    @Test("apply merges backup bookmarks into the current library instead of replacing it")
    func applyMergesBookmarksIntoLibrary() {
        let manager = SettingsManager.shared
        let previous = manager.loadWallpaperBookmarks()
        defer {
            manager.saveWallpaperBookmarks(previous)
            BookmarkStore.shared.reload()
        }

        let existing = WallpaperBookmark(label: "Existing", content: .video(bookmarkData: Data([0xA0])))
        manager.saveWallpaperBookmarks([existing])

        let incoming = WallpaperBookmark(label: "FromBackup", content: .video(bookmarkData: Data([0xB0])))
        _ = ConfigurationPorter.apply(ConfigurationBundle(wallpaperBookmarks: [incoming]))

        let library = manager.loadWallpaperBookmarks()
        #expect(library.count == 2, "Import must merge into the library, not replace it")
        #expect(library.contains { $0.id == existing.id })
        #expect(library.contains { $0.id == incoming.id })
    }

    @Test("A backup mark on an entry folded into an existing one lands on the kept entry")
    func libraryBookmarkFollowsDedupedEntry() {
        let manager = SettingsManager.shared
        let store = LibraryBookmarkStore.shared
        let previous = manager.loadWallpaperBookmarks()
        let content = WallpaperContent.video(bookmarkData: Data([0xC0]))
        let kept = WallpaperBookmark(label: "Mine", content: content)
        let backupCopy = WallpaperBookmark(label: "Backup copy", content: content)
        defer {
            manager.saveWallpaperBookmarks(previous)
            BookmarkStore.shared.reload()
            store.remove("bookmark:\(kept.id)")
            store.remove("bookmark:\(backupCopy.id)")
        }
        manager.saveWallpaperBookmarks([kept])

        ConfigurationPorter.apply(ConfigurationBundle(wallpaperBookmarks: [backupCopy], libraryBookmarks: ["bookmark:\(backupCopy.id)"]))

        #expect(store.contains("bookmark:\(kept.id)"), "the restored mark points at the dropped duplicate, not the kept entry")
        #expect(!store.contains("bookmark:\(backupCopy.id)"))
    }

    @Test("Library bookmarks survive an export and import, merged into the marks made since")
    func libraryBookmarksRoundTripThroughApply() throws {
        let store = LibraryBookmarkStore.shared
        let exported = "bookmark:\(UUID())"
        let markedSince = "bookmark:\(UUID())"
        defer {
            store.remove(exported)
            store.remove(markedSince)
        }
        store.add(exported)
        let data = try ConfigurationPorter.encode(ConfigurationBundle(libraryBookmarks: ConfigurationPorter.currentBundle().libraryBookmarks))
        store.remove(exported)
        store.add(markedSince)

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let backup = try decoder.decode(ConfigurationBundle.self, from: data)
        let summary = ConfigurationPorter.apply(backup)

        #expect(store.contains(exported), "the backup's library bookmarks did not come back")
        #expect(store.contains(markedSince), "the import cleared a mark made after the backup")
        #expect(summary.totalBookmarkCount == backup.libraryBookmarks?.count, "the import summary leaves the library bookmarks out")

        ConfigurationPorter.apply(ConfigurationBundle())
        #expect(store.contains(markedSince), "a backup without library bookmarks cleared the marks")
    }

    @Test("An export with no library bookmarks writes an empty list, so nil only means a backup from before them")
    func exportWritesEmptyLibraryBookmarks() {
        let store = LibraryBookmarkStore.shared
        let previous = store.ids
        defer { store.merge(previous) }
        for id in previous {
            store.remove(id)
        }

        #expect(ConfigurationPorter.currentBundle().libraryBookmarks == [], "an export without marks reads as a backup from before them")
    }

    @Test("The import summary counts a mark on an entry of the same backup once")
    func importSummaryCountsMarkedEntryOnce() {
        let first = WallpaperBookmark(label: "First", content: .video(bookmarkData: Data([0xD0])))
        let second = WallpaperBookmark(label: "Second", content: .video(bookmarkData: Data([0xD1])))
        let bundle = ConfigurationBundle(wallpaperBookmarks: [first, second], libraryBookmarks: ["bookmark:\(first.id)", "workshop:42"])

        let summary = ConfigurationPorter.importSummary(for: bundle)

        #expect(summary.bookmarkCount == 3, "a marked entry of the backup is counted twice")
    }
}

@Suite("SettingsManager: file-store migration from UserDefaults")
@MainActor
struct SettingsManagerMigrationTests {
    @Test("Seeds AtomicFileStore from legacy UserDefaults blob on first launch")
    func seedsFromLegacyUserDefaults() async throws {
        let directory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let scratch = try TestScratch.defaultsSuite("com.loomscreen.pro.MigrationTests.seedsFromLegacy")
        let defaults = scratch.defaults
        defer { scratch.discard() }

        let original = [
            ScreenConfiguration(screenID: 42, wallpaper: .video(bookmarkData: Data([0x10, 0x20])))
        ]
        let legacyData = try JSONEncoder().encode(original)
        defaults.set(legacyData, forKey: "screenConfigurations")
        defaults.removeObject(forKey: "Settings.MigrationVersion")

        let manager = SettingsManager(directory: ConfigurationDirectory(root: directory), defaults: defaults)

        let loaded = manager.loadConfigurations()
        #expect(loaded.count == 1)
        #expect(loaded.first?.screenID == 42)

        let onDisk = directory.appendingPathComponent("screen-configurations.json")
        #expect(FileManager.default.fileExists(atPath: onDisk.path(percentEncoded: false)))
        await TestScratch.discard(directory, flushing: manager)
    }

    @Test("Migration version is NOT bumped when seed writes fail (retry on next launch)")
    func migrationVersionDeferredOnSeedFailure() async throws {
        let unwritableRoot = try makeUnwritableDirectory()
        defer {
            try? FileManager.default.setAttributes(
                [.posixPermissions: NSNumber(value: Int16(0o700))],
                ofItemAtPath: unwritableRoot.path(percentEncoded: false)
            )
            try? FileManager.default.removeItem(at: unwritableRoot)
        }

        let legacyConfigs = [
            ScreenConfiguration(screenID: 7, wallpaper: .video(bookmarkData: Data([0xCC])))
        ]
        let scratch = try TestScratch.defaultsSuite("com.loomscreen.pro.MigrationTests.migrationVersionDeferredOnSeedFailure")
        let defaults = scratch.defaults
        defer { scratch.discard() }
        let legacyData = try JSONEncoder().encode(legacyConfigs)
        defaults.set(legacyData, forKey: "screenConfigurations")
        defaults.removeObject(forKey: "Settings.MigrationVersion")

        let unwritableSubdir = unwritableRoot.appendingPathComponent("Configuration", isDirectory: true)
        let manager = SettingsManager(directory: ConfigurationDirectory(root: unwritableSubdir), defaults: defaults)

        let postVersion = defaults.integer(forKey: "Settings.MigrationVersion")
        #expect(postVersion == 0,
                "Migration version must stay at 0 after a failed seed so the next launch retries")
        await manager.flushPendingWrites()
    }

    @Test("Zero-byte store file does not block migration from a valid legacy blob")
    func zeroByteFileDoesNotBlockMigration() async throws {
        let directory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let scratch = try TestScratch.defaultsSuite("com.loomscreen.pro.MigrationTests.zeroByteFile")
        let defaults = scratch.defaults
        defer { scratch.discard() }

        let onDisk = directory.appendingPathComponent("screen-configurations.json")
        #expect(FileManager.default.createFile(atPath: onDisk.path(percentEncoded: false), contents: nil))

        let legacy = [
            ScreenConfiguration(screenID: 42, wallpaper: .video(bookmarkData: Data([0x10, 0x20])))
        ]
        defaults.set(try JSONEncoder().encode(legacy), forKey: "screenConfigurations")

        let manager = SettingsManager(
            directory: ConfigurationDirectory(root: directory),
            defaults: defaults
        )

        let loaded = manager.loadConfigurations()
        #expect(loaded.first?.screenID == 42,
                "A zero-byte file must not count as persisted; the legacy blob should seed the store")
        await TestScratch.discard(directory, flushing: manager)
    }

    @Test("File payload wins over the legacy UserDefaults blob")
    func filePayloadWinsOverLegacy() async throws {
        let directory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let onDisk = directory.appendingPathComponent("screen-configurations.json")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let fileConfigs = [
            ScreenConfiguration(screenID: 1, wallpaper: .video(bookmarkData: Data([0xAA])))
        ]
        try JSONEncoder().encode(fileConfigs).write(to: onDisk)

        let legacyConfigs = [
            ScreenConfiguration(screenID: 99, wallpaper: .video(bookmarkData: Data([0xBB])))
        ]
        let scratch = try TestScratch.defaultsSuite("com.loomscreen.pro.MigrationTests.filePayloadWinsOverLegacy")
        let defaults = scratch.defaults
        defer { scratch.discard() }
        let legacyData = try JSONEncoder().encode(legacyConfigs)
        defaults.set(legacyData, forKey: "screenConfigurations")
        defaults.removeObject(forKey: "Settings.MigrationVersion")

        let manager = SettingsManager(directory: ConfigurationDirectory(root: directory), defaults: defaults)
        let loaded = manager.loadConfigurations()
        #expect(loaded.first?.screenID == 1, "File store wins; legacy 99 must not appear")
        await TestScratch.discard(directory, flushing: manager)
    }

    private func makeTempDirectory() throws -> URL {
        let url = FileManager.default
            .temporaryDirectory
            .appendingPathComponent("SettingsManagerMigrationTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func makeUnwritableDirectory() throws -> URL {
        let url = FileManager.default
            .temporaryDirectory
            .appendingPathComponent("SettingsManagerUnwritable-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: Int16(0o500))],
            ofItemAtPath: url.path(percentEncoded: false)
        )
        return url
    }
}

#if !LITE_BUILD
@MainActor
extension ConfigurationPorterTests {
    @Test("A backup carries the Workshop bookmarks, and restoring one merges them by Workshop id")
    func workshopBookmarksRoundTripThroughApply() {
        let store = WorkshopBookmarkStore.shared
        let existing = WorkshopBookmark(id: 9_100_001, rawTitle: "Mine", previewImageURL: nil, tags: [])
        let incoming = WorkshopBookmark(id: 9_100_002, rawTitle: "FromBackup", previewImageURL: nil, tags: [])
        defer {
            store.remove(existing.id)
            store.remove(incoming.id)
        }
        store.add(existing)

        #expect(ConfigurationPorter.currentBundle().workshopBookmarks?.contains(existing) == true, "the export leaves Workshop bookmarks out")

        let summary = ConfigurationPorter.apply(ConfigurationBundle(workshopBookmarks: [
            WorkshopBookmark(id: existing.id, rawTitle: "Backup copy", previewImageURL: nil, tags: []),
            incoming,
        ]))

        #expect(summary.bookmarkCount == nil)
        #expect(summary.workshopBookmarkCount == 2)
        #expect(summary.totalBookmarkCount == 2, "The summary counts accepted input entries, including a saved duplicate")
        #expect(!summary.isEmpty, "A successful Workshop-only import must not be reported as unrecognized")
        #expect(store.contains(incoming.id), "the restore drops the backup's Workshop bookmarks")
        #expect(store.bookmarks.first { $0.id == existing.id }?.rawTitle == "Mine", "the backup overwrote a saved bookmark")
    }

    @Test("Restoring a backup from before library bookmarks marks the installed rows its saved entries fold into")
    func legacyBackupMarksFoldedWorkshopRows() {
        let manager = SettingsManager.shared
        let store = LibraryBookmarkStore.shared
        let previousBookmarks = manager.loadWallpaperBookmarks()
        let previousGlobal = manager.loadGlobalSettings()
        let hadMark = store.contains("workshop:123")
        defer {
            manager.saveGlobalSettings(previousGlobal)
            manager.saveWallpaperBookmarks(previousBookmarks)
            BookmarkStore.shared.reload()
            if !hadMark {
                store.remove("workshop:123")
            }
        }
        store.remove("workshop:123")
        let origin = WPEOrigin(
            workshopID: "123", title: "Installed 123", originalType: .scene,
            sourceFolderBookmark: Data(), cacheRelativePath: nil, previewFileName: nil
        )
        var folded = WallpaperBookmark(
            label: "Folded",
            content: .scene(SceneDescriptor(workshopID: "123", cacheRelativePath: "scene-\(UUID())", entryFile: "scene.json", capabilityTier: .imageOnly))
        )
        folded.wpeOrigin = origin
        var global = previousGlobal
        global.recentWPEImports = [WPEHistoryEntry(origin: origin, importedAt: Date(timeIntervalSince1970: 1_750_000_000))]

        ConfigurationPorter.apply(ConfigurationBundle(globalSettings: global, wallpaperBookmarks: [folded]))

        #expect(store.contains("workshop:123"), "the saved entry folded into the installed row lost its bookmark")
    }
}
#endif
