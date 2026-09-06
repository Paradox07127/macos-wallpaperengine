#if !LITE_BUILD
import Foundation
import Testing
@testable import LiveWallpaper

/// Download readiness must reflect facts that are current, not bytes that once
/// meant access.
@Suite("Workshop download readiness", .serialized)
@MainActor
struct WorkshopDownloadReadinessTests {
    private func makeService(function: String = #function) throws -> SteamCMDDoctorService {
        let scratch = try TestScratch.defaultsSuite(
            prefix: "LiveWallpaperTests.DownloadReadiness", function: function
        )
        return SteamCMDDoctorService(defaults: scratch.defaults)
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
    func failedResolutionBlocksDownloads() throws {
        let service = try makeService()
        // Bytes exist but can never resolve to a folder.
        configureAllGreen(service, bookmark: Data([0x01]))

        #expect(throws: (any Error).self) { _ = try service.resolveWorkdirURL() }

        #expect(service.downloadBlocker != nil)
        #expect(!service.isDownloadReady)
    }

    @Test("A red binary-identity probe blocks downloads")
    func redIdentityProbeBlocksDownloads() throws {
        let service = try makeService()
        configureAllGreen(service, bookmark: try resolvableBookmark())
        service.setProbe(.binaryIdentity, status: .red(message: "signature mismatch", command: nil))

        #expect(service.downloadBlocker != nil)
    }

    @Test("An unprobed binary identity does not block downloads")
    func notRunIdentityProbeDoesNotBlock() throws {
        // Control: probes are not persisted, so .notRun must never block —
        // otherwise every launch demands a manual probe run before downloading.
        let service = try makeService()
        configureAllGreen(service, bookmark: try resolvableBookmark())
        service.setProbe(.binaryIdentity, status: .notRun)

        #expect(service.downloadBlocker == nil)
        #expect(service.isDownloadReady)
    }

    @Test("An untested session after relaunch can attempt a cached download")
    func unknownSessionDoesNotMeanLoggedOut() throws {
        let service = try makeService()
        try configureAllGreen(service, bookmark: resolvableBookmark())
        service.setProbe(.cachedLogin, status: .notRun)
        #expect(service.downloadBlocker == nil)
        #expect(!service.isGreen(.cachedLogin))
        service.noteSuccessfulSteamOperation(generation: service.accountGeneration)
        #expect(service.isGreen(.cachedLogin))
    }

    @Test("An operation reporting login-required demotes the green probe")
    func loginRequiredDemotesCachedLogin() throws {
        let service = try makeService()
        configureAllGreen(service, bookmark: try resolvableBookmark())
        #expect(service.isGreen(.cachedLogin))
        #expect(service.downloadBlocker == nil)

        service.noteOperationReportedLoginRequired(generation: service.accountGeneration)

        #expect(!service.isGreen(.cachedLogin))
        #expect(service.downloadBlocker != nil)
        // Demoted to the existing "session expired" guidance, not to an
        // unrelated red.
        guard case .yellow? = service.probes[.cachedLogin]?.status else {
            Issue.record("expected a yellow cachedLogin probe after login-required")
            return
        }
    }

    @Test("Removing the saved session stops an in-flight result from greening the probe")
    func removedSessionIgnoresInFlightResults() throws {
        let service = try makeService()
        try configureAllGreen(service, bookmark: resolvableBookmark())
        let inFlight = service.accountGeneration

        service.forgetSignedInSession()

        // The account stays selected; only its session is gone.
        #expect(service.username == "someone")
        #expect(service.cachedLoginVerdict == nil)
        #expect(!service.isGreen(.cachedLogin))

        service.noteSuccessfulSteamOperation(generation: inFlight)
        #expect(!service.isGreen(.cachedLogin))

        // Control: a result from after the removal still lands.
        service.noteSuccessfulSteamOperation(generation: service.accountGeneration)
        #expect(service.isGreen(.cachedLogin))
    }

    @Test("A transient network failure reddens the probe but does not block downloads")
    func transientFailureDoesNotBlockDownloads() throws {
        let service = try makeService()
        try configureAllGreen(service, bookmark: resolvableBookmark())

        for outcome in [SteamCachedLoginOutcome.noConnection, .timedOut, .rateLimited] {
            service.applyCachedLoginOutcome(
                SteamCachedLoginResult(outcome: outcome, steamID64: nil, diagnosticTail: ""),
                username: "someone", binary: URL(fileURLWithPath: "/tmp/steamcmd"),
                generation: service.accountGeneration
            )
            #expect(!service.isGreen(.cachedLogin))
            #expect(
                service.downloadBlocker == nil,
                Comment(rawValue: "\(outcome) locked the download entry; the download validates its own session")
            )
        }
    }

    @Test("A missing, expired or refused session blocks downloads")
    func credentialFailureBlocksDownloads() throws {
        // Control for the transient case above: these verdicts are about the
        // account, not the network, and must still gate.
        let service = try makeService()
        try configureAllGreen(service, bookmark: resolvableBookmark())

        for outcome in [SteamCachedLoginOutcome.noCachedSession, .sessionExpired, .loginFailed] {
            service.applyCachedLoginOutcome(
                SteamCachedLoginResult(outcome: outcome, steamID64: nil, diagnosticTail: ""),
                username: "someone", binary: URL(fileURLWithPath: "/tmp/steamcmd"),
                generation: service.accountGeneration
            )
            #expect(service.downloadBlocker != nil, Comment(rawValue: "\(outcome) did not block"))
        }
    }

    @Test("An operation that started under another account cannot colour this one")
    func staleOperationResultsAreIgnored() throws {
        let service = try makeService()
        try configureAllGreen(service, bookmark: resolvableBookmark())
        service.setProbe(.cachedLogin, status: .notRun)
        let stale = service.accountGeneration
        try service.setUsername("bob")

        service.noteSuccessfulSteamOperation(generation: stale)
        #expect(!service.isGreen(.cachedLogin))
        service.noteOperationReportedLoginRequired(generation: stale)
        #expect(service.downloadBlocker == nil)

        // Control: the same calls with the live generation take effect.
        service.noteSuccessfulSteamOperation(generation: service.accountGeneration)
        #expect(service.isGreen(.cachedLogin))
        service.noteOperationReportedLoginRequired(generation: service.accountGeneration)
        #expect(service.downloadBlocker != nil)
    }

    /// The Diagnostics section reports on things `downloadBlocker` deliberately
    /// ignores. If one of them ever reached the blocker, a wallpaper-engine
    /// folder the user never linked would start refusing Workshop downloads.
    /// `redIdentityProbeBlocksDownloads` above is the control: it proves a red
    /// probe *can* block, so a pass here is not just "nothing blocks anything".
    @Test("Red Workshop-wide diagnostics never block downloads")
    func advisoryProbesNeverBlockDownloads() throws {
        let service = try makeService()
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
        let service = try makeService()
        configureAllGreen(service, bookmark: try resolvableBookmark())

        #expect(service.downloadBlocker == nil)
        #expect(service.isDownloadReady)
    }
}
#endif
