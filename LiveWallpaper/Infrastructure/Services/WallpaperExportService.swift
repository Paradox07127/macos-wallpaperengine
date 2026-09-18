import AppKit
import AVFoundation
import Foundation
import LiveWallpaperCore
import Observation

@MainActor
@Observable
final class WallpaperExportService {
    struct Dependencies {
        let sharedRoot: URL
        let resolver: SecurityScopedBookmarkResolver
        let now: @Sendable () -> Date
        /// JPEG data (480×270 target) for the already-copied video, nil on failure.
        let makeThumbnailJPEG: @Sendable (URL) async -> Data?
        /// The appex this app ships. A heartbeat stamped with anything else is not evidence about our extension. `nil` disables the check.
        var expectedProvider: SystemWallpaperProviderIdentity?
        var isProviderRunning: @Sendable (Int32) -> Bool = { pid in
            pid <= 0 || kill(pid, 0) == 0 || errno != ESRCH
        }

        static func live(hostBundleID: String? = Bundle.main.bundleIdentifier) -> Dependencies {
            Dependencies(
                sharedRoot: SystemWallpaperPaths.sharedRoot(hostBundleID: hostBundleID ?? "com.loomscreen"),
                resolver: .live,
                now: Date.init,
                makeThumbnailJPEG: WallpaperExportService.generateThumbnailJPEG,
                expectedProvider: SystemWallpaperProviderIdentity.bundledProvider()
            )
        }
    }

    enum ServiceError: LocalizedError, Equatable {
        /// Only video files are publishable in v1 — other content kinds have no file the appex could read.
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
                return String(localized: "Only video wallpapers can be added to System Wallpaper.", bundle: .appLanguage)
            case .packageEntryMissing(let name):
                return String(
                    localized: "The video “\(name)” is missing from its Workshop package.",
                    bundle: .appLanguage, comment: "Error shown when a Workshop wallpaper's packaged video cannot be located."
                )
            case .thumbnailFailed:
                return String(
                    localized: "Couldn't create a preview image for this video.",
                    bundle: .appLanguage, comment: "Error shown when publishing to System Wallpaper fails because no thumbnail could be generated."
                )
            case .manifestUnreadable:
                return String(
                    localized: "The System Wallpaper library index is damaged, so it wasn't changed.",
                    bundle: .appLanguage, comment: "Error shown when the system wallpaper manifest cannot be decoded and the operation is refused."
                )
            case .supersededByRemoval:
                return String(
                    localized: "Couldn't add the video: it was removed from System Wallpaper while it was still being copied.",
                    bundle: .appLanguage, comment: "Error shown when a publish is abandoned because the user removed that item, or cleared the library, mid-copy."
                )
            }
        }
    }

    /// No `unsupported` case: the sidebar row and the detail route carry the same `#available(macOS 26.0, *)`, so below 26 the feature is absent, not disabled.
    enum Status: Equatable {
        case systemIncompatible
        case failed(String)
        case empty
        case publishedNotSelected
        case inUse(itemTitle: String)
    }

    /// Heartbeat younger than this counts as "the system is driving us now".
    static let heartbeatFreshnessInterval: TimeInterval = 300

    private(set) var items: [SystemWallpaperManifest.Item] = []
    private(set) var heartbeat: SystemWallpaperHeartbeat?
    private(set) var providerIsRunning = true
    private(set) var lastError: String?
    private(set) var diskUsageBytes: Int64 = 0
    private(set) var playbackMode: SystemWallpaperPlaybackMode = .always

    @ObservationIgnored private let dependencies: Dependencies
    /// Publishes that have started copying but not yet committed, keyed by a per-publish token so two publishes of the same item stay distinct.
    @ObservationIgnored private var activePublishes: [UUID: String] = [:]

    init(dependencies: Dependencies = .live()) {
        self.dependencies = dependencies
        refresh()
    }

    // MARK: - Paths (contract layout, SystemWallpaperManifest.swift)

    private var manifestURL: URL {
        dependencies.sharedRoot.appendingPathComponent("manifest.json")
    }

    private var heartbeatURL: URL {
        dependencies.sharedRoot.appendingPathComponent("heartbeat.json")
    }

    private var providerURL: URL {
        dependencies.sharedRoot.appendingPathComponent("provider.json")
    }

    var videosDirectory: URL {
        dependencies.sharedRoot.appendingPathComponent("Videos", isDirectory: true)
    }

    func thumbnailURL(for item: SystemWallpaperManifest.Item) -> URL? {
        item.thumbnailFileName.map { videosDirectory.appendingPathComponent($0) }
    }

    /// The copy macOS plays, for Show in Finder. Nil once the file is gone — the manifest entry can outlive it.
    func videoURL(for item: SystemWallpaperManifest.Item) -> URL? {
        let url = videosDirectory.appendingPathComponent(item.fileName)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    // MARK: - Status

    var status: Status {
        // The stamp matters as much as `barsPublishing`: without it a process
        // left over by an in-place update condemns the installed extension.
        if let heartbeat,
           heartbeat.isFromProvider(matching: dependencies.expectedProvider),
           heartbeat.barsPublishing {
            return .systemIncompatible
        }
        if let lastError {
            return .failed(lastError)
        }
        if let heartbeat, isFresh(heartbeat),
           let failures = heartbeat.playbackFailures,
           let item = items.first(where: { failures[$0.id] != nil }) {
            return .failed(String(localized: "The system wallpaper video could not be loaded. Select it again in System Settings or import another video.", bundle: .appLanguage)
                + " (" + item.title + ": " + (failures[item.id] ?? "video.failed") + ")")
        }
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
        isPublished(itemID: bookmarkID.uuidString)
    }

    func isPublished(itemID: String) -> Bool {
        items.contains { $0.id == itemID }
    }

    func isItemInUse(_ itemID: String) -> Bool {
        guard let heartbeat, isFresh(heartbeat) else { return false }
        return heartbeat.showsChoice(itemID)
    }

    /// Recent and ours. A stale appex keeps its keep-alive running, so without the stamp check a leftover process's fresh-looking beats would look like the shipped extension's state.
    private func isFresh(_ heartbeat: SystemWallpaperHeartbeat) -> Bool {
        guard heartbeat.isFromProvider(matching: dependencies.expectedProvider) else { return false }
        if !providerIsRunning {
            return false
        }
        return dependencies.now().timeIntervalSince(heartbeat.timestamp) < Self.heartbeatFreshnessInterval
    }

    enum ProviderIssue: Equatable {
        case differentCopy
        case stopped
        case unresponsive
    }

    var providerIssue: ProviderIssue? {
        guard let heartbeat else { return nil }
        let hasActiveChoices = heartbeat.activeChoiceIDs?.isEmpty == false || heartbeat.activeChoiceID != nil
        if !providerIsRunning {
            return hasActiveChoices ? .stopped : nil
        }
        if dependencies.now().timeIntervalSince(heartbeat.timestamp) >= Self.heartbeatFreshnessInterval {
            return hasActiveChoices ? .unresponsive : nil
        }
        if !heartbeat.isFromProvider(matching: dependencies.expectedProvider) {
            return .differentCopy
        }
        return nil
    }

    func refreshProviderStatus() {
        heartbeat = loadHeartbeat()
        providerIsRunning = heartbeat?.provider.map { dependencies.isProviderRunning($0.pid) } ?? true
    }

    // MARK: - Publish / remove

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

    func publish(fileURL: URL) async throws {
        try await publish(
            id: UUID().uuidString,
            title: fileURL.deletingPathExtension().lastPathComponent,
            source: .pickedFile(fileURL)
        )
    }

    /// The summary is assembled here because a successful publish clears `lastError`: a plain per-file loop reported only the last file's outcome.
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
            bundle: .appLanguage, comment: "One line of the summary shown after importing several videos at once. Placeholders are the file name and the failure reason."
        )
    }

    /// `id` must be stable for a given source. A fresh UUID each time would make `isPublished` blind to Workshop entries.
    func publish(content: WallpaperContent, title: String, id: String) async throws {
        guard case .video(let data, let entryName) = content else {
            let error = ServiceError.unsupportedContent
            lastError = error.localizedDescription
            throw error
        }
        try await publish(
            id: id,
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

        // Copy off the main actor. Everything lands in a uniquely-named staging file first: the live copy is only touched by the atomic swap after the thumbnail succeeds.
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
            // Unique name: two concurrent publishes of the same bookmark must not fight over one staging path. The name carries the creation time so a concurrent sweep stays off it (see `SystemWallpaperLibrary.stagingFileName`).
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
                        // `copyItem` carries the source's mtime over. Stamp the copy with now so the orphan sweep judges age by when it entered the library.
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

        // Thumbnail from the staging copy so a failure aborts before the live copy or manifest is touched. No thumbnail means no tile in the wallpaper panel.
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
        // A republish overwrites files the manifest still points at, so the old copies are renamed aside (cheap, no second copy of a 4K video) and only dropped once the manifest write lands.
        // They carry staging names so a sweep in the other process judges them by that timestamp rather than by the displaced file's own, possibly ancient, mtime.
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
            // Locked from the swap onwards, not just the manifest write: the appex removes an entry and unlinks its files under this lock.
            manifest = try SystemWallpaperLock.withExclusiveLock(root: dependencies.sharedRoot) {
                // Each path is judged on its own: a republish that changes the video's extension writes a *new* destination while reusing the one thumbnail name, so "is this a republish" cannot answer both.
                let destinationExists = manager.fileExists(atPath: destination.path)
                let thumbnailExists = manager.fileExists(atPath: thumbnailURL.path)

                /// Puts the library back exactly as it was. Without this a failed thumbnail write or unreadable manifest reported failure while the old video was already gone.
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
                    // Atomic swap — no window where the old copy is gone and the new one is not yet in place.
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
                    // A republish under a new extension leaves the copy the old entry named behind: waiting for the sweep means carrying two copies.
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
            // A no-op once the swap has consumed it; this catches the lock being untakeable, which would otherwise strand the staged copy until the sweep.
            try? manager.removeItem(at: staged.url)
            throw error
        }
        items = manifest.items
        refreshDiskUsage()
        postLibraryChanged()
    }

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

    func clearLibrary() throws {
        activePublishes.removeAll()
        nonisolated(unsafe) var survivors: [String] = []
        do {
            try SystemWallpaperLock.withExclusiveLock(root: dependencies.sharedRoot) {
                let manifest = try loadManifestForMutation()
                var emptied = manifest
                emptied.items = []
                try writeManifest(emptied)
                // Every file is unreferenced now, so the sweep is the delete — no age guard, because nothing can be mid-publish once the manifest is empty and the lock is held.
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
            bundle: .appLanguage, comment: "Error after clearing the System Wallpaper library. Placeholder is a file name list."
        )
    }

    // MARK: - Refresh

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
            // The extension observes this over the Darwin notify center (`WallpaperXPCBridge.LibraryChangeObserver`).
            postLibraryChanged()
        } catch {
            lastError = error.localizedDescription
        }
    }

    func refresh() {
        let manifest = loadManifest()
        // Present on disk but undecodable: showing an empty library here would invite the user to re-add everything, and every mutation is refused anyway.
        if manifest == nil, FileManager.default.fileExists(atPath: manifestURL.path) {
            lastError = ServiceError.manifestUnreadable.localizedDescription
        }
        playbackMode = manifest?.playbackMode ?? .always
        items = manifest?.items ?? []
        refreshProviderStatus()
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

    /// Streamed in chunks through the already-open handle: `.mappedIfSafe` degrades to a whole-file heap read on removable and network volumes, and Steam libraries live on those.
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

    /// Absent manifest = empty library. Unreadable = refuse. Treating corruption as empty would rewrite the file with only the newest item and the orphan sweep would delete the rest.
    private func loadManifestForMutation() throws -> SystemWallpaperManifest {
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

    /// Writes which appex this app ships; an idle appex instance elsewhere (another copy of the app, a leftover build directory) reads it when the Agent disconnects and retires. A launch step, not an init side effect: the test host is this same app and must not declare a build directory into the real container.
    func declareBundledProvider() {
        guard let provider = dependencies.expectedProvider else { return }
        do {
            try FileManager.default.createDirectory(at: dependencies.sharedRoot, withIntermediateDirectories: true)
            try SystemWallpaperCoding.encoder.encode(provider).write(to: providerURL, options: .atomic)
        } catch {
            Logger.warning("[systemWallpaper] provider declaration failed: \(error.localizedDescription)", category: .fileAccess)
        }
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
