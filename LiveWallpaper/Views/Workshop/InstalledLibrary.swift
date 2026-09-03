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

/// State and command owner for the Installed page. The SwiftUI view supplies
/// environment-bound operations, while this model owns publication lifetime.
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
            now: Date.init
        )
    }

    struct DeleteServices {
        let containsBookmark: @MainActor (String) -> Bool
        let removeBookmarks: @MainActor (String) -> Void
        let removeImportIfMatching: @MainActor (WorkshopInstalledEntryIdentity) -> Bool
        /// Real removal from the shared Steam repository, performed by the
        /// connector — the app holds no write access to Steam's files.
        let deleteSharedRepositoryItem: @MainActor (String) async -> SteamDeleteResult?
    }

    struct DropTicket: Equatable, Sendable {
        fileprivate let appearanceGeneration: UInt64
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
    @ObservationIgnored private var applyTasks: [UUID: Task<Void, Never>] = [:]
    @ObservationIgnored private var deleteHandles: [String: DeleteHandle] = [:]
    @ObservationIgnored private var appearanceGeneration: UInt64 = 0
    @ObservationIgnored private var isActive = false

    private(set) var entries: [WPEHistoryEntry] = []
    var searchText = ""
    private(set) var selectedTypes = Set(WPELibraryTypeKind.allCases)
    private(set) var selectedSources = Set(InstalledSource.allCases)
    private(set) var selectedStorage = Set(InstalledStorageKind.allCases)
    var showFilters = false
    var sortOrder: WPELibrarySortOrder = .recommended
    var errorMessage: String?
    var pendingDelete: WPEHistoryEntry?
    private(set) var selectedEntry: WPEHistoryEntry?
    var inspectorHidden = false
    private(set) var isDraggingEntry = false
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
        applyTasks.values.forEach { $0.cancel() }
        deleteHandles.values.forEach { $0.task.cancel() }
    }

    var visibleEntries: [WPEHistoryEntry] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        let filtered = entries.filter { entry in
            typeMatches(entry)
                && sourceMatches(entry)
                && storageMatches(entry)
                && matchesSearch(entry, query: query)
        }
        return WPEInstalledLibrarySorter.sorted(
            filtered,
            by: sortOrder,
            updatedWorkshopIDs: updatedWorkshopIDs
        )
    }

    var activeFilterCount: Int {
        var count = 0
        if WorkshopFilterMath.isNarrowing(selectedTypes, total: WPELibraryTypeKind.allCases.count) {
            count += 1
        }
        if WorkshopFilterMath.isNarrowing(selectedSources, total: InstalledSource.allCases.count) {
            count += 1
        }
        if WorkshopFilterMath.isNarrowing(selectedStorage, total: InstalledStorageKind.allCases.count) {
            count += 1
        }
        return count
    }

    #if DEBUG
    /// Test-only introspection; no production reader.
    var activeApplyCommandCount: Int {
        applyTasks.count
    }
    #endif

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
        applyTasks.values.forEach { $0.cancel() }
        applyTasks.removeAll()
        isDraggingEntry = false
    }

    func historyDidChange() {
        reload()
        reconcileUpdateFlags()
        refreshSelectedEntry()
        scheduleUpdateCheck()
    }

    func select(_ entry: WPEHistoryEntry) {
        if selectedEntry?.id == entry.id {
            selectedEntry = nil
        } else {
            selectedEntry = entry
            inspectorHidden = false
        }
    }

    func clearSelection() {
        selectedEntry = nil
    }

    func clearSelectionAndBrowse(tag: String, action: (String) -> Void) {
        selectedEntry = nil
        action(tag)
    }

    func requestDelete(_ entry: WPEHistoryEntry) {
        pendingDelete = entry
    }

    func cancelDelete() {
        pendingDelete = nil
    }

    /// Deselecting a category's last chip snaps it back to all-selected:
    /// an empty set already matched everything, but the chips all rendered
    /// as struck-through, contradicting the full grid below (same rule as
    /// the Browse filters).
    func toggleType(_ kind: WPELibraryTypeKind) {
        if selectedTypes.contains(kind) {
            selectedTypes.remove(kind)
            if selectedTypes.isEmpty {
                selectedTypes = Set(WPELibraryTypeKind.allCases)
            }
        } else {
            selectedTypes.insert(kind)
        }
    }

    func isolateType(_ kind: WPELibraryTypeKind) {
        selectedTypes = [kind]
    }

    func toggleSource(_ source: InstalledSource) {
        if selectedSources.contains(source) {
            selectedSources.remove(source)
            if selectedSources.isEmpty {
                selectedSources = Set(InstalledSource.allCases)
            }
        } else {
            selectedSources.insert(source)
        }
    }

    func isolateSource(_ source: InstalledSource) {
        selectedSources = [source]
    }

    func toggleStorage(_ storage: InstalledStorageKind) {
        if selectedStorage.contains(storage) {
            selectedStorage.remove(storage)
            if selectedStorage.isEmpty {
                selectedStorage = Set(InstalledStorageKind.allCases)
            }
        } else {
            selectedStorage.insert(storage)
        }
    }

    func isolateStorage(_ storage: InstalledStorageKind) {
        selectedStorage = [storage]
    }

    func resetFilters() {
        selectedTypes = Set(WPELibraryTypeKind.allCases)
        selectedSources = Set(InstalledSource.allCases)
        selectedStorage = Set(InstalledStorageKind.allCases)
    }

    func reload() {
        entries = dependencies.loadEntries()
        invalidatePendingDeleteIfStale()
        invalidateDeletesForReimports()
    }

    /// `operation` returns the error that stopped the apply, or nil on
    /// success. It used to return `Bool`: the import tracker already held an
    /// `AppError` naming the file, the package fault or the import failure, and
    /// the call site reduced it to `!= nil`.
    func startApply(
        entry: WPEHistoryEntry,
        operation: @escaping @MainActor () async -> AppError?
    ) {
        errorMessage = nil
        let token = UUID()
        let generation = appearanceGeneration
        let identity = WorkshopInstalledEntryIdentity(entry)
        let task = Task { @MainActor [weak self] in
            let failure = await operation()
            guard let self else { return }
            defer { self.applyTasks.removeValue(forKey: token) }
            guard canPublish(generation: generation, identity: identity) else { return }
            if let failure {
                errorMessage = failure.errorDescription.map {
                    String(
                        localized: "Couldn't apply \(entry.origin.title) — \($0)",
                        bundle: .appLanguage, comment: "Workshop installed apply failure. Placeholders are the wallpaper title and why it failed."
                    )
                } ?? String(
                    localized: "Couldn't apply \(entry.origin.title).",
                    bundle: .appLanguage, comment: "Workshop installed apply failure. Placeholder is the wallpaper title."
                )
            }
            reload()
            refreshSelectedEntry()
        }
        applyTasks[token] = task
    }

    func performDelete(_ entry: WPEHistoryEntry, services: DeleteServices) {
        errorMessage = nil
        let identity = WorkshopInstalledEntryIdentity(entry)
        pendingDelete = nil
        guard services.removeImportIfMatching(identity) else {
            reload()
            refreshSelectedEntry()
            return
        }
        if selectedEntry.map(WorkshopInstalledEntryIdentity.init) == identity {
            selectedEntry = nil
        }

        let workshopID = entry.origin.workshopID
        if services.containsBookmark(workshopID) {
            services.removeBookmarks(workshopID)
        }
        reload()

        guard !workshopID.isEmpty else { return }
        deleteHandles.removeValue(forKey: workshopID)?.task.cancel()
        let expectedToFree = deletesFiles(entry)
        let ticket = DeleteTicket(
            token: UUID(),
            appearanceGeneration: appearanceGeneration,
            identity: identity
        )
        // History/bookmark removal already committed synchronously. Keep
        // cleanup alive when the transient page disappears.
        let task = Task { @MainActor [self] in
            guard canContinueDeleteCleanup(ticket) else {
                finishDelete(ticket)
                return
            }
            // Deleting a wallpaper now removes Steam's own copy: the shared
            // repository is where the files actually live, so leaving them
            // meant "delete" never freed anything.
            let repositoryDeleted = await services.deleteSharedRepositoryItem(workshopID)?.outcome == .deleted
            guard canContinueDeleteCleanup(ticket) else {
                finishDelete(ticket)
                return
            }
            let shouldPublish = canPublishDelete(ticket)
            finishDelete(ticket)
            guard shouldPublish else { return }
            if expectedToFree, !repositoryDeleted {
                errorMessage = String(
                    localized: "Removed \(entry.origin.title) from the library, but its files couldn't be deleted.",
                    bundle: .appLanguage, comment: "Workshop delete: history removed but managed files couldn't be deleted."
                )
            }
        }
        deleteHandles[workshopID] = DeleteHandle(ticket: ticket, task: task)
    }

    /// True when deleting will actually reclaim disk. A Workshop item always
    /// will: its files live in the shared repository and the connector
    /// removes them for real.
    func deletesFiles(_ entry: WPEHistoryEntry) -> Bool {
        let id = entry.origin.workshopID
        guard WPEPathSafety.isSafeProjectID(id) else { return false }
        // A numeric id is a Steam Workshop item, whose files live in the shared repository
        // (the connector reports `.notFound` harmlessly if already gone). Only Workshop items
        // have files of ours to free; folder imports point at the user's own directory, which we never delete.
        return id.allSatisfy(\.isNumber)
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

    func toggleBookmark(_ entry: WPEHistoryEntry, store: BookmarkStore) {
        errorMessage = nil
        let workshopID = entry.origin.workshopID
        if store.containsWPEBookmark(workshopID: workshopID) {
            store.removeWPEBookmarks(workshopID: workshopID)
            return
        }
        guard let content = WPECachedContentResolver().content(for: entry.origin) else {
            errorMessage = String(
                localized: "Couldn't add \(entry.origin.title) to Bookmarks.",
                bundle: .appLanguage, comment: "Workshop installed bookmark failure. Placeholder is the wallpaper title."
            )
            return
        }
        _ = store.add(
            label: entry.origin.title,
            content: content,
            sourceDisplayName: workshopID,
            wpeOrigin: entry.origin
        )
    }

    func canAddBookmark(_ entry: WPEHistoryEntry) -> Bool {
        let origin = entry.origin
        guard let entryFile = origin.entryFile, !entryFile.isEmpty else { return false }
        switch origin.resourceLocation {
        case .cache:
            return origin.originalType == .video || origin.originalType == .web || origin.originalType == .scene
        case .sourceFolder:
            return origin.originalType == .video || origin.originalType == .web
        default:
            return false
        }
    }

    func beginEntryDrag(_ entry: WPEHistoryEntry) -> String {
        isDraggingEntry = true
        lifecycleOwner.installDragEndMonitors { [weak self] in self?.endEntryDrag() }
        return entry.origin.workshopID
    }

    func endEntryDrag() {
        isDraggingEntry = false
        lifecycleOwner.removeDragEndMonitors()
    }

    func makeDropTicket() -> DropTicket {
        DropTicket(appearanceGeneration: appearanceGeneration)
    }

    func consumeDrop(
        _ ticket: DropTicket,
        workshopID: String?,
        loadFailed: Bool
    ) -> WPEHistoryEntry? {
        endEntryDrag()
        guard !loadFailed,
              isActive,
              ticket.appearanceGeneration == appearanceGeneration,
              let workshopID
        else { return nil }
        return entries.first { $0.origin.workshopID == workshopID }
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

    private func refreshSelectedEntry() {
        guard let current = selectedEntry else { return }
        selectedEntry = entries.first { $0.origin.workshopID == current.origin.workshopID }
    }

    private func invalidatePendingDeleteIfStale() {
        guard let pendingDelete else { return }
        let identity = WorkshopInstalledEntryIdentity(pendingDelete)
        guard !entries.contains(where: { WorkshopInstalledEntryIdentity($0) == identity }) else { return }
        self.pendingDelete = nil
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

    private func canPublish(generation: UInt64, identity: WorkshopInstalledEntryIdentity) -> Bool {
        guard isActive, generation == appearanceGeneration, !Task.isCancelled else { return false }
        guard let current = entries.first(where: { $0.origin.workshopID == identity.workshopID }) else {
            return false
        }
        return WorkshopInstalledEntryIdentity(current) == identity
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
        return !dependencies.loadEntries().contains {
            $0.origin.workshopID == ticket.identity.workshopID
        }
    }

    private func finishDelete(_ ticket: DeleteTicket) {
        guard deleteHandles[ticket.identity.workshopID]?.ticket == ticket else { return }
        deleteHandles.removeValue(forKey: ticket.identity.workshopID)
    }

    private func matchesSearch(_ entry: WPEHistoryEntry, query: String) -> Bool {
        guard !query.isEmpty else { return true }
        return entry.origin.title.localizedCaseInsensitiveContains(query)
            || entry.origin.workshopID.localizedCaseInsensitiveContains(query)
            || entry.origin.localizedDisplayTypeName.localizedCaseInsensitiveContains(query)
    }

    private func typeMatches(_ entry: WPEHistoryEntry) -> Bool {
        if selectedTypes.isEmpty || selectedTypes.count == WPELibraryTypeKind.allCases.count {
            return true
        }
        return selectedTypes.contains { $0.matches(entry) }
    }

    private func sourceMatches(_ entry: WPEHistoryEntry) -> Bool {
        if selectedSources.isEmpty || selectedSources.count == InstalledSource.allCases.count {
            return true
        }
        return selectedSources.contains { $0.matches(entry) }
    }

    private func storageMatches(_ entry: WPEHistoryEntry) -> Bool {
        if selectedStorage.isEmpty || selectedStorage.count == InstalledStorageKind.allCases.count {
            return true
        }
        return selectedStorage.contains { $0.matches(entry) }
    }
}
#endif
