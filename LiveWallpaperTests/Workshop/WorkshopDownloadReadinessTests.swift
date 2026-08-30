#if !LITE_BUILD
import Foundation
import Testing
@testable import LiveWallpaper

/// Download readiness must reflect facts that are current, not bytes that once
/// meant access.
@Suite("Workshop download readiness", .serialized)
@MainActor
struct WorkshopDownloadReadinessTests {
    private func makeService() -> SteamCMDDoctorService {
        let defaults = UserDefaults(suiteName: "LiveWallpaperTests.DownloadReadiness.\(UUID().uuidString)")!
        return SteamCMDDoctorService(defaults: defaults)
    }

    /// A bookmark the shared resolver can actually resolve (plain bookmark to a
    /// real folder; the live resolver falls back to plain resolution).
    private func resolvableBookmark() throws -> Data {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("DownloadReadiness-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return try dir.bookmarkData()
    }

    private func configureAllGreen(_ service: SteamCMDDoctorService, bookmark: Data) {
        service.binaryPath = "/tmp/steamcmd"
        service.workdirBookmarkData = bookmark
        service.username = "someone"
        service.setProbe(.binaryIdentity, status: .green(detail: "ok"))
        service.setProbe(.cachedLogin, status: .green(detail: "someone"))
    }

    @Test("A library grant that fails to resolve blocks downloads")
    func failedResolutionBlocksDownloads() {
        let service = makeService()
        // Bytes exist but can never resolve to a folder.
        configureAllGreen(service, bookmark: Data([0x01]))

        #expect(throws: (any Error).self) { _ = try service.resolveWorkdirURL() }

        #expect(service.downloadBlocker != nil)
        #expect(!service.isDownloadReady)
    }

    @Test("A red binary-identity probe blocks downloads")
    func redIdentityProbeBlocksDownloads() throws {
        let service = makeService()
        configureAllGreen(service, bookmark: try resolvableBookmark())
        service.setProbe(.binaryIdentity, status: .red(message: "signature mismatch", command: nil))

        #expect(service.downloadBlocker != nil)
    }

    @Test("An unprobed binary identity does not block downloads")
    func notRunIdentityProbeDoesNotBlock() throws {
        // Control: probes are not persisted, so .notRun must never block —
        // otherwise every launch demands a manual probe run before downloading.
        let service = makeService()
        configureAllGreen(service, bookmark: try resolvableBookmark())
        service.setProbe(.binaryIdentity, status: .notRun)

        #expect(service.downloadBlocker == nil)
        #expect(service.isDownloadReady)
    }

    @Test("An operation reporting login-required demotes the green probe")
    func loginRequiredDemotesCachedLogin() throws {
        let service = makeService()
        configureAllGreen(service, bookmark: try resolvableBookmark())
        #expect(service.isGreen(.cachedLogin))
        #expect(service.downloadBlocker == nil)

        service.noteOperationReportedLoginRequired()

        #expect(!service.isGreen(.cachedLogin))
        #expect(service.downloadBlocker != nil)
        // Demoted to the existing "session expired" guidance, not to an
        // unrelated red.
        guard case .yellow? = service.probes[.cachedLogin]?.status else {
            Issue.record("expected a yellow cachedLogin probe after login-required")
            return
        }
    }

    /// The Diagnostics section reports on things `downloadBlocker` deliberately
    /// ignores. If one of them ever reached the blocker, a wallpaper-engine
    /// folder the user never linked would start refusing Workshop downloads.
    /// `redIdentityProbeBlocksDownloads` above is the control: it proves a red
    /// probe *can* block, so a pass here is not just "nothing blocks anything".
    @Test("Red Workshop-wide diagnostics never block downloads")
    func advisoryProbesNeverBlockDownloads() throws {
        let service = makeService()
        configureAllGreen(service, bookmark: try resolvableBookmark())

        for kind in [DoctorProbeKind.workshopContent, .sceneResources, .connector] {
            service.setProbe(kind, status: .red(message: "failing", command: nil))
            #expect(
                service.downloadBlocker == nil,
                Comment(rawValue: "\(kind.rawValue) reached downloadBlocker; it is advisory and must not gate")
            )
            #expect(kind.isAdvisory)
        }
    }

    @Test("Everything green with a resolvable grant is ready")
    func allGreenResolvableIsReady() throws {
        // Control: the added conditions must not block a genuinely ready setup.
        let service = makeService()
        configureAllGreen(service, bookmark: try resolvableBookmark())

        #expect(service.downloadBlocker == nil)
        #expect(service.isDownloadReady)
    }
}
#endif
