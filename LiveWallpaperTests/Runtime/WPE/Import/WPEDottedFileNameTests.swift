#if !LITE_BUILD
import Foundation
@testable import LiveWallpaper
import LiveWallpaperCore
import Testing

@Suite("WPE names containing consecutive dots", .serialized) @MainActor
struct WPEDottedFileNameTests {
    private func makeFolder(named name: String = UUID().uuidString, manifest: String) throws -> URL {
        let parent = FileManager.default.temporaryDirectory
            .appendingPathComponent("wpe-dotted-\(UUID())", isDirectory: true)
        let folder = parent.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data(manifest.utf8).write(to: folder.appendingPathComponent("project.json"))
        return folder
    }

    @Test func manifestEntryWithDoubleDotFileNameReads() throws {
        let folder = try makeFolder(manifest: #"{"title":"light like feather","file":"light like feather..mp4","type":"Video"}"#)
        defer { try? FileManager.default.removeItem(at: folder.deletingLastPathComponent()) }
        let project = try WallpaperEngineProject.read(from: folder)
        #expect(project.entryFile == "light like feather..mp4")
        #expect(project.type == .video)
    }

    @Test func videoWithDoubleDotFileNameImports() async throws {
        let folder = try makeFolder(manifest: #"{"title":"light like feather","file":"light like feather..mp4","type":"Video"}"#)
        defer { try? FileManager.default.removeItem(at: folder.deletingLastPathComponent()) }
        try Data([0]).write(to: folder.appendingPathComponent("light like feather..mp4"))
        let service = WallpaperEngineImportService(
            validateVideo: { _ in },
            makeBookmark: { try? $0.bookmarkData(options: .minimalBookmark, includingResourceValuesForKeys: nil, relativeTo: nil) }
        )
        let result = try await service.importProject(folder: folder)
        guard case .ready(.video, _) = result else {
            Issue.record("Expected a ready video import, got \(result)")
            return
        }
    }

    @Test func localFolderWithDoubleDotNameIsAValidProjectID() throws {
        let folder = try makeFolder(named: "My..Wallpaper", manifest: #"{"title":"Mine","file":"index.html","type":"web"}"#)
        defer { try? FileManager.default.removeItem(at: folder.deletingLastPathComponent()) }
        let project = try WallpaperEngineProject.read(from: folder)
        #expect(project.workshopID == "My..Wallpaper")
    }

    @Test func traversalEntryStillRejected() throws {
        for file in ["../x.mp4", "a/../b.mp4", "a/..", "..", "/abs.mp4"] {
            let folder = try makeFolder(manifest: #"{"file":"\#(file)","type":"video"}"#)
            defer { try? FileManager.default.removeItem(at: folder.deletingLastPathComponent()) }
            #expect(throws: WPEProjectError.self, "\(file) must stay rejected") {
                try WallpaperEngineProject.read(from: folder)
            }
        }
    }

    @Test func deleteTombstoneAcceptsDoubleDotNamesOnly() async throws {
        let scratch = try TestScratch.defaultsSuite(prefix: "WPEDottedFileNameTests")
        defer { scratch.discard() }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("wpe-dotted-settings-\(UUID())", isDirectory: true)
        let settings = SettingsManager(directory: ConfigurationDirectory(root: directory), defaults: scratch.defaults)
        for id in ["My..Wallpaper", "..", ".", "a/b", "a\\b", ""] {
            settings.recordWPEDeleteTombstone(workshopID: id)
        }
        #expect(settings.loadGlobalSettings().deletedWorkshopIDs == ["My..Wallpaper"])
        await TestScratch.discard(directory, flushing: settings)
    }

    @Test(.timeLimit(.minutes(1)))
    func workshopDownloadSurfacesTheImportError() async throws {
        let folder = try makeFolder(named: "420000077", manifest: #"{"file":"../escape.mp4","type":"video"}"#)
        defer { try? FileManager.default.removeItem(at: folder.deletingLastPathComponent()) }
        let scratch = try TestScratch.defaultsSuite(prefix: "WPEDottedFileNameTests")
        defer { scratch.discard() }
        let directory = folder.deletingLastPathComponent().appendingPathComponent("settings", isDirectory: true)
        let settings = SettingsManager(directory: ConfigurationDirectory(root: directory), defaults: scratch.defaults)
        let downloads = WorkshopDownloadCoordinator(
            importService: WallpaperEngineImportService(validateVideo: { _ in }),
            repositoryCoordinator: WorkshopRepositoryCoordinator(),
            settings: settings, toasts: WorkshopToastCenter(), cancelSteamCMD: { _ in }
        )
        let attempt = try #require(downloads.download(itemID: 420_000_077, title: "Fixture", using: FixedFolderDownloader(folder: folder)))
        while attempt.outcome == nil {
            try await Task.sleep(for: .milliseconds(10))
        }
        guard case let .failed(reason)? = attempt.outcome else {
            Issue.record("Expected the malformed manifest to fail the download")
            return
        }
        let cause = try #require(WPEProjectError.manifestMalformed("").errorDescription)
        #expect(reason.contains(cause))
        #expect(downloads.phase(for: 420_000_077) == .failed(reason))
        await TestScratch.discard(directory, flushing: settings)
    }
}

@MainActor
private struct FixedFolderDownloader: WorkshopItemDownloading {
    let folder: URL

    func downloadWorkshopItem<Imported: Sendable>(
        _: UInt64,
        onProgress _: SteamCMDDoctorService.SteamCMDProgressHandler?,
        onContentReady: @MainActor @Sendable (URL) async -> Imported
    ) async -> WorkshopItemDownloadResult<Imported> {
        await .imported(onContentReady(folder))
    }
}
#endif
