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
