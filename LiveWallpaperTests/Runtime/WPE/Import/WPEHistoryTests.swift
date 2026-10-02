import Foundation
import LiveWallpaperCore
import Testing
@testable import LiveWallpaper

@Suite("WPE history", .serialized) @MainActor
struct WPEHistoryTests {
    @Test("Record pushes to front")
    func recordPushesToFront() throws {
        withIsolatedGlobalSettings {
            let manager = SettingsManager.shared
            manager.recordWPEImport(makeEntry("1"))
            manager.recordWPEImport(makeEntry("2"))

            let ids = manager.loadGlobalSettings().recentWPEImports.map(\.origin.workshopID)
            #expect(ids == ["2", "1"])
        }
    }

    @Test("Duplicate moves to front")
    func duplicateMovesToFront() throws {
        withIsolatedGlobalSettings {
            let manager = SettingsManager.shared
            let lastUsedAt = Date(timeIntervalSince1970: 50)
            manager.recordWPEImport(makeEntry("1"))
            manager.recordWPEImport(makeEntry("2"))
            manager.recordWPEImport(makeEntry("1", title: "Updated", lastUsedAt: lastUsedAt))

            let recent = manager.loadGlobalSettings().recentWPEImports
            #expect(recent.map(\.origin.workshopID) == ["1", "2"])
            #expect(recent.first?.origin.title == "Updated")
            #expect(recent.first?.lastUsedAt == lastUsedAt)
        }
    }

    @Test("A Steam folder recorded under a copied manifest's id is the same entry as its re-download under the folder's id")
    func steamFolderReRecordReplacesManifestIDEntry() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("history-steam-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        func entry(_ workshopID: String, inFolder relativePath: String) throws -> WPEHistoryEntry {
            let folder = root.appendingPathComponent(relativePath, isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let origin = WPEOrigin(
                workshopID: workshopID, title: "Lunar Tear [4K]", originalType: .scene,
                sourceFolderBookmark: try #require(ResourceUtilities.createBookmark(for: folder)),
                cacheRelativePath: "wpe-cache/\(workshopID)", previewFileName: nil
            )
            return WPEHistoryEntry(origin: origin, importedAt: Date(timeIntervalSince1970: Double(workshopID) ?? 0))
        }

        try withIsolatedGlobalSettings {
            let manager = SettingsManager.shared
            let steamFolder = "steamapps/workshop/content/431960/3159206868"
            manager.recordWPEImport(try entry("2585024298", inFolder: steamFolder))
            manager.recordWPEImport(try entry("3159206868", inFolder: steamFolder))
            #expect(manager.loadGlobalSettings().recentWPEImports.map(\.origin.workshopID) == ["3159206868"])
        }
        // Control: outside Steam's layout a numeric folder name says nothing about the item, so two ids stay two entries.
        try withIsolatedGlobalSettings {
            let manager = SettingsManager.shared
            manager.recordWPEImport(try entry("2585024298", inFolder: "loose/3159206868"))
            manager.recordWPEImport(try entry("3159206868", inFolder: "loose/3159206868"))
            #expect(manager.loadGlobalSettings().recentWPEImports.map(\.origin.workshopID) == ["3159206868", "2585024298"])
        }
    }

    @Test("Re-recording a Steam folder replaces only that folder's entry, not another folder whose manifest names it")
    func steamFolderReRecordKeepsOtherFolderNamingIt() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("history-steam-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        func entry(_ workshopID: String, inFolder itemID: String) throws -> WPEHistoryEntry {
            let folder = root.appendingPathComponent("steamapps/workshop/content/431960/\(itemID)", isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let origin = try WPEOrigin(
                workshopID: workshopID, title: "Item \(itemID)", originalType: .scene,
                sourceFolderBookmark: #require(ResourceUtilities.createBookmark(for: folder)),
                cacheRelativePath: "wpe-cache/\(workshopID)", previewFileName: nil
            )
            return WPEHistoryEntry(origin: origin, importedAt: Date(timeIntervalSince1970: Double(workshopID) ?? 0))
        }

        try withIsolatedGlobalSettings {
            let manager = SettingsManager.shared
            try manager.recordWPEImport(entry("100", inFolder: "200"))
            try manager.recordWPEImport(entry("200", inFolder: "300"))
            try manager.recordWPEImport(entry("200", inFolder: "200"))
            #expect(manager.loadGlobalSettings().recentWPEImports.map(\.origin.steamFolderItemID) == ["200", "300"])
        }
    }

    @Test("A folder size measured for one entry is stored on that entry, not on another folder sharing its id", .timeLimit(.minutes(1)))
    func measuredSizeLandsOnMeasuredEntry() async throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("history-size-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        func entry(inFolder itemID: String, importedAt: Double) throws -> WPEHistoryEntry {
            let folder = root.appendingPathComponent("steamapps/workshop/content/431960/\(itemID)", isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try Data(count: 4096).write(to: folder.appendingPathComponent("scene.pkg"))
            let origin = try WPEOrigin(
                workshopID: "2585024298", title: "Item \(itemID)", originalType: .scene,
                sourceFolderBookmark: folder.bookmarkData(),
                cacheRelativePath: "wpe-cache/2585024298", previewFileName: nil
            )
            return WPEHistoryEntry(origin: origin, importedAt: Date(timeIntervalSince1970: importedAt))
        }

        let manager = SettingsManager.shared
        manager.cleanAllSettings(applyLoginSetting: false)
        defer { manager.cleanAllSettings(applyLoginSetting: false) }
        let measured = try entry(inFolder: "2585024298", importedAt: 1)
        manager.recordWPEImport(measured)
        try manager.recordWPEImport(entry(inFolder: "3159206868", importedAt: 2))

        _ = await loadWPELocalProjectInfo(for: measured)

        let recent = manager.loadGlobalSettings().recentWPEImports
        #expect(recent.map(\.origin.steamFolderItemID) == ["3159206868", "2585024298"])
        #expect(recent.map { $0.sizeBytes != nil } == [false, true])
    }

    @Test("Keeps every import past 200, newest first")
    func keepsEveryImportNewestFirst() {
        withIsolatedGlobalSettings {
            let manager = SettingsManager.shared
            let total = 201
            for index in 0..<total {
                manager.recordWPEImport(makeEntry("\(index)"))
            }

            let ids = manager.loadGlobalSettings().recentWPEImports.map(\.origin.workshopID)
            #expect(ids.count == total)
            #expect(ids.first == "\(total - 1)")
            #expect(ids.last == "0")
        }
    }

    @Test("Round trips through GlobalSettings Codable")
    func roundTripsThroughGlobalSettingsCodable() throws {
        let entry = makeEntry("42", title: "Round Trip", lastUsedAt: Date(timeIntervalSince1970: 123))
        let settings = GlobalSettings(recentWPEImports: [entry])

        let data = try JSONEncoder().encode(settings)
        let decoded = try JSONDecoder().decode(GlobalSettings.self, from: data)

        #expect(decoded.recentWPEImports == [entry])
    }

    @Test("Re-import keeps the previously measured size")
    func reimportPreservesSize() throws {
        withIsolatedGlobalSettings {
            let manager = SettingsManager.shared
            manager.recordWPEImport(makeEntry("1", sizeBytes: 4096))
            manager.recordWPEImport(makeEntry("1", title: "Reactivated"))

            let entry = manager.loadGlobalSettings().recentWPEImports.first
            #expect(entry?.origin.title == "Reactivated")
            #expect(entry?.sizeBytes == 4096)
        }
    }

    @Test("updateWPEImportSize backfills once and never overwrites")
    func updateSizeBackfillsOnce() throws {
        withIsolatedGlobalSettings {
            let manager = SettingsManager.shared
            manager.recordWPEImport(makeEntry("1"))
            #expect(manager.loadGlobalSettings().recentWPEImports.first?.sizeBytes == nil)

            let importedAt = Date(timeIntervalSince1970: 1)
            manager.updateWPEImportSize(workshopID: "1", matchingImportedAt: importedAt, sizeBytes: 2048)
            #expect(manager.loadGlobalSettings().recentWPEImports.first?.sizeBytes == 2048)

            manager.updateWPEImportSize(workshopID: "1", matchingImportedAt: importedAt, sizeBytes: 9999)
            #expect(manager.loadGlobalSettings().recentWPEImports.first?.sizeBytes == 2048)

            manager.updateWPEImportSize(workshopID: "missing", matchingImportedAt: importedAt, sizeBytes: 1)
            #expect(manager.loadGlobalSettings().recentWPEImports.count == 1)
        }
    }

    @Test("Legacy JSON without sizeBytes decodes to nil")
    func legacyDecodeWithoutSize() throws {
        let entry = makeEntry("7", title: "Legacy")
        let data = try JSONEncoder().encode(entry)
        #expect(!String(decoding: data, as: UTF8.self).contains("sizeBytes"))

        let decoded = try JSONDecoder().decode(WPEHistoryEntry.self, from: data)
        #expect(decoded.sizeBytes == nil)
        #expect(decoded.origin.workshopID == "7")
    }

    private func withIsolatedGlobalSettings(_ body: () throws -> Void) rethrows {
        let defaults = UserDefaults.standard
        let keys = [
            "screenConfigurations",
            "globalSettings",
            "AerialsLibrary.DirectoryBookmark",
            "WallpaperBookmarks.v1",
            "TrustedHTMLHosts.v1",
        ]
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

    private func makeEntry(
        _ workshopID: String,
        title: String? = nil,
        lastUsedAt: Date? = nil,
        sizeBytes: Int64? = nil
    ) -> WPEHistoryEntry {
        let origin = WPEOrigin(
            workshopID: workshopID,
            title: title ?? "Wallpaper \(workshopID)",
            originalType: .video,
            sourceFolderBookmark: Data(workshopID.utf8),
            cacheRelativePath: "wpe-cache/\(workshopID)",
            previewFileName: "preview.gif"
        )
        return WPEHistoryEntry(
            origin: origin,
            importedAt: Date(timeIntervalSince1970: Double(workshopID) ?? 0),
            lastUsedAt: lastUsedAt,
            sizeBytes: sizeBytes
        )
    }
}
