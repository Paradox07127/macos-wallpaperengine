import AppKit
import Foundation
import LiveWallpaperCore
import Testing
@testable import LiveWallpaper

@Suite("WPE delete tombstone lifecycle", .serialized) @MainActor
struct WPEDeleteTombstoneTests {
    @Test("A legacy settings blob without the key decodes to an empty tombstone list")
    func legacyDecodeDefaultsEmpty() throws {
        let settings = try JSONDecoder().decode(GlobalSettings.self, from: Data("{}".utf8))
        #expect(settings.deletedWorkshopIDs.isEmpty)
    }

    @Test("deletedWorkshopIDs round-trips through Codable")
    func roundTripsThroughCodable() throws {
        var settings = GlobalSettings()
        settings.deletedWorkshopIDs = ["123", "456"]
        let decoded = try JSONDecoder().decode(GlobalSettings.self, from: JSONEncoder().encode(settings))
        #expect(decoded.deletedWorkshopIDs == ["123", "456"])
    }

    @Test("Recording a delete tombstone is idempotent")
    func recordIsIdempotent() throws {
        withIsolatedGlobalSettings {
            let manager = SettingsManager.shared
            manager.recordWPEDeleteTombstone(workshopID: "999")
            manager.recordWPEDeleteTombstone(workshopID: "999")
            #expect(manager.loadGlobalSettings().deletedWorkshopIDs.filter { $0 == "999" }.count == 1)
        }
    }

    @Test("A passive re-import (apply / auto-scan) leaves the tombstone in place")
    func passiveReimportKeepsTombstone() throws {
        withIsolatedGlobalSettings {
            let manager = SettingsManager.shared
            manager.recordWPEDeleteTombstone(workshopID: "999")

            manager.recordWPEImport(makeReaddedEntry("999"))

            let after = manager.loadGlobalSettings()
            #expect(after.deletedWorkshopIDs.contains("999"),
                    "a passive record must NOT resurrect a deleted item on the next library scan")
            #expect(after.recentWPEImports.first?.origin.workshopID == "999")
        }
    }

    @Test("An explicit re-acquire clears the tombstone")
    func deliberateReimportClears() throws {
        withIsolatedGlobalSettings {
            let manager = SettingsManager.shared
            manager.recordWPEDeleteTombstone(workshopID: "999")

            manager.recordWPEImport(makeReaddedEntry("999"), clearsDeleteTombstone: true)

            let after = manager.loadGlobalSettings()
            #expect(!after.deletedWorkshopIDs.contains("999"),
                    "an explicit re-acquire must clear the delete tombstone")
            #expect(after.recentWPEImports.first?.origin.workshopID == "999")
        }
    }

    @Test("Deleting an entry whose manifest names another item keeps its own folder out of the scan, not the other item's", .timeLimit(.minutes(1)))
    func deleteTombstonesTheDeletedSteamFolder() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("WPEDeleteTombstoneTests-\(UUID().uuidString)", isDirectory: true)
        let suite = try TestScratch.defaultsSuite(prefix: "LiveWallpaperTests.WPEDeleteTombstone", function: #function)
        defer {
            suite.discard()
            try? FileManager.default.removeItem(at: root)
        }
        let original = "2585024298"
        let reupload = "3159206868"
        func steamFolder(_ itemID: String) throws -> URL {
            let folder = SteamLibraryPaths.workshopContentRoot(steamRoot: root).appendingPathComponent(itemID, isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let manifest = #"{"workshopid":"\#(original)","title":"Item \#(itemID)","type":"video","file":"video.mp4"}"#
            try Data(manifest.utf8).write(to: folder.appendingPathComponent("project.json"))
            try Data([0x00]).write(to: folder.appendingPathComponent("video.mp4"))
            return folder
        }
        _ = try steamFolder(original)
        let reuploadFolder = try steamFolder(reupload)
        let doctor = SteamCMDDoctorService(defaults: suite.defaults)
        doctor.workdirBookmarkData = try root.bookmarkData()

        let manager = SettingsManager.shared
        manager.cleanAllSettings(applyLoginSetting: false)
        defer { manager.cleanAllSettings(applyLoginSetting: false) }
        // workshopID is the manifest's id; the folder is the re-upload's.
        let deleted = try WPEHistoryEntry(
            origin: WPEOrigin(
                workshopID: original, title: "Re-upload", originalType: .video,
                sourceFolderBookmark: reuploadFolder.bookmarkData(),
                cacheRelativePath: nil, previewFileName: nil, entryFile: "video.mp4", resourceLocation: .sourceFolder
            ),
            importedAt: Date(timeIntervalSince1970: 1)
        )
        manager.recordWPEImport(deleted)
        #expect(manager.removeWPEImport(workshopID: original, matchingImportedAt: deleted.importedAt))

        let coordinator = WorkshopFolderImportCoordinator(
            importService: WallpaperEngineImportService(validateVideo: { _ in }, makeBookmark: { try? $0.bookmarkData() })
        )
        await coordinator.ingestExistingDownloads(using: doctor)

        #expect(
            manager.loadGlobalSettings().recentWPEImports.map(\.origin.workshopID) == [original],
            "the deleted re-upload came back, or the original item nobody deleted was kept out"
        )
    }

    @Test("Deleting a local copy whose manifest names a Steam item leaves that item in the library and its folder scannable")
    func deletingLocalCopyKeepsSteamItem() throws {
        let fixture = try LocalCopyFixture()
        defer { fixture.discard() }
        try withIsolatedGlobalSettings {
            let manager = SettingsManager.shared
            manager.recordWPEImport(fixture.steam)
            manager.recordWPEImport(fixture.local)

            #expect(manager.removeWPEImport(workshopID: fixture.workshopID, matchingImportedAt: fixture.local.importedAt))
            var after = manager.loadGlobalSettings()
            #expect(after.recentWPEImports == [fixture.steam])
            #expect(!after.deletedWorkshopIDs.contains(fixture.workshopID))

            // Control: deleting the Steam item itself still keeps its folder out of the scan.
            #expect(manager.removeWPEImport(workshopID: fixture.workshopID, matchingImportedAt: fixture.steam.importedAt))
            after = manager.loadGlobalSettings()
            #expect(after.deletedWorkshopIDs == [fixture.workshopID])
        }
    }

    @Test("Deleting a local copy leaves a screen playing the Steam item it was copied from")
    func deletingLocalCopyKeepsScreenPlayingSteamItem() throws {
        let fixture = try LocalCopyFixture()
        defer { fixture.discard() }
        try withIsolatedGlobalSettings {
            SettingsManager.shared.recordWPEImport(fixture.steam)
            SettingsManager.shared.recordWPEImport(fixture.local)
            let screen = Screen(nsScreen: TombstoneTestNSScreen())
            let manager = ScreenManager(startupOptions: ScreenManagerStartupOptions(
                restoreSavedWallpapers: false, startAutomation: false,
                powerMonitor: FakePowerMonitor(), fullScreenDetector: FakeFullScreenDetector(),
                playableVideoLoader: FakePlayableVideoLoader(), displayRegistry: FakeDisplayRegistry(screens: [screen]),
                featureCatalog: FeatureCatalog(capabilities: .pro), originReconciler: PreservingOriginReconciler()
            ))
            defer {
                manager.tearDownForTermination()
                manager.configurationStore.remove(for: screen.id)
            }
            var configuration = ScreenConfiguration(
                screenID: screen.id, wallpaper: .video(bookmarkData: Data("steam-video".utf8), packageEntryName: nil)
            )
            configuration.displayFingerprint = screen.displayFingerprint
            configuration.wpeOrigin = fixture.steam.origin
            manager.saveConfiguration(configuration)
            let playing = configuration.activeWallpaper

            #expect(manager.removeWPEImport(workshopID: fixture.workshopID, matchingImportedAt: fixture.local.importedAt))
            #expect(manager.getConfiguration(for: screen)?.activeWallpaper == playing)

            // Control: deleting the Steam item clears the screen playing it.
            #expect(manager.removeWPEImport(workshopID: fixture.workshopID, matchingImportedAt: fixture.steam.importedAt))
            #expect(manager.getConfiguration(for: screen)?.activeWallpaper != playing)
        }
    }

    private func makeReaddedEntry(_ workshopID: String) -> WPEHistoryEntry {
        WPEHistoryEntry(
            origin: WPEOrigin(
                workshopID: workshopID,
                title: "Re-added",
                originalType: .video,
                sourceFolderBookmark: Data([0xCC]),
                cacheRelativePath: "wpe-cache/\(workshopID)",
                previewFileName: nil
            ),
            importedAt: Date(timeIntervalSince1970: 1),
            lastUsedAt: nil
        )
    }

    @Test("An empty workshop id is never tombstoned")
    func emptyIDIgnored() throws {
        withIsolatedGlobalSettings {
            let manager = SettingsManager.shared
            manager.recordWPEDeleteTombstone(workshopID: "")
            #expect(manager.loadGlobalSettings().deletedWorkshopIDs.isEmpty)
        }
    }

    private func withIsolatedGlobalSettings(_ body: () throws -> Void) rethrows {
        let defaults = UserDefaults.standard
        let keys = ["screenConfigurations", "globalSettings"]
        let previousValues = keys.reduce(into: [String: Any]()) { result, key in
            result[key] = defaults.object(forKey: key)
        }

        SettingsManager.shared.cleanAllSettings(applyLoginSetting: false)
        defer {
            SettingsManager.shared.cleanAllSettings(applyLoginSetting: false)
            for key in keys {
                if let value = previousValues[key] {
                    defaults.set(value, forKey: key)
                } else {
                    defaults.removeObject(forKey: key)
                }
            }
        }

        try body()
    }
}

/// A Steam item and a local copy of its folder whose manifest still carries the Steam item's id.
@MainActor
private struct LocalCopyFixture {
    let workshopID = "2585024298"
    let root: URL
    let steam: WPEHistoryEntry
    let local: WPEHistoryEntry

    init() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("WPELocalCopy-\(UUID().uuidString)", isDirectory: true)
        self.root = root
        func entry(inFolder relativePath: String, importedAt: Double) throws -> WPEHistoryEntry {
            let folder = root.appendingPathComponent(relativePath, isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            return try WPEHistoryEntry(
                origin: WPEOrigin(
                    workshopID: "2585024298", title: "Lunar Tear [4K]", originalType: .video,
                    sourceFolderBookmark: #require(ResourceUtilities.createBookmark(for: folder)),
                    cacheRelativePath: "wpe-cache/2585024298", previewFileName: nil
                ),
                importedAt: Date(timeIntervalSince1970: importedAt)
            )
        }
        steam = try entry(inFolder: "steamapps/workshop/content/431960/\(workshopID)", importedAt: 1)
        local = try entry(inFolder: "Wallpapers/edit", importedAt: 2)
    }

    func discard() {
        try? FileManager.default.removeItem(at: root)
    }
}

private final class TombstoneTestNSScreen: NSScreen {
    override var frame: NSRect {
        NSRect(x: 0, y: 0, width: 800, height: 600)
    }

    override var deviceDescription: [NSDeviceDescriptionKey: Any] {
        [NSDeviceDescriptionKey("NSScreenNumber"): UInt32(0xEDA0_0D17)]
    }

    override var localizedName: String {
        "Delete Tombstone Test"
    }
}
