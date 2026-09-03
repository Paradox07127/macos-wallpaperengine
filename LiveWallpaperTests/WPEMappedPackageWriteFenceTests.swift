import Foundation
import Testing
@testable import LiveWallpaper

/// The renderer keeps a Workshop `scene.pkg` memory-mapped for the whole scene
/// lifetime (`WPEPackageSceneAssetProvider.mappedWindow`). On APFS, deleting or
/// rename-replacing the file under a live mapping is safe — the vnode survives —
/// but rewriting or truncating it in place SIGBUSes the mapping process on the
/// next page fault. This suite pins both halves of that invariant:
/// the sanctioned operations (delete, write-temp + rename) keep a live window
/// readable, and the production tree keeps no write-capable open that could hit
/// a mapped file in place.
@Suite("WPE mapped package write fence")
struct WPEMappedPackageWriteFenceTests {
    /// Large enough that `.mappedIfSafe` genuinely maps instead of heap-reading,
    /// so the survival tests exercise page faults against a real vnode.
    private static let payloadSize = 4 * 1024 * 1024

    private static func makePayload(fill: UInt8) -> Data {
        Data(repeating: fill, count: payloadSize)
    }

    private static func makePackageData(_ entries: [(name: String, data: Data)]) -> Data {
        func u32(_ value: UInt32) -> Data {
            withUnsafeBytes(of: value.littleEndian) { Data($0) }
        }
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

    private static func makeScratchDirectory() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("pkg-write-fence-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    // MARK: - Sanctioned operations keep a live mapping readable

    @Test("A live mapped window survives deletion of the package")
    func mappedWindowSurvivesDelete() throws {
        let dir = try Self.makeScratchDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let payload = Self.makePayload(fill: 0xA5)
        let pkgURL = dir.appendingPathComponent("scene.pkg")
        try Self.makePackageData([(name: "materials/a.tex", data: payload)]).write(to: pkgURL)

        let provider = try WPEPackageSceneAssetProvider(packageURL: pkgURL)
        let window = try provider.mappedWindow(atRelativePath: "materials/a.tex")

        try FileManager.default.removeItem(at: pkgURL)

        // Full read faults every page; the unlinked vnode must still back them.
        #expect(window.materializedData() == payload)
    }

    @Test("A live mapped window survives write-temp + rename replacement")
    func mappedWindowSurvivesRenameReplace() throws {
        let dir = try Self.makeScratchDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let oldPayload = Self.makePayload(fill: 0x11)
        let newPayload = Self.makePayload(fill: 0xEE)
        let pkgURL = dir.appendingPathComponent("scene.pkg")
        try Self.makePackageData([(name: "materials/a.tex", data: oldPayload)]).write(to: pkgURL)

        let provider = try WPEPackageSceneAssetProvider(packageURL: pkgURL)
        let window = try provider.mappedWindow(atRelativePath: "materials/a.tex")

        // The sanctioned replacement idiom: write the new package to a temp
        // sibling, then swap it in by rename.
        let replacement = dir.appendingPathComponent("scene.pkg.tmp")
        try Self.makePackageData([(name: "materials/a.tex", data: newPayload)]).write(to: replacement)
        _ = try FileManager.default.replaceItemAt(pkgURL, withItemAt: replacement)

        // The live window still reads the superseded vnode, byte for byte.
        #expect(window.materializedData() == oldPayload)

        // A fresh open sees the replacement.
        let reopened = try WPEPackageSceneAssetProvider(packageURL: pkgURL)
        let newWindow = try reopened.mappedWindow(atRelativePath: "materials/a.tex")
        #expect(newWindow.materializedData() == newPayload)
    }

    @Test("The connector's workshop delete leaves a live mapping readable")
    func deleteWorkshopItemLeavesLiveMappingReadable() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory
            .appendingPathComponent("pkg-write-fence-steam-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: root) }
        let itemID = "3725117707"
        let item = SteamLibraryPaths.workshopContentRoot(steamRoot: root)
            .appendingPathComponent(itemID, isDirectory: true)
        try fm.createDirectory(at: item, withIntermediateDirectories: true)
        let payload = Self.makePayload(fill: 0x3C)
        let pkgURL = item.appendingPathComponent("scene.pkg")
        try Self.makePackageData([(name: "materials/a.tex", data: payload)]).write(to: pkgURL)

        let provider = try WPEPackageSceneAssetProvider(packageURL: pkgURL)
        let window = try provider.mappedWindow(atRelativePath: "materials/a.tex")

        let result = SteamLibraryWriter.deleteWorkshopItem(workshopID: itemID, steamRoot: root)

        #expect(result.outcome == .deleted)
        var info = stat()
        #expect(lstat(item.path(percentEncoded: false), &info) != 0)
        #expect(window.materializedData() == payload)
    }

    // MARK: - Source fence: no in-place writer may appear
    //
    // The behaviour tests above cannot police the write side: `.mappedIfSafe`
    // maps MAP_PRIVATE, so a same-inode rewrite is snapshot-isolated from an
    // already-created window (probed 2026-08-16 — even unfaulted pages keep the
    // old bytes). The remaining hazard is a SIGBUS while the file is truncated
    // mid-rewrite, a cross-process race no in-process test can stage. The two
    // source audits below are therefore the enforcement, mutation-verified: a
    // planted `FileHandle(forUpdating:)` + bare `data.write(to:)` in
    // WPECachedContentResolver turned both red.

    private static let productionRoots = [
        "LiveWallpaper",
        "SteamConnector",
        "Packages/LiveWallpaperCore/Sources",
        "Packages/LiveWallpaperProWPE/Sources",
    ]

    /// `FileHandle(forUpdating:)` / `forUpdatingAtPath:` open an existing file
    /// for in-place rewriting — exactly the operation that SIGBUSes a mapped
    /// reader. There is no legitimate use anywhere in production.
    @Test("The in-place update API is absent from all production sources")
    func inPlaceUpdateAPIIsAbsent() throws {
        var hits: [String] = []
        for root in Self.productionRoots {
            for file in RepositoryRoot.swiftFiles(under: root) where !file.path.contains("/Tests/") {
                let source = try String(contentsOf: file, encoding: .utf8)
                if source.contains("forUpdating") {
                    hits.append(file.path)
                }
            }
        }
        #expect(
            hits.isEmpty,
            Comment(rawValue: "FileHandle(forUpdating…) rewrites a file in place and will SIGBUS any process mapping it (scene.pkg stays mapped for the whole scene lifetime). Replace via write-temp + rename instead:\n\(hits.joined(separator: "\n"))")
        )
    }

    /// Content-handling surface: everything that touches workshop items,
    /// installed scenes, scene caches, or the Steam library. Any write-capable
    /// file open added here must be re-audited against the mmap invariant
    /// (mapped files may be deleted or rename-replaced, never rewritten in
    /// place) and then recorded below with its occurrence count.
    private static let fencedRoots = [
        "LiveWallpaper/Infrastructure",
        "LiveWallpaper/VideoPlayback",
        "LiveWallpaper/Runtime",
        "SteamConnector",
        "Packages/LiveWallpaperProWPE/Sources",
    ]

    private static let writePatterns = [
        "FileHandle(forWritingTo",
        "forWritingAtPath",
        "forWriting:",
        ".write(to",
        "createFile(",
        "ftruncate",
        "truncateFile",
        "O_WRONLY",
        "O_RDWR",
    ]

    /// Audited 2026-08-16: every entry writes to a fresh temp/staging/cache
    /// path or uses `.atomic` (write-temp + rename). None opens an existing
    /// mapped file for writing.
    private static let auditedWriteSites: [String: [String: Int]] = [
        // Audited 2026-08-24: writes a `<sha256>.<uuid>.tmp` under the app's own
        // Caches / Application Support dir and renames it into place. Never touches
        // a mapped package — the bytes are Workshop preview images and query pages
        // fetched over the network, and the directory is created by this type, not
        // opened from scene content. (Shared by WorkshopPreviewDiskCache and
        // WorkshopQueryCache since 2026-09-02.)
        "LiveWallpaper/Infrastructure/Workshop/WorkshopDiskCacheStore.swift": [".write(to": 1],
        "LiveWallpaper/Infrastructure/Platform/DesktopPictureFrameExtractor.swift": [".write(to": 1],
        "LiveWallpaper/Infrastructure/Diagnostics/WPESceneDebugArtifacts.swift": [
            "createFile(": 1,
            "FileHandle(forWritingTo": 1,
            ".write(to": 2,
        ],
        "LiveWallpaper/Infrastructure/Assets/WallpaperEnginePackage.swift": [
            "createFile(": 1,
            "FileHandle(forWritingTo": 1,
        ],
        "LiveWallpaper/Infrastructure/Assets/WPEPackageSceneAssetProvider.swift": [
            "createFile(": 1,
            "FileHandle(forWritingTo": 1,
        ],
        "LiveWallpaper/Infrastructure/Assets/WPEVideoTextureDiskCache.swift": [".write(to": 1],
        // Audited 2026-08-18: extraction streams into a fresh dot-prefixed
        // staging file in the app's own Videos/ dir (never the mapped pkg,
        // which stays open read-only); the two `.write(to` are the thumbnail
        // JPEG and the manifest, both `.atomic`.
        "LiveWallpaper/Infrastructure/Services/WallpaperExportService.swift": [
            "createFile(": 1,
            "FileHandle(forWritingTo": 1,
            ".write(to": 2,
        ],
        "LiveWallpaper/VideoPlayback/OggAudioTranscoder.swift": ["forWriting:": 1],
        // Audited 2026-08-22: the MSL translation cache writes JSON under the
        // app's own Caches/wpe-msl/v<schema> dir — never a scene content path,
        // and `.atomic`, so a concurrent reader never sees a partial file.
        "LiveWallpaper/Runtime/Metal/WPEShaderCompiler.swift": [".write(to": 1],
        "LiveWallpaper/Runtime/Metal/WPEMetalSceneRenderer+Debug.swift": [".write(to": 2],
        "LiveWallpaper/Runtime/Metal/WPEMetalPassGPUProfiler.swift": [".write(to": 1],
        "SteamConnector/SteamConnectorProtocol.swift": [".write(to": 1],
    ]

    @Test("Write-capable file opens in the content surface stay on the audited allowlist")
    func writeCapableOpensStayAudited() throws {
        var sweptFiles = 0
        var observed: [String: [String: Int]] = [:]
        for root in Self.fencedRoots {
            for file in RepositoryRoot.swiftFiles(under: root) where !file.path.contains("/Tests/") {
                sweptFiles += 1
                let source = try String(contentsOf: file, encoding: .utf8)
                let relativePath = RepositoryRoot.relativePath(of: file)
                for pattern in Self.writePatterns {
                    let count = source.components(separatedBy: pattern).count - 1
                    if count > 0 {
                        observed[relativePath, default: [:]][pattern] = count
                    }
                }
            }
        }
        #expect(sweptFiles > 100, "Content-surface sweep collapsed to \(sweptFiles) files")

        var violations: [String] = []
        for (file, patterns) in observed {
            for (pattern, count) in patterns where count > (Self.auditedWriteSites[file]?[pattern] ?? 0) {
                violations.append("\(file): `\(pattern)` ×\(count) (audited ×\(Self.auditedWriteSites[file]?[pattern] ?? 0))")
            }
        }
        let stale = Self.auditedWriteSites.flatMap { file, patterns in
            patterns.compactMap { pattern, expected -> String? in
                let actual = observed[file]?[pattern] ?? 0
                return actual == expected ? nil : "\(file): `\(pattern)` audited ×\(expected), found ×\(actual)"
            }
        }
        #expect(
            violations.isEmpty,
            Comment(rawValue: "Unaudited write-capable open in the content surface. Mapped files (scene.pkg, loose scene assets) may be deleted or rename-replaced, never opened for in-place writing — audit the new site, then record it:\n\(violations.sorted().joined(separator: "\n"))")
        )
        #expect(
            stale.isEmpty,
            Comment(rawValue: "Write-site allowlist drifted; shrink or re-audit it:\n\(stale.sorted().joined(separator: "\n"))")
        )
    }
}
