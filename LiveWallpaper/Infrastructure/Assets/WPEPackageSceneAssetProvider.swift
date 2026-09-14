#if !LITE_BUILD
import Foundation
import LiveWallpaperCore
import LiveWallpaperProWPE

/// Reads packed scene assets in place with serialized seeks and mapped staging for large entries.
final class WPEPackageSceneAssetProvider: WPESceneAssetProvider, @unchecked Sendable {
    /// Entries above 64 MiB are staged and mapped to bound resident memory.
    private static let mmapThreshold: UInt64 = 64 * 1024 * 1024
    private static let copyChunkSize = 1 << 20
    /// Name prefix shared by every per-session staging directory under
    /// `NSTemporaryDirectory()`. The launch-time sweep keys off it.
    static let stagingDirectoryNamePrefix = "LiveWallpaper-WPEPkgStage-"

    private let package: WallpaperEnginePackage
    private let handle: FileHandle
    private let packageURL: URL
    private let lock = NSLock()
    private let stagingRoot: URL
    private var stagedPaths: [String: URL] = [:]
    /// Costs address space, not resident memory; clean pages are kernel-reclaimable.
    private var mappedPackageData: Data?

    init(packageURL: URL) throws {
        self.stagingRoot = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("\(Self.stagingDirectoryNamePrefix)\(UUID().uuidString)", isDirectory: true)
        let handle = try FileHandle(forReadingFrom: packageURL)
        do {
            self.package = try WallpaperEnginePackage.parseIndex(streamingFrom: handle)
        } catch {
            try? handle.close()
            throw error
        }
        self.handle = handle
        self.packageURL = packageURL
        Self.logCaseFoldCollisions(in: package)
    }

    static func open(
        packageURL: URL,
        limits: WallpaperEnginePackage.IndexLimits = .production
    ) async throws -> WPEPackageSceneAssetProvider {
        let prepared = try await WPEPackageIndexLoader.load(from: packageURL, limits: limits)
        do {
            try Task.checkCancellation()
        } catch {
            try? prepared.handle.close()
            throw error
        }
        return WPEPackageSceneAssetProvider(prepared: prepared, packageURL: packageURL)
    }

    private init(prepared: WPEPackageIndexLoader.PreparedPackage, packageURL: URL) {
        self.stagingRoot = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("\(Self.stagingDirectoryNamePrefix)\(UUID().uuidString)", isDirectory: true)
        self.package = prepared.package
        self.handle = prepared.handle
        self.packageURL = packageURL
        Self.logCaseFoldCollisions(in: prepared.package)
    }

    var caseFoldCollisions: [WallpaperEnginePackage.CaseFoldCollision] {
        package.caseFoldCollisions
    }

    private static func logCaseFoldCollisions(in package: WallpaperEnginePackage) {
        guard !package.caseFoldCollisions.isEmpty else { return }
        Logger.warning(
            "PKG_CASE_FOLD_COLLISION: package contains \(package.caseFoldCollisions.count) "
                + "case-insensitive entry collision(s); the first entry remains authoritative",
            category: .fileAccess
        )
    }

    deinit {
        try? handle.close()
        try? FileManager.default.removeItem(at: stagingRoot)
    }

    // MARK: - Stale staging-dir sweep

    static func staleStagingDirectoryNames(in entries: [String]) -> [String] {
        entries.filter { $0.hasPrefix(stagingDirectoryNamePrefix) }
    }

    /// Best-effort: anything that can't be listed or removed is skipped rather than throwing.
    @discardableResult
    static func sweepStaleStagingDirectories(
        in directory: URL = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true),
        fileManager: FileManager = .default
    ) -> Int {
        guard let entries = try? fileManager.contentsOfDirectory(atPath: directory.path) else {
            return 0
        }
        var removed = 0
        for name in staleStagingDirectoryNames(in: entries) {
            let url = directory.appendingPathComponent(name, isDirectory: true)
            if (try? fileManager.removeItem(at: url)) != nil {
                removed += 1
            }
        }
        return removed
    }

    @discardableResult
    static func sweepStaleStagingDirectoriesAtLaunch(
        in directory: URL = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
    ) async -> Int {
        await Task.detached(priority: .utility) {
            let removed = sweepStaleStagingDirectories(in: directory)
            if removed > 0 {
                Logger.notice("Swept \(removed) stale WPE package staging dir(s)", category: .startup)
            }
            return removed
        }.value
    }

    func data(atRelativePath relativePath: String) throws -> Data {
        let entry = try packageEntry(for: relativePath)
        lock.lock()
        defer { lock.unlock() }
        return try entryDataLocked(entry, relativePath: relativePath)
    }

    private func entryDataLocked(
        _ entry: WallpaperEnginePackage.Entry,
        relativePath: String
    ) throws -> Data {
        if entry.dataSize > Self.mmapThreshold {
            let url = try stageEntryLocked(entry, relativePath: relativePath)
            do {
                return try Data(contentsOf: url, options: [.mappedIfSafe])
            } catch {
                throw WPESceneAssetProviderError.unreadable(relativePath)
            }
        }
        do {
            return try package.readEntry(entry, from: handle)
        } catch {
            throw WPESceneAssetProviderError.unreadable(relativePath)
        }
    }

    /// Truncating or rewriting the pkg in place while a scene plays would SIGBUS on the next page fault; writers must swap by rename.
    func mappedWindow(atRelativePath relativePath: String) throws -> WPEMappedByteSpan {
        let entry = try packageEntry(for: relativePath)
        lock.lock()
        defer { lock.unlock() }
        // On a volume that cannot be mapped, fall back per-entry so residency stays bounded by the entry instead of pinning the whole package on the heap.
        guard InMemoryVideoAssetLoader.isVolumeMappable(packageURL) else {
            return WPEMappedByteSpan(
                data: try entryDataLocked(entry, relativePath: relativePath)
            )
        }
        let mapped: Data
        if let existing = mappedPackageData {
            mapped = existing
        } else {
            do {
                mapped = try Data(contentsOf: packageURL, options: [.mappedIfSafe])
            } catch {
                throw WPESceneAssetProviderError.unreadable(relativePath)
            }
            mappedPackageData = mapped
        }
        let start = Int(package.dataStart + entry.dataOffset)
        let end = start + Int(entry.dataSize)
        guard start >= 0, end <= mapped.count else {
            throw WPESceneAssetProviderError.unreadable(relativePath)
        }
        return WPEMappedByteSpan(owner: mapped, range: start..<end)
    }

    func stagedURL(atRelativePath relativePath: String) throws -> URL {
        let entry = try packageEntry(for: relativePath)
        lock.lock()
        defer { lock.unlock() }
        return try stageEntryLocked(entry, relativePath: relativePath)
    }

    func exists(atRelativePath relativePath: String) -> Bool {
        (try? packageEntry(for: relativePath)) != nil
    }

    var entryNames: [String] {
        package.entries.map(\.name).sorted()
    }

    private func packageEntry(for relativePath: String) throws -> WallpaperEnginePackage.Entry {
        guard let lookupName = WallpaperEnginePackage.canonicalLookupName(relativePath) else {
            throw WPESceneAssetProviderError.invalidRelativePath(relativePath)
        }
        guard let entry = package.entry(named: lookupName) else {
            throw WPESceneAssetProviderError.fileMissing(relativePath)
        }
        return entry
    }

    /// Chunked so a large entry never fully materializes in RAM. Caller holds `lock`.
    private func stageEntryLocked(_ entry: WallpaperEnginePackage.Entry, relativePath: String) throws -> URL {
        if let existing = stagedPaths[entry.name],
           FileManager.default.fileExists(atPath: existing.path) {
            return existing
        }
        do {
            try FileManager.default.createDirectory(at: stagingRoot, withIntermediateDirectories: true)
            let safeName = (entry.name as NSString).lastPathComponent
            let target = stagingRoot.appendingPathComponent(
                "\(stagedPaths.count)-\(safeName.isEmpty ? "asset" : safeName)",
                isDirectory: false
            )
            FileManager.default.createFile(atPath: target.path, contents: nil)
            let writer = try FileHandle(forWritingTo: target)
            do {
                try handle.seek(toOffset: package.dataStart + entry.dataOffset)
                var remaining = entry.dataSize
                while remaining > 0 {
                    let toRead = Int(min(UInt64(Self.copyChunkSize), remaining))
                    guard let chunk = try handle.read(upToCount: toRead), chunk.count == toRead else {
                        throw WPESceneAssetProviderError.unreadable(relativePath)
                    }
                    try writer.write(contentsOf: chunk)
                    remaining -= UInt64(chunk.count)
                }
                try writer.close()
            } catch {
                try? writer.close()
                try? FileManager.default.removeItem(at: target)
                throw error
            }
            stagedPaths[entry.name] = target
            return target
        } catch let error as WPESceneAssetProviderError {
            throw error
        } catch {
            throw WPESceneAssetProviderError.stagingUnavailable(relativePath)
        }
    }
}
#endif
