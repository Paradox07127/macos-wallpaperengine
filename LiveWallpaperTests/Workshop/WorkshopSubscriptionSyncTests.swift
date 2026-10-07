#if !LITE_BUILD
import Foundation
@testable import LiveWallpaper
import Testing

@Suite("Workshop subscription sync", .serialized, .timeLimit(.minutes(1)))
@MainActor
struct WorkshopSubscriptionSyncTests {
    private let itemID: UInt64 = 42

    @Test("An item downloaded earlier in this run, then deleted, is offered again by the next check")
    func downloadedThenDeletedIsOfferedAgain() async throws {
        let fixture = try SyncFixture()
        try await TestScratch.withCleanup { await fixture.discard() } operation: {
            fixture.listing.ids = [itemID]
            await fixture.sync.refresh(using: fixture.doctor)
            fixture.sync.downloadSelected(using: fixture.downloader)
            #expect(await waitUntil { fixture.downloads.phase(for: itemID) == .succeeded && !fixture.downloads.isBusy(itemID) })

            // The download landed outside the Steam library, so the check reads it as not installed.
            await fixture.sync.refresh(using: fixture.doctor)

            #expect(fixture.sync.phase == .ready(missing: [itemID]))
            #expect(fixture.sync.downloadableSelection() == [itemID], "a past success hid an item missing from disk")
            #expect(fixture.downloads.phase(for: itemID) == .idle)
        }
    }

    @Test("An item whose folder is in the Steam library is not missing")
    func installedFolderIsNotMissing() async throws {
        let fixture = try SyncFixture()
        try await TestScratch.withCleanup { await fixture.discard() } operation: {
            try fixture.installInLibrary(itemID)
            fixture.listing.ids = [itemID]

            await fixture.sync.refresh(using: fixture.doctor)

            #expect(fixture.sync.phase == .ready(missing: []))
            #expect(fixture.sync.downloadableSelection().isEmpty)
        }
    }

    @Test("An item SteamCMD installs while the subscription list is read is not missing")
    func installedDuringListingIsNotMissing() async throws {
        let fixture = try SyncFixture()
        try await TestScratch.withCleanup { await fixture.discard() } operation: {
            fixture.listing.ids = [itemID]
            fixture.listing.installsBeforeAnswering = SteamLibraryPaths.workshopContentRoot(steamRoot: fixture.root)
                .appendingPathComponent(String(itemID), isDirectory: true)

            await fixture.sync.refresh(using: fixture.doctor)

            #expect(fixture.sync.phase == .ready(missing: []))
        }
    }

    @Test("A workshop folder that cannot be read fails the check instead of listing every item as missing")
    func unreadableContentFolderFailsCheck() async throws {
        let fixture = try SyncFixture()
        try await TestScratch.withCleanup { await fixture.discard() } operation: {
            try fixture.installInLibrary(itemID)
            try fixture.setContentFolderPermissions(0o000)
            fixture.listing.ids = [itemID]

            await fixture.sync.refresh(using: fixture.doctor)

            guard case .failed = fixture.sync.phase else {
                Issue.record("an unreadable library was read as empty, got \(fixture.sync.phase)")
                return
            }
        }
    }

    @Test("A library with no workshop folder lists every subscription as missing")
    func absentContentFolderListsAllMissing() async throws {
        let fixture = try SyncFixture()
        try await TestScratch.withCleanup { await fixture.discard() } operation: {
            try FileManager.default.removeItem(at: fixture.contentFolder)
            fixture.listing.ids = [itemID]

            await fixture.sync.refresh(using: fixture.doctor)

            #expect(fixture.sync.phase == .ready(missing: [itemID]))
        }
    }

    @Test("A check that fails mid-download keeps the download active and cancellable")
    func failedCheckKeepsActiveDownload() async throws {
        let fixture = try SyncFixture(parks: true)
        try await TestScratch.withCleanup { await fixture.discard() } operation: {
            fixture.listing.ids = [itemID]
            await fixture.sync.refresh(using: fixture.doctor)
            fixture.sync.downloadSelected(using: fixture.downloader)
            #expect(await waitUntil { fixture.downloader.isParked })

            fixture.listing.ids = nil
            await fixture.sync.refresh(using: fixture.doctor)
            guard case .failed = fixture.sync.phase else {
                Issue.record("the check was expected to fail, got \(fixture.sync.phase)")
                fixture.downloader.release()
                return
            }

            #expect(fixture.sync.hasActiveDownloads, "a failed check hid the running download")
            #expect(fixture.sync.rows == [itemID])
            fixture.sync.cancelDownloads()
            #expect(!fixture.downloads.isBusy(itemID), "Cancel downloads left the running download alone")
            #expect(!fixture.sync.hasActiveDownloads)
            fixture.downloader.release()
        }
    }

    private func waitUntil(_ condition: () -> Bool) async -> Bool {
        for _ in 0 ..< 200 {
            if condition() {
                return true
            }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return condition()
    }
}

/// nil `ids` stands for a connector that did not answer.
@MainActor
private final class SubscriptionListing {
    var ids: [UInt64]?
    /// A folder the listing creates before it answers, as SteamCMD finishing a download during the read would.
    var installsBeforeAnswering: URL?
}

/// Delivers the video project in `folder`; `parks` holds the download until `release()`.
@MainActor
private final class SyncDownloader: WorkshopItemDownloading {
    private let folder: URL
    private let parks: Bool
    private var gate: CheckedContinuation<Void, Never>?

    init(folder: URL, parks: Bool) {
        self.folder = folder
        self.parks = parks
    }

    var isParked: Bool {
        gate != nil
    }

    func downloadWorkshopItem<Imported: Sendable>(
        _: UInt64,
        onProgress _: SteamCMDDoctorService.SteamCMDProgressHandler?,
        onContentReady: @MainActor @Sendable (URL) async -> Imported
    ) async -> WorkshopItemDownloadResult<Imported> {
        if parks {
            await withCheckedContinuation { gate = $0 }
        }
        return await .imported(onContentReady(folder))
    }

    func release() {
        gate?.resume()
        gate = nil
    }
}

@MainActor
private final class SyncFixture {
    let root: URL
    let steamSuite: TestScratch.DefaultsSuite
    let librarySuite: TestScratch.DefaultsSuite
    let settings: SettingsManager
    let doctor: SteamCMDDoctorService
    let downloader: SyncDownloader
    let downloads: WorkshopDownloadCoordinator
    let listing: SubscriptionListing
    let sync: WorkshopSubscriptionSync

    init(parks: Bool = false, function: String = #function) throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("SubscriptionSync-\(UUID().uuidString)", isDirectory: true)
        self.root = root
        let source = root.appendingPathComponent("source/42", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try Data(#"{"workshopid":"42","title":"Item","type":"video","file":"video.mp4"}"#.utf8)
            .write(to: source.appendingPathComponent("project.json"))
        try Data([0x00]).write(to: source.appendingPathComponent("video.mp4"))
        try FileManager.default.createDirectory(
            at: SteamLibraryPaths.workshopContentRoot(steamRoot: root), withIntermediateDirectories: true
        )

        let steamSuite = try TestScratch.defaultsSuite(prefix: "LiveWallpaperTests.SubscriptionSync.Steam", function: function)
        let librarySuite = try TestScratch.defaultsSuite(prefix: "LiveWallpaperTests.SubscriptionSync.Library", function: function)
        self.steamSuite = steamSuite
        self.librarySuite = librarySuite
        let doctor = SteamCMDDoctorService(defaults: steamSuite.defaults)
        doctor.workdirBookmarkData = try root.bookmarkData()
        doctor.username = "tester"
        self.doctor = doctor
        let settings = SettingsManager(
            directory: ConfigurationDirectory(root: root.appendingPathComponent("settings")), defaults: librarySuite.defaults
        )
        self.settings = settings
        downloader = SyncDownloader(folder: source, parks: parks)
        let downloads = WorkshopDownloadCoordinator(
            importService: WallpaperEngineImportService(validateVideo: { _ in }, makeBookmark: { try? $0.bookmarkData() }),
            repositoryCoordinator: WorkshopRepositoryCoordinator(),
            settings: settings,
            toasts: WorkshopToastCenter(),
            cancelSteamCMD: { _ in }
        )
        self.downloads = downloads
        // Title lookups time out at once instead of reaching Steam.
        let offline = URLSessionConfiguration.ephemeral
        offline.timeoutIntervalForResource = 0.001
        let listing = SubscriptionListing()
        self.listing = listing
        sync = WorkshopSubscriptionSync(
            metadataService: SteamWorkshopMetadataService(session: URLSession(configuration: offline)),
            downloads: downloads,
            queue: WorkshopDownloadQueue(downloads: downloads),
            listSubscriptions: { _ in
                if let folder = listing.installsBeforeAnswering {
                    try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                }
                return listing.ids.map { SteamSubscribedItemsResult(outcome: .listed, workshopIDs: $0.map(String.init), diagnosticTail: "") }
            }
        )
    }

    var contentFolder: URL {
        SteamLibraryPaths.workshopContentRoot(steamRoot: root)
    }

    func installInLibrary(_ itemID: UInt64) throws {
        try FileManager.default.createDirectory(
            at: contentFolder.appendingPathComponent(String(itemID), isDirectory: true),
            withIntermediateDirectories: true
        )
    }

    func setContentFolderPermissions(_ mode: Int) throws {
        try FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: contentFolder.path(percentEncoded: false))
    }

    func discard() async {
        // An unreadable folder would block removing the scratch root.
        try? setContentFolderPermissions(0o755)
        steamSuite.discard()
        librarySuite.discard()
        await TestScratch.discard(root, flushing: settings)
    }
}
#endif
