#if !LITE_BUILD
import Foundation
@testable import LiveWallpaper
import Testing

extension WorkshopDownloadTests {
    @Test("A download with a missing dependency runs the post-SteamCMD hook once per run: root, dependency, re-read")
    @MainActor
    func dependencyRunsHookPerSteamCMDRun() async throws {
        let fixture = try HookFixture()
        defer { await fixture.discard() }
        let attempt = try #require(fixture.downloads.download(itemID: HookFixture.rootID, title: "Root", using: fixture.downloader))
        await fixture.downloads.downloadTaskForTesting(itemID: HookFixture.rootID)?.value

        #expect(fixture.downloader.requestedIDs == [HookFixture.rootID, HookFixture.dependencyID, HookFixture.rootID])
        guard case .succeeded? = attempt.outcome else {
            Issue.record("the dependency chain did not finish: \(String(describing: attempt.outcome))")
            return
        }
        #expect(fixture.runs.value == 3)
    }

    @Test("A dependency fetch the mutation gate refuses ran no SteamCMD and runs no hook")
    @MainActor
    func refusedDependencyGateSkipsHook() async throws {
        let fixture = try HookFixture()
        defer { await fixture.discard() }
        let holder = fixture.holdMutation(of: HookFixture.dependencyID)
        #expect(await fixture.waitUntilMutating(HookFixture.dependencyID))

        fixture.downloads.download(itemID: HookFixture.rootID, title: "Root", using: fixture.downloader)
        await fixture.downloads.downloadTaskForTesting(itemID: HookFixture.rootID)?.value

        #expect(fixture.downloader.requestedIDs == [HookFixture.rootID])
        #expect(fixture.runs.value == 1)
        fixture.gate.release()
        await holder.value
    }

    @Test("A re-read the mutation gate refuses ran no SteamCMD and runs no hook")
    @MainActor
    func refusedReimportGateSkipsHook() async throws {
        let fixture = try HookFixture()
        defer { await fixture.discard() }
        var holder: Task<Void, Never>?
        fixture.downloader.afterDependency = {
            holder = fixture.holdMutation(of: HookFixture.rootID)
            _ = await fixture.waitUntilMutating(HookFixture.rootID)
        }

        fixture.downloads.download(itemID: HookFixture.rootID, title: "Root", using: fixture.downloader)
        await fixture.downloads.downloadTaskForTesting(itemID: HookFixture.rootID)?.value

        #expect(fixture.downloader.requestedIDs == [HookFixture.rootID, HookFixture.dependencyID])
        #expect(fixture.runs.value == 2)
        fixture.gate.release()
        await holder?.value
        fixture.downloader.afterDependency = nil
    }
}

@MainActor
private final class HookRunCount {
    var value = 0
}

@MainActor
private final class HookGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private var released = false

    func wait() async {
        guard !released else { return }
        await withCheckedContinuation { continuation = $0 }
    }

    func release() {
        released = true
        continuation?.resume()
        continuation = nil
    }
}

/// Serves a root that needs one dependency; delivering the dependency makes the root a playable video.
@MainActor
private final class DependencyDownloader: WorkshopItemDownloading {
    let content: URL
    private(set) var requestedIDs: [UInt64] = []
    var afterDependency: (@MainActor () async -> Void)?

    init(content: URL) {
        self.content = content
    }

    func downloadWorkshopItem<Imported: Sendable>(
        _ itemID: UInt64,
        onProgress _: SteamCMDDoctorService.SteamCMDProgressHandler?,
        onContentReady: @MainActor @Sendable (URL) async -> Imported
    ) async -> WorkshopItemDownloadResult<Imported> {
        requestedIDs.append(itemID)
        let folder = content.appendingPathComponent(String(itemID), isDirectory: true)
        if itemID == HookFixture.dependencyID {
            do {
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                try Data(#"{"workshopid":"990000099","type":"application","file":"unused","title":"Dependency"}"#.utf8)
                    .write(to: folder.appendingPathComponent("project.json"))
                let root = content.appendingPathComponent(String(HookFixture.rootID), isDirectory: true)
                try Data(#"{"workshopid":"420000042","type":"video","file":"video.mp4","title":"Resolved"}"#.utf8)
                    .write(to: root.appendingPathComponent("project.json"))
                try Data([0]).write(to: root.appendingPathComponent("video.mp4"))
            } catch {
                return .failed(reason: error.localizedDescription)
            }
            await afterDependency?()
        }
        return await .imported(onContentReady(folder))
    }
}

@MainActor
private final class HookFixture {
    static let rootID: UInt64 = 420_000_042
    static let dependencyID: UInt64 = 990_000_099

    let root: URL
    let defaults: TestScratch.DefaultsSuite
    let settings: SettingsManager
    let repository: WorkshopRepositoryCoordinator
    let downloader: DependencyDownloader
    let runs: HookRunCount
    let gate = HookGate()
    let downloads: WorkshopDownloadCoordinator

    init(function: String = #function) throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("DependencyRunHook-\(UUID().uuidString)", isDirectory: true)
        self.root = root
        let content = SteamLibraryPaths.workshopContentRoot(steamRoot: root)
        let item = content.appendingPathComponent(String(Self.rootID), isDirectory: true)
        try FileManager.default.createDirectory(at: item, withIntermediateDirectories: true)
        try Data(#"{"workshopid":"420000042","title":"Needs dependency","type":"scene","file":"scene.json","dependencies":["990000099"]}"#.utf8)
            .write(to: item.appendingPathComponent("project.json"))
        let defaults = try TestScratch.defaultsSuite(prefix: "LiveWallpaperTests.DependencyRunHook", function: function)
        self.defaults = defaults
        let settings = SettingsManager(
            directory: ConfigurationDirectory(root: root.appendingPathComponent("settings")), defaults: defaults.defaults
        )
        self.settings = settings
        downloader = DependencyDownloader(content: content)
        let repository = WorkshopRepositoryCoordinator()
        self.repository = repository
        let runs = HookRunCount()
        self.runs = runs
        downloads = WorkshopDownloadCoordinator(
            importService: WallpaperEngineImportService(validateVideo: { _ in }, makeBookmark: { try? $0.bookmarkData() }),
            repositoryCoordinator: repository,
            settings: settings,
            toasts: WorkshopToastCenter(),
            cancelSteamCMD: { _ in },
            afterSteamCMDRun: { runs.value += 1 }
        )
    }

    /// Holds the item's mutation gate until `gate` is released.
    func holdMutation(of itemID: UInt64) -> Task<Void, Never> {
        Task { [repository, gate] in
            _ = try? await repository.withExclusiveMutation(workshopID: String(itemID)) { await gate.wait() }
        }
    }

    func waitUntilMutating(_ itemID: UInt64) async -> Bool {
        for _ in 0 ..< 200 {
            if repository.isMutating(workshopID: String(itemID)) {
                return true
            }
            await Task.yield()
        }
        return repository.isMutating(workshopID: String(itemID))
    }

    func discard() async {
        defaults.discard()
        await TestScratch.discard(root, flushing: settings)
    }
}
#endif
