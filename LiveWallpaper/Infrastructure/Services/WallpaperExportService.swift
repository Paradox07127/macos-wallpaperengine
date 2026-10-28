import AppKit
import AVFoundation
import CryptoKit
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

        /// Copies an admitted loose video into staging. Injectable so rejection tests never open a special file.
        var copyVideoFile: @Sendable (URL, URL) throws -> Void = { source, destination in
            try FileManager.default.copyItem(at: source, to: destination)
        }

        /// The same source admission precedes package parsing; injectable for special-file rejection fixtures.
        var extractVideoFromPackage: @Sendable (URL, String, URL) throws -> Void = { source, name, destination in
            try WallpaperExportService.extractPackagedVideo(packageURL: source, entryName: name, to: destination)
        }

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
        case preparationBusy
        case invalidPreparationOptions
        case liveWebUnsupported
        case sceneSourceUnavailable

        var errorDescription: String? {
            switch self {
            case .unsupportedContent:
                String(localized: "Only video wallpapers can be added to System Wallpaper.", bundle: .appLanguage)
            case .sceneSourceUnavailable:
                String(localized: "The scene source could not be opened. Check its location and access permission.", bundle: .appLanguage)
            case let .packageEntryMissing(name):
                String(
                    localized: "The video “\(name)” is missing from its Workshop package.",
                    bundle: .appLanguage, comment: "Error shown when a Workshop wallpaper's packaged video cannot be located."
                )
            case .thumbnailFailed:
                String(
                    localized: "Couldn't create a preview image for this video.",
                    bundle: .appLanguage, comment: "Error shown when publishing to System Wallpaper fails because no thumbnail could be generated."
                )
            case .manifestUnreadable:
                String(
                    localized: "The System Wallpaper library index is damaged, so it wasn't changed.",
                    bundle: .appLanguage, comment: "Error shown when the system wallpaper manifest cannot be decoded and the operation is refused."
                )
            case .supersededByRemoval:
                String(
                    localized: "Couldn't add the video: it was removed from System Wallpaper while it was still being copied.",
                    bundle: .appLanguage, comment: "Error shown when a publish is abandoned because the user removed that item, or cleared the library, mid-copy."
                )
            case .preparationBusy:
                String(localized: "Another wallpaper is being prepared. Wait or cancel it first.", bundle: .appLanguage)
            case .invalidPreparationOptions:
                String(localized: "Choose a valid recording duration, frame rate and resolution.", bundle: .appLanguage)
            case .liveWebUnsupported:
                String(localized: "A video copy cannot keep web clocks, calendars or live data accurate. Disable those elements before recording.", bundle: .appLanguage)
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
    let maintenance = SystemWallpaperMaintenanceController()
    private(set) var providerIsRunning = true
    private(set) var lastError: String?
    private(set) var diskUsageBytes: Int64 = 0
    private(set) var playbackMode: SystemWallpaperPlaybackMode = .always
    private(set) var hidesClockCalendarOnLockScreen = true
    var preparationProgress: Double?
    private(set) var preparingTitle: String?
    @ObservationIgnored private var preparationTask: Task<Void, Error>?
    @ObservationIgnored private var hasPendingLegacyRepreparation = false
    @ObservationIgnored private var isRepreparingLegacyScenes = false
    @ObservationIgnored private var preparingItemID: String?
    @ObservationIgnored var onItemPublished: (@MainActor (String) -> Void)?
    @ObservationIgnored var onHeartbeatRefreshed: (@MainActor () -> Void)?
    /// nil until the follow coordinator exists; it is the owner, so the service must not retain it.
    weak var followCoordinator: SystemWallpaperSelectionCoordinator?

    /// Items with this ID prefix are copies the selected tile made; nothing else may use it, because unselected ones are deleted.
    static let selectionCopyIDPrefix = "selected-"

    static func sourceKey(for content: WallpaperContent) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try SHA256.hash(data: encoder.encode(content)).map { String(format: "%02x", $0) }.joined()
    }

    /// The beat has no per-display choice, so with different choices on several displays every serving display counts.
    func showsSelectedTile(on displayID: UInt32) -> Bool {
        guard let heartbeat, isFresh(heartbeat), heartbeat.showsChoice(SystemWallpaperManifest.selectedChoiceID) else { return false }
        return heartbeat.selectedTileDisplayIDs?.contains(displayID) ?? true
    }

    func selectItem(_ itemID: String, for displayID: UInt32) throws {
        let cleanup = try SystemWallpaperLock.withExclusiveLock(root: dependencies.sharedRoot) {
            var manifest = try loadManifestForMutation()
            guard manifest.items.contains(where: { $0.id == itemID }) else { throw ServiceError.unsupportedContent }
            manifest.selectedItemID = itemID
            manifest.displaySelections[String(displayID)] = itemID
            manifest.clearedDisplays[String(displayID)] = nil
            try writeManifest(manifest)
            return try removeUnselectedCopies(from: manifest)
        }
        items = cleanup.manifest.items
        lastError = cleanup.failures.isEmpty ? nil : cleanup.failures.joined(separator: "\n")
        refreshDiskUsage()
        postLibraryChanged()
    }

    /// Persists the explicit clear so neither a heartbeat nor a relaunch brings the display's old copy back; `selectItem` replaces it.
    func clearSelection(for displayID: UInt32, generation: Int) throws {
        let cleanup = try SystemWallpaperLock.withExclusiveLock(root: dependencies.sharedRoot) {
            var manifest = try loadManifestForMutation()
            manifest.displaySelections[String(displayID)] = nil
            manifest.clearedDisplays[String(displayID)] = generation
            try writeManifest(manifest)
            return try removeUnselectedCopies(from: manifest)
        }
        items = cleanup.manifest.items
        lastError = cleanup.failures.isEmpty ? nil : cleanup.failures.joined(separator: "\n")
        refreshDiskUsage()
        postLibraryChanged()
    }

    /// Caller holds the manifest lock.
    private func removeUnselectedCopies(from manifest: SystemWallpaperManifest) throws -> (manifest: SystemWallpaperManifest, failures: [String]) {
        var manifest = manifest
        var failures: [String] = []
        // Displays without their own selection resolve through `selectedItemID`.
        let selected = Set(manifest.displaySelections.values).union([manifest.selectedItemID].compactMap(\.self))
        for item in manifest.items where item.id.hasPrefix(Self.selectionCopyIDPrefix) && !selected.contains(item.id) {
            manifest = try SystemWallpaperLibrary.remove(
                id: item.id, from: manifest, videosDirectory: videosDirectory, persist: { try writeManifest($0) },
                onFileRemovalFailure: { name, error in
                    failures.append("\(name): \(error.localizedDescription)")
                }
            ) ?? manifest
        }
        return (manifest, failures)
    }

    @ObservationIgnored private(set) var preparationCancellationGeneration = 0

    @ObservationIgnored private let dependencies: Dependencies
    /// Publishes that have started copying but not yet committed, keyed by a per-publish token so two publishes of the same item stay distinct.
    @ObservationIgnored private var activePublishes: [UUID: String] = [:]
    @ObservationIgnored private var sharedRootWatch: DispatchSourceFileSystemObject?
    @ObservationIgnored private var stalenessTimer: DispatchSourceTimer?
    /// Bumped by `clearLibrary`; a batch publish stops once it differs from the value it started with.
    @ObservationIgnored private(set) var clearGeneration = 0

    /// Covers the two transitions no file write announces: the appex exiting, and a
    /// heartbeat ageing past `heartbeatFreshnessInterval`. Far below that 300s window.
    private static let stalenessPollInterval: TimeInterval = 30

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
        if !heartbeat.isFromProvider(matching: dependencies.expectedProvider) {
            return .differentCopy
        }
        let hasActiveChoices = heartbeat.activeChoiceIDs?.isEmpty == false || heartbeat.activeChoiceID != nil
        if !providerIsRunning {
            return hasActiveChoices ? .stopped : nil
        }
        if dependencies.now().timeIntervalSince(heartbeat.timestamp) >= Self.heartbeatFreshnessInterval {
            return hasActiveChoices ? .unresponsive : nil
        }
        return nil
    }

    func refreshProviderStatus() {
        heartbeat = loadHeartbeat()
        providerIsRunning = heartbeat?.provider.map { dependencies.isProviderRunning($0.pid) } ?? true
        maintenance.considerAutomaticRecovery(service: self)
        #if !LITE_BUILD
        if #available(macOS 26.0, *), let heartbeat, isFresh(heartbeat),
           heartbeat.playbackFailures?.values.contains("scene.load.failed") == true {
            Task { [weak self] in await self?.reprepareLegacySceneCapsules() }
        }
        #endif
        onHeartbeatRefreshed?()
    }

    /// Idempotent: both System Wallpaper screens call it, and the watch outlives either.
    ///
    /// The heartbeat is written with `.atomic`, which replaces the file by rename, so a
    /// watch on the file itself goes deaf after the first beat — this watches the
    /// directory instead. One atomic write raises two directory events (the temporary
    /// file, then the rename); refreshing twice is cheaper than debouncing it.
    func startObservingSharedRoot() {
        guard sharedRootWatch == nil else { return }

        try? FileManager.default.createDirectory(
            at: dependencies.sharedRoot,
            withIntermediateDirectories: true
        )
        let descriptor = open(dependencies.sharedRoot.path, O_EVTONLY)
        guard descriptor >= 0 else { return }

        // Explicitly `@Sendable`: these handlers run on a utility queue, and a closure
        // formed inside this `@MainActor` method otherwise inherits that isolation and
        // traps in `swift_task_isCurrentExecutor` the first time the queue calls it.
        let reread: @Sendable () -> Void = { [weak self] in
            Task { @MainActor in self?.refreshProviderStatus() }
        }

        let watch = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor,
            eventMask: [.write, .delete, .rename],
            queue: .global(qos: .utility)
        )
        watch.setEventHandler(handler: reread)
        let closeDescriptor: @Sendable () -> Void = { close(descriptor) }
        watch.setCancelHandler(handler: closeDescriptor)
        watch.resume()
        sharedRootWatch = watch

        let timer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        timer.schedule(
            deadline: .now() + Self.stalenessPollInterval,
            repeating: Self.stalenessPollInterval
        )
        timer.setEventHandler(handler: reread)
        timer.resume()
        stalenessTimer = timer
    }

    func stopObservingSharedRoot() {
        sharedRootWatch?.cancel()
        sharedRootWatch = nil
        stalenessTimer?.cancel()
        stalenessTimer = nil
    }

    // MARK: - Publish / remove

    private enum PublishSource {
        case bookmark(data: Data, packageEntryName: String?)
        case pickedFile(URL)
        case sceneBundle(URL)
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
            source: .bookmark(data: data, packageEntryName: entryName), sourceKey: Self.sourceKey(for: bookmark.content)
        )
    }

    func cancelPreparation() {
        preparationCancellationGeneration &+= 1
        hasPendingLegacyRepreparation = false
        preparationTask?.cancel()
    }

    private struct PublishedSceneRepreparation {
        let bundle: URL
        let item: SystemWallpaperManifest.Item
    }

    #if !LITE_BUILD
    /// Reuse the publication slot and atomic replace path; never patch a bundle an extension may be reading.
    @available(macOS 26.0, *)
    func reprepareLegacySceneCapsules() async {
        guard !isRepreparingLegacyScenes else { return }
        guard preparationTask == nil else {
            hasPendingLegacyRepreparation = true
            return
        }
        hasPendingLegacyRepreparation = false
        isRepreparingLegacyScenes = true
        defer { isRepreparingLegacyScenes = false }
        let generation = clearGeneration
        let cancellationGeneration = preparationCancellationGeneration
        let candidates = items.filter { $0.fileName.hasSuffix(".scene") }
        for item in candidates {
            guard generation == clearGeneration, cancellationGeneration == preparationCancellationGeneration,
                  !Task.isCancelled else { return }
            guard items.contains(where: { $0.id == item.id && $0.fileName == item.fileName }) else { continue }
            let bundle = videosDirectory.appendingPathComponent(item.fileName, isDirectory: true)
            do {
                let configurationResult = Result {
                    try JSONDecoder().decode(SystemWallpaperSceneConfiguration.self,
                                             from: Data(contentsOf: bundle.appendingPathComponent("configuration.json")))
                }
                let loadFailed = heartbeat.map {
                    isFresh($0) && $0.playbackFailures?[item.id] == "scene.load.failed"
                } ?? false
                guard try loadFailed || configurationResult.get().needsRepreparation else { continue }
                let fingerprint = try await Task.detached { try Self.sceneContentFingerprint(at: bundle) }.value
                guard generation == clearGeneration, cancellationGeneration == preparationCancellationGeneration,
                      !Task.isCancelled, items.contains(where: { $0 == item }) else { return }
                guard preparationTask == nil else { hasPendingLegacyRepreparation = true; return }
                var receipts = try loadSceneRecoveryReceipts()
                guard receipts[item.id]?.contains(fingerprint) != true else { continue }
                receipts[item.id, default: []].insert(fingerprint)
                try writeSceneRecoveryReceipts(receipts)
                let configuration = try configurationResult.get()
                var options = item.preparationOptions ?? SystemWallpaperPreparationOptions()
                if item.preparationOptions == nil {
                    options.framesPerSecond = configuration.framesPerSecond
                    options.size = configuration.renderSize
                }
                options.sceneMode = .live
                do {
                    try await prepareAndPublish(content: .scene(configuration.descriptor), title: item.title,
                                                id: item.id, options: options, origin: nil,
                                                repreparation: PublishedSceneRepreparation(bundle: bundle, item: item))
                    let replacement = try await Task.detached { try Self.sceneContentFingerprint(at: bundle) }.value
                    receipts[item.id, default: []].insert(replacement)
                    try writeSceneRecoveryReceipts(receipts)
                } catch is CancellationError {
                    receipts[item.id]?.remove(fingerprint)
                    try writeSceneRecoveryReceipts(receipts)
                    return
                }
            } catch is CancellationError {
                return
            } catch {
                lastError = error.localizedDescription
                Logger.warning("[systemWallpaper] scene capsule migration failed for \(item.id): \(error)",
                               category: .fileAccess)
            }
        }
    }

    private var sceneRecoveryReceiptsURL: URL {
        dependencies.sharedRoot.appendingPathComponent("scene-recovery.json")
    }

    private func loadSceneRecoveryReceipts() throws -> [String: Set<String>] {
        guard FileManager.default.fileExists(atPath: sceneRecoveryReceiptsURL.path) else { return [:] }
        return try JSONDecoder().decode([String: Set<String>].self, from: Data(contentsOf: sceneRecoveryReceiptsURL))
    }

    private func writeSceneRecoveryReceipts(_ receipts: [String: Set<String>]) throws {
        try JSONEncoder().encode(receipts).write(to: sceneRecoveryReceiptsURL, options: .atomic)
    }

    private nonisolated static func sceneContentFingerprint(at bundle: URL) throws -> String {
        var hash = SHA256()
        hash.update(data: Data(SystemWallpaperSceneConfiguration.recoveryVersion.utf8))
        var enumerationError: Error?
        guard let enumerator = FileManager.default.enumerator(at: bundle, includingPropertiesForKeys: [.isRegularFileKey],
                                                              errorHandler: { _, error in enumerationError = error; return false }) else {
            throw CocoaError(.fileReadUnknown)
        }
        let files = enumerator.compactMap { $0 as? URL }.sorted { $0.path < $1.path }
        if let enumerationError {
            throw enumerationError
        }
        for file in files {
            try Task.checkCancellation()
            guard try file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else { continue }
            let name = String(file.path.dropFirst(bundle.path.count))
            hash.update(data: Data(name.utf8))
            let reader = try FileHandle(forReadingFrom: file)
            defer { try? reader.close() }
            var fileHash = SHA256()
            while let chunk = try reader.read(upToCount: 1 << 20), !chunk.isEmpty {
                fileHash.update(data: chunk)
            }
            hash.update(data: Data(fileHash.finalize()))
        }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }
    #endif

    /// Preparation is serial across every window, and cancellation drains its renderer before the slot is freed.
    @available(macOS 26.0, *)
    func prepareAndPublish(content: WallpaperContent, title: String, id: String,
                           options: SystemWallpaperPreparationOptions, origin: WPEOrigin? = nil) async throws {
        try await prepareAndPublish(content: content, title: title, id: id, options: options, origin: origin,
                                    repreparation: nil)
    }

    @available(macOS 26.0, *)
    private func prepareAndPublish(content: WallpaperContent, title: String, id: String,
                                   options: SystemWallpaperPreparationOptions, origin: WPEOrigin?,
                                   repreparation: PublishedSceneRepreparation?) async throws {
        if case .video = content {
            try await publish(content: content, title: title, id: id); return
        }
        guard preparationTask == nil else { throw ServiceError.preparationBusy }
        guard options.isValid else { throw ServiceError.invalidPreparationOptions }
        if case .html = content, options.containsLiveData {
            throw ServiceError.liveWebUnsupported
        }
        let generation = clearGeneration
        preparingItemID = id
        preparingTitle = title
        preparationProgress = 0
        let task = Task { @MainActor in
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("WallpaperPreparation-\(UUID())", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: directory) }
            let movie = directory.appendingPathComponent("wallpaper.mov")
            let progress: (Double) -> Void = { self.preparationProgress = $0 }
            let publicationSourceKey: String?
            let publicationOptions: SystemWallpaperPreparationOptions?
            if let repreparation {
                publicationSourceKey = repreparation.item.sourceKey
                publicationOptions = repreparation.item.preparationOptions
            } else {
                publicationSourceKey = try Self.sourceKey(for: content)
                publicationOptions = options
            }
            switch content {
            case let .html(source, config):
                #if !LITE_BUILD
                try await SystemWallpaperWebRecording.record(
                    source: source, config: config, url: movie, size: options.size,
                    duration: options.duration, framesPerSecond: options.framesPerSecond, progress: progress
                )
                #else
                throw ServiceError.unsupportedContent
                #endif
            case let .scene(descriptor):
                #if !LITE_BUILD
                let source = if let repreparation {
                    try SystemWallpaperSceneSource.legacyRepreparation(at: repreparation.bundle)
                } else {
                    try SystemWallpaperScenePreparation.resolve(descriptor, origin: origin)
                }
                if options.sceneMode == .live {
                    let source = try SystemWallpaperSceneBundle.freezeParity(source: source)
                    let bundle = directory.appendingPathComponent("wallpaper.scene", isDirectory: true)
                    let staging = Task.detached {
                        try SystemWallpaperSceneBundle.stage(source: source, at: bundle,
                                                             framesPerSecond: options.framesPerSecond, renderSize: options.size)
                    }
                    try await withTaskCancellationHandler(operation: { try await staging.value }, onCancel: { staging.cancel() })
                    try Task.checkCancellation()
                    let prepared = try SystemWallpaperSceneSource.published(at: bundle, shaderPolicy: .compileAllowed)
                    // Fill both visibility variants: the extension restores clock/calendar objects after unlock.
                    try await SystemWallpaperScenePreparation.prepare(source: prepared, size: options.size,
                                                                      hidingClockCalendar: false)
                    try await SystemWallpaperScenePreparation.record(
                        source: prepared, url: movie, size: options.size,
                        duration: 1, framesPerSecond: options.framesPerSecond, progress: progress
                    )
                    let readOnly = try SystemWallpaperSceneSource.published(at: bundle)
                    for hidingClockCalendar in [false, true] {
                        try await SystemWallpaperScenePreparation.prepare(source: readOnly, size: options.size,
                                                                          hidingClockCalendar: hidingClockCalendar)
                    }
                    guard let poster = await Self.generateThumbnailJPEG(for: movie) else { throw ServiceError.thumbnailFailed }
                    try poster.write(to: bundle.appendingPathComponent("poster.jpg"), options: .atomic)
                    try Task.checkCancellation()
                    guard clearGeneration == generation else { throw ServiceError.supersededByRemoval }
                    try await publish(id: id, title: title, source: .sceneBundle(bundle), preparationOptions: publicationOptions,
                                      sourceKey: publicationSourceKey, preservingAddedAt: repreparation?.item.addedAt)
                    return
                }
                try await SystemWallpaperScenePreparation.record(
                    source: source, url: movie, size: options.size,
                    duration: options.duration, framesPerSecond: options.framesPerSecond, progress: progress
                )
                #else
                throw ServiceError.unsupportedContent
                #endif
            case .video: break
            }
            try Task.checkCancellation()
            guard clearGeneration == generation else { throw ServiceError.supersededByRemoval }
            try await publish(id: id, title: title, source: .pickedFile(movie), preparationOptions: publicationOptions,
                              sourceKey: publicationSourceKey, preservingAddedAt: repreparation?.item.addedAt)
        }
        preparationTask = task
        defer {
            preparationTask = nil
            preparingItemID = nil
            preparationProgress = nil
            preparingTitle = nil
            #if !LITE_BUILD
            if hasPendingLegacyRepreparation {
                hasPendingLegacyRepreparation = false
                let retryCancellationGeneration = preparationCancellationGeneration
                Task { [weak self] in
                    guard let self, preparationCancellationGeneration == retryCancellationGeneration else { return }
                    await reprepareLegacySceneCapsules()
                }
            }
            #endif
        }
        try await withTaskCancellationHandler(operation: { try await task.value }, onCancel: { task.cancel() })
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
            source: .bookmark(data: data, packageEntryName: entryName), sourceKey: Self.sourceKey(for: content)
        )
    }

    private func publish(id: String, title: String, source: PublishSource,
                         preparationOptions: SystemWallpaperPreparationOptions? = nil, sourceKey: String? = nil,
                         preservingAddedAt: Date? = nil) async throws {
        do {
            try await performPublish(id: id, title: title, source: source, preparationOptions: preparationOptions,
                                     sourceKey: sourceKey, preservingAddedAt: preservingAddedAt)
            lastError = nil
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            lastError = error.localizedDescription
            Logger.warning(
                "[systemWallpaper] publish failed for \(id): \(error.localizedDescription)",
                category: .fileAccess
            )
            throw error
        }
    }

    private func performPublish(id itemID: String, title: String, source: PublishSource,
                                preparationOptions: SystemWallpaperPreparationOptions?, sourceKey: String?,
                                preservingAddedAt: Date?) async throws {
        let resolver = dependencies.resolver
        let copyVideoFile = dependencies.copyVideoFile
        let extractVideoFromPackage = dependencies.extractVideoFromPackage
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
            case let .sceneBundle(url):
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
                    guard sourceURL.isFileURL else {
                        throw ServiceError.unsupportedContent
                    }
                    // Keep the resolving bookmark's scope alive while validating and copying the local target.
                    // Copying the link itself would leave the provider dependent on the original source.
                    let readableSource = sourceURL.resolvingSymlinksInPath()
                    let isScene = if case .sceneBundle = source {
                        true
                    } else {
                        false
                    }
                    let values = try readableSource.resourceValues(forKeys: [.isRegularFileKey, .isDirectoryKey])
                    guard isScene ? values.isDirectory == true : values.isRegularFile == true else {
                        throw ServiceError.unsupportedContent
                    }
                    if let packageEntryName {
                        try extractVideoFromPackage(readableSource, packageEntryName, staging)
                    } else {
                        try copyVideoFile(readableSource, staging)
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

        if Task.isCancelled {
            try? FileManager.default.removeItem(at: staged.url)
            throw CancellationError()
        }

        // Thumbnail from the staging copy so a failure aborts before the live copy or manifest is touched. No thumbnail means no tile in the wallpaper panel.
        let thumbnail: Data? = if case .sceneBundle = source {
            try? Data(contentsOf: staged.url.appendingPathComponent("poster.jpg"))
        } else {
            await dependencies.makeThumbnailJPEG(staged.url)
        }
        guard let jpeg = thumbnail else {
            try? FileManager.default.removeItem(at: staged.url)
            throw ServiceError.thumbnailFailed
        }
        if Task.isCancelled {
            try? FileManager.default.removeItem(at: staged.url)
            throw CancellationError()
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
                        addedAt: preservingAddedAt ?? dependencies.now(), preparationOptions: preparationOptions, sourceKey: sourceKey
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
        if let sourceKey {
            onItemPublished?(sourceKey)
        }
    }

    func remove(itemID: String) throws {
        if preparingItemID == itemID {
            cancelPreparation()
        }
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
        cancelPreparation()
        clearGeneration += 1
        activePublishes.removeAll()
        nonisolated(unsafe) var survivors: [String] = []
        var committed = false
        do {
            try SystemWallpaperLock.withExclusiveLock(root: dependencies.sharedRoot) {
                let manifest = try loadManifestForMutation()
                var emptied = manifest
                emptied.items = []
                try writeManifest(emptied)
                committed = true
                items = []
                // Every file is unreferenced now, so the sweep is the delete — no age guard, because nothing can be mid-publish once the manifest is empty and the lock is held.
                SystemWallpaperLibrary.sweepOrphans(
                    manifest: emptied,
                    videosDirectory: videosDirectory,
                    olderThan: -1,
                    stagingGrace: -1,
                    now: dependencies.now()
                )
                survivors = try Self.remainingFileNames(in: videosDirectory)
            }
            // Emptying the index while the files are still there would report a
            // clean library and leave the bytes unreachable, so say what stayed.
            lastError = survivors.isEmpty ? nil : Self.undeletedMessage(survivors)
        } catch {
            lastError = error.localizedDescription
            if committed {
                refreshDiskUsage()
                postLibraryChanged()
            }
            throw error
        }
        items = []
        refreshDiskUsage()
        postLibraryChanged()
    }

    /// Preserve batch failures after the add sheet closes, including failures followed by successes.
    func reportPublishFailures(_ failures: [String]) {
        if !failures.isEmpty {
            lastError = failures.joined(separator: "\n")
        }
    }

    func clearLastError() {
        lastError = nil
    }

    private static func remainingFileNames(in directory: URL) throws -> [String] {
        guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .map(\.lastPathComponent).sorted()
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

    func setHidesClockCalendarOnLockScreen(_ hides: Bool) {
        guard hides != hidesClockCalendarOnLockScreen else { return }
        do {
            try SystemWallpaperLock.withExclusiveLock(root: dependencies.sharedRoot) {
                var manifest = try loadManifestForMutation()
                manifest.hideClockCalendarOnLockScreen = hides
                try writeManifest(manifest)
            }
            hidesClockCalendarOnLockScreen = hides
            lastError = nil
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
        hidesClockCalendarOnLockScreen = manifest?.hideClockCalendarOnLockScreen ?? true
        items = manifest?.items ?? []
        refreshProviderStatus()
        // Re-read under the lock: another instance may have committed a new video since the read above.
        try? SystemWallpaperLock.withExclusiveLock(root: dependencies.sharedRoot) {
            guard let current = loadManifest() else { return }
            SystemWallpaperLibrary.sweepOrphans(
                manifest: current,
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
        let files = FileManager.default.enumerator(at: videosDirectory, includingPropertiesForKeys: [.fileSizeKey])?
            .compactMap { $0 as? URL } ?? []
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
            #if !LITE_BUILD
            if #available(macOS 26.0, *) {
                Task { [weak self] in await self?.reprepareLegacySceneCapsules() }
            }
            #endif
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
