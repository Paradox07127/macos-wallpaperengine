#if !LITE_BUILD
import Foundation
@testable import LiveWallpaper
import Testing

@Suite("Workshop download byte progress — staged size, presentation and recording", .timeLimit(.minutes(1)))
@MainActor
struct WorkshopDownloadByteProgressTests {
    // MARK: Staged size

    private func makeScratch() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("byte-progress-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    @Test("Staging lives under downloads and temp, per app and item")
    func stagingDirectoriesNameOnlyTheItem() {
        let root = URL(fileURLWithPath: "/Steam", isDirectory: true)
        let paths = SteamLibraryPaths.workshopStagingDirectories(steamRoot: root, appID: "431960", itemID: "123")
            .map { $0.path(percentEncoded: false) }
        #expect(paths == [
            "/Steam/steamapps/workshop/downloads/431960/123/",
            "/Steam/steamapps/workshop/temp/431960/123/",
        ])
    }

    @Test("Real files count, links and their targets do not")
    func allocatedBytesSkipsSymlinks() throws {
        let root = try makeScratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let staged = root.appendingPathComponent("staged", isDirectory: true)
        let nested = staged.appendingPathComponent("materials", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try Data(repeating: 1, count: 5000).write(to: staged.appendingPathComponent("scene.pkg"))
        try Data(repeating: 2, count: 100).write(to: nested.appendingPathComponent("project.json"))
        let outside = root.appendingPathComponent("big.bin")
        try Data(repeating: 3, count: 1_000_000).write(to: outside)
        try FileManager.default.createSymbolicLink(
            at: staged.appendingPathComponent("link.bin"), withDestinationURL: outside
        )

        #expect(SteamDirectorySize.allocatedBytes(at: staged, entryLimit: 10000) == 5100)
    }

    @Test("A preallocated file counts only the blocks it really holds")
    func allocatedBytesIgnoresPreallocatedLength() throws {
        let root = try makeScratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("scene.pkg")
        FileManager.default.createFile(atPath: file.path(percentEncoded: false), contents: Data(repeating: 1, count: 4096))
        let handle = try FileHandle(forWritingTo: file)
        try handle.truncate(atOffset: 10_000_000)
        try handle.close()

        #expect(SteamDirectorySize.allocatedBytes(at: root, entryLimit: 10000) == 4096)
    }

    @Test("A missing directory is zero; the entry limit stops the walk where it got to")
    func allocatedBytesMissingAndLimited() throws {
        let root = try makeScratch()
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(SteamDirectorySize.allocatedBytes(at: root.appendingPathComponent("absent"), entryLimit: 10000) == 0)

        for index in 0 ..< 3 {
            try Data(repeating: 1, count: 1000).write(to: root.appendingPathComponent("file\(index)"))
        }
        #expect(SteamDirectorySize.allocatedBytes(at: root, entryLimit: 10000) == 3000)
        #expect(SteamDirectorySize.allocatedBytes(at: root, entryLimit: 2) == 2000)
    }

    @Test("Only a larger measurement is reported: the commit empties the staging directory")
    func onlyGrowthIsReported() {
        #expect(SteamDirectorySize.nextReport(measured: 10, reported: 0) == 10)
        #expect(SteamDirectorySize.nextReport(measured: 10, reported: 10) == nil)
        #expect(SteamDirectorySize.nextReport(measured: 0, reported: 10) == nil)
        #expect(SteamDirectorySize.nextReport(measured: 0, reported: 0) == nil)
    }

    // MARK: Presentation

    private func downloading(
        downloaded: UInt64?, total: UInt64?, fraction: Double? = nil
    ) -> WorkshopDownloadPresentation {
        WorkshopDownloadPresentation.make(
            ticketState: nil, screenName: "", wallpapersOn: true, phase: .downloading,
            isFetchingDependencies: false, fraction: fraction, downloadedBytes: downloaded, totalBytes: total,
            bytesPerSecond: nil, isInstalled: false, reportsSave: true, blocker: nil
        )
    }

    private func megabytes(_ bytes: UInt64) -> String {
        WorkshopByteFormatter.megabytesAndUp.string(fromByteCount: Int64(bytes))
    }

    @Test("Bytes with no total show the running size over an indeterminate bar")
    func downloadedOnlyShowsSize() {
        let line = downloading(downloaded: 264_000_000, total: nil)
        #expect(line.progress == .indeterminate)
        #expect(line.detail == megabytes(264_000_000))
    }

    @Test("Bytes and a total with no fraction derive the bar, short of full")
    func bytesAndTotalDeriveFraction() {
        let quarter = downloading(downloaded: 100_000_000, total: 400_000_000)
        #expect(quarter.progress == .fraction(0.25))
        #expect(quarter.detail == "\(megabytes(100_000_000)) / \(megabytes(400_000_000))")
        #expect(downloading(downloaded: 500_000_000, total: 400_000_000).progress == .fraction(0.99))
        #expect(downloading(downloaded: 400_000_000, total: 400_000_000).progress == .fraction(0.99))
    }

    @Test("With no bytes the line shows no numbers, not a zero")
    func unknownBytesShowNothing() {
        let sizedOnly = downloading(downloaded: nil, total: 400_000_000)
        #expect(sizedOnly.detail.isEmpty, Comment(rawValue: sizedOnly.detail))
        #expect(sizedOnly.progress == .indeterminate)
        #expect(downloading(downloaded: nil, total: nil).detail.isEmpty)
        #expect(downloading(downloaded: 0, total: nil).detail.isEmpty)
    }

    @Test("A fraction SteamCMD reported still drives the bar over the byte ratio")
    func reportedFractionWins() {
        let line = downloading(downloaded: 100_000_000, total: 400_000_000, fraction: 0.5)
        #expect(line.progress == .fraction(0.5))
        #expect(line.detail.hasPrefix("50%"), Comment(rawValue: line.detail))
    }

    // MARK: Recording

    private func waitUntil(_ condition: () -> Bool) async -> Bool {
        for _ in 0 ..< 200 {
            if condition() {
                return true
            }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return condition()
    }

    @Test("A frame without a fraction keeps the last fraction and updates the bytes")
    func fractionlessFrameUpdatesBytesOnly() async throws {
        let itemID: UInt64 = 920_000_001
        let downloader = ProgressReportingDownloader()
        let downloads = WorkshopDownloadCoordinator(
            repositoryCoordinator: WorkshopRepositoryCoordinator(),
            toasts: WorkshopToastCenter()
        )
        downloads.download(itemID: itemID, title: String(itemID), using: downloader)
        #expect(await waitUntil { downloader.onProgress != nil })
        let report = try #require(downloader.onProgress)

        report(42, 1000, 10000)
        #expect(await waitUntil { downloads.progress[itemID] == 0.42 })
        report(nil, 2000, nil)
        #expect(await waitUntil { downloads.progressBytes[itemID]?.downloaded == 2000 })
        #expect(downloads.progress[itemID] == 0.42)
        downloader.release()
    }
}

@MainActor
private final class ProgressReportingDownloader: WorkshopItemDownloading {
    private(set) var onProgress: SteamCMDDoctorService.SteamCMDProgressHandler?
    private var gate: CheckedContinuation<Void, Never>?

    func downloadWorkshopItem<Imported: Sendable>(
        _: UInt64,
        onProgress: SteamCMDDoctorService.SteamCMDProgressHandler?,
        onContentReady _: @MainActor @Sendable (URL) async -> Imported
    ) async -> WorkshopItemDownloadResult<Imported> {
        self.onProgress = onProgress
        await withCheckedContinuation { gate = $0 }
        return .failed(reason: "released by test")
    }

    func release() {
        gate?.resume()
        gate = nil
    }
}
#endif
