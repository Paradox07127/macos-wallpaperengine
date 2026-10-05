#if !LITE_BUILD
import Foundation
import LiveWallpaperCore

/// Disjoint app-owned locations. Parent buckets exclude all catalogued children,
/// including hidden files; directory symlinks are never followed during a walk.
struct AppStorageLocation: Sendable, Identifiable {
    enum Kind: String, Sendable, CaseIterable {
        case video, query, previews, shaders, audio, webCache
        case configuration, covers, legacyScenes, diagnostics, logs
        case webData, preferences, support, systemCaches, temporary, systemMetadata
        case steamTools, steamProfiles, credentials, application, localWallpapers

        var isCache: Bool {
            [.video, .query, .previews, .shaders, .audio, .webCache, .systemCaches].contains(self)
        }

        var canClear: Bool {
            [.video, .query, .previews, .shaders, .audio, .webCache].contains(self)
        }

        /// Account and application data are informational; reveal only content and regenerable files.
        var canRevealInFinder: Bool {
            switch self {
            case .video, .query, .previews, .shaders, .audio, .webCache,
                 .covers, .legacyScenes, .diagnostics, .logs, .temporary, .localWallpapers: true
            default: false
            }
        }
    }

    let kind: Kind
    let url: URL
    var id: String {
        kind.rawValue + ":" + url.path
    }
}

struct AppStorageMeasurement: Sendable, Identifiable {
    enum Status: Sendable { case complete, missing, unavailable, partial }
    let location: AppStorageLocation
    let bytes: UInt64
    let fileCount: Int
    let status: Status
    var id: String {
        location.id
    }
}

/// `path` is `root` or lies beneath it; `root` may already end in "/" (the volume root).
func storagePath(_ path: String, isWithin root: String) -> Bool {
    path == root || path.hasPrefix(root.hasSuffix("/") ? root : root + "/")
}

actor AppStorageScanner {
    static let shared = AppStorageScanner()
    private let fileManager = FileManager()

    func scan(_ locations: [AppStorageLocation], excluding externalRoots: [URL] = [], budget: Int = 200_000) -> [AppStorageMeasurement] {
        locations.map { location in
            let exclusions = locations.filter { $0.id != location.id }.map(\.url) + externalRoots
            return measure(location, excluding: exclusions, budget: budget)
        }
    }

    private func measure(_ location: AppStorageLocation, excluding exclusions: [URL], budget: Int) -> AppStorageMeasurement {
        var bytes: UInt64 = 0
        var count = 0
        var status: AppStorageMeasurement.Status = .complete
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey,
                                         .totalFileAllocatedSizeKey, .fileAllocatedSizeKey]
        func result() -> AppStorageMeasurement {
            AppStorageMeasurement(location: location, bytes: bytes, fileCount: count, status: status)
        }
        let root = location.url.standardizedFileURL
        if exclusions.contains(where: { $0.standardizedFileURL == root }) {
            return result()
        }
        let rootValues: URLResourceValues
        do {
            rootValues = try root.resourceValues(forKeys: keys)
        } catch {
            let cocoa = error as NSError
            status = cocoa.domain == NSCocoaErrorDomain &&
                [NSFileNoSuchFileError, NSFileReadNoSuchFileError].contains(cocoa.code) ? .missing : .unavailable
            return result()
        }
        guard rootValues.isSymbolicLink != true else { status = .unavailable; return result() }
        if rootValues.isRegularFile == true {
            bytes = UInt64(max(0, rootValues.totalFileAllocatedSize ?? rootValues.fileAllocatedSize ?? 0))
            count = 1
            return result()
        }
        guard rootValues.isDirectory == true else { status = .unavailable; return result() }
        let excludedPaths = exclusions.map(\.standardizedFileURL.path)
            .filter { storagePath($0, isWithin: root.path) }
        guard let enumerator = fileManager.enumerator(
            at: root, includingPropertiesForKeys: Array(keys), options: [],
            errorHandler: { _, _ in status = .partial; return true }
        ) else { status = .unavailable; return result() }
        var visited = 0
        for case let item as URL in enumerator {
            guard !Task.isCancelled, visited < budget else { status = .partial; break }
            visited += 1
            if excludedPaths.contains(item.standardizedFileURL.path) {
                enumerator.skipDescendants()
                continue
            }
            do {
                let values = try item.resourceValues(forKeys: keys)
                if values.isSymbolicLink == true {
                    enumerator.skipDescendants(); continue
                }
                guard values.isRegularFile == true else { continue }
                bytes += UInt64(max(0, values.totalFileAllocatedSize ?? values.fileAllocatedSize ?? 0))
                count += 1
            } catch { status = .partial }
        }
        return result()
    }
}

extension AppStorageLocation {
    @MainActor
    static func current(systemWallpaperRoot: URL) -> [AppStorageLocation] {
        let fm = FileManager.default
        let support = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let caches = fm.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        let library = support.deletingLastPathComponent()
        let configuration = ConfigurationDirectory().root
        let legacy = support.appendingPathComponent("LiveWallpaper", isDirectory: true)
        let realSupport = SystemWallpaperPaths.realHomeDirectory.appendingPathComponent("Library/Application Support/Loomscreen", isDirectory: true)
        return [
            .init(kind: .video, url: WPEVideoTextureDiskCache.defaultRootURL),
            .init(kind: .query, url: WorkshopQueryCache.defaultDirectoryURL()),
            .init(kind: .previews, url: WorkshopPreviewDiskCache.defaultDirectoryURL()),
            .init(kind: .shaders, url: WPEShaderTranslationCache.defaultRootURL),
            .init(kind: .audio, url: OggAudioTranscoder.defaultCacheDirectory),
            .init(kind: .webCache, url: caches.appendingPathComponent("WebKit", isDirectory: true)),
            .init(kind: .configuration, url: configuration),
            .init(kind: .covers, url: configuration.appendingPathComponent("Covers", isDirectory: true)),
            .init(kind: .legacyScenes, url: legacy.appendingPathComponent("wpe-cache", isDirectory: true)),
            .init(kind: .diagnostics, url: legacy),
            .init(kind: .logs, url: Logger.persistentLogFileURL?.deletingLastPathComponent()
                ?? library.appendingPathComponent("Logs/LiveWallpaper", isDirectory: true)),
            .init(kind: .webData, url: library.appendingPathComponent("WebKit", isDirectory: true)),
            .init(kind: .preferences, url: library.appendingPathComponent("Preferences", isDirectory: true)),
            .init(kind: .support, url: support),
            .init(kind: .systemCaches, url: caches),
            .init(kind: .temporary, url: fm.temporaryDirectory),
            .init(kind: .systemMetadata, url: systemWallpaperRoot),
            .init(kind: .steamTools, url: realSupport.appendingPathComponent("SteamCMD", isDirectory: true)),
            .init(kind: .steamProfiles, url: realSupport.appendingPathComponent("SteamCMDProfiles", isDirectory: true)),
            .init(kind: .credentials, url: support.appendingPathComponent("Workshop/steam-webapi.key", isDirectory: false)),
            .init(kind: .application, url: Bundle.main.bundleURL),
        ]
    }
}
#endif
