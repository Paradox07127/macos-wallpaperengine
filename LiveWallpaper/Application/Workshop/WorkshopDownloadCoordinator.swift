#if !LITE_BUILD
import Foundation
import LiveWallpaperCore
import Observation

/// The existing Doctor owns transport and security scope; this seam lets tests
/// deliver late content without running SteamCMD. It owns no application state.
@MainActor
protocol WorkshopItemDownloading {
    func downloadWorkshopItem<Imported: Sendable>(
        _ itemID: UInt64,
        onProgress: SteamCMDDoctorService.SteamCMDProgressHandler?,
        onContentReady: @MainActor @Sendable (URL) async -> Imported
    ) async -> WorkshopItemDownloadResult<Imported>
}

extension SteamCMDDoctorService: WorkshopItemDownloading {}

@MainActor
@Observable
final class WorkshopDownloadCoordinator {
    enum DownloadPhase: Equatable, Sendable {
        case idle
        case downloading
        case importing
        case succeeded
        /// Preset for baseWorkshopID, not a wallpaper — separate from succeeded because it lands somewhere else.
        case succeededAsPreset(baseWorkshopID: String)
        case failed(String)
    }

    struct DownloadProgressBytes: Equatable, Sendable {
        let downloaded: UInt64?
        let total: UInt64?
    }

    static let shared = WorkshopDownloadCoordinator()

    private(set) var phases: [UInt64: DownloadPhase] = [:]
    /// Per-item download fraction (0...1); absent = indeterminate.
    private(set) var progress: [UInt64: Double] = [:]
    private(set) var progressBytes: [UInt64: DownloadProgressBytes] = [:]
    /// Roots whose missing Workshop dependencies are downloading; their phase stays `.importing` meanwhile.
    private(set) var fetchingDependencies: Set<UInt64> = []

    @ObservationIgnored private let importService: WallpaperEngineImportService
    @ObservationIgnored private let repositoryCoordinator: WorkshopRepositoryCoordinator
    @ObservationIgnored private let settings: SettingsManager
    @ObservationIgnored private let toasts: WorkshopToastCenter
    @ObservationIgnored private let cancelSteamCMD: @MainActor (UUID) async -> Void
    @ObservationIgnored private var tasks: [UInt64: Task<Void, Never>] = [:]
    @ObservationIgnored private var activeDownloads: [UInt64: WorkshopDownloadAttempt] = [:]

    init(
        importService: WallpaperEngineImportService = WallpaperEngineImportService(),
        repositoryCoordinator: WorkshopRepositoryCoordinator = .shared,
        settings: SettingsManager = .shared,
        toasts: WorkshopToastCenter = .shared,
        cancelSteamCMD: @escaping @MainActor (UUID) async -> Void = {
            _ = await SteamConnectorClient.cancelActiveSteamCMD(operationID: $0.uuidString)
        }
    ) {
        self.importService = importService
        self.repositoryCoordinator = repositoryCoordinator
        self.settings = settings
        self.toasts = toasts
        self.cancelSteamCMD = cancelSteamCMD
    }

    func phase(for itemID: UInt64) -> DownloadPhase {
        phases[itemID] ?? .idle
    }

    func isBusy(_ itemID: UInt64) -> Bool {
        // tasks outlives the phase while a root's dependencies are still downloading; without it a second Download would leave the first chain running unattended.
        if tasks[itemID] != nil {
            return true
        }
        switch phases[itemID] {
        case .downloading, .importing: return true
        default: return false
        }
    }

    func activeAttempt(for itemID: UInt64) -> WorkshopDownloadAttempt? {
        activeDownloads[itemID]
    }

    @discardableResult
    func download(
        itemID: UInt64, title: String, using doctor: any WorkshopItemDownloading, replacing: WPEHistoryEntry? = nil
    ) -> WorkshopDownloadAttempt? {
        guard !isBusy(itemID) else { return activeDownloads[itemID] }
        let attemptID = UUID()
        let attempt = WorkshopDownloadAttempt(id: attemptID, itemID: itemID)
        activeDownloads[itemID] = attempt
        clearProgress(itemID)
        phases[itemID] = .downloading
        let approved = replacing?.origin.steamFolderItemID == nil ? replacing : nil
        tasks[itemID] = Task { [weak self] in
            await SteamCMDOperationScope.$currentID.withValue(attemptID.uuidString) {
                await self?.run(itemID: itemID, title: title, doctor: doctor, attemptID: attemptID, approved: approved)
            }
        }
        return attempt
    }

    func cancel(_ itemID: UInt64) {
        tasks[itemID]?.cancel()
        tasks[itemID] = nil
        let cancelledAttempt = activeDownloads[itemID]?.id
        phases[itemID] = .idle
        clearProgress(itemID)
        fetchingDependencies.remove(itemID)
        activeDownloads.removeValue(forKey: itemID)?.finish(.cancelled)
        // Task.cancel invalidates the connection, which makes the connector drop a still-queued run; a child already running is signalled here, scoped to this attempt's id so another item or a retry survives.
        if let cancelledAttempt {
            Task { [cancelSteamCMD] in await cancelSteamCMD(cancelledAttempt) }
        }
    }

    #if DEBUG
    func downloadTaskForTesting(itemID: UInt64) -> Task<Void, Never>? {
        tasks[itemID]
    }
    #endif

    private func isCurrent(itemID: UInt64, attemptID: UUID) -> Bool {
        !Task.isCancelled && activeDownloads[itemID]?.id == attemptID
    }

    /// `approved`: the one local copy this attempt may land beside; any other conflicting entry still refuses it.
    private func run(
        itemID: UInt64, title: String, doctor: any WorkshopItemDownloading, attemptID: UUID, approved: WPEHistoryEntry?
    ) async {
        let result: WorkshopItemDownloadResult<WallpaperEngineImportService.ImportResult?>
        if let existing = libraryCopyBlockingDownload(of: itemID), !Self.isApproved(existing, approved) {
            result = .failed(reason: Self.libraryConflictReason(existing))
        } else {
            do {
                result = try await repositoryCoordinator.withExclusiveMutation(
                    workshopID: String(itemID)
                ) { [weak self] in
                    guard let self else {
                        return .failed(reason: String(
                            localized: "The Workshop download stopped because its owner was released.",
                            bundle: .appLanguage, comment: "Workshop download failed because its app-lifetime coordinator was unexpectedly released."
                        ))
                    }
                    return await doctor.downloadWorkshopItem(
                        itemID,
                        onProgress: { [weak self] percent, downloadedBytes, totalBytes in
                            Task { [weak self] in
                                await self?.recordProgress(
                                    itemID: itemID,
                                    attemptID: attemptID,
                                    percent: percent,
                                    downloadedBytes: downloadedBytes,
                                    totalBytes: totalBytes
                                )
                            }
                        },
                        onContentReady: { [weak self] folderURL -> WallpaperEngineImportService.ImportResult? in
                            guard let self, isCurrent(itemID: itemID, attemptID: attemptID) else { return nil }
                            phases[itemID] = .importing
                            clearProgress(itemID)
                            let result: WallpaperEngineImportService.ImportResult
                            do {
                                result = try await importService.importProject(folder: folderURL)
                            } catch {
                                result = .rejected(reason: String(
                                    localized: "Couldn't import this project: \(error.localizedDescription)", bundle: .appLanguage
                                ))
                            }
                            guard isCurrent(itemID: itemID, attemptID: attemptID) else { return nil }
                            return result
                        }
                    )
                }
            } catch WorkshopRepositoryCoordinator.MutationError.itemAlreadyMutating {
                result = .failed(reason: String(
                    localized: "This Workshop item is already being updated.",
                    bundle: .appLanguage, comment: "Workshop download rejected because the same item is already being mutated."
                ))
            } catch {
                result = .failed(reason: error.localizedDescription)
            }
        }
        // A newer attempt may have superseded this one mid-flight; only the
        // current attempt may mutate shared state.
        guard isCurrent(itemID: itemID, attemptID: attemptID) else { return }

        var outcome: WorkshopDownloadOutcome?
        switch result {
        case let .imported(importResult):
            outcome = await finishImport(importResult, itemID: itemID, title: title, attemptID: attemptID, approved: approved)
            guard isCurrent(itemID: itemID, attemptID: attemptID) else { return }
            if case .unsupported? = outcome, case let .unsupported(origin)? = importResult, !origin.missingDependencyIDs.isEmpty {
                fetchingDependencies.insert(itemID)
                outcome = await fetchDependencies(
                    rootItemID: itemID,
                    rootTitle: title,
                    attemptID: attemptID,
                    missingIDs: origin.missingDependencyIDs,
                    doctor: doctor,
                    approved: approved
                )
                // A cancel, or a retry that started after it, owns the item now.
                if isCurrent(itemID: itemID, attemptID: attemptID) {
                    fetchingDependencies.remove(itemID)
                    phases[itemID] = .succeeded
                }
            }
        case let .notConfigured(reason):
            finish(itemID: itemID, title: title, phase: .failed(reason))
        case .loginRequired:
            finish(itemID: itemID, title: title, phase: .failed(String(localized: "Loomscreen's Steam download session isn't connected. Connect your account in Settings → Workshop, then try again.", bundle: .appLanguage, comment: "Steam download blocked because Loomscreen's own Steam session is not signed in; shared by engine-assets and Workshop item downloads.")))
        case .untrustedBinary:
            finish(itemID: itemID, title: title, phase: .failed(String(localized: "SteamCMD isn't a verified Valve build, so the download was blocked. Re-select the official SteamCMD in the Doctor.", bundle: .appLanguage, comment: "Workshop download blocked: unverified SteamCMD binary.")))
        case .steamUnreachable:
            finish(itemID: itemID, title: title, phase: .failed(String(localized: "Steam reported \"No Connection\" while downloading this item. Check your network and try again; Steam also answers this way when the account doesn't own Wallpaper Engine.", bundle: .appLanguage, comment: "Workshop download failed: SteamCMD reported No Connection, which is ambiguous between network and ownership.")))
        case .removedFromSteam:
            finish(itemID: itemID, title: title, phase: .failed(String(localized: "This item is no longer available on Steam.", bundle: .appLanguage, comment: "Workshop download failed: item removed from Steam.")))
        case .timedOut:
            finish(itemID: itemID, title: title, phase: .failed(String(localized: "The download timed out. Try again.", bundle: .appLanguage, comment: "Workshop download timed out.")))
        case let .failed(reason):
            finish(itemID: itemID, title: title, phase: .failed(reason))
        }
        // Released here rather than in `finish` so the dependency fetch above
        // still counts as this item's in-flight download for `cancel`.
        if isCurrent(itemID: itemID, attemptID: attemptID) {
            tasks[itemID] = nil
            let attempt = activeDownloads.removeValue(forKey: itemID)
            if let outcome {
                attempt?.finish(outcome)
            } else if case let .failed(reason) = phases[itemID] {
                attempt?.finish(.failed(reason: reason))
            }
        }
    }

    /// Ignored unless the item is still in the `.downloading` phase
    /// (import/terminal phases clear it).
    private func recordProgress(
        itemID: UInt64,
        attemptID: UUID,
        percent: Double,
        downloadedBytes: UInt64?,
        totalBytes: UInt64?
    ) {
        guard isCurrent(itemID: itemID, attemptID: attemptID), case .downloading? = phases[itemID], percent.isFinite else { return }
        progress[itemID] = min(max(percent / 100, 0), 1)
        progressBytes[itemID] = DownloadProgressBytes(
            downloaded: downloadedBytes,
            total: (totalBytes ?? 0) > 0 ? totalBytes : nil
        )
    }

    private func clearProgress(_ itemID: UInt64) {
        progress[itemID] = nil
        progressBytes[itemID] = nil
    }

    private func finishImport(
        _ result: WallpaperEngineImportService.ImportResult?, itemID: UInt64, title: String, attemptID: UUID, approved: WPEHistoryEntry?
    ) async -> WorkshopDownloadOutcome {
        guard isCurrent(itemID: itemID, attemptID: attemptID) else { return .cancelled }
        guard let result else {
            let reason = String(localized: "Couldn't read the downloaded files.", bundle: .appLanguage, comment: "Workshop import failed: unreadable download.")
            finish(itemID: itemID, title: title, phase: .failed(reason))
            return .failed(reason: reason)
        }
        switch result {
        case let .ready(_, origin), let .unsupported(origin):
            if let existing = libraryConflict(for: origin, approved: approved) {
                let reason = Self.libraryConflictReason(existing)
                finish(itemID: itemID, title: title, phase: .failed(reason))
                return .failed(reason: reason)
            }
        default:
            break
        }
        switch result {
        case let .ready(_, origin):
            let entry = recordImport(origin)
            finish(itemID: itemID, title: title, phase: .succeeded)
            return .succeeded(entry)
        case let .unsupported(origin):
            let entry = recordImport(origin)
            // With dependencies missing, the fetch that follows posts the result and ends the stage.
            if origin.missingDependencyIDs.isEmpty {
                finishUnsupported(entry, itemID: itemID, title: title)
            }
            return .unsupported(entry)
        case let .workshopPreset(preset):
            await settings.registerScenePreset(preset, clearsDeleteTombstone: true)
            guard isCurrent(itemID: itemID, attemptID: attemptID) else { return .cancelled }
            Logger.info("Registered a downloaded Workshop preset", category: .workshop)
            // Not the shared success toast: a preset does not become a wallpaper-library entry, so Added to your library would send the user looking where it will never be.
            finish(itemID: itemID, title: title, phase: .succeededAsPreset(
                baseWorkshopID: preset.baseWorkshopID
            ))
            return .succeededAsPreset(baseWorkshopID: preset.baseWorkshopID)
        case let .sceneFailure(cause, _, _):
            finish(itemID: itemID, title: title, phase: .failed(cause.reason))
            return .failed(reason: cause.reason)
        case let .rejected(reason):
            finish(itemID: itemID, title: title, phase: .failed(reason))
            return .failed(reason: reason)
        }
    }

    private func finish(itemID: UInt64, title: String, phase: DownloadPhase) {
        clearProgress(itemID)
        phases[itemID] = phase
        switch phase {
        case .succeeded:
            toasts.post(
                headline: String(localized: "Downloaded", bundle: .appLanguage, comment: "Workshop download success toast headline."),
                title: title,
                message: String(localized: "Added to your library.", bundle: .appLanguage, comment: "Workshop download success toast subtitle."),
                isSuccess: true
            )
        case let .succeededAsPreset(baseWorkshopID):
            let hasBase = settings.loadGlobalSettings()
                .recentWPEImports.contains { $0.origin.matchesWorkshopItem(baseWorkshopID) }
            toasts.post(
                headline: String(localized: "Preset added", bundle: .appLanguage, comment: "Workshop preset download success toast headline."),
                title: title,
                message: hasBase
                    ? String(
                        localized: "Pick it under Preset in that wallpaper's scene settings.",
                        bundle: .appLanguage, comment: "Workshop preset download success toast subtitle when the base wallpaper is installed."
                    )
                    : String(
                        localized: "Download wallpaper \(baseWorkshopID) to use it — a preset only restyles the wallpaper it was made for.",
                        bundle: .appLanguage, comment: "Workshop preset download toast subtitle when the base wallpaper is missing; %@ is its Workshop ID."
                    ),
                isSuccess: true
            )
        case let .failed(message):
            toasts.post(
                headline: String(localized: "Download failed", bundle: .appLanguage, comment: "Workshop download failure toast headline."),
                title: title,
                message: message,
                isSuccess: false
            )
        default:
            break
        }
    }

    /// A library entry holding `itemID` from a still-present folder, when no entry is this item's own Steam folder (which an update refreshes).
    func libraryCopyBlockingDownload(of itemID: UInt64) -> WPEHistoryEntry? {
        let id = String(itemID)
        let holders = settings.loadGlobalSettings().recentWPEImports.filter {
            [$0.origin.workshopID, $0.origin.steamFolderItemID].contains(id)
        }
        guard !holders.contains(where: { $0.origin.steamFolderItemID == id }) else { return nil }
        return holders.first { WorkshopFolderImportCoordinator.originResolves($0.origin) }
    }

    /// The local copy a manual download must confirm replacing; nil = download without asking.
    func localCopyToReplace(for itemID: UInt64) -> WPEHistoryEntry? {
        libraryCopyBlockingDownload(of: itemID).flatMap { $0.origin.steamFolderItemID == nil ? $0 : nil }
    }

    /// Rechecked after the download because the user may have imported a local copy while it ran.
    private func libraryConflict(for origin: WPEOrigin, approved: WPEHistoryEntry?) -> WPEHistoryEntry? {
        guard let path = URL.resourceValues(forKeys: [.pathKey], fromBookmarkData: origin.sourceFolderBookmark)?.path,
              let conflict = settings.conflictingWPEImport(workshopID: origin.workshopID, sourceFolder: URL(fileURLWithPath: path, isDirectory: true)),
              !Self.isApproved(conflict, approved) else { return nil }
        return conflict
    }

    private static func isApproved(_ existing: WPEHistoryEntry, _ approved: WPEHistoryEntry?) -> Bool {
        guard let approved else { return false }
        return existing.importedAt == approved.importedAt
            && existing.origin.sourceFolderBookmark == approved.origin.sourceFolderBookmark
    }

    private static func libraryConflictReason(_ existing: WPEHistoryEntry) -> String {
        String(localized: "\(existing.origin.title) is already in your library from another folder.", bundle: .appLanguage, comment: "Folder import failure: the one chosen project has a Workshop id the library already holds from a different folder. Placeholder is the title of the wallpaper already in the library.")
    }

    private func recordImport(_ origin: WPEOrigin) -> WPEHistoryEntry {
        let entry = WPEHistoryEntry(origin: origin, importedAt: Date(), lastUsedAt: nil)
        settings.recordWPEImport(
            entry,
            clearsDeleteTombstone: true
        )
        Logger.info("Imported downloaded Workshop item into the library", category: .workshop)
        return entry
    }

    /// The phase stays a success because the item is in the library; only the card says it can't run.
    private func finishUnsupported(_ entry: WPEHistoryEntry, itemID: UInt64, title: String) {
        clearProgress(itemID)
        phases[itemID] = .succeeded
        toasts.post(
            headline: String(
                localized: "Downloaded, but it can't run on this Mac", bundle: .appLanguage,
                comment: "Workshop download card headline: the item reached the library but this Mac cannot run it."
            ),
            title: title,
            message: FallbackReason.cannotRunSummary(for: entry.origin),
            isSuccess: false
        )
    }

    // MARK: - Dependencies

    private func fetchDependencies(
        rootItemID: UInt64,
        rootTitle: String,
        attemptID: UUID,
        missingIDs: [String],
        doctor: any WorkshopItemDownloading,
        approved: WPEHistoryEntry?
    ) async -> WorkshopDownloadOutcome {
        let report = await WorkshopDependencyResolver.resolve(
            rootWorkshopID: String(rootItemID),
            missingDependencyIDs: missingIDs,
            isCancelled: { !self.isCurrent(itemID: rootItemID, attemptID: attemptID) },
            fetch: { await self.fetchDependency(workshopID: $0, doctor: doctor) }
        )
        guard isCurrent(itemID: rootItemID, attemptID: attemptID), !report.wasCancelled else { return .cancelled }

        for failure in report.failures {
            Logger.warning(
                "Workshop dependency \(failure.workshopID) failed to download: \(failure.reason)",
                category: .workshop
            )
        }
        if !report.truncations.isEmpty {
            Logger.warning(
                "Workshop dependency fetch stopped at a limit (\(report.truncations)); still missing: \(report.skipped.joined(separator: ", "))",
                category: .workshop
            )
        }

        guard report.isFullyResolved else {
            let unresolved = (report.failures.map(\.workshopID) + report.skipped).joined(separator: ", ")
            let reason = report.truncations.isEmpty
                ? String(
                    localized: "Couldn't download: \(unresolved)",
                    bundle: .appLanguage, comment: "Workshop toast subtitle listing the Workshop IDs of linked items that failed to download."
                )
                : String(
                    localized: "Stopped at the download limit for linked items. Still missing: \(unresolved)",
                    bundle: .appLanguage, comment: "Workshop toast subtitle when the linked-item download hit its depth, count or size limit; the placeholder lists the remaining Workshop IDs."
                )
            toasts.post(
                headline: String(localized: "Required items missing", bundle: .appLanguage, comment: "Workshop toast headline when a wallpaper's linked Workshop items could not all be downloaded."),
                title: rootTitle,
                message: reason,
                isSuccess: false
            )
            return .failed(reason: reason)
        }

        // Every dependency arrived, but claiming success before the re-read would leave the library entry still saying it needs them.
        let entry = await reimportRoot(itemID: rootItemID, attemptID: attemptID, doctor: doctor, approved: approved)
        guard isCurrent(itemID: rootItemID, attemptID: attemptID) else { return .cancelled }
        guard let entry else {
            let reason = String(localized: "Downloaded them, but this wallpaper still couldn't be read. Try downloading it again.", bundle: .appLanguage, comment: "Workshop toast subtitle when the linked items arrived but re-reading the wallpaper failed.")
            toasts.post(
                headline: String(localized: "Required items missing", bundle: .appLanguage, comment: "Workshop toast headline when a wallpaper's linked Workshop items could not all be downloaded."),
                title: rootTitle,
                message: reason,
                isSuccess: false
            )
            return .failed(reason: reason)
        }
        toasts.post(
            headline: String(localized: "Required items added", bundle: .appLanguage, comment: "Workshop toast headline when a wallpaper's linked Workshop items were downloaded too."),
            title: rootTitle,
            message: String(localized: "Downloaded the other Workshop items this wallpaper needs.", bundle: .appLanguage, comment: "Workshop toast subtitle after the linked Workshop items were downloaded."),
            isSuccess: true
        )
        return .succeeded(entry)
    }

    private func fetchDependency(
        workshopID: String,
        doctor: any WorkshopItemDownloading
    ) async -> WorkshopDependencyFetchOutcome {
        guard let itemID = UInt64(workshopID) else {
            return WorkshopDependencyFetchOutcome(failureReason: "not a Workshop ID")
        }
        let result: WorkshopItemDownloadResult<[String]>
        do {
            result = try await repositoryCoordinator.withExclusiveMutation(workshopID: workshopID) { [weak self] in
                guard let self else { return .failed(reason: "coordinator released") }
                return await doctor.downloadWorkshopItem(
                    itemID,
                    onProgress: nil,
                    onContentReady: { [weak self] folderURL -> [String] in
                        guard let self else { return [] }
                        return await importService.missingDependencyIDs(inFolder: folderURL)
                    }
                )
            }
        } catch {
            return WorkshopDependencyFetchOutcome(failureReason: error.localizedDescription)
        }
        switch result {
        case let .imported(nestedDependencyIDs):
            return WorkshopDependencyFetchOutcome(dependencyIDs: nestedDependencyIDs)
        case let .notConfigured(reason), let .failed(reason):
            return WorkshopDependencyFetchOutcome(failureReason: reason)
        case .loginRequired:
            return WorkshopDependencyFetchOutcome(failureReason: "SteamCMD login required")
        case .untrustedBinary:
            return WorkshopDependencyFetchOutcome(failureReason: "SteamCMD binary not verified")
        case .steamUnreachable:
            return WorkshopDependencyFetchOutcome(failureReason: "Steam unreachable")
        case .removedFromSteam:
            return WorkshopDependencyFetchOutcome(failureReason: "removed from Steam")
        case .timedOut:
            return WorkshopDependencyFetchOutcome(failureReason: "timed out")
        }
    }

    /// Re-read the root now that dependencies are on disk — SteamCMD no-ops on an item that is already current.
    @discardableResult
    private func reimportRoot(
        itemID: UInt64, attemptID: UUID, doctor: any WorkshopItemDownloading, approved: WPEHistoryEntry?
    ) async -> WPEHistoryEntry? {
        let result: WorkshopItemDownloadResult<WallpaperEngineImportService.ImportResult?>
        do {
            result = try await repositoryCoordinator.withExclusiveMutation(workshopID: String(itemID)) { [weak self] in
                guard let self else {
                    return .failed(reason: String(
                        localized: "The Workshop download stopped because its owner was released.",
                        bundle: .appLanguage, comment: "Workshop download failed because its app-lifetime coordinator was unexpectedly released."
                    ))
                }
                return await doctor.downloadWorkshopItem(
                    itemID,
                    onProgress: nil,
                    onContentReady: { [weak self] folderURL -> WallpaperEngineImportService.ImportResult? in
                        guard let self, isCurrent(itemID: itemID, attemptID: attemptID) else { return nil }
                        return try? await importService.importProject(folder: folderURL)
                    }
                )
            }
        } catch {
            return nil
        }
        guard isCurrent(itemID: itemID, attemptID: attemptID),
              case let .imported(importResult) = result,
              case let .ready(_, origin)? = importResult,
              libraryConflict(for: origin, approved: approved) == nil else { return nil }
        let entry = WPEHistoryEntry(origin: origin, importedAt: Date(), lastUsedAt: nil)
        settings.recordWPEImport(
            entry,
            clearsDeleteTombstone: true
        )
        Logger.info("Re-imported a Workshop item once its dependencies arrived", category: .workshop)
        return entry
    }
}
#endif
