#if !LITE_BUILD
import Foundation
import LiveWallpaperCore
import Testing
@testable import LiveWallpaper

@Suite("WPE in-place asset reading")
struct WPEInPlaceAssetReadingTests {

    // MARK: - Helpers

    private func u32(_ value: UInt32) -> Data {
        withUnsafeBytes(of: value.littleEndian) { Data($0) }
    }

    private func makePackageData(_ entries: [(name: String, data: Data)]) -> Data {
        var header = Data()
        let magic = "PKGV0001"
        header.append(u32(UInt32(magic.utf8.count)))
        header.append(contentsOf: magic.utf8)
        header.append(u32(UInt32(entries.count)))

        var blob = Data()
        var offset: UInt32 = 0
        for entry in entries {
            let nameBytes = Array(entry.name.utf8)
            header.append(u32(UInt32(nameBytes.count)))
            header.append(contentsOf: nameBytes)
            header.append(u32(offset))
            header.append(u32(UInt32(entry.data.count)))
            blob.append(entry.data)
            offset += UInt32(entry.data.count)
        }
        return header + blob
    }

    private func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("inplace-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @MainActor
    @Test("Restored scene packages stay within their source folder", arguments: [
        "plain", "internal-link", "windows", "external-link", "traversal", "absolute", "directory",
    ])
    func restoredPackageSourceIsContained(kind: String) throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = root.appendingPathComponent("source", isDirectory: true)
        let nested = folder.appendingPathComponent("nested", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        let bytes = Data("safe-scene-json".utf8)
        let outside = root.appendingPathComponent("outside.pkg")
        try makePackageData([("scene.json", Data("outside-sentinel".utf8))]).write(to: outside)
        let actual = nested.appendingPathComponent("actual.pkg")
        try makePackageData([("scene.json", bytes)]).write(to: actual)
        let fileName: String
        switch kind {
        case "windows": fileName = "nested\\actual.pkg"
        case "traversal": fileName = "../outside.pkg"
        case "absolute": fileName = outside.path
        case "directory": fileName = "nested"
        case "internal-link", "external-link":
            fileName = "scene.pkg"
            try FileManager.default.createSymbolicLink(
                at: folder.appendingPathComponent(fileName),
                withDestinationURL: kind == "internal-link" ? actual : outside
            )
        default: fileName = "nested/actual.pkg"
        }
        let descriptor = SceneDescriptor(
            workshopID: "fixture", cacheRelativePath: "wpe-cache/fixture",
            entryFile: "scene.json", capabilityTier: .degraded,
            assetStorage: .packageSource(fileName: fileName)
        )
        let bookmark = Data("fixture-bookmark".utf8)
        let origin = WPEOrigin(
            workshopID: "fixture", title: "Fixture", originalType: .scene,
            sourceFolderBookmark: bookmark, cacheRelativePath: nil, previewFileName: nil
        )
        let builder = AmbientWallpaperSessionBuilder(
            bookmarkResolver: SecurityScopedBookmarkResolver(
                resolveData: { _ in (folder, false) }, refreshData: { _ in bookmark }
            ),
            relocateWorkshopSource: { _ in nil }
        )
        let assets = builder.sceneAssets(
            descriptor: descriptor, origin: origin,
            cacheURL: root.appendingPathComponent("missing-cache"),
            fileManager: .default, onOriginBookmarkRefresh: { _, _ in }
        )
        if ["plain", "internal-link", "windows"].contains(kind) {
            let provider = try #require(assets?.provider)
            let data = try provider.data(atRelativePath: "scene.json")
            #expect(data == bytes)
        } else {
            #expect(assets == nil)
        }
    }

    @MainActor
    @Test("An escaping legacy package leaves the loose source fallback available")
    func legacyPackageEscapeFallsBackToLooseSource() throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = root.appendingPathComponent("source", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let bytes = Data("loose-scene".utf8)
        try bytes.write(to: folder.appendingPathComponent("scene.json"))
        let outside = root.appendingPathComponent("outside.pkg")
        try makePackageData([("scene.json", Data("outside-sentinel".utf8))]).write(to: outside)
        try FileManager.default.createSymbolicLink(
            at: folder.appendingPathComponent("scene.pkg"), withDestinationURL: outside
        )
        let bookmark = Data("fixture-bookmark".utf8)
        let origin = WPEOrigin(
            workshopID: "fixture", title: "Fixture", originalType: .scene,
            sourceFolderBookmark: bookmark, cacheRelativePath: nil, previewFileName: nil
        )
        let builder = AmbientWallpaperSessionBuilder(
            bookmarkResolver: SecurityScopedBookmarkResolver(
                resolveData: { _ in (folder, false) }, refreshData: { _ in bookmark }
            ),
            relocateWorkshopSource: { _ in nil }
        )
        let descriptor = SceneDescriptor(
            workshopID: "fixture", cacheRelativePath: "wpe-cache/fixture",
            entryFile: "scene.json", capabilityTier: .degraded, assetStorage: .cache
        )
        let assets = builder.sceneAssets(
            descriptor: descriptor, origin: origin,
            cacheURL: root.appendingPathComponent("missing-cache"),
            fileManager: .default, onOriginBookmarkRefresh: { _, _ in }
        )
        let provider = try #require(assets?.provider)
        let data = try provider.data(atRelativePath: "scene.json")
        #expect(data == bytes)
    }

    // MARK: - canonicalLookupName

    @Test("canonicalLookupName normalizes and rejects traversal")
    func canonicalLookupNameNormalizes() {
        #expect(WallpaperEnginePackage.canonicalLookupName("./materials/a.tex") == "materials/a.tex")
        #expect(WallpaperEnginePackage.canonicalLookupName("a//b/c") == "a/b/c")
        #expect(WallpaperEnginePackage.canonicalLookupName("scene.json") == "scene.json")
        #expect(WallpaperEnginePackage.canonicalLookupName("../escape") == nil)
        #expect(WallpaperEnginePackage.canonicalLookupName("/abs") == nil)
        #expect(WallpaperEnginePackage.canonicalLookupName("") == nil)
        #expect(WallpaperEnginePackage.canonicalLookupName(".") == nil)
        #expect(WallpaperEnginePackage.canonicalLookupName("image..png") == "image..png")
    }

    // MARK: - Directory provider

    @Test("Directory provider reads, reports existence, rejects escapes")
    func directoryProviderReadsAndContains() throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        try "hello".data(using: .utf8)!.write(to: root.appendingPathComponent("scene.json"))
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("materials"), withIntermediateDirectories: true)
        try Data([1, 2, 3]).write(to: root.appendingPathComponent("materials/a.tex"))

        let provider = WPEDirectorySceneAssetProvider(rootURL: root)

        #expect(try provider.data(atRelativePath: "scene.json") == "hello".data(using: .utf8))
        #expect(provider.exists(atRelativePath: "materials/a.tex"))
        #expect(!provider.exists(atRelativePath: "missing.json"))
        #expect(!provider.exists(atRelativePath: "materials"))
        #expect(throws: WPESceneAssetProviderError.self) {
            _ = try provider.data(atRelativePath: "../escape")
        }
        #expect(!provider.exists(atRelativePath: "../escape"))
        #expect(provider.entryNames.contains("scene.json"))
        #expect(provider.entryNames.contains("materials/a.tex"))
    }

    // MARK: - Package provider

    @Test("Package provider reads entries in place and matches canonical lookups")
    func packageProviderReadsInPlace() throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let sceneJSON = #"{"k":"v"}"#.data(using: .utf8)!
        let texBytes = Data([0xAA, 0xBB, 0xCC, 0xDD])
        let pkg = makePackageData([
            (name: "scene.json", data: sceneJSON),
            (name: "materials/a.tex", data: texBytes)
        ])
        let pkgURL = root.appendingPathComponent("scene.pkg")
        try pkg.write(to: pkgURL)

        let provider = try WPEPackageSceneAssetProvider(packageURL: pkgURL)

        #expect(try provider.data(atRelativePath: "scene.json") == sceneJSON)
        #expect(try provider.data(atRelativePath: "./materials/a.tex") == texBytes)
        #expect(provider.exists(atRelativePath: "materials/a.tex"))
        #expect(!provider.exists(atRelativePath: "missing.tex"))
        #expect(!provider.exists(atRelativePath: "../escape"))
        #expect(throws: WPESceneAssetProviderError.self) {
            _ = try provider.data(atRelativePath: "missing.tex")
        }
        #expect(provider.entryNames == ["materials/a.tex", "scene.json"])
    }

    @Test("Package provider stages an entry to a readable file URL")
    func packageProviderStagesURL() throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let payload = Data((0..<2048).map { UInt8($0 & 0xFF) })
        let pkg = makePackageData([(name: "audio/clip.mp3", data: payload)])
        let pkgURL = root.appendingPathComponent("scene.pkg")
        try pkg.write(to: pkgURL)

        let provider = try WPEPackageSceneAssetProvider(packageURL: pkgURL)
        let stagedURL = try provider.stagedURL(atRelativePath: "audio/clip.mp3")

        #expect(FileManager.default.fileExists(atPath: stagedURL.path))
        #expect(try Data(contentsOf: stagedURL) == payload)
    }

    @Test("Package entry lookup is case-insensitive and first-match-wins on collision")
    func packageEntryFirstMatchWins() throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let pkg = makePackageData([
            (name: "Material.json", data: Data("first".utf8)),
            (name: "material.json", data: Data("second".utf8)),
        ])
        let pkgURL = root.appendingPathComponent("scene.pkg")
        try pkg.write(to: pkgURL)

        let provider = try WPEPackageSceneAssetProvider(packageURL: pkgURL)
        #expect(try provider.data(atRelativePath: "material.json") == Data("first".utf8))
        #expect(try provider.data(atRelativePath: "MATERIAL.JSON") == Data("first".utf8))
        #expect(provider.caseFoldCollisions == [
            WallpaperEnginePackage.CaseFoldCollision(
                winningName: "Material.json",
                shadowedName: "material.json"
            ),
        ])
    }

    // MARK: - Stale staging-dir sweep

    @Test("staleStagingDirectoryNames matches only the per-session staging prefix")
    func staleStagingNamesFilterOurDirsOnly() {
        let prefix = WPEPackageSceneAssetProvider.stagingDirectoryNamePrefix
        let ours = ["\(prefix)\(UUID().uuidString)", "\(prefix)2222", prefix]
        let others = [
            "LiveWallpaper-Other-thing",
            "com.apple.something",
            "scene.pkg",
            "WPEPkgStage-missing-leading-prefix",
        ]
        let stale = WPEPackageSceneAssetProvider.staleStagingDirectoryNames(in: ours + others)
        #expect(Set(stale) == Set(ours))
    }

    @Test("sweepStaleStagingDirectories reclaims matching entries and spares others")
    func sweepReclaimsOnlyStagingEntries() throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let fm = FileManager.default
        let prefix = WPEPackageSceneAssetProvider.stagingDirectoryNamePrefix

        let staging1 = root.appendingPathComponent("\(prefix)\(UUID().uuidString)", isDirectory: true)
        let staging2 = root.appendingPathComponent("\(prefix)\(UUID().uuidString)", isDirectory: true)
        let unrelated = root.appendingPathComponent("keep-me", isDirectory: true)
        for dir in [staging1, staging2, unrelated] {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        try Data([0xAB]).write(to: staging1.appendingPathComponent("asset.bin"))
        let stray = root.appendingPathComponent("\(prefix)stray", isDirectory: false)
        try Data([0xCD]).write(to: stray)

        let removed = WPEPackageSceneAssetProvider.sweepStaleStagingDirectories(in: root, fileManager: fm)

        #expect(removed == 3)
        #expect(!fm.fileExists(atPath: staging1.path))
        #expect(!fm.fileExists(atPath: staging2.path))
        #expect(!fm.fileExists(atPath: stray.path))
        #expect(fm.fileExists(atPath: unrelated.path))
    }

    @Test("sweepStaleStagingDirectories tolerates a missing directory")
    func sweepToleratesMissingDirectory() {
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("does-not-exist-\(UUID().uuidString)", isDirectory: true)
        #expect(WPEPackageSceneAssetProvider.sweepStaleStagingDirectories(in: missing) == 0)
    }

    @Test("launch sweep is an awaitable barrier and returns after reclamation")
    func launchSweepWaitsForReclamation() async throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let stale = root.appendingPathComponent(
            "\(WPEPackageSceneAssetProvider.stagingDirectoryNamePrefix)orphan",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: stale, withIntermediateDirectories: true)
        try Data([0xAB]).write(to: stale.appendingPathComponent("asset.bin"))

        let removed = await WPEPackageSceneAssetProvider.sweepStaleStagingDirectoriesAtLaunch(
            in: root
        )

        #expect(removed == 1)
        #expect(!FileManager.default.fileExists(atPath: stale.path))
    }

    // MARK: - SceneDescriptor.assetStorage

    @Test("SceneDescriptor without assetStorage decodes as .cache")
    func descriptorDefaultsToCacheStorage() throws {
        let payload: [String: Any] = [
            "workshopID": "abc",
            "cacheRelativePath": "wpe-cache/abc",
            "entryFile": "scene.json",
            "capabilityTier": "imageOnly"
        ]
        let data = try JSONSerialization.data(withJSONObject: payload, options: .sortedKeys)
        let decoded = try JSONDecoder().decode(SceneDescriptor.self, from: data)
        #expect(decoded.assetStorage == .cache)
    }

    @Test("SceneDescriptor with .cache storage omits the key on encode")
    func descriptorCacheStorageNotEncoded() throws {
        let descriptor = SceneDescriptor(
            workshopID: "abc",
            cacheRelativePath: "wpe-cache/abc",
            entryFile: "scene.json",
            capabilityTier: .imageOnly
        )
        let data = try JSONEncoder().encode(descriptor)
        let json = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(json["assetStorage"] == nil)
    }

    @Test("SceneDescriptor round-trips packageSource and sourceDirectory storage")
    func descriptorStorageRoundTrips() throws {
        for storage in [SceneAssetStorage.packageSource(fileName: "scene.pkg"), .sourceDirectory] {
            let descriptor = SceneDescriptor(
                workshopID: "id",
                cacheRelativePath: "wpe-cache/id",
                entryFile: "scene.json",
                capabilityTier: .degraded,
                assetStorage: storage
            )
            let data = try JSONEncoder().encode(descriptor)
            let decoded = try JSONDecoder().decode(SceneDescriptor.self, from: data)
            #expect(decoded == descriptor)
            #expect(decoded.assetStorage == storage)
        }
    }
}
#endif
