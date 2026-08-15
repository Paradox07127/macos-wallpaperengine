#if !LITE_BUILD
import Foundation
import LiveWallpaperCore
@testable import LiveWallpaper
import Testing

@Suite("Workshop Installed ownership characterization", .serialized)
struct InstalledOwnershipCharacterizationTests {
    @Test("installed filters preserve category semantics and the current storage-location heuristic")
    func installedFilterSemantics() {
        let scene = entry(id: "100", type: .scene, location: .cache)
        let video = entry(id: "local-video", type: .video, location: .sourceFolder)
        let packagedVideo = entry(id: "300", type: .video, location: .sourceFolder)
        let app = entry(id: "200", type: .application, location: .sourceFolder)

        #expect(!WorkshopFilterMath.isNarrowing(Set<WPELibraryTypeKind>(), total: 4))
        #expect(!WorkshopFilterMath.isNarrowing(Set(WPELibraryTypeKind.allCases), total: 4))
        #expect(WorkshopFilterMath.isNarrowing(Set([WPELibraryTypeKind.scene]), total: 4))

        #expect(WPELibraryTypeKind.scene.matches(scene))
        #expect(WPELibraryTypeKind.video.matches(video))
        #expect(WPELibraryTypeKind.unsupported.matches(app))
        #expect(InstalledSource.steamWorkshop.matches(scene))
        #expect(InstalledSource.local.matches(video))
        #expect(InstalledStorageKind.managed.matches(scene))
        #expect(InstalledStorageKind.linked.matches(video))
        #expect(InstalledStorageKind.linked.matches(packagedVideo))
    }

    @Test("selection identity survives re-import while content refreshes")
    func selectionIdentitySurvivesReimport() {
        let old = entry(id: "100", title: "Old", importedAt: 10)
        let refreshed = entry(id: "100", title: "Refreshed", importedAt: 20)

        #expect(old.id == refreshed.id)
        #expect(old != refreshed)
        #expect([refreshed].first { $0.origin.workshopID == old.origin.workshopID } == refreshed)
    }

    @Test("Settings CAS removes only the exact import and atomically tombstones success")
    @MainActor
    func settingsIdentityAwareRemoval() async {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("WorkshopInstalledSettingsCAS-\(UUID().uuidString)", isDirectory: true)
        let manager = SettingsManager(directory: ConfigurationDirectory(root: root))
        manager.saveGlobalSettings(GlobalSettings())
        let old = entry(id: "same-id", title: "Old", importedAt: 10)
        let reimported = entry(id: "same-id", title: "New", importedAt: 20)
        manager.recordWPEImport(old)
        manager.recordWPEImport(reimported, clearsDeleteTombstone: true)

        #expect(!manager.removeWPEImport(
            workshopID: "same-id",
            matchingImportedAt: old.importedAt
        ))
        var persisted = manager.loadGlobalSettings()
        #expect(persisted.recentWPEImports == [reimported])
        #expect(!persisted.deletedWorkshopIDs.contains("same-id"))

        #expect(manager.removeWPEImport(
            workshopID: "same-id",
            matchingImportedAt: reimported.importedAt
        ))
        persisted = manager.loadGlobalSettings()
        #expect(persisted.recentWPEImports.isEmpty)
        #expect(persisted.deletedWorkshopIDs.first == "same-id")
        await TestScratch.discard(root, flushing: manager)
    }



    @Test("Steam metadata request and update epoch decode stay stable")
    @MainActor
    func workshopMetadataNetworkFixture() async throws {
        let endpoint = SteamWorkshopMetadataService.endpoint
        let service = metadataService { request in
            #expect(request.url == endpoint)
            #expect(request.httpMethod == "POST")
            #expect(String(data: WorkshopMetadataRequestBody.data(from: request) ?? Data(), encoding: .utf8)
                == "itemcount=1&publishedfileids%5B0%5D=100")
            return .http(
                status: 200,
                headers: [:],
                body: Self.metadataPayload(id: "100", updated: 1_720_000_000)
            )
        }

        let result = await service.fetch(publishedFileID: 100)
        let metadata = try result.get()
        #expect(metadata.publishedFileID == 100)
        #expect(metadata.title == "Fixture")
        #expect(metadata.timeUpdated == Date(timeIntervalSince1970: 1_720_000_000))
            #expect(metadata.appID == 431_960)
        }

        @Test("Steam metadata rejects consumer_app_id values that aren't exactly 431960")
        @MainActor
        func workshopMetadataRejectsForeignOrMalformedAppID() async {
            // Negative — must not reach the trapping `UInt32(_:)` initializer.
            var service = metadataService { _ in
                .http(status: 200, headers: [:], body: Self.metadataPayload(id: "100", updated: 1, consumerAppIDLiteral: "-431960"))
            }
            #expect(await service.fetch(publishedFileID: 100) == .failure(.schemaMismatch))

            // Overflows UInt32.max — must not reach the trapping initializer either.
            service = metadataService { _ in
                .http(status: 200, headers: [:], body: Self.metadataPayload(id: "100", updated: 1, consumerAppIDLiteral: "5000000000"))
            }
            #expect(await service.fetch(publishedFileID: 100) == .failure(.schemaMismatch))

            // A different, validly-encoded Steam app's item.
            service = metadataService { _ in
                .http(status: 200, headers: [:], body: Self.metadataPayload(id: "100", updated: 1, consumerAppIDLiteral: "440"))
            }
            #expect(await service.fetch(publishedFileID: 100) == .failure(.schemaMismatch))

            // Field omitted entirely.
            service = metadataService { _ in
                .http(status: 200, headers: [:], body: Self.metadataPayload(id: "100", updated: 1, consumerAppIDLiteral: nil))
            }
            #expect(await service.fetch(publishedFileID: 100) == .failure(.schemaMismatch))
    }

    @Test("Steam metadata maps cancellation, rate limit and transient network failure")
    @MainActor
    func workshopMetadataFailureFixtures() async {
        var service = metadataService { _ in .error(URLError(.cancelled)) }
        #expect(await service.fetch(publishedFileID: 100) == .failure(.cancelled))

        service = metadataService { _ in
            .http(status: 429, headers: ["Retry-After": "37"], body: Data())
        }
        #expect(await service.fetch(publishedFileID: 100) == .failure(.rateLimited(retryAfter: 37)))

        service = metadataService { _ in .error(URLError(.networkConnectionLost)) }
        #expect(await service.fetch(publishedFileID: 100) == .failure(.networkUnreachable))
    }

    @Test("Installed page routes state and commands through one library model")
    func lifecycleOwnerProductionWiring() throws {
        let view = try installedViewSource()
        let model = try installedModelSource()
        #expect(view.contains("@State private var model = InstalledLibraryModel()"))
        #expect(view.contains(".onAppear { model.onAppear() }"))
        #expect(view.contains(".onDisappear { model.onDisappear() }"))
        #expect(view.contains("model.historyDidChange()"))
        #expect(!view.contains("@State private var entries"))
        #expect(!view.contains("private func checkForUpdatesIfNeeded"))
        #expect(!view.contains("private func installDragEndMonitors"))

        #expect(model.contains("@Observable"))
        #expect(model.contains("final class InstalledLibraryModel"))
        #expect(model.contains("let lifecycleOwner: InstalledPageLifecycleOwner"))
        #expect(model.contains("lifecycleOwner.installDragEndMonitors"))
        #expect(model.contains("lifecycleOwner.replaceUpdate"))
        #expect(model.components(separatedBy: "lifecycleOwner.canContinue(ticket)").count - 1 == 2)
        #expect(model.contains("lifecycleOwner.commitUpdate(replacement)"))
    }

    @Test("drag monitor replacement, teardown and deinit leave no dynamic monitor")
    @MainActor
    func dragMonitorLifecycleIsBounded() {
        let probe = WorkshopDragMonitorProbe()
        let hooks = InstalledPageLifecycleOwner.DragMonitorHooks(
            installLocal: { _ in probe.install() },
            installGlobal: { _ in probe.install() },
            remove: { probe.remove($0) }
        )
        var owner: InstalledPageLifecycleOwner? = InstalledPageLifecycleOwner(
            monitorHooks: hooks
        )

        owner?.installDragEndMonitors {}
        #expect(owner?.activeDragMonitorCount == 2)
        #expect(probe.activeCount == 2)

        owner?.installDragEndMonitors {}
        #expect(owner?.activeDragMonitorCount == 2)
        #expect(probe.activeCount == 2)
        #expect(probe.removeCount == 2)

        owner?.tearDown()
        #expect(owner?.activeDragMonitorCount == 0)
        #expect(probe.activeCount == 0)

        owner?.installDragEndMonitors {}
        #expect(probe.activeCount == 2)
        owner = nil
        #expect(probe.activeCount == 0)
        #expect(probe.removeCount == 6)
    }

    @Test("replacement and cancellation reject late generation publication")
    @MainActor
    func updateLifecycleIsNewestWins() async {
        let owner = InstalledPageLifecycleOwner(monitorHooks: .noOp)
        let gate = WorkshopInstalledUpdateGate()
        var publications: [String] = []

        let old = Task { @MainActor in
            await owner.replaceUpdate(operation: { _ in
                await gate.suspend("old")
            })
        }
        await gate.waitUntilSuspended("old")

        let newest = Task { @MainActor in
            await owner.replaceUpdate(operation: { _ in
                await gate.suspend("new")
            })
        }
        await gate.waitUntilSuspended("new")
        await gate.resume("new", value: "new")
        let newestResult = await newest.value
        #expect(newestResult != nil)
        if let newestResult {
            #expect(owner.commitUpdate(newestResult) { publications.append($0) })
        }
        await gate.resume("old", value: "old")
        let oldResult = await old.value
        #expect(oldResult == nil)

        #expect(publications == ["new"])
        #expect(!owner.hasActiveUpdate)

        let readyOld = Task { @MainActor in
            await owner.replaceUpdate(operation: { _ in
                await gate.suspend("ready-old")
            })
        }
        await gate.waitUntilSuspended("ready-old")
        await gate.resume("ready-old", value: "ready-old")
        let readyOldResult = await readyOld.value
        #expect(readyOldResult != nil)
        #expect(owner.hasActiveUpdate)

        let successor = Task { @MainActor in
            await owner.replaceUpdate(operation: { _ in
                await gate.suspend("successor")
            })
        }
        await gate.waitUntilSuspended("successor")
        if let readyOldResult {
            #expect(!owner.commitUpdate(readyOldResult) { publications.append($0) })
        }
        #expect(publications == ["new"])
        await gate.resume("successor", value: "successor")
        let successorResult = await successor.value
        if let successorResult {
            #expect(owner.commitUpdate(successorResult) { publications.append($0) })
        }
        #expect(publications == ["new", "successor"])

        let cancelled = Task { @MainActor in
            await owner.replaceUpdate(operation: { _ in
                await gate.suspend("cancelled")
            })
        }
        await gate.waitUntilSuspended("cancelled")
        owner.cancelUpdate()
        #expect(!owner.hasActiveUpdate)
        await gate.resume("cancelled", value: "late")
        let cancelledValue = await cancelled.value
        #expect(cancelledValue == nil)
        #expect(publications == ["new", "successor"])
    }

    @Test("Inspector load and download attempts guard every async publication boundary")
    @MainActor
    func loadAndDownloadPublicationGuards() async throws {
        let oldEntry = entry(id: "same-id", importedAt: 10)
        let reimportedEntry = entry(id: "same-id", importedAt: 20)
        let oldIdentity = WorkshopInstalledLocalInfoLoadIdentity(
            entryID: oldEntry.id,
            importedAt: oldEntry.importedAt
        )
        let reimportedIdentity = WorkshopInstalledLocalInfoLoadIdentity(
            entryID: reimportedEntry.id,
            importedAt: reimportedEntry.importedAt
        )
        #expect(oldIdentity.entryID == reimportedIdentity.entryID)
        #expect(oldIdentity != reimportedIdentity)

        let loadOwner = WorkshopInstalledLocalInfoLoadOwner()
        let gate = WorkshopInstalledUpdateGate()
        let oldTicket = loadOwner.begin(identity: oldIdentity)
        let lateOldLoad = Task { @MainActor in
            _ = await gate.suspend("old-local-info")
            return loadOwner.canPublish(oldTicket)
        }
        await gate.waitUntilSuspended("old-local-info")
        let reimportedTicket = loadOwner.begin(identity: reimportedIdentity)
        await gate.resume("old-local-info", value: "loaded")
        let oldLoadCanPublish = await lateOldLoad.value
        #expect(!oldLoadCanPublish)
        #expect(loadOwner.canPublish(reimportedTicket))
        loadOwner.invalidate()
        #expect(!loadOwner.canPublish(reimportedTicket))

        let inspector = try projectSource("LiveWallpaper/Views/Workshop/InstalledInspector.swift")
        #expect(inspector.contains(".task(id: localInfoLoadIdentity)"))
        #expect(inspector.contains("localInfoLoadOwner.begin(identity: localInfoLoadIdentity)"))
        #expect(inspector.contains("let loadedInfo = await loadWPELocalProjectInfo(for: entry)"))
        #expect(inspector.contains("guard localInfoLoadOwner.canPublish(ticket) else { return }"))
        #expect(inspector.contains(".onDisappear { localInfoLoadOwner.invalidate() }"))

        let download = try projectSource("LiveWallpaper/Infrastructure/Workshop/WorkshopDownloadCoordinator.swift")
        let importBoundary = try sourceSlice(
            download,
            from: "let result = try? await self.importService.importProject(folder: folderURL)",
            to: "\n                    }\n                )"
        )
        #expect(importBoundary.contains("guard !Task.isCancelled, self.attempts[itemID] == attemptID"))

        // Scoped to the region after the download await: asserting on the whole
        // file would pass with the guard sitting anywhere, which is the one thing
        // this is meant to pin down.
        let doctorBoundary = try sourceSlice(
            download,
            from: "return await doctor.downloadWorkshopItem(",
            to: "tasks[itemID] = nil"
        )
        #expect(doctorBoundary.contains("guard !Task.isCancelled, attempts[itemID] == attemptID else { return }"))
    }


    @Test("update policy keeps the daily throttle, partial results and retry semantics")
    func updateLifecyclePolicySourceContract() throws {
        let source = try installedModelSource()
        #expect(source.contains("private static let updateInterval: TimeInterval = 86400"))
        let update = try sourceSlice(
            source,
            from: "func checkForUpdatesIfNeeded() async",
            to: "private func scheduleUpdateCheck()"
        )
        #expect(update.contains("let snapshot = entries"))
        #expect(update.contains("let initialEpochs = cachedRemoteUpdateEpochs.filter"))
        #expect(update.contains("if case .rateLimited = error"))
        #expect(update.contains("break fetchLoop"))
        #expect(update.contains("continue"))
        #expect(update.contains("cachedRemoteUpdateEpochs = remoteEpochs"))
        let commit = try sourceSlice(
            update,
            from: "lifecycleOwner.commitUpdate(replacement)",
            to: "\n            }\n        }"
        )
        #expect(commit.contains("cachedRemoteUpdateEpochs = remoteEpochs"))
        #expect(commit.contains("dependencies.saveRemoteUpdateEpochs(remoteEpochs)"))
        #expect(update.contains("reconcileUpdateFlags()"))
        #expect(update.contains("dependencies.saveLastUpdateCheckEpoch(now)"))
    }

    @Test("production model skips fresh checks then saves stale metadata and clears re-import badge")
    @MainActor
    func productionUpdateModelThrottleCacheFlagsAndReimport() async {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let requests = WorkshopMetadataResponseGate { id in
            return .http(
                status: 200,
                headers: [:],
                body: Self.metadataPayload(id: id, updated: 900_000)
            )
        }
        defer { requests.releaseAll() }
        let service = metadataService { requests.response(for: $0) }
        let old = entry(id: "100", importedAt: 100)
        let store = WorkshopInstalledLibraryStoreProbe(
            entries: [old],
            remoteEpochs: ["100": 200, "orphan": 300],
            now: now,
            lastUpdateCheckEpoch: now.timeIntervalSince1970 - 3600,
            makeMetadataService: { service }
        )
        let model = InstalledLibraryModel(
            dependencies: store.dependencies,
            lifecycleOwner: InstalledPageLifecycleOwner(monitorHooks: .noOp)
        )

        model.onAppear()
        await Task.yield()
        await model.checkForUpdatesIfNeeded()
        #expect(requests.ids.isEmpty)
        #expect(store.remoteSaveCount == 0)
        #expect(store.lastCheckSaveCount == 0)

        store.lastUpdateCheckEpoch = now.timeIntervalSince1970 - 86401
        let update = Task { @MainActor in await model.checkForUpdatesIfNeeded() }
        await requests.waitUntilStarted(count: 1)
        #expect(model.lifecycleOwner.hasActiveUpdate)
        requests.releaseNext()
        await update.value
        #expect(requests.ids == ["100"])
        #expect(store.remoteEpochs == ["100": 900_000])
        #expect(store.remoteSaveCount == 1)
        #expect(store.lastUpdateCheckEpoch == now.timeIntervalSince1970)
        #expect(store.lastCheckSaveCount == 1)
        #expect(model.updatedWorkshopIDs == ["100"])

        store.entries = [entry(id: "100", title: "Re-imported", importedAt: 950_000)]
        model.historyDidChange()
        #expect(model.updatedWorkshopIDs.isEmpty)
        model.onDisappear()
    }

    @Test("production model preserves unvisited cache entries after 429")
    @MainActor
    func productionUpdateModelRateLimitPartialPreserve() async {
        let now = Date(timeIntervalSince1970: 2_000_000)
        let requests = WorkshopMetadataResponseGate { id in
            switch id {
            case "100":
                .http(
                    status: 200,
                    headers: [:],
                    body: Self.metadataPayload(id: "100", updated: 444)
                )
            case "200":
                .http(status: 429, headers: ["Retry-After": "60"], body: Data())
            default:
                .http(status: 500, headers: [:], body: Data())
            }
        }
        defer { requests.releaseAll() }
        let service = metadataService { requests.response(for: $0) }
        let store = WorkshopInstalledLibraryStoreProbe(
            entries: [
                entry(id: "100", importedAt: 10),
                entry(id: "200", importedAt: 10),
                entry(id: "300", importedAt: 10),
            ],
            remoteEpochs: ["100": 111, "200": 222, "300": 333],
            now: now,
            lastUpdateCheckEpoch: now.timeIntervalSince1970,
            makeMetadataService: { service }
        )
        let model = InstalledLibraryModel(
            dependencies: store.dependencies,
            lifecycleOwner: InstalledPageLifecycleOwner(monitorHooks: .noOp)
        )

        model.onAppear()
        await Task.yield()
        store.lastUpdateCheckEpoch = now.timeIntervalSince1970 - 86401
        let update = Task { @MainActor in await model.checkForUpdatesIfNeeded() }
        await requests.waitUntilStarted(count: 1)
        #expect(model.lifecycleOwner.hasActiveUpdate)
        requests.releaseNext()
        await requests.waitUntilStarted(count: 2)
        #expect(model.lifecycleOwner.hasActiveUpdate)
        requests.releaseNext()
        await update.value
        #expect(requests.ids == ["100", "200"])
        #expect(store.remoteEpochs == ["100": 444, "200": 222, "300": 333])
        #expect(store.remoteSaveCount == 1)
        #expect(store.lastCheckSaveCount == 1)
        #expect(model.updatedWorkshopIDs == ["100", "200", "300"])
        model.onDisappear()
    }

    @Test("library model owns filtering and refreshes same-ID selection to the new import")
    @MainActor
    func libraryModelFilterAndSelectionIdentity() {
        let old = entry(id: "100", title: "Beta", type: .scene, importedAt: 10)
        let other = entry(id: "200", title: "Alpha", type: .video, importedAt: 20)
        let store = WorkshopInstalledLibraryStoreProbe(
            entries: [old, other],
            remoteEpochs: ["100": 30]
        )
        let model = InstalledLibraryModel(
            dependencies: store.dependencies,
            lifecycleOwner: InstalledPageLifecycleOwner(monitorHooks: .noOp)
        )

        model.onAppear()
        model.sortOrder = .updateAvailable
        #expect(model.visibleEntries.map(\.id) == ["100", "200"])
        model.searchText = "alpha"
        #expect(model.visibleEntries.map(\.id) == ["200"])
        model.searchText = ""
        model.isolateType(.scene)
        #expect(model.visibleEntries.map(\.id) == ["100"])
        model.resetFilters()

        model.select(old)
        let reimported = entry(id: "100", title: "Beta refreshed", type: .scene, importedAt: 40)
        store.entries = [reimported, other]
        model.historyDidChange()
        #expect(model.selectedEntry == reimported)
        #expect(model.selectedEntry != old)
        model.onDisappear()
    }

    @Test("re-import and disappear reject cancellation-insensitive apply publication")
    @MainActor
    func applyPublicationUsesEntryAndAppearanceTickets() async {
        let old = entry(id: "same-id", title: "Old", importedAt: 10)
        let store = WorkshopInstalledLibraryStoreProbe(entries: [old])
        let model = InstalledLibraryModel(
            dependencies: store.dependencies,
            lifecycleOwner: InstalledPageLifecycleOwner(monitorHooks: .noOp)
        )
        let gate = WorkshopInstalledUpdateGate()
        model.onAppear()
        model.select(old)

        model.startApply(entry: old) {
            _ = await gate.suspend("reimport-apply")
            return true
        }
        await gate.waitUntilSuspended("reimport-apply")
        let reimported = entry(id: "same-id", title: "New", importedAt: 20)
        store.entries = [reimported]
        model.historyDidChange()
        await gate.resume("reimport-apply", value: "failed")
        await waitForCommandDrain(model)
        #expect(model.errorMessage == nil)
        #expect(model.selectedEntry == reimported)

        model.startApply(entry: reimported) {
            _ = await gate.suspend("disappear-apply")
            return true
        }
        await gate.waitUntilSuspended("disappear-apply")
        let dropTicket = model.makeDropTicket()
        model.onDisappear()
        await gate.resume("disappear-apply", value: "failed")
        await Task.yield()
        #expect(model.errorMessage == nil)
        #expect(model.activeApplyCommandCount == 0)
        #expect(model.consumeDrop(dropTicket, workshopID: reimported.id, loadFailed: false) == nil)
    }



    @MainActor
    private func waitForCommandDrain(_ model: InstalledLibraryModel) async {
        for _ in 0..<100 where model.activeApplyCommandCount != 0 {
            await Task.yield()
        }
        #expect(model.activeApplyCommandCount == 0)
    }

    private func installedModelSource() throws -> String {
        try projectSource("LiveWallpaper/Views/Workshop/InstalledLibrary.swift")
    }

    @Test("The auto-ingest scan never deletes library records")
    func autoIngestNeverDeletesRecords() throws {
        // Enumerating the bound Steam library proves an id is absent from *that*
        // library — not that its content is gone. A folder-imported project on an
        // unplugged drive looks identical, and pruning on that signal deleted it
        // for good. WPEOrigin carries no "came from Steam" discriminator, so this
        // scan has no sound basis for deleting anything.
        let source = try projectSource(
            "LiveWallpaper/Infrastructure/Workshop/WorkshopFolderImportCoordinator.swift"
        )
        let body = try sourceSlice(source, from: "func ingestExistingDownloads", to: "\n    nonisolated static func")
        // Name-independent: the bulk API that shipped is gone, so pin the shape.
        #expect(!body.contains("removeWPEImports"))
        #expect(!body.contains("SettingsManager.shared.remove"))
    }

    @Test("Re-recording an existing item keeps its library history")
    @MainActor
    func rerecordPreservesImportHistory() async {
        // The relink path rebuilds the entry with `importedAt: Date()`. The
        // update badge fires on `remoteEpoch > importedAt`, so stamping "now"
        // silently clears a real pending update for every relinked item.
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("WorkshopRerecord-\(UUID().uuidString)", isDirectory: true)
        let manager = SettingsManager(directory: ConfigurationDirectory(root: root))
        manager.saveGlobalSettings(GlobalSettings())

        let firstSeen = Date(timeIntervalSince1970: 1_000_000)
        let used = Date(timeIntervalSince1970: 1_500_000)
        var original = entry(id: "relinked")
        original = WPEHistoryEntry(origin: original.origin, importedAt: firstSeen, lastUsedAt: used)
        manager.recordWPEImport(original)

        manager.recordWPEImport(entry(id: "relinked"), preservesHistory: true)

        let stored = manager.loadGlobalSettings().recentWPEImports.first { $0.origin.workshopID == "relinked" }
        #expect(stored?.importedAt == firstSeen)
        #expect(stored?.lastUsedAt == used)
        await TestScratch.discard(root, flushing: manager)
    }

    @Test("Library-sync summary names every kind of change it made")
    func librarySyncSummaryCoversEachOutcome() {
        let both = WorkshopFolderImportCoordinator.syncSummary(added: 2, repaired: 3)
        #expect(both.contains("2"))
        #expect(both.contains("3"))

        let repairOnly = WorkshopFolderImportCoordinator.syncSummary(added: 0, repaired: 4)
        #expect(repairOnly.contains("4"))
        #expect(!repairOnly.contains("0"))
    }

    private func entry(
        id: String,
        title: String = "Fixture",
        type: WPEType = .scene,
        location: WPEResourceLocation = .cache,
        importedAt: TimeInterval = 10
    ) -> WPEHistoryEntry {
        WPEHistoryEntry(
            origin: WPEOrigin(
                workshopID: id,
                title: title,
                originalType: type,
                sourceFolderBookmark: Data("bookmark-\(id)".utf8),
                cacheRelativePath: location == .cache ? "wpe-cache/\(id)" : nil,
                previewFileName: "preview.jpg",
                entryFile: "entry",
                resourceLocation: location
            ),
            importedAt: Date(timeIntervalSince1970: importedAt)
        )
    }

    private func installedViewSource() throws -> String {
        try projectSource("LiveWallpaper/Views/Workshop/InstalledView.swift")
    }

    private func projectSource(_ relativePath: String) throws -> String {
        try RepositoryRoot.source(relativePath)
    }

    private func sourceSlice(_ source: String, from start: String, to end: String) throws -> String {
        let startRange = try #require(source.range(of: start))
        let endRange = try #require(source.range(of: end, range: startRange.upperBound..<source.endIndex))
        return String(source[startRange.lowerBound..<endRange.lowerBound])
    }

    @MainActor
    private func metadataService(
        _ plan: @escaping @Sendable (URLRequest) -> WorkshopMetadataURLProtocolStub.Plan
    ) -> SteamWorkshopMetadataService {
        WorkshopMetadataURLProtocolStub.plan = plan
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [WorkshopMetadataURLProtocolStub.self]
        return SteamWorkshopMetadataService(session: URLSession(configuration: configuration))
    }

        private static func metadataPayload(id: String, updated: Int, consumerAppIDLiteral: String? = "431960") -> Data {
            let appIDField = consumerAppIDLiteral.map { "\"consumer_app_id\":\($0)," } ?? ""
            return Data("""
        {"response":{"result":1,"resultcount":1,"publishedfiledetails":[{
              "publishedfileid":"\(id)","result":1,\(appIDField)
          "title":" Fixture ","short_description":"summary","time_updated":\(updated),
          "visibility":0,"banned":0
        }]}}
        """.utf8)
    }
}

@MainActor
private final class WorkshopInstalledLibraryStoreProbe {
    var entries: [WPEHistoryEntry]
    var remoteEpochs: [String: Double]
    var lastUpdateCheckEpoch: Double
    var now: Date
    var makeMetadataService: @MainActor () -> SteamWorkshopMetadataService
    private(set) var remoteSaveCount = 0
    private(set) var lastCheckSaveCount = 0

    init(
        entries: [WPEHistoryEntry],
        remoteEpochs: [String: Double] = [:],
        now: Date = Date(timeIntervalSince1970: 1000),
        lastUpdateCheckEpoch: Double? = nil,
        makeMetadataService: @escaping @MainActor () -> SteamWorkshopMetadataService = {
            SteamWorkshopMetadataService()
        }
    ) {
        self.entries = entries
        self.remoteEpochs = remoteEpochs
        self.now = now
        self.lastUpdateCheckEpoch = lastUpdateCheckEpoch ?? now.timeIntervalSince1970
        self.makeMetadataService = makeMetadataService
    }

    var dependencies: InstalledLibraryModel.Dependencies {
        InstalledLibraryModel.Dependencies(
            loadEntries: { [weak self] in self?.entries ?? [] },
            loadRemoteUpdateEpochs: { [weak self] in self?.remoteEpochs ?? [:] },
            saveRemoteUpdateEpochs: { [weak self] in
                self?.remoteEpochs = $0
                self?.remoteSaveCount += 1
            },
            loadLastUpdateCheckEpoch: { [weak self] in self?.lastUpdateCheckEpoch ?? 0 },
            saveLastUpdateCheckEpoch: { [weak self] in
                self?.lastUpdateCheckEpoch = $0
                self?.lastCheckSaveCount += 1
            },
            makeMetadataService: { [weak self] in
                self?.makeMetadataService() ?? SteamWorkshopMetadataService()
            },
            now: { [weak self] in self?.now ?? .distantPast }
        )
    }
}

private final class WorkshopMetadataURLProtocolStub: URLProtocol, @unchecked Sendable {
    enum Plan: @unchecked Sendable {
        case http(status: Int, headers: [String: String], body: Data)
        case error(Error)
    }

    nonisolated(unsafe) static var plan: (@Sendable (URLRequest) -> Plan)?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let plan = Self.plan else {
            client?.urlProtocol(self, didFailWithError: URLError(.unknown))
            return
        }
        switch plan(request) {
        case .http(let status, let headers, let body):
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: status,
                httpVersion: "HTTP/1.1",
                headerFields: headers
            )!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: body)
            client?.urlProtocolDidFinishLoading(self)
        case .error(let error):
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

private enum WorkshopMetadataRequestBody {
    static func data(from request: URLRequest) -> Data? {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return nil }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 512)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            guard count > 0 else { break }
            data.append(buffer, count: count)
        }
        return data
    }

    static func publishedFileID(from request: URLRequest) -> String? {
        guard let data = data(from: request),
              let body = String(data: data, encoding: .utf8)
        else { return nil }
        return body.components(separatedBy: "publishedfileids%5B0%5D=").last
    }
}

private final class WorkshopMetadataResponseGate: @unchecked Sendable {
    typealias Plan = WorkshopMetadataURLProtocolStub.Plan

    private let condition = NSCondition()
    private let makeResponse: @Sendable (String) -> Plan
    private var startedIDs: [String] = []
    private var releasedCount = 0

    init(makeResponse: @escaping @Sendable (String) -> Plan) {
        self.makeResponse = makeResponse
    }

    var ids: [String] {
        condition.lock()
        defer { condition.unlock() }
        return startedIDs
    }

    func response(for request: URLRequest) -> Plan {
        guard let id = WorkshopMetadataRequestBody.publishedFileID(from: request) else {
            return .error(URLError(.badURL))
        }
        condition.lock()
        startedIDs.append(id)
        let ordinal = startedIDs.count
        condition.broadcast()
        while releasedCount < ordinal {
            condition.wait()
        }
        condition.unlock()
        return makeResponse(id)
    }

    @MainActor
    func waitUntilStarted(count: Int) async {
        for _ in 0..<10_000 {
            if ids.count >= count { return }
            await Task.yield()
        }
        Issue.record("Metadata request never entered the production URLSession seam")
    }

    func releaseNext() {
        condition.lock()
        releasedCount += 1
        condition.broadcast()
        condition.unlock()
    }

    func releaseAll() {
        condition.lock()
        releasedCount = .max
        condition.broadcast()
        condition.unlock()
    }
}

@MainActor
private final class WorkshopDragMonitorProbe {
    private final class Token {}

    private var activeTokens: Set<ObjectIdentifier> = []
    private(set) var removeCount = 0

    var activeCount: Int { activeTokens.count }

    func install() -> Any {
        let token = Token()
        activeTokens.insert(ObjectIdentifier(token))
        return token
    }

    func remove(_ token: Any) {
        guard let token = token as? Token else {
            Issue.record("Unexpected drag monitor token")
            return
        }
        if activeTokens.remove(ObjectIdentifier(token)) != nil {
            removeCount += 1
        }
    }
}

private extension InstalledPageLifecycleOwner.DragMonitorHooks {
    static var noOp: Self {
        Self(installLocal: { _ in nil }, installGlobal: { _ in nil }, remove: { _ in })
    }
}

private actor WorkshopInstalledUpdateGate {
    private var resultContinuations: [String: CheckedContinuation<String, Never>] = [:]
    private var suspendedKeys: Set<String> = []
    private var suspensionWaiters: [String: [CheckedContinuation<Void, Never>]] = [:]

    func suspend(_ key: String) async -> String {
        await withCheckedContinuation { continuation in
            resultContinuations[key] = continuation
            suspendedKeys.insert(key)
            suspensionWaiters.removeValue(forKey: key)?.forEach { $0.resume() }
        }
    }

    func waitUntilSuspended(_ key: String) async {
        guard !suspendedKeys.contains(key) else { return }
        await withCheckedContinuation { continuation in
            suspensionWaiters[key, default: []].append(continuation)
        }
    }

    func resume(_ key: String, value: String) {
        suspendedKeys.remove(key)
        guard let continuation = resultContinuations.removeValue(forKey: key) else {
            Issue.record("No suspended update operation for \(key)")
            return
        }
        continuation.resume(returning: value)
    }
}
#endif
