import AppKit
import AVFoundation
import Foundation
import LiveWallpaperCore
import Observation

/// Publishes library videos into the shared directory the wallpaper appex
/// reads (plan §4.5), and mirrors the appex's heartbeat back into UI state.
/// Both SKUs ship this — the system-wallpaper outlet is not Pro-gated.
@MainActor
@Observable
final class WallpaperExportService {
    struct Dependencies {
        let sharedRoot: URL
        let resolver: SecurityScopedBookmarkResolver
        let now: @Sendable () -> Date
        /// JPEG data (480×270 target) for the already-copied video, nil on failure.
        let makeThumbnailJPEG: @Sendable (URL) async -> Data?
        let osSupported: Bool

        static func live(hostBundleID: String? = Bundle.main.bundleIdentifier) -> Dependencies {
            let supported: Bool
            if #available(macOS 26.0, *) { supported = true } else { supported = false }
            return Dependencies(
                sharedRoot: SystemWallpaperPaths.sharedRoot(hostBundleID: hostBundleID ?? "com.loomscreen"),
                resolver: .live,
                now: Date.init,
                makeThumbnailJPEG: WallpaperExportService.generateThumbnailJPEG,
                osSupported: supported
            )
        }
    }

    enum ServiceError: LocalizedError, Equatable {
        /// Only loose video files are publishable in v1 — pkg-embedded videos
        /// and other content kinds have no file the appex could read.
        case unsupportedContent
        case packageEntryMissing(String)
        /// The wallpaper panel refuses to show a choice without a thumbnail,
        /// so a publish that cannot produce one has not published anything.
        case thumbnailFailed

        var errorDescription: String? {
            switch self {
            case .unsupportedContent:
                return String(localized: "Only video wallpapers can be added to System Wallpaper.")
            case .packageEntryMissing(let name):
                return String(
                    localized: "The video “\(name)” is missing from its Workshop package.",
                    comment: "Error shown when a Workshop wallpaper's packaged video cannot be located."
                )
            case .thumbnailFailed:
                return String(
                    localized: "Couldn't create a preview image for this video.",
                    comment: "Error shown when publishing to System Wallpaper fails because no thumbnail could be generated."
                )
            }
        }
    }

    enum Status: Equatable {
        case unsupported
        case systemIncompatible
        case failed(String)
        case empty
        case publishedNotSelected
        case inUse(itemTitle: String)
    }

    /// Heartbeat younger than this counts as "the system is driving us now".
    /// 300 s is provisional — recalibrate once the real acquire/update cadence
    /// is measured (plan §3 U5).
    static let heartbeatFreshnessInterval: TimeInterval = 300

    private(set) var items: [SystemWallpaperManifest.Item] = []
    private(set) var heartbeat: SystemWallpaperHeartbeat?
    private(set) var lastError: String?
    private(set) var diskUsageBytes: Int64 = 0
    private(set) var playbackMode: SystemWallpaperPlaybackMode = .always

    @ObservationIgnored private let dependencies: Dependencies

    init(dependencies: Dependencies = .live()) {
        self.dependencies = dependencies
        // Load once so the library context menu sees published state before
        // the settings panel ever opens. Two tiny JSON reads.
        refresh()
    }

    // MARK: - Paths (contract layout, SystemWallpaperManifest.swift)

    private var manifestURL: URL { dependencies.sharedRoot.appendingPathComponent("manifest.json") }
    private var heartbeatURL: URL { dependencies.sharedRoot.appendingPathComponent("heartbeat.json") }
    var videosDirectory: URL { dependencies.sharedRoot.appendingPathComponent("Videos", isDirectory: true) }

    func thumbnailURL(for item: SystemWallpaperManifest.Item) -> URL? {
        item.thumbnailFileName.map { videosDirectory.appendingPathComponent($0) }
    }

    // MARK: - Status

    var status: Status {
        guard dependencies.osSupported else { return .unsupported }
        // An "incompatible" verdict is only as good as the OS build that
        // reached it — after an update, ignore the old build's verdict until
        // the extension has run again (nil = pre-osVersion heartbeat, honored
        // to keep the old behaviour).
        if let heartbeat, !heartbeat.runtimeHealthy,
           heartbeat.osVersion == nil
               || heartbeat.osVersion == SystemWallpaperHeartbeat.currentOSVersion() {
            return .systemIncompatible
        }
        if let lastError { return .failed(lastError) }
        guard !items.isEmpty else { return .empty }
        // Any item on any display counts — after removing the display-1 choice,
        // the display-2 one keeps this in the in-use state.
        if let heartbeat, isFresh(heartbeat),
           let item = items.first(where: { heartbeat.showsChoice($0.id) }) {
            return .inUse(itemTitle: item.title)
        }
        return .publishedNotSelected
    }

    func isPublished(bookmarkID: UUID) -> Bool {
        items.contains { $0.id == bookmarkID.uuidString }
    }

    func isItemInUse(_ itemID: String) -> Bool {
        guard let heartbeat, isFresh(heartbeat) else { return false }
        return heartbeat.showsChoice(itemID)
    }

    private func isFresh(_ heartbeat: SystemWallpaperHeartbeat) -> Bool {
        dependencies.now().timeIntervalSince(heartbeat.timestamp) < Self.heartbeatFreshnessInterval
    }

    // MARK: - Publish / remove

    /// Where the video bytes come from. Bookmarked library entries need a fresh
    /// security-scoped resolve; a file the user just picked in an open panel is
    /// already readable and would only lose access by round-tripping through a
    /// bookmark.
    private enum PublishSource {
        case bookmark(data: Data, packageEntryName: String?)
        case pickedFile(URL)
    }

    func publish(bookmark: WallpaperBookmark) async throws {
        guard case .video(let data, let entryName) = bookmark.content else {
            let error = ServiceError.unsupportedContent
            lastError = error.localizedDescription
            throw error
        }
        try await publish(
            id: bookmark.id.uuidString,
            title: bookmark.label,
            source: .bookmark(data: data, packageEntryName: entryName)
        )
    }

    /// A video the user picked in an open panel: it never has to become a
    /// bookmark, because publishing copies it into the shared directory anyway.
    func publish(fileURL: URL) async throws {
        try await publish(
            id: UUID().uuidString,
            title: fileURL.deletingPathExtension().lastPathComponent,
            source: .pickedFile(fileURL)
        )
    }

    /// Content resolved from an installed Workshop entry that the user has not
    /// bookmarked (the Workshop library keeps its own list).
    func publish(content: WallpaperContent, title: String) async throws {
        guard case .video(let data, let entryName) = content else {
            let error = ServiceError.unsupportedContent
            lastError = error.localizedDescription
            throw error
        }
        try await publish(
            id: UUID().uuidString,
            title: title,
            source: .bookmark(data: data, packageEntryName: entryName)
        )
    }

    private func publish(id: String, title: String, source: PublishSource) async throws {
        do {
            try await performPublish(id: id, title: title, source: source)
            lastError = nil
        } catch {
            lastError = error.localizedDescription
            Logger.warning(
                "[systemWallpaper] publish failed for \(id): \(error.localizedDescription)",
                category: .fileAccess
            )
            throw error
        }
    }

    private func performPublish(id itemID: String, title: String, source: PublishSource) async throws {
        let resolver = dependencies.resolver
        let videosDirectory = videosDirectory

        // Copy off the main actor — a 4K source can be hundreds of MB. Bookmarks
        // are resolved fresh every time and the URL is never cached (resolver contract).
        // Everything lands in a uniquely-named staging file first: the live copy
        // (a republish target) is only touched by the atomic swap below, after
        // the thumbnail has succeeded — so no failure mode can leave a manifest
        // entry pointing at a missing or half-written file.
        struct Staged { let url: URL; let ext: String }
        let staged: Staged = try await Task.detached(priority: .userInitiated) {
            let sourceURL: URL
            let packageEntryName: String?
            switch source {
            case .bookmark(let data, let entryName):
                sourceURL = try resolver.resolve(data, target: .transient).get().url
                packageEntryName = entryName
            case .pickedFile(let url):
                sourceURL = url
                packageEntryName = nil
            }

            let sourceName = packageEntryName ?? sourceURL.lastPathComponent
            let ext = (sourceName as NSString).pathExtension.isEmpty
                ? "mov"
                : (sourceName as NSString).pathExtension
            // Unique name: two concurrent publishes of the same bookmark must
            // not fight over one staging path. The dot prefix plus the orphan
            // sweep's age guard keeps sweeps away from it.
            let staging = videosDirectory
                .appendingPathComponent(".\(itemID)-\(UUID().uuidString).\(ext).partial")
            let manager = FileManager.default
            try manager.createDirectory(at: videosDirectory, withIntermediateDirectories: true)
            do {
                try SecurityScopedBookmarkResolver.withScopedAccess(sourceURL) { _ in
                    if let packageEntryName {
                        try Self.extractPackagedVideo(
                            packageURL: sourceURL,
                            entryName: packageEntryName,
                            to: staging
                        )
                    } else {
                        try manager.copyItem(at: sourceURL, to: staging)
                        // copyItem preserves the source's mtime; the orphan
                        // sweep's age guard keys off it, and a year-old source
                        // would read as sweepable while still mid-publish.
                        try? manager.setAttributes(
                            [.modificationDate: Date()], ofItemAtPath: staging.path
                        )
                    }
                }
            } catch {
                try? manager.removeItem(at: staging)
                throw error
            }
            return Staged(url: staging, ext: ext)
        }.value

        // Thumbnail from the staging copy, so a failure aborts before the live
        // copy or the manifest is touched. No thumbnail means no tile in the
        // wallpaper panel (the provider skips it), so this is a failed publish,
        // not a cosmetic downgrade.
        guard let jpeg = await dependencies.makeThumbnailJPEG(staged.url) else {
            try? FileManager.default.removeItem(at: staged.url)
            throw ServiceError.thumbnailFailed
        }

        let destination = videosDirectory.appendingPathComponent("\(itemID).\(staged.ext)")
        let manager = FileManager.default
        do {
            if manager.fileExists(atPath: destination.path) {
                // Atomic swap — no window where the old copy is gone and the
                // new one is not yet in place.
                _ = try manager.replaceItemAt(destination, withItemAt: staged.url)
            } else {
                try manager.moveItem(at: staged.url, to: destination)
            }
        } catch {
            try? manager.removeItem(at: staged.url)
            throw error
        }
        let thumbnailURL = videosDirectory.appendingPathComponent("\(itemID).jpg")
        try jpeg.write(to: thumbnailURL, options: .atomic)
        let thumbnailFileName = thumbnailURL.lastPathComponent

        let manifest = try SystemWallpaperLock.withExclusiveLock(root: dependencies.sharedRoot) {
            var manifest = loadManifest() ?? .empty
            manifest.items.removeAll { $0.id == itemID }
            manifest.items.append(SystemWallpaperManifest.Item(
                id: itemID,
                title: title,
                fileName: destination.lastPathComponent,
                thumbnailFileName: thumbnailFileName,
                addedAt: dependencies.now()
            ))
            try writeManifest(manifest)
            return manifest
        }
        items = manifest.items
        refreshDiskUsage()
        postLibraryChanged()
    }

    /// Removing the item macOS is showing is allowed: the wallpaper panel's own
    /// Remove crashes on third-party choices (macOS 27.0), so refusing here
    /// would leave the user with no way to delete the files at all. The
    /// confirmation states what macOS does afterwards.
    func remove(itemID: String) throws {
        let manifest: SystemWallpaperManifest?
        do {
            manifest = try SystemWallpaperLock.withExclusiveLock(root: dependencies.sharedRoot) {
                let removed = try SystemWallpaperLibrary.remove(
                    id: itemID,
                    from: loadManifest() ?? .empty,
                    videosDirectory: videosDirectory,
                    persist: { try writeManifest($0) }
                )
                if let removed {
                    SystemWallpaperLibrary.sweepOrphans(
                        manifest: removed,
                        videosDirectory: videosDirectory,
                        now: dependencies.now()
                    )
                }
                return removed
            }
            lastError = nil
        } catch {
            lastError = error.localizedDescription
            throw error
        }
        guard let manifest else { return }
        items = manifest.items
        refreshDiskUsage()
        postLibraryChanged()
    }

    func clearLastError() {
        lastError = nil
    }

    // MARK: - Refresh

    /// Called when the panel appears — no resident polling; the panel is the
    /// only reader and it is open a few times a year.
    func setPlaybackMode(_ mode: SystemWallpaperPlaybackMode) {
        guard mode != playbackMode else { return }
        do {
            try SystemWallpaperLock.withExclusiveLock(root: dependencies.sharedRoot) {
                var manifest = loadManifest() ?? .empty
                manifest.playbackMode = mode
                try writeManifest(manifest)
            }
            playbackMode = mode
            lastError = nil
            // The extension observes this over the Darwin notify center
            // (WallpaperXPCBridge.LibraryChangeObserver), so a running
            // wallpaper follows the switch now, not at the next system event.
            postLibraryChanged()
        } catch {
            lastError = error.localizedDescription
        }
    }

    func refresh() {
        let manifest = loadManifest()
        playbackMode = manifest?.playbackMode ?? .always
        items = manifest?.items ?? []
        heartbeat = loadHeartbeat()
        // Reclaim files a crash or a lost manifest update left unreferenced;
        // the age guard inside protects any publish that is mid-copy.
        if let manifest {
            SystemWallpaperLibrary.sweepOrphans(
                manifest: manifest,
                videosDirectory: videosDirectory,
                now: dependencies.now()
            )
        }
        refreshDiskUsage()
    }

    func openWallpaperSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.Wallpaper-Settings.extension") else { return }
        NSWorkspace.shared.open(url)
    }

    /// Workshop videos live inside `scene.pkg` as one contiguous, uncompressed
    /// byte range (the player windows into it the same way rather than
    /// extracting). Streamed in chunks through the already-open handle:
    /// `.mappedIfSafe` degrades to a whole-file heap read on removable and
    /// network volumes, and Steam libraries live on exactly those.
    nonisolated private static func extractPackagedVideo(
        packageURL: URL,
        entryName: String,
        to destination: URL
    ) throws {
        let handle = try FileHandle(forReadingFrom: packageURL)
        defer { try? handle.close() }
        let package = try WallpaperEnginePackage.parseIndex(streamingFrom: handle)

        guard let lookup = WallpaperEnginePackage.canonicalLookupName(entryName),
              let entry = package.entry(named: lookup) else {
            throw ServiceError.packageEntryMissing(entryName)
        }
        guard let start = UInt64(exactly: package.dataStart + entry.dataOffset),
              let length = UInt64(exactly: entry.dataSize) else {
            throw ServiceError.packageEntryMissing(entryName)
        }
        let fileSize = try handle.seekToEnd()
        guard start <= fileSize, length <= fileSize - start else {
            throw ServiceError.packageEntryMissing(entryName)
        }

        let manager = FileManager.default
        try? manager.removeItem(at: destination)
        guard manager.createFile(atPath: destination.path, contents: nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        let out = try FileHandle(forWritingTo: destination)
        defer { try? out.close() }
        try handle.seek(toOffset: start)
        var remaining = length
        let chunkSize: UInt64 = 8 << 20
        while remaining > 0 {
            let want = Int(min(chunkSize, remaining))
            guard let chunk = try handle.read(upToCount: want), !chunk.isEmpty else {
                throw ServiceError.packageEntryMissing(entryName)
            }
            try out.write(contentsOf: chunk)
            remaining -= UInt64(chunk.count)
        }
    }

    // MARK: - Manifest / heartbeat IO

    private func loadManifest() -> SystemWallpaperManifest? {
        guard let data = try? Data(contentsOf: manifestURL) else { return nil }
        // A corrupt manifest reads as empty rather than wedging the panel; the
        // next publish rewrites it whole.
        return try? SystemWallpaperCoding.decoder.decode(SystemWallpaperManifest.self, from: data)
    }

    private func loadHeartbeat() -> SystemWallpaperHeartbeat? {
        guard let data = try? Data(contentsOf: heartbeatURL) else { return nil }
        return try? SystemWallpaperCoding.decoder.decode(SystemWallpaperHeartbeat.self, from: data)
    }

    private func writeManifest(_ manifest: SystemWallpaperManifest) throws {
        try FileManager.default.createDirectory(
            at: dependencies.sharedRoot,
            withIntermediateDirectories: true
        )
        let data = try SystemWallpaperCoding.encoder.encode(manifest)
        try data.write(to: manifestURL, options: .atomic)
    }

    private func refreshDiskUsage() {
        let manager = FileManager.default
        let files = (try? manager.contentsOfDirectory(
            at: videosDirectory,
            includingPropertiesForKeys: [.fileSizeKey]
        )) ?? []
        diskUsageBytes = files.reduce(Int64(0)) { total, file in
            total + Int64((try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
    }

    private func postLibraryChanged() {
        CFNotificationCenterPostNotification(
            CFNotificationCenterGetDarwinNotifyCenter(),
            CFNotificationName(SystemWallpaperPaths.darwinLibraryChangedNote as CFString),
            nil,
            nil,
            true
        )
    }

    // MARK: - Thumbnail

    @Sendable private static func generateThumbnailJPEG(for videoURL: URL) async -> Data? {
        let asset = AVURLAsset(url: videoURL)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 480, height: 270)
        do {
            let (image, _) = try await generator.image(at: CMTime(seconds: 0.5, preferredTimescale: 600))
            let rep = NSBitmapImageRep(cgImage: image)
            return rep.representation(using: .jpeg, properties: [.compressionFactor: 0.8])
        } catch {
            Logger.warning(
                "[systemWallpaper] thumbnail generation failed: \(error.localizedDescription)",
                category: .fileAccess
            )
            return nil
        }
    }
}
