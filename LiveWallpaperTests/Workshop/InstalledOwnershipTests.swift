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
    func settingsIdentityAwareRemoval() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("WorkshopInstalledSettingsCAS-\(UUID().uuidString)", isDirectory: true)
        let manager = SettingsManager(directory: ConfigurationDirectory(root: root))
        manager.saveGlobalSettings(GlobalSettings())
        let steamFolder = SteamLibraryPaths.workshopContentRoot(steamRoot: root.appendingPathComponent("steam"))
            .appendingPathComponent("420000077", isDirectory: true)
        let localFolder = root.appendingPathComponent("local/420000078", isDirectory: true)
        try FileManager.default.createDirectory(at: steamFolder, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: localFolder, withIntermediateDirectories: true)
        let steamBookmark = try steamFolder.bookmarkData(options: .minimalBookmark, includingResourceValuesForKeys: nil, relativeTo: nil)
        let old = entry(id: "420000077", title: "Old", importedAt: 10, sourceFolderBookmark: steamBookmark)
        let reimported = entry(id: "420000077", title: "New", importedAt: 20, sourceFolderBookmark: steamBookmark)
        manager.recordWPEImport(old)
        manager.recordWPEImport(reimported, clearsDeleteTombstone: true)

        #expect(!manager.removeWPEImport(
            workshopID: "420000077",
            matchingImportedAt: old.importedAt
        ))
        var persisted = manager.loadGlobalSettings()
        #expect(persisted.recentWPEImports == [reimported])
        #expect(!persisted.deletedWorkshopIDs.contains("420000077"))

        #expect(manager.removeWPEImport(
            workshopID: "420000077",
            matchingImportedAt: reimported.importedAt
        ))
        persisted = manager.loadGlobalSettings()
        #expect(persisted.recentWPEImports.isEmpty)
        #expect(persisted.deletedWorkshopIDs.first == "420000077")

        let localBookmark = try localFolder.bookmarkData(options: .minimalBookmark, includingResourceValuesForKeys: nil, relativeTo: nil)
        let local = entry(id: "420000078", title: "Local copy", importedAt: 30, sourceFolderBookmark: localBookmark)
        manager.recordWPEImport(local)
        #expect(manager.removeWPEImport(
            workshopID: "420000078",
            matchingImportedAt: local.importedAt
        ))
        persisted = manager.loadGlobalSettings()
        #expect(persisted.recentWPEImports.isEmpty)
        #expect(!persisted.deletedWorkshopIDs.contains("420000078"))
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

            service = metadataService { _ in
                .http(status: 200, headers: [:], body: Self.metadataPayload(id: "100", updated: 1, consumerAppIDLiteral: "5000000000"))
            }
            #expect(await service.fetch(publishedFileID: 100) == .failure(.schemaMismatch))

            service = metadataService { _ in
                .http(status: 200, headers: [:], body: Self.metadataPayload(id: "100", updated: 1, consumerAppIDLiteral: "440"))
            }
            #expect(await service.fetch(publishedFileID: 100) == .failure(.schemaMismatch))

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

    @Test("replacement and cancellation reject late generation publication")
    @MainActor
    func updateLifecycleIsNewestWins() async {
        let owner = InstalledPageLifecycleOwner()
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

    @Test("production model skips fresh checks then saves stale metadata and clears re-import badge")
    @MainActor
    func productionUpdateModelThrottleCacheFlagsAndReimport() async {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let requests = WorkshopMetadataResponseGate { ids in
            .http(status: 200, headers: [:], body: Self.metadataBatchPayload(ids.map { ($0, 900_000) }))
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
            lifecycleOwner: InstalledPageLifecycleOwner()
        )

        model.onAppear()
        await Task.yield()
        await model.checkForUpdatesIfNeeded()
        #expect(requests.batches.isEmpty)
        #expect(store.remoteSaveCount == 0)
        #expect(store.lastCheckSaveCount == 0)

        store.lastUpdateCheckEpoch = now.timeIntervalSince1970 - 86401
        let update = Task { @MainActor in await model.checkForUpdatesIfNeeded() }
        await requests.waitUntilStarted(count: 1)
        #expect(model.lifecycleOwner.hasActiveUpdate)
        requests.releaseNext()
        await update.value
        #expect(requests.batches == [["100"]])
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

    @Test("production model checks 120 items in three batched requests with per-item results unchanged")
    @MainActor
    func productionUpdateModelBatchesFiftyPerRequest() async {
        let now = Date(timeIntervalSince1970: 3_000_000)
        let numbers = Array(2000 ..< 2120)
        let ids = numbers.map(String.init)
        let failingBatch = Set(ids[50 ..< 100])
        // Multiples of 7 are absent from Steam's reply; multiples of 5 carry no time_updated.
        let absent = Set(numbers.filter { $0.isMultiple(of: 7) }.map(String.init))
        let updatedByID = Dictionary(uniqueKeysWithValues: numbers.filter { !$0.isMultiple(of: 5) }.map { (String($0), $0 * 10) })
        let requests = WorkshopMetadataResponseGate { requested in
            if requested.contains(where: failingBatch.contains) {
                return .http(status: 500, headers: [:], body: Data())
            }
            let items = requested.filter { !absent.contains($0) }.map { (id: $0, updated: updatedByID[$0]) }
            return .http(status: 200, headers: [:], body: Self.metadataBatchPayload(items))
        }
        requests.releaseAll()
        let service = metadataService { requests.response(for: $0) }
        let store = WorkshopInstalledLibraryStoreProbe(
            entries: ids.map { entry(id: $0, importedAt: 10) },
            remoteEpochs: Dictionary(uniqueKeysWithValues: ids.map { ($0, 1) }),
            now: now,
            lastUpdateCheckEpoch: now.timeIntervalSince1970 - 86401,
            makeMetadataService: { service }
        )
        let model = InstalledLibraryModel(
            dependencies: store.dependencies,
            lifecycleOwner: InstalledPageLifecycleOwner()
        )

        model.onAppear()
        await Task.yield()
        await model.checkForUpdatesIfNeeded()

        var expected: [String: Double] = [:]
        for id in ids {
            if failingBatch.contains(id) || absent.contains(id) {
                expected[id] = 1
            } else if let updated = updatedByID[id] {
                expected[id] = Double(updated)
            }
        }
        #expect(requests.batches.map(\.count) == [50, 50, 20])
        #expect(Array(requests.batches.joined()) == ids)
        #expect(store.remoteEpochs == expected)
        #expect(store.remoteSaveCount == 1)
        #expect(store.lastCheckSaveCount == 1)
        model.onDisappear()
    }

    @Test("production model preserves unvisited cache entries after 429")
    @MainActor
    func productionUpdateModelRateLimitPartialPreserve() async {
        let now = Date(timeIntervalSince1970: 2_000_000)
        let ids = (1000 ... 1100).map(String.init)
        let rateLimitedBatch = Set(ids[50 ..< 100])
        let requests = WorkshopMetadataResponseGate { requested in
            if requested.contains(where: rateLimitedBatch.contains) {
                return .http(status: 429, headers: ["Retry-After": "60"], body: Data())
            }
            if requested.contains("1100") {
                return .http(status: 500, headers: [:], body: Data())
            }
            return .http(status: 200, headers: [:], body: Self.metadataBatchPayload(requested.map { ($0, 444) }))
        }
        defer { requests.releaseAll() }
        let service = metadataService { requests.response(for: $0) }
        let store = WorkshopInstalledLibraryStoreProbe(
            entries: ids.map { entry(id: $0, importedAt: 10) },
            remoteEpochs: Dictionary(uniqueKeysWithValues: ids.map { ($0, 222) }),
            now: now,
            lastUpdateCheckEpoch: now.timeIntervalSince1970,
            makeMetadataService: { service }
        )
        let model = InstalledLibraryModel(
            dependencies: store.dependencies,
            lifecycleOwner: InstalledPageLifecycleOwner()
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
        requests.releaseAll()
        await update.value
        #expect(requests.batches.map(\.count) == [50, 50])
        var expected = Dictionary(uniqueKeysWithValues: ids.map { ($0, 222.0) })
        for id in ids[..<50] {
            expected[id] = 444
        }
        #expect(store.remoteEpochs == expected)
        #expect(store.remoteSaveCount == 1)
        #expect(store.lastCheckSaveCount == 1)
        #expect(model.updatedWorkshopIDs == Set(ids))
        model.onDisappear()
    }

    @Test("a refused mutation gate leaves the library record and bookmark intact")
    @MainActor
    func deleteRefusedByMutationGateKeepsLocalRecords() async throws {
        let (root, target) = try deletionFixture(id: "100")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = WorkshopInstalledLibraryStoreProbe(entries: [target])
        let probe = WorkshopInstalledDeleteProbe(store: store, bookmarks: ["100"])
        probe.repositoryThrows = true
        let model = InstalledLibraryModel(
            dependencies: store.dependencies,
            lifecycleOwner: InstalledPageLifecycleOwner()
        )
        model.onAppear()

        model.performDelete(target, services: probe.services)
        await Self.waitUntil { model.errorMessage != nil }

        #expect(probe.log == ["repository:100"])
        #expect(store.entries == [target])
        #expect(probe.bookmarks == ["100"])
        // Not the post-removal "files couldn't be deleted" message, which names
        // the title: nothing was removed, so nothing was orphaned.
        #expect(model.errorMessage?.contains("Fixture") != true)
        model.onDisappear()
    }

    @Test("the repository delete runs before the history and bookmark removal")
    @MainActor
    func deleteRemovesRepositoryItemBeforeLocalRecords() async throws {
        let (root, target) = try deletionFixture(id: "100")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = WorkshopInstalledLibraryStoreProbe(entries: [target])
        let probe = WorkshopInstalledDeleteProbe(store: store, bookmarks: ["100"])
        let gate = WorkshopInstalledUpdateGate()
        probe.gate = (gate, "delete-100")
        let model = InstalledLibraryModel(
            dependencies: store.dependencies,
            lifecycleOwner: InstalledPageLifecycleOwner()
        )
        model.onAppear()

        model.performDelete(target, services: probe.services)
        await gate.waitUntilSuspended("delete-100")
        #expect(probe.log == ["repository:100"])
        #expect(store.entries == [target])

        await gate.resume("delete-100", value: "deleted")
        await Self.waitUntil { probe.log.count >= 3 }

        #expect(probe.log == ["repository:100", "removeImport:100", "removeBookmark:100"])
        #expect(store.entries.isEmpty)
        #expect(model.errorMessage == nil)
        model.onDisappear()
    }

    @Test("delete refuses outright while the same item is downloading")
    @MainActor
    func deleteRefusesWhileItemIsMutating() async throws {
        let (root, target) = try deletionFixture(id: "100")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = WorkshopInstalledLibraryStoreProbe(entries: [target])
        let probe = WorkshopInstalledDeleteProbe(store: store, bookmarks: ["100"])
        probe.isMutating = true
        let model = InstalledLibraryModel(
            dependencies: store.dependencies,
            lifecycleOwner: InstalledPageLifecycleOwner()
        )
        model.onAppear()

        model.performDelete(target, services: probe.services)
        await Self.waitUntil { model.errorMessage != nil }

        #expect(probe.log.isEmpty)
        #expect(store.entries == [target])
        #expect(probe.bookmarks == ["100"])
        model.onDisappear()
    }

    @Test("A local folder declaring a numeric Workshop ID never deletes a Steam repository item", .timeLimit(.minutes(1)))
    @MainActor
    func localNumericIDCannotDeleteRepository() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let bookmark = try root.bookmarkData(options: .minimalBookmark, includingResourceValuesForKeys: nil, relativeTo: nil)
        let target = entry(id: "100", location: .sourceFolder, sourceFolderBookmark: bookmark)
        let store = WorkshopInstalledLibraryStoreProbe(entries: [target])
        let probe = WorkshopInstalledDeleteProbe(store: store, bookmarks: ["100"])
        let model = InstalledLibraryModel(dependencies: store.dependencies)
        #expect(!model.deletesFiles(target))
        model.performDelete(target, services: probe.services)
        await Self.waitUntil { store.entries.isEmpty }
        #expect(probe.log == ["removeImport:100", "removeBookmark:100"])
        #expect(FileManager.default.fileExists(atPath: root.path))
    }

    @Test("Repository deletion belongs to the bookmarked library, even when IDs match")
    @MainActor
    func deletionCannotCrossLibraryRoots() throws {
        let (root, target) = try deletionFixture(id: "100")
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(InstalledLibraryModel.repositoryDeletionItemID(for: target.origin, steamRoot: root) == "100")
        let other = root.appendingPathComponent("other-library")
        #expect(InstalledLibraryModel.repositoryDeletionItemID(for: target.origin, steamRoot: other) == nil)
        #expect(InstalledLibraryModel.repositoryDeletionItemID(for: target.origin, steamRoot: root.appendingPathComponent("../sibling").standardizedFileURL) == nil)
    }

    @Test("A mismatched manifest and Steam folder identity removes only local records", .timeLimit(.minutes(1)))
    @MainActor
    func mismatchedIdentityNeverDeletesSourceFiles() async throws {
        let (root, target) = try deletionFixture(id: "100")
        defer { try? FileManager.default.removeItem(at: root) }
        let sentinel = SteamLibraryPaths.workshopContentRoot(steamRoot: root)
            .appendingPathComponent("100/source.txt")
        try Data("source stays".utf8).write(to: sentinel)
        let origin = WPEOrigin(
            workshopID: "200", title: "Reupload", originalType: .scene,
            sourceFolderBookmark: target.origin.sourceFolderBookmark,
            cacheRelativePath: nil, previewFileName: nil
        )
        let entry = WPEHistoryEntry(origin: origin, importedAt: target.importedAt)
        let store = WorkshopInstalledLibraryStoreProbe(entries: [entry])
        let probe = WorkshopInstalledDeleteProbe(store: store, bookmarks: ["200"])
        let model = InstalledLibraryModel(dependencies: store.dependencies)
        #expect(!model.deletesFiles(entry))
        #expect(InstalledLibraryModel.repositoryDeletionItemID(for: origin, steamRoot: root) == nil)
        model.performDelete(entry, services: probe.services)
        await Self.waitUntil { store.entries.isEmpty }
        #expect(probe.log == ["removeImport:200", "removeBookmark:200"])
        #expect(try Data(contentsOf: sentinel) == Data("source stays".utf8))
    }

    @Test("Deleting an installed item clears its user shortcut bindings and no one else's")
    @MainActor
    func deleteClearsUserShortcutBindings() throws {
        let deleted = "usershortcut-delete-\(UUID().uuidString)"
        let kept = "usershortcut-keep-\(UUID().uuidString)"
        let shortcuts = UserShortcutBindingStore.shared
        defer {
            shortcuts.removeAll(forWallpaper: deleted)
            shortcuts.removeAll(forWallpaper: kept)
        }
        try shortcuts.setWebsite("https://example.com", for: UserShortcutBindingKey(wallpaperID: deleted, propertyKey: "open"))
        try shortcuts.setWebsite("https://example.org", for: UserShortcutBindingKey(wallpaperID: kept, propertyKey: "open"))
        let target = entry(id: deleted, location: .sourceFolder)
        let store = WorkshopInstalledLibraryStoreProbe(entries: [target])
        let probe = WorkshopInstalledDeleteProbe(store: store)
        let model = InstalledLibraryModel(dependencies: store.dependencies)
        #expect(!model.deletesFiles(target))

        model.performDelete(target, services: probe.services)
        #expect(store.entries.isEmpty)
        #expect(shortcuts.bindings(forWallpaper: deleted).isEmpty, "a deleted wallpaper kept its user shortcut bindings")
        #expect(shortcuts.bindings(forWallpaper: kept).count == 1, "deleting one wallpaper cleared another's bindings")
    }

    @Test("The live deletion closure validates the source library before opening the mutation gate")
    func liveDeletionChecksSourceRoot() throws {
        let source = try RepositoryRoot.source("LiveWallpaper/Views/EditDesk/Library/ModalActions.swift")
        let start = try #require(source.range(of: "deleteSharedRepositoryItem: { origin in"))
        let body = source[start.upperBound...]
        let identity = try #require(body.range(of: "repositoryDeletionItemID(for: origin, steamRoot: steamRoot)"))
        let gate = try #require(body.range(of: "withExclusiveMutation(workshopID: workshopID)"))
        #expect(identity.lowerBound < gate.lowerBound)
    }

    private func deletionFixture(id: String) throws -> (URL, WPEHistoryEntry) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let folder = SteamLibraryPaths.workshopContentRoot(steamRoot: root).appendingPathComponent(id)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let bookmark = try folder.bookmarkData(options: .minimalBookmark, includingResourceValuesForKeys: nil, relativeTo: nil)
        return (root, entry(id: id, sourceFolderBookmark: bookmark))
    }

    @MainActor
    private static func waitUntil(_ condition: () -> Bool) async {
        for _ in 0 ..< 500 where !condition() {
            await Task.yield()
        }
        #expect(condition())
    }

    @Test("The auto-ingest scan never deletes library records")
    func autoIngestNeverDeletesRecords() throws {
        let source = try projectSource(
            "LiveWallpaper/Application/Workshop/WorkshopFolderImportCoordinator.swift"
        )
        let body = try sourceSlice(source, from: "func ingestExistingDownloads", to: "\n    nonisolated static func")
        #expect(!body.contains("removeWPEImports"))
        #expect(!body.contains("SettingsManager.shared.remove"))
    }

    @Test("Re-recording an existing item keeps its library history")
    @MainActor
    func rerecordPreservesImportHistory() async {
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
        importedAt: TimeInterval = 10,
        sourceFolderBookmark: Data? = nil
    ) -> WPEHistoryEntry {
        WPEHistoryEntry(
            origin: WPEOrigin(
                workshopID: id,
                title: title,
                originalType: type,
                sourceFolderBookmark: sourceFolderBookmark ?? Data("bookmark-\(id)".utf8),
                cacheRelativePath: location == .cache ? "wpe-cache/\(id)" : nil,
                previewFileName: "preview.jpg",
                entryFile: "entry",
                resourceLocation: location
            ),
            importedAt: Date(timeIntervalSince1970: importedAt)
        )
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

    /// `updated: nil` omits `time_updated` from that item.
    private static func metadataBatchPayload(_ items: [(id: String, updated: Int?)]) -> Data {
        let details = items.map { item in
            let updatedField = item.updated.map { "\"time_updated\":\($0)," } ?? ""
            return """
            {"publishedfileid":"\(item.id)","result":1,"consumer_app_id":431960,\(updatedField)"visibility":0,"banned":0}
            """
        }
        return Data("""
        {"response":{"result":1,"resultcount":\(items.count),"publishedfiledetails":[\(details.joined(separator: ","))]}}
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

    static func publishedFileIDs(from request: URLRequest) -> [String] {
        guard let data = data(from: request),
              let body = String(data: data, encoding: .utf8)
        else { return [] }
        return body.components(separatedBy: "&")
            .filter { $0.hasPrefix("publishedfileids%5B") }
            .compactMap { $0.components(separatedBy: "=").last }
    }
}

private final class WorkshopMetadataResponseGate: @unchecked Sendable {
    typealias Plan = WorkshopMetadataURLProtocolStub.Plan

    private let condition = NSCondition()
    private let makeResponse: @Sendable ([String]) -> Plan
    private var startedBatches: [[String]] = []
    private var releasedCount = 0

    init(makeResponse: @escaping @Sendable ([String]) -> Plan) {
        self.makeResponse = makeResponse
    }

    /// One element per POST, holding the ids that request carried.
    var batches: [[String]] {
        condition.lock()
        defer { condition.unlock() }
        return startedBatches
    }

    func response(for request: URLRequest) -> Plan {
        let ids = WorkshopMetadataRequestBody.publishedFileIDs(from: request)
        guard !ids.isEmpty else { return .error(URLError(.badURL)) }
        condition.lock()
        startedBatches.append(ids)
        let ordinal = startedBatches.count
        condition.broadcast()
        while releasedCount < ordinal {
            condition.wait()
        }
        condition.unlock()
        return makeResponse(ids)
    }

    @MainActor
    func waitUntilStarted(count: Int) async {
        for _ in 0..<10_000 {
            if batches.count >= count {
                return
            }
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
private final class WorkshopInstalledDeleteProbe {
    let store: WorkshopInstalledLibraryStoreProbe
    var bookmarks: Set<String>
    var isMutating = false
    var repositoryThrows = false
    var gate: (gate: WorkshopInstalledUpdateGate, key: String)?
    /// Call order across the two halves of a delete.
    private(set) var log: [String] = []

    init(store: WorkshopInstalledLibraryStoreProbe, bookmarks: Set<String> = []) {
        self.store = store
        self.bookmarks = bookmarks
    }

    var services: InstalledLibraryModel.DeleteServices {
        InstalledLibraryModel.DeleteServices(
            containsBookmark: { [self] in bookmarks.contains($0) },
            removeBookmarks: { [self] id in
                bookmarks.remove(id)
                log.append("removeBookmark:\(id)")
            },
            removeImportIfMatching: { [self] identity in
                guard let index = store.entries.firstIndex(where: {
                    WorkshopInstalledEntryIdentity($0) == identity
                }) else { return false }
                store.entries.remove(at: index)
                log.append("removeImport:\(identity.workshopID)")
                return true
            },
            isMutating: { [self] _ in isMutating },
            deleteSharedRepositoryItem: { [self] origin in
                let id = origin.steamFolderItemID ?? origin.workshopID
                log.append("repository:\(id)")
                if let gate {
                    _ = await gate.gate.suspend(gate.key)
                }
                if repositoryThrows {
                    throw WorkshopRepositoryCoordinator.MutationError.itemAlreadyMutating(id)
                }
                return SteamDeleteResult(outcome: .deleted, freedBytes: 1, refusalReason: nil)
            }
        )
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
