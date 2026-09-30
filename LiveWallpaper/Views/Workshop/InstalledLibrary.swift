#if !LITE_BUILD
import AppKit
import Foundation
import LiveWallpaperCore
import LiveWallpaperProWPE
import Observation

struct WorkshopInstalledEntryIdentity: Equatable, Hashable, Sendable {
    let workshopID: String
    let importedAt: Date

    init(_ entry: WPEHistoryEntry) {
        workshopID = entry.origin.workshopID
        importedAt = entry.importedAt
    }
}

@MainActor
@Observable
final class InstalledLibraryModel {
    struct Dependencies {
        let loadEntries: @MainActor () -> [WPEHistoryEntry]
        let loadRemoteUpdateEpochs: @MainActor () -> [String: Double]
        let saveRemoteUpdateEpochs: @MainActor ([String: Double]) -> Void
        let loadLastUpdateCheckEpoch: @MainActor () -> Double
        let saveLastUpdateCheckEpoch: @MainActor (Double) -> Void
        let makeMetadataService: @MainActor () -> SteamWorkshopMetadataService
        let now: @MainActor () -> Date
        let prefetchPreviewURLs: @MainActor ([WPEHistoryEntry]) -> Void

        static let live = Dependencies(
            loadEntries: { SettingsManager.shared.loadGlobalSettings().recentWPEImports },
            loadRemoteUpdateEpochs: {
                UserDefaults.standard.dictionary(forKey: InstalledLibraryModel.remoteUpdateEpochsKey)
                    as? [String: Double] ?? [:]
            },
            saveRemoteUpdateEpochs: {
                UserDefaults.standard.set($0, forKey: InstalledLibraryModel.remoteUpdateEpochsKey)
            },
            loadLastUpdateCheckEpoch: {
                UserDefaults.standard.double(forKey: InstalledLibraryModel.lastUpdateCheckEpochKey)
            },
            saveLastUpdateCheckEpoch: {
                UserDefaults.standard.set($0, forKey: InstalledLibraryModel.lastUpdateCheckEpochKey)
            },
            makeMetadataService: { SteamWorkshopMetadataService() },
            now: Date.init,
            prefetchPreviewURLs: { WPEPreviewURLCache.shared.prefetch($0) }
        )
    }

    struct DeleteServices {
        let containsBookmark: @MainActor (String) -> Bool
        let removeBookmarks: @MainActor (String) -> Void
        let removeImportIfMatching: @MainActor (WorkshopInstalledEntryIdentity) -> Bool
        /// True while a download or update of this id is in flight.
        let isMutating: @MainActor (String) -> Bool
        /// Real removal from the shared Steam repository, performed by the connector —
        /// the app holds no write access. Throws when the mutation gate refuses, which
        /// must abort the delete instead of being folded into "nothing was freed".
        let deleteSharedRepositoryItem: @MainActor (WPEOrigin) async throws -> SteamDeleteResult?
    }

    private struct DeleteTicket: Equatable, Sendable {
        let token: UUID
        let appearanceGeneration: UInt64
        let identity: WorkshopInstalledEntryIdentity
    }

    private struct DeleteHandle {
        let ticket: DeleteTicket
        let task: Task<Void, Never>
    }

    @ObservationIgnored private let dependencies: Dependencies
    @ObservationIgnored let lifecycleOwner: InstalledPageLifecycleOwner
    @ObservationIgnored private var updateLaunchTask: Task<Void, Never>?
    @ObservationIgnored private var deleteHandles: [String: DeleteHandle] = [:]
    @ObservationIgnored private var appearanceGeneration: UInt64 = 0
    @ObservationIgnored private var isActive = false

    private(set) var entries: [WPEHistoryEntry] = []
    var errorMessage: String?
    private(set) var updatedWorkshopIDs: Set<String> = []
    private var cachedRemoteUpdateEpochs: [String: Double] = [:]

    static let remoteUpdateEpochsKey = "loomscreen.workshop.updateCheck.remoteEpochs.v1"
    static let lastUpdateCheckEpochKey = "loomscreen.workshop.updateCheck.epoch.v1"
    private static let updateInterval: TimeInterval = 86400

    init(
        dependencies: Dependencies = .live,
        lifecycleOwner: InstalledPageLifecycleOwner = InstalledPageLifecycleOwner()
    ) {
        self.dependencies = dependencies
        self.lifecycleOwner = lifecycleOwner
    }

    deinit {
        updateLaunchTask?.cancel()
        deleteHandles.values.forEach { $0.task.cancel() }
    }

    func onAppear() {
        if !isActive {
            appearanceGeneration &+= 1
            isActive = true
        }
        reload()
        loadUpdateFlags()
        scheduleUpdateCheck()
    }

    func onDisappear() {
        guard isActive else { return }
        isActive = false
        appearanceGeneration &+= 1
        updateLaunchTask?.cancel()
        updateLaunchTask = nil
        lifecycleOwner.tearDown()
    }

    func historyDidChange() {
        reload()
        reconcileUpdateFlags()
        scheduleUpdateCheck()
    }

    func reload() {
        entries = dependencies.loadEntries()
        dependencies.prefetchPreviewURLs(entries)
        invalidateDeletesForReimports()
    }

    func performDelete(_ entry: WPEHistoryEntry, services: DeleteServices) {
        errorMessage = nil
        let identity = WorkshopInstalledEntryIdentity(entry)
        let workshopID = entry.origin.workshopID

        // A download or update of this id holds the repository mutation gate, so the
        // delete would only fail there — after the library record was already gone.
        guard !services.isMutating(workshopID) else {
            errorMessage = Self.itemIsMutatingMessage
            return
        }

        guard deletesFiles(entry) else {
            removeLocalRecords(identity, services: services)
            return
        }

        deleteHandles.removeValue(forKey: workshopID)?.task.cancel()
        let expectedToFree = deletesFiles(entry)
        let ticket = DeleteTicket(
            token: UUID(),
            appearanceGeneration: appearanceGeneration,
            identity: identity
        )
        // History/bookmark removal waits for the repository call, so a refused gate keeps the record of files still on disk.
        // Keep cleanup alive when the transient page disappears.
        let task = Task { @MainActor [self] in
            guard canContinueDeleteCleanup(ticket) else {
                finishDelete(ticket)
                return
            }
            let repositoryDeleted: Bool
            do {
                repositoryDeleted = try await services.deleteSharedRepositoryItem(entry.origin)?.outcome == .deleted
            } catch {
                let shouldPublish = canPublishDelete(ticket)
                finishDelete(ticket)
                if shouldPublish {
                    errorMessage = Self.itemIsMutatingMessage
                }
                return
            }
            guard canContinueDeleteCleanup(ticket) else {
                finishDelete(ticket)
                return
            }
            let removed = removeLocalRecords(identity, services: services)
            let shouldPublish = canPublishDelete(ticket)
            finishDelete(ticket)
            guard shouldPublish, removed else { return }
            if expectedToFree, !repositoryDeleted {
                errorMessage = String(
                    localized: "Removed \(entry.origin.title) from the library, but its files couldn't be deleted.",
                    bundle: .appLanguage, comment: "Workshop delete: history removed but managed files couldn't be deleted."
                )
            }
        }
        deleteHandles[workshopID] = DeleteHandle(ticket: ticket, task: task)
    }

    /// The persisted half of a delete. The history CAS refuses when a re-import
    /// replaced this exact import, in which case the bookmark stays too.
    @discardableResult
    private func removeLocalRecords(
        _ identity: WorkshopInstalledEntryIdentity,
        services: DeleteServices
    ) -> Bool {
        guard services.removeImportIfMatching(identity) else {
            reload()
            return false
        }
        if services.containsBookmark(identity.workshopID) {
            services.removeBookmarks(identity.workshopID)
        }
        reload()
        return true
    }

    private static var itemIsMutatingMessage: String {
        String(
            localized: "This Workshop item is already being updated.",
            bundle: .appLanguage, comment: "Workshop download rejected because the same item is already being mutated."
        )
    }

    /// True when deleting will actually reclaim disk: a Workshop item's files live in
    /// the shared repository and the connector removes them for real.
    func deletesFiles(_ entry: WPEHistoryEntry) -> Bool {
        Self.repositorySourceItemID(for: entry.origin) != nil
    }

    private static func repositorySourceItemID(for origin: WPEOrigin) -> String? {
        guard let itemID = origin.steamFolderItemID,
              itemID == origin.workshopID,
              SteamLibraryPaths.isSafeWorkshopID(itemID) else { return nil }
        return itemID
    }

    /// A numeric manifest ID alone grants no ownership of a same-ID item in another library.
    static func repositoryDeletionItemID(for origin: WPEOrigin, steamRoot: URL) -> String? {
        guard let itemID = repositorySourceItemID(for: origin),
              let path = URL.resourceValues(forKeys: [.pathKey], fromBookmarkData: origin.sourceFolderBookmark)?.path
        else { return nil }
        let source = URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL.resolvingSymlinksInPath()
        let expected = SteamLibraryPaths.workshopContentRoot(steamRoot: steamRoot)
            .appendingPathComponent(itemID, isDirectory: true).standardizedFileURL.resolvingSymlinksInPath()
        guard source == expected else { return nil }
        return itemID
    }

    func showInFinder(_ entry: WPEHistoryEntry) {
        guard let folder = try? SecurityScopedBookmarkResolver.shared
            .resolve(entry.origin.sourceFolderBookmark, target: .transient).get().url
        else { return }
        let didStart = folder.startAccessingSecurityScopedResource()
        defer {
            if didStart {
                folder.stopAccessingSecurityScopedResource()
            }
        }
        NSWorkspace.shared.activateFileViewerSelecting([folder])
    }

    func checkForUpdatesIfNeeded() async {
        guard isActive else { return }
        let now = dependencies.now().timeIntervalSince1970
        guard now - dependencies.loadLastUpdateCheckEpoch() >= Self.updateInterval else { return }
        let snapshot = entries
        guard !snapshot.isEmpty else { return }

        let service = dependencies.makeMetadataService()
        let currentIDs = Set(snapshot.map(\.origin.workshopID))
        let initialEpochs = cachedRemoteUpdateEpochs.filter { currentIDs.contains($0.key) }
        let generation = appearanceGeneration

        guard let replacement = await lifecycleOwner.replaceUpdate(operation: { ticket -> [String: Double]? in
            var remoteEpochs = initialEpochs
            fetchLoop: for entry in snapshot {
                guard self.lifecycleOwner.canContinue(ticket) else { return nil }
                guard let id = UInt64(entry.origin.workshopID) else { continue }
                let result = await service.fetch(publishedFileID: id)
                guard self.lifecycleOwner.canContinue(ticket) else { return nil }
                switch result {
                case let .success(metadata):
                    if let remoteUpdated = metadata.timeUpdated {
                        remoteEpochs[entry.origin.workshopID] = remoteUpdated.timeIntervalSince1970
                    } else {
                        remoteEpochs.removeValue(forKey: entry.origin.workshopID)
                    }
                case let .failure(error):
                    if case .rateLimited = error {
                        break fetchLoop
                    }
                    continue
                }
            }
            return remoteEpochs
        }) else { return }

        lifecycleOwner.commitUpdate(replacement) { remoteEpochs in
            guard isActive, generation == appearanceGeneration else { return }
            cachedRemoteUpdateEpochs = remoteEpochs
            dependencies.saveRemoteUpdateEpochs(remoteEpochs)
            reconcileUpdateFlags()
            dependencies.saveLastUpdateCheckEpoch(now)
        }
    }

    private func scheduleUpdateCheck() {
        updateLaunchTask?.cancel()
        updateLaunchTask = Task { @MainActor [weak self] in
            await self?.checkForUpdatesIfNeeded()
        }
    }

    private func loadUpdateFlags() {
        cachedRemoteUpdateEpochs = dependencies.loadRemoteUpdateEpochs()
        reconcileUpdateFlags()
    }

    private func reconcileUpdateFlags() {
        updatedWorkshopIDs = Set(entries.compactMap { entry in
            guard let remoteEpoch = cachedRemoteUpdateEpochs[entry.origin.workshopID],
                  remoteEpoch > entry.importedAt.timeIntervalSince1970
            else { return nil }
            return entry.origin.workshopID
        })
    }

    private func invalidateDeletesForReimports() {
        let staleWorkshopIDs = deleteHandles.compactMap { workshopID, handle -> String? in
            guard let current = entries.first(where: { $0.origin.workshopID == workshopID }),
                  WorkshopInstalledEntryIdentity(current) != handle.ticket.identity
            else { return nil }
            return workshopID
        }
        for workshopID in staleWorkshopIDs {
            deleteHandles.removeValue(forKey: workshopID)?.task.cancel()
        }
    }

    private func canPublishDelete(_ ticket: DeleteTicket) -> Bool {
        guard isActive,
              ticket.appearanceGeneration == appearanceGeneration,
              deleteHandles[ticket.identity.workshopID]?.ticket == ticket,
              !Task.isCancelled
        else { return false }
        guard let current = entries.first(where: { $0.origin.workshopID == ticket.identity.workshopID }) else {
            return true
        }
        return WorkshopInstalledEntryIdentity(current) == ticket.identity
    }

    /// Re-read the persisted library before every destructive phase. Page
    /// disappearance may continue cleanup; a same-ID re-import may not.
    private func canContinueDeleteCleanup(_ ticket: DeleteTicket) -> Bool {
        guard deleteHandles[ticket.identity.workshopID]?.ticket == ticket,
              !Task.isCancelled
        else { return false }
        // The record survives until the repository call returns, so absence is not the
        // signal — only a *different* import of the same id is.
        guard let current = dependencies.loadEntries().first(where: {
            $0.origin.workshopID == ticket.identity.workshopID
        }) else { return true }
        return WorkshopInstalledEntryIdentity(current) == ticket.identity
    }

    private func finishDelete(_ ticket: DeleteTicket) {
        guard deleteHandles[ticket.identity.workshopID]?.ticket == ticket else { return }
        deleteHandles.removeValue(forKey: ticket.identity.workshopID)
    }
}
#endif
