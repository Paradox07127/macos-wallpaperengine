import AppKit
import AVFoundation
import Foundation
import LiveWallpaperCore
import Observation

/// Publishes library videos into the shared directory the wallpaper appex
/// reads, and mirrors the appex's heartbeat back into UI state.
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
        /// The manifest exists but will not decode. Every mutation refuses
        /// rather than rewriting the library from scratch.
        case manifestUnreadable
        /// A remove (or a Remove All) landed while this publish was still
        /// copying, so committing would resurrect what the user just deleted.
        case supersededByRemoval

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
            case .manifestUnreadable:
                return String(
                    localized: "The System Wallpaper library index is damaged, so it wasn't changed.",
                    comment: "Error shown when the system wallpaper manifest cannot be decoded and the operation is refused."
                )
            case .supersededByRemoval:
                return String(
                    localized: "Couldn't add the video: it was removed from System Wallpaper while it was still being copied.",
                    comment: "Error shown when a publish is abandoned because the user removed that item, or cleared the library, mid-copy."
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
    /// is measured.
    static let heartbeatFreshnessInterval: TimeInterval = 300

    private(set) var items: [SystemWallpaperManifest.Item] = []
    private(set) var heartbeat: SystemWallpaperHeartbeat?
    private(set) var lastError: String?
    private(set) var diskUsageBytes: Int64 = 0
    private(set) var playbackMode: SystemWallpaperPlaybackMode = .always

    @ObservationIgnored private let dependencies: Dependencies
    /// Publishes that have started copying but not yet committed, keyed by a
    /// per-publish token so two publishes of the same item stay distinct. The
    /// copy and the thumbnail run off the main actor, so a remove can land in
    /// between — and the commit used to write the entry straight back.
    @ObservationIgnored private var activePublishes: [UUID: String] = [:]

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
        // An "incompatible" verdict is only as good as the OS build *and* the
        // check revision that reached it — see `barsPublishing`.
        if heartbeat?.barsPublishing == true { return .systemIncompatible }
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

    /// Publishes several picked files in turn. The summary is assembled here
    /// rather than at the call site because a successful publish clears
    /// `lastError`: a plain per-file loop reported only the last file's outcome,
    /// so a file that failed mid-selection disappeared with no message at all.
    func publish(fileURLs: [URL]) async {
        var failures: [String] = []
        for url in fileURLs {
            do {
                try await publish(fileURL: url)
            } catch {
                failures.append(Self.publishFailureLine(
                    name: url.lastPathComponent,
                    reason: error.localizedDescription
                ))
            }
        }
        lastError = failures.isEmpty ? nil : failures.joined(separator: "\n")
    }

    private static func publishFailureLine(name: String, reason: String) -> String {
        String(
            localized: "Couldn't add “\(name)”: \(reason)",
            comment: "One line of the summary shown after importing several videos at once. Placeholders are the file name and the failure reason."
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
        let token = UUID()
        activePublishes[token] = itemID
        defer { activePublishes[token] = nil }

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
            // not fight over one staging path. The name also carries the
            // creation time, which is what keeps a concurrent sweep off it —
            // see `SystemWallpaperLibrary.stagingFileName`.
            let staging = videosDirectory.appendingPathComponent(
                SystemWallpaperLibrary.stagingFileName(itemID: itemID, ext: ext, now: Date())
            )
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
                        // `copyItem` carries the source's mtime over. Stamp the
                        // copy with now so the published file's age reflects
                        // when it entered the library, which is what the orphan
                        // sweep judges a de-referenced file by.
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

        // A remove that landed while this publish was copying wins: committing
        // now would put the entry the user just deleted straight back.
        guard activePublishes[token] != nil else {
            try? FileManager.default.removeItem(at: staged.url)
            throw ServiceError.supersededByRemoval
        }

        let destination = videosDirectory.appendingPathComponent("\(itemID).\(staged.ext)")
        let thumbnailURL = videosDirectory.appendingPathComponent("\(itemID).jpg")
        let thumbnailFileName = thumbnailURL.lastPathComponent
        let manager = FileManager.default
        // A republish overwrites files the manifest still points at, so the old
        // copies are renamed aside (cheap, no second copy of a 4K video) and
        // only dropped once the manifest write lands. They carry staging names
        // so a sweep in the other process judges them by that timestamp rather
        // than by the displaced file's own, possibly ancient, mtime.
        let backupTag = UUID()
        let videoBackupURL = videosDirectory.appendingPathComponent(
            SystemWallpaperLibrary.transientBackupName(
                itemID: itemID, ext: staged.ext, tag: backupTag, now: dependencies.now()
            )
        )
        let thumbnailBackupURL = videosDirectory.appendingPathComponent(
            SystemWallpaperLibrary.transientBackupName(
                itemID: itemID, ext: "jpg", tag: backupTag, now: dependencies.now()
            )
        )

        let manifest: SystemWallpaperManifest
        do {
            // Locked from the swap onwards, not just for the manifest write: the
            // appex removes an entry *and unlinks its files* under this lock, so
            // swapping outside it could commit a manifest entry naming a file
            // that the removal had already deleted.
            manifest = try SystemWallpaperLock.withExclusiveLock(root: dependencies.sharedRoot) {
                // Each path is judged on its own: a republish that changes the
                // video's extension writes a *new* destination while reusing the
                // one thumbnail name, so "is this a republish" cannot answer both.
                // Treating the whole publish as a first one because of the new
                // extension let the rollback delete the thumbnail the still-live
                // manifest entry pointed at, which erased that wallpaper from the
                // system panel.
                let destinationExists = manager.fileExists(atPath: destination.path)
                let thumbnailExists = manager.fileExists(atPath: thumbnailURL.path)

                /// Puts the library back exactly as it was. Without this a failed
                /// thumbnail write or an unreadable manifest reported failure
                /// while the old video was already gone.
                func rollbackPublish() {
                    if destinationExists {
                        if manager.fileExists(atPath: videoBackupURL.path) {
                            _ = try? manager.replaceItemAt(destination, withItemAt: videoBackupURL)
                        }
                    } else {
                        try? manager.removeItem(at: destination)
                    }
                    try? manager.removeItem(at: thumbnailURL)
                    if manager.fileExists(atPath: thumbnailBackupURL.path) {
                        try? manager.moveItem(at: thumbnailBackupURL, to: thumbnailURL)
                    }
                }

                if destinationExists {
                    // Atomic swap — no window where the old copy is gone and the
                    // new one is not yet in place. The displaced original stays
                    // behind under `backupItemName` until this publish commits.
                    _ = try manager.replaceItemAt(
                        destination,
                        withItemAt: staged.url,
                        backupItemName: videoBackupURL.lastPathComponent,
                        options: [.withoutDeletingBackupItem]
                    )
                } else {
                    try manager.moveItem(at: staged.url, to: destination)
                }
                if thumbnailExists {
                    try? manager.moveItem(at: thumbnailURL, to: thumbnailBackupURL)
                }

                do {
                    try jpeg.write(to: thumbnailURL, options: .atomic)
                    var manifest = try loadManifestForMutation()
                    let previousFileName = manifest.items.first { $0.id == itemID }?.fileName
                    manifest.items.removeAll { $0.id == itemID }
                    manifest.items.append(SystemWallpaperManifest.Item(
                        id: itemID,
                        title: title,
                        fileName: destination.lastPathComponent,
                        thumbnailFileName: thumbnailFileName,
                        addedAt: dependencies.now()
                    ))
                    try writeManifest(manifest)
                    try? manager.removeItem(at: videoBackupURL)
                    try? manager.removeItem(at: thumbnailBackupURL)
                    // A republish under a new extension leaves the copy the old
                    // entry named behind: nothing references it now, and waiting
                    // for the sweep means carrying two copies of a 4K video.
                    if let previousFileName, previousFileName != destination.lastPathComponent {
                        try? manager.removeItem(
                            at: videosDirectory.appendingPathComponent(previousFileName)
                        )
                    }
                    return manifest
                } catch {
                    rollbackPublish()
                    throw error
                }
            }
        } catch {
            // A no-op once the swap has consumed it; what this catches is the
            // lock itself being untakeable, which would otherwise strand the
            // staged copy until the sweep.
            try? manager.removeItem(at: staged.url)
            throw error
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
        // A publish of this item that is still copying must not commit after
        // the user has asked for it to go away.
        activePublishes = activePublishes.filter { $0.value != itemID }
        let manifest: SystemWallpaperManifest?
        // Collected inside the lock, reported after: the entry is gone either
        // way, but leftover bytes on disk should not be silent.
        nonisolated(unsafe) var undeleted: [String] = []
        do {
            manifest = try SystemWallpaperLock.withExclusiveLock(root: dependencies.sharedRoot) {
                let removed = try SystemWallpaperLibrary.remove(
                    id: itemID,
                    from: try loadManifestForMutation(),
                    videosDirectory: videosDirectory,
                    persist: { try writeManifest($0) },
                    onFileRemovalFailure: { name, error in
                        undeleted.append("\(name): \(error.localizedDescription)")
                    }
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
            lastError = undeleted.isEmpty ? nil : undeleted.joined(separator: "\n")
        } catch {
            lastError = error.localizedDescription
            throw error
        }
        guard let manifest else { return }
        items = manifest.items
        refreshDiskUsage()
        postLibraryChanged()
    }

    /// Deletes every published video and empties the manifest. Trashing the
    /// app does not remove its container, so without this the system's copies
    /// survive an uninstall with no way to reach them.
    func clearLibrary() throws {
        activePublishes.removeAll()
        nonisolated(unsafe) var survivors: [String] = []
        do {
            try SystemWallpaperLock.withExclusiveLock(root: dependencies.sharedRoot) {
                let manifest = try loadManifestForMutation()
                var emptied = manifest
                emptied.items = []
                try writeManifest(emptied)
                // Every file is unreferenced now, so the sweep is the delete —
                // with no age guard, because nothing here can be mid-publish
                // once the manifest is empty and the lock is held.
                SystemWallpaperLibrary.sweepOrphans(
                    manifest: emptied,
                    videosDirectory: videosDirectory,
                    olderThan: -1,
                    stagingGrace: -1,
                    now: dependencies.now()
                )
                survivors = Self.remainingFileNames(in: videosDirectory)
            }
            // Emptying the index while the files are still there would report a
            // clean library and leave the bytes unreachable, so say what stayed.
            lastError = survivors.isEmpty ? nil : Self.undeletedMessage(survivors)
        } catch {
            lastError = error.localizedDescription
            throw error
        }
        items = []
        refreshDiskUsage()
        postLibraryChanged()
    }

    func clearLastError() {
        lastError = nil
    }

    /// Regular files left in the videos directory — after a full sweep these
    /// are files the delete could not remove.
    private static func remainingFileNames(in directory: URL) -> [String] {
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.isDirectoryKey]
        )) ?? []
        return contents.compactMap { url in
            let isDirectory = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
            return isDirectory ? nil : url.lastPathComponent
        }.sorted()
    }

    private static func undeletedMessage(_ names: [String]) -> String {
        String(
            localized: "Some files could not be deleted: \(names.joined(separator: ", "))",
            comment: "Error after clearing the System Wallpaper library. Placeholder is a file name list."
        )
    }

    // MARK: - Refresh

    /// Called when the panel appears — no resident polling; the panel is the
    /// only reader and it is open a few times a year.
    func setPlaybackMode(_ mode: SystemWallpaperPlaybackMode) {
        guard mode != playbackMode else { return }
        do {
            try SystemWallpaperLock.withExclusiveLock(root: dependencies.sharedRoot) {
                var manifest = try loadManifestForMutation()
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
        // Present on disk but undecodable: showing an empty library here would
        // invite the user to re-add everything, and every mutation is refused
        // anyway.
        if manifest == nil, FileManager.default.fileExists(atPath: manifestURL.path) {
            lastError = ServiceError.manifestUnreadable.localizedDescription
        }
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
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Wallpaper-Settings.extension")!)
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
        return try? SystemWallpaperCoding.decoder.decode(SystemWallpaperManifest.self, from: data)
    }

    /// Absent manifest = empty library, which is a normal first-run state.
    /// Unreadable manifest = refuse. Treating corruption as "empty" used to
    /// rewrite the file with only the newest item, which turned every already
    /// published video into an unreferenced file the orphan sweep then deleted.
    private func loadManifestForMutation() throws -> SystemWallpaperManifest {
        // Absent is the only read outcome that means "empty library"; an
        // unreadable-but-present file (permissions, IO) has to refuse for the
        // same reason a corrupt one does.
        guard FileManager.default.fileExists(atPath: manifestURL.path) else { return .empty }
        guard let data = try? Data(contentsOf: manifestURL) else { throw ServiceError.manifestUnreadable }
        guard let manifest = try? SystemWallpaperCoding.decoder
            .decode(SystemWallpaperManifest.self, from: data)
        else { throw ServiceError.manifestUnreadable }
        return manifest
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
