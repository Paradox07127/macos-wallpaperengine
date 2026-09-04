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

    /// Lite and Pro are one product family, and the UTI list has always said so.
    /// A user upgrading Lite → Pro (or moving a backup the other way) must be
    /// able to restore their setup; only foreign apps are provenance failures.
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

    // MARK: - Screen schemes

    private func sampleScheme(name: String) -> ScreenScheme {
        // Whole-second timestamps: the porter encodes dates as ISO-8601, which
        // has no sub-second field, so `Date()` would not survive a round-trip
        // and the equality check below would fail on the timestamps alone.
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
        // Identity is stripped at capture, so a restored scheme is still unbound.
        #expect(decoded.screenSchemes?.first?.configuration.screenID == ScreenScheme.unboundScreenID)
    }

    @Test("A backup written before schemes existed still decodes, with no schemes")
    func decodesLegacyBundleWithoutSchemesField() throws {
        let directory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        // Hand-built to match what shipped builds wrote: no `screenSchemes` key
        // at all. Encoding a nil-schemes bundle would prove nothing, because the
        // encoder omits it either way.
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
        )

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
        )

        #expect(merged.count == 1)
        #expect(merged.first?.label == "Mine")
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
}

@Suite("SettingsManager: file-store migration from UserDefaults")
@MainActor
struct SettingsManagerMigrationTests {
    @Test("Seeds AtomicFileStore from legacy UserDefaults blob on first launch")
    func seedsFromLegacyUserDefaults() throws {
        let directory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let scratch = try TestScratch.defaultsSuite("com.loomscreen.pro.MigrationTests.seedsFromLegacy")
        let defaults = scratch.defaults
        defer { scratch.discard() }

        let original = [
            ScreenConfiguration(screenID: 42, wallpaper: .video(bookmarkData: Data([0x10, 0x20])))
        ]
        let legacyData = try JSONEncoder().encode(original)
        // The legacy blob goes in the suite this test already owns: seeding it into
        // `.standard` only worked because SettingsManager read the real domain.
        defaults.set(legacyData, forKey: "screenConfigurations")
        defaults.removeObject(forKey: "Settings.MigrationVersion")

        let manager = SettingsManager(directory: ConfigurationDirectory(root: directory), defaults: defaults)

        let loaded = manager.loadConfigurations()
        #expect(loaded.count == 1)
        #expect(loaded.first?.screenID == 42)

        let onDisk = directory.appendingPathComponent("screen-configurations.json")
        #expect(FileManager.default.fileExists(atPath: onDisk.path(percentEncoded: false)))
    }

    @Test("Migration version is NOT bumped when seed writes fail (retry on next launch)")
    func migrationVersionDeferredOnSeedFailure() throws {
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
        UserDefaults.standard.set(try JSONEncoder().encode(legacyConfigs), forKey: "screenConfigurations")
        UserDefaults.standard.removeObject(forKey: "Settings.MigrationVersion")
        defer {
            UserDefaults.standard.removeObject(forKey: "screenConfigurations")
            UserDefaults.standard.removeObject(forKey: "Settings.MigrationVersion")
        }

        let unwritableSubdir = unwritableRoot.appendingPathComponent("Configuration", isDirectory: true)
        _ = SettingsManager(directory: ConfigurationDirectory(root: unwritableSubdir))

        let postVersion = UserDefaults.standard.integer(forKey: "Settings.MigrationVersion")
        #expect(postVersion == 0,
                "Migration version must stay at 0 after a failed seed so the next launch retries")
    }

    @Test("Zero-byte store file does not block migration from a valid legacy blob")
    func zeroByteFileDoesNotBlockMigration() throws {
        let directory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let scratch = try TestScratch.defaultsSuite("com.loomscreen.pro.MigrationTests.zeroByteFile")
        let defaults = scratch.defaults
        defer { scratch.discard() }

        // Interrupted write left a zero-byte primary and no backup.
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
    }

    @Test("File payload wins over the legacy UserDefaults blob")
    func filePayloadWinsOverLegacy() throws {
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
        UserDefaults.standard.set(try JSONEncoder().encode(legacyConfigs), forKey: "screenConfigurations")
        UserDefaults.standard.removeObject(forKey: "Settings.MigrationVersion")
        defer {
            UserDefaults.standard.removeObject(forKey: "screenConfigurations")
            UserDefaults.standard.removeObject(forKey: "Settings.MigrationVersion")
        }

        let manager = SettingsManager(directory: ConfigurationDirectory(root: directory))
        let loaded = manager.loadConfigurations()
        #expect(loaded.first?.screenID == 1, "File store wins; legacy 99 must not appear")
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
