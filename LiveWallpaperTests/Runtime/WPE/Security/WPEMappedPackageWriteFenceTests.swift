import Foundation
import Testing
@testable import LiveWallpaper

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

        let replacement = dir.appendingPathComponent("scene.pkg.tmp")
        try Self.makePackageData([(name: "materials/a.tex", data: newPayload)]).write(to: replacement)
        _ = try FileManager.default.replaceItemAt(pkgURL, withItemAt: replacement)

        #expect(window.materializedData() == oldPayload)

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

    /// `swiftFiles(under:)` returns [] for a path that does not exist and reports no error, so a renamed root
    /// must be named, not merely folded into an aggregate file count. Every root below is a
    /// production tree with no test sources under it, so nothing here filters them out —
    /// adding a root that carries its own `Tests/` needs that decided again, not assumed.
    private static func sweep(_ roots: [String]) -> (files: [URL], emptyRoots: [String]) {
        var files: [URL] = []
        var emptyRoots: [String] = []
        for root in roots {
            let found = RepositoryRoot.swiftFiles(under: root)
            if found.isEmpty {
                emptyRoots.append(root)
            }
            files.append(contentsOf: found)
        }
        return (files, emptyRoots)
    }

    private static func staleRootComment(_ emptyRoots: [String]) -> Comment {
        Comment(rawValue: "Scan root matches no sources — renamed or deleted directory, leaving that tree unguarded: \(emptyRoots.joined(separator: ", "))")
    }

    private static let productionRoots = [
        "LiveWallpaper",
        "SteamConnector",
        "Packages/LiveWallpaperCore/Sources",
        "Packages/LiveWallpaperProWPE/Sources",
    ]

    @Test("The in-place update API is absent from all production sources")
    func inPlaceUpdateAPIIsAbsent() throws {
        let (files, emptyRoots) = Self.sweep(Self.productionRoots)
        #expect(emptyRoots.isEmpty, Self.staleRootComment(emptyRoots))

        var hits: [String] = []
        for file in files {
            let source = try String(contentsOf: file, encoding: .utf8)
            if source.contains("forUpdating") {
                hits.append(file.path)
            }
        }
        #expect(
            hits.isEmpty,
            Comment(rawValue: "FileHandle(forUpdating…) rewrites a file in place and will SIGBUS any process mapping it (scene.pkg stays mapped for the whole scene lifetime). Replace via write-temp + rename instead:\n\(hits.joined(separator: "\n"))")
        )
    }

    /// Every write-capable open under these roots must be audited against the mmap invariant (delete or
    /// rename-replace only, never an in-place rewrite) and then recorded in `auditedWriteSites` with its count.
    private static let fencedRoots = [
        "LiveWallpaper/Infrastructure",
        "LiveWallpaper/Playback",
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

    private static let auditedWriteSites: [String: [String: Int]] = [
        "LiveWallpaper/Infrastructure/Workshop/WorkshopDiskCacheStore.swift": [".write(to": 1],
        "LiveWallpaper/Infrastructure/Platform/DesktopPictureFrameExtractor.swift": [".write(to": 1],
        "LiveWallpaper/Infrastructure/Persistence/WallpaperCoverStore.swift": [".write(to": 1],
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
        "LiveWallpaper/Infrastructure/Services/WallpaperExportService.swift": [
            "createFile(": 1,
            "FileHandle(forWritingTo": 1,
            // manifest.json, heartbeat-adjacent provider.json — atomic writes into the app's own container, never a mapped scene file.
            ".write(to": 3,
        ],
        "LiveWallpaper/Runtime/Audio/OggAudioTranscoder.swift": ["forWriting:": 1],
        "LiveWallpaper/Runtime/Metal/WPEShaderCompiler.swift": [".write(to": 1],
        "LiveWallpaper/Runtime/Metal/WPEMetalSceneRenderer+Debug.swift": [".write(to": 2],
        "LiveWallpaper/Runtime/Metal/WPEMetalPassGPUProfiler.swift": [".write(to": 1],
        "SteamConnector/SteamConnectorProtocol.swift": [".write(to": 1, "O_RDWR": 1],
        "SteamConnector/SteamLibraryWriter.swift": ["O_WRONLY": 1],
    ]

    @Test("Write-capable file opens in the content surface stay on the audited allowlist")
    func writeCapableOpensStayAudited() throws {
        let (files, emptyRoots) = Self.sweep(Self.fencedRoots)
        #expect(emptyRoots.isEmpty, Self.staleRootComment(emptyRoots))

        var observed: [String: [String: Int]] = [:]
        for file in files {
            let source = try String(contentsOf: file, encoding: .utf8)
            let relativePath = RepositoryRoot.relativePath(of: file)
            for pattern in Self.writePatterns {
                let count = source.components(separatedBy: pattern).count - 1
                if count > 0 {
                    observed[relativePath, default: [:]][pattern] = count
                }
            }
        }
        #expect(files.count > 100, "Content-surface sweep collapsed to \(files.count) files")

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
