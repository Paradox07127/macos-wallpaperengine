#if !LITE_BUILD
import Foundation
@testable import LiveWallpaper
import LiveWallpaperCore
import os
import Testing

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
    private func resolvableBookmark() throws -> (bookmark: Data, directory: URL) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("DownloadReadiness-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return try (dir.bookmarkData(), dir)
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
        let grant = try resolvableBookmark()
        defer { try? FileManager.default.removeItem(at: grant.directory) }
        configureAllGreen(service, bookmark: grant.bookmark)
        service.setProbe(.binaryIdentity, status: .red(message: "signature mismatch", command: nil))

        #expect(service.downloadBlocker != nil)
    }

    @Test("An unprobed binary identity does not block downloads")
    func notRunIdentityProbeDoesNotBlock() throws {
        // Control: probes are not persisted, so .notRun must never block —
        // otherwise every launch demands a manual probe run before downloading.
        let service = try makeService()
        let grant = try resolvableBookmark()
        defer { try? FileManager.default.removeItem(at: grant.directory) }
        configureAllGreen(service, bookmark: grant.bookmark)
        service.setProbe(.binaryIdentity, status: .notRun)

        #expect(service.downloadBlocker == nil)
        #expect(service.isDownloadReady)
    }

    @Test("The blocker names the first setup step a download still lacks")
    func blockerNamesTheFirstMissingStep() throws {
        let service = try makeService()
        #expect(service.downloadBlocker == .steamCMD)
        service.binaryPath = "/tmp/steamcmd"
        #expect(service.downloadBlocker == .library)
        let grant = try resolvableBookmark()
        defer { try? FileManager.default.removeItem(at: grant.directory) }
        service.workdirBookmarkData = grant.bookmark
        #expect(service.downloadBlocker == .account)
        service.username = "someone"
        #expect(service.downloadBlocker == nil)
        service.noteOperationReportedLoginRequired(generation: service.accountGeneration)
        #expect(service.downloadBlocker == .session)
    }

    @Test("Confirmation needs a session proven this launch, not one nobody has refuted yet")
    func confirmationNeedsAGreenSession() throws {
        let service = try makeService()
        let grant = try resolvableBookmark()
        defer { try? FileManager.default.removeItem(at: grant.directory) }
        configureAllGreen(service, bookmark: grant.bookmark)
        service.setProbe(.cachedLogin, status: .notRun)
        #expect(service.isDownloadReady)
        #expect(!service.isDownloadConfirmed)
        service.noteSuccessfulSteamOperation(generation: service.accountGeneration)
        #expect(service.isDownloadConfirmed)
    }

    @Test("An untested session after relaunch can attempt a cached download")
    func unknownSessionDoesNotMeanLoggedOut() throws {
        let service = try makeService()
        let grant = try resolvableBookmark()
        defer { try? FileManager.default.removeItem(at: grant.directory) }
        configureAllGreen(service, bookmark: grant.bookmark)
        service.setProbe(.cachedLogin, status: .notRun)
        #expect(service.downloadBlocker == nil)
        #expect(!service.isGreen(.cachedLogin))
        service.noteSuccessfulSteamOperation(generation: service.accountGeneration)
        #expect(service.isGreen(.cachedLogin))
    }

    @Test("An operation reporting login-required demotes the green probe")
    func loginRequiredDemotesCachedLogin() throws {
        let service = try makeService()
        let grant = try resolvableBookmark()
        defer { try? FileManager.default.removeItem(at: grant.directory) }
        configureAllGreen(service, bookmark: grant.bookmark)
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
        let grant = try resolvableBookmark()
        defer { try? FileManager.default.removeItem(at: grant.directory) }
        configureAllGreen(service, bookmark: grant.bookmark)
        let inFlight = service.accountGeneration

        service.forgetSignedInSession()

        #expect(service.username == "someone")
        #expect(service.cachedLoginVerdict == nil)
        #expect(!service.isGreen(.cachedLogin))

        service.noteSuccessfulSteamOperation(generation: inFlight)
        #expect(!service.isGreen(.cachedLogin))

        service.noteSuccessfulSteamOperation(generation: service.accountGeneration)
        #expect(service.isGreen(.cachedLogin))
    }

    @Test("A transient network failure reddens the probe but does not block downloads")
    func transientFailureDoesNotBlockDownloads() throws {
        let service = try makeService()
        let grant = try resolvableBookmark()
        defer { try? FileManager.default.removeItem(at: grant.directory) }
        configureAllGreen(service, bookmark: grant.bookmark)

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
        let grant = try resolvableBookmark()
        defer { try? FileManager.default.removeItem(at: grant.directory) }
        configureAllGreen(service, bookmark: grant.bookmark)

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
        let grant = try resolvableBookmark()
        defer { try? FileManager.default.removeItem(at: grant.directory) }
        configureAllGreen(service, bookmark: grant.bookmark)
        service.setProbe(.cachedLogin, status: .notRun)
        let stale = service.accountGeneration
        try service.setUsername("bob")

        service.noteSuccessfulSteamOperation(generation: stale)
        #expect(!service.isGreen(.cachedLogin))
        service.noteOperationReportedLoginRequired(generation: stale)
        #expect(service.downloadBlocker == nil)

        service.noteSuccessfulSteamOperation(generation: service.accountGeneration)
        #expect(service.isGreen(.cachedLogin))
        service.noteOperationReportedLoginRequired(generation: service.accountGeneration)
        #expect(service.downloadBlocker != nil)
    }

    /// `redIdentityProbeBlocksDownloads` is the control: it proves a red probe *can* block,
    /// so a pass here is not just "nothing blocks anything".
    @Test("Red Workshop-wide diagnostics never block downloads")
    func advisoryProbesNeverBlockDownloads() throws {
        let service = try makeService()
        let grant = try resolvableBookmark()
        defer { try? FileManager.default.removeItem(at: grant.directory) }
        configureAllGreen(service, bookmark: grant.bookmark)

        for kind in [DoctorProbeKind.workshopContent, .sceneResources, .connector] {
            service.setProbe(kind, status: .red(message: "failing", command: nil))
            #expect(
                service.downloadBlocker == nil,
                Comment(rawValue: "\(kind.rawValue) reached downloadBlocker; it is advisory and must not gate")
            )
            #expect(kind.isAdvisory)
        }
    }

    @Test("A finished download is authorized by containment, not by the reported path")
    func downloadedItemDirectoryIsRevalidated() async throws {
        let doctor = try makeService()
        let fm = FileManager.default
        let root = fm.temporaryDirectory
            .appendingPathComponent("DownloadContainment-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: root) }
        let steamRoot = root.appendingPathComponent("Steam", isDirectory: true)
        let content = steamRoot
            .appendingPathComponent("steamapps/workshop/content/431960", isDirectory: true)
        let outside = root.appendingPathComponent("outside", isDirectory: true)
        try fm.createDirectory(at: content, withIntermediateDirectories: true)
        try fm.createDirectory(at: outside, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: outside.appendingPathComponent("project.json"))

        let item = content.appendingPathComponent("100", isDirectory: true)
        try fm.createDirectory(at: item, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: item.appendingPathComponent("project.json"))

        #expect(
            await doctor.authorizedDownloadedItemDirectory(workshopID: "100", steamRoot: steamRoot)?.path
                == item.resolvingSymlinksInPath().path
        )

        try fm.removeItem(at: item)
        try fm.createSymbolicLink(at: item, withDestinationURL: outside)
        #expect(await doctor.authorizedDownloadedItemDirectory(workshopID: "100", steamRoot: steamRoot) == nil)

        #expect(await doctor.authorizedDownloadedItemDirectory(workshopID: "200", steamRoot: steamRoot) == nil)
    }

    @Test("Slow inventory stays off MainActor and obsolete downloads never adopt", .timeLimit(.minutes(1)), arguments: AdoptionMutation.allCases, AdoptionInventoryPhase.allCases)
    fileprivate func slowInventoryDoesNotAdoptObsoleteDownload(mutation: AdoptionMutation, phase: AdoptionInventoryPhase) async throws {
        let fixture = try AdoptionLibraryFixture()
        defer { fixture.discard() }
        let inventory = BlockingAdoptionInventory(phase: phase)
        defer { inventory.release() }
        let doctor = SteamCMDDoctorService(
            defaults: fixture.suite.defaults,
            workshopFileInventory: inventory,
            operationCoordinator: SteamCMDDoctorOperationCoordinator(),
            downloadOperation: { @Sendable item, account, library, _ in
                #expect(item == "100")
                #expect(account == "someone")
                #expect(library == fixture.steamRoot.resolvingSymlinksInPath().standardizedFileURL.path(percentEncoded: false))
                return SteamWorkshopDownloadResult(
                    outcome: .downloaded, itemPath: "/untrusted/reported-path", diagnosticTail: "",
                    executedBinaryPath: "/tmp/fixture-execution-receipt"
                )
            }
        )
        configureAllGreen(doctor, bookmark: fixture.bookmark)
        doctor.lastBinarySHA256 = "fixture-sha"
        let callbacks = AdoptionCallbackLog()
        let task = Task {
            await doctor.downloadWorkshopItem(100) { @Sendable url in
                callbacks.paths.append(url.path(percentEncoded: false))
                return url.path(percentEncoded: false)
            }
        }
        await waitForInventory { inventory.hasStarted }
        #expect(inventory.hasStarted)
        #expect(!inventory.hasFinished, "MainActor only continued after inventory timed out")
        #expect(!inventory.ranOnMainThread)

        switch mutation {
        case .unchanged: break
        case .cancelled: task.cancel()
        case .accountChanged: try doctor.setUsername("bob")
        case .accountChangedBack:
            try doctor.setUsername("bob")
            try doctor.setUsername("someone")
        case .libraryChanged: doctor.workdirBookmarkData = fixture.otherBookmark
        case .libraryChangedBack:
            doctor.workdirBookmarkData = fixture.otherBookmark
            doctor.workdirBookmarkData = fixture.bookmark
        case .symlinkSwap:
            try FileManager.default.removeItem(at: fixture.item)
            try FileManager.default.createSymbolicLink(at: fixture.item, withDestinationURL: fixture.outside)
        }
        inventory.release()
        let result = await task.value
        if mutation == .unchanged {
            #expect(callbacks.paths == [fixture.item.resolvingSymlinksInPath().path(percentEncoded: false)])
            guard case .imported = result else {
                Issue.record("unchanged authorized content was not adopted")
                return
            }
        } else {
            #expect(callbacks.paths.isEmpty)
            guard case .failed = result else {
                Issue.record("obsolete or replaced content was adopted")
                return
            }
        }
        #expect(doctor.lastExecutedBinaryPath == "/tmp/fixture-execution-receipt")
    }

    @Test("A connector reply from a previous binding does not adopt", .timeLimit(.minutes(1)), arguments: [false, true])
    func lateConnectorReplyCannotAdoptChangedBinding(changeAccount: Bool) async throws {
        let fixture = try AdoptionLibraryFixture()
        defer { fixture.discard() }
        let reply = AdoptionReplyGate()
        defer { Task { await reply.release() } }
        let doctor = SteamCMDDoctorService(
            defaults: fixture.suite.defaults,
            operationCoordinator: SteamCMDDoctorOperationCoordinator(),
            downloadOperation: { @Sendable _, _, _, _ in await reply.wait() }
        )
        configureAllGreen(doctor, bookmark: fixture.bookmark)
        doctor.lastBinarySHA256 = "fixture-sha"
        let callbacks = AdoptionCallbackLog()
        let task = Task {
            await doctor.downloadWorkshopItem(100) { @Sendable url in
                callbacks.paths.append(url.path(percentEncoded: false))
                return url.path(percentEncoded: false)
            }
        }
        await waitForInventory { await reply.hasStarted }
        #expect(await reply.hasStarted)
        if changeAccount {
            try doctor.setUsername("bob")
            try doctor.setUsername("someone")
        } else {
            doctor.workdirBookmarkData = fixture.otherBookmark
            doctor.workdirBookmarkData = fixture.bookmark
        }
        await reply.release()
        let result = await task.value
        #expect(callbacks.paths.isEmpty)
        guard case .failed = result else {
            Issue.record("a late connector reply adopted content after the binding changed")
            return
        }
        #expect(doctor.lastExecutedBinaryPath == "/tmp/fixture-execution-receipt")
    }

    private func waitForInventory(_ hasStarted: () async -> Bool) async {
        for _ in 0 ..< 200 {
            if await hasStarted() {
                return
            }
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    /// Outside the app container, where only a sandbox extension can open the folder.
    private static let sharedLibrary = URL(fileURLWithPath: "/private/tmp/LoomscreenUnscopedLibrary", isDirectory: true)

    private func makeService(resolvingTo url: URL, scoped: Bool, function: String = #function) throws -> SteamCMDDoctorService {
        let scratch = try TestScratch.defaultsSuite(prefix: "LiveWallpaperTests.DownloadReadiness", function: function)
        let resolver = SecurityScopedBookmarkResolver(
            resolveScoped: { _ in
                guard scoped else { throw CocoaError(.fileReadNoPermission) }
                return (url, false)
            },
            resolveUnscoped: { _ in (url, false) },
            refreshData: { _ in Data() }
        )
        return SteamCMDDoctorService(defaults: scratch.defaults, bookmarkResolver: resolver)
    }

    @Test("A library grant that only resolves unscoped is a broken grant, not a ready library")
    func unscopedFallbackBlocksDownloads() throws {
        let service = try makeService(resolvingTo: Self.sharedLibrary, scoped: false)
        configureAllGreen(service, bookmark: Data([0x01]))

        #expect(throws: SteamCMDDoctorError.self) { _ = try service.resolveWorkdirURL() }

        #expect(service.workdirResolutionFailed)
        #expect(!service.isLibraryReady)
        #expect(service.libraryStepState == .attention)
        #expect(service.downloadBlocker == .library)
        #expect(!service.isDownloadReady)
    }

    @Test("A broken library grant scans nothing and is marked broken", .timeLimit(.minutes(1)))
    func unscopedFallbackScansNothing() async throws {
        let service = try makeService(resolvingTo: Self.sharedLibrary, scoped: false)
        configureAllGreen(service, bookmark: Data([0x01]))
        service.workdirResolutionFailed = false
        var scanned: [URL] = []

        await service.enumerateDownloadedItemFolders { scanned.append($0) }

        #expect(scanned.isEmpty)
        #expect(service.workdirResolutionFailed)
        #expect(service.downloadBlocker == .library)
    }

    @Test("A scoped library grant is ready as before")
    func scopedGrantIsReady() throws {
        let grant = try resolvableBookmark()
        defer { try? FileManager.default.removeItem(at: grant.directory) }
        let service = try makeService(resolvingTo: grant.directory, scoped: true)
        configureAllGreen(service, bookmark: grant.bookmark)

        #expect(try service.resolveWorkdirURL().path == grant.directory.resolvingSymlinksInPath().standardizedFileURL.path)
        #expect(!service.workdirResolutionFailed)
        #expect(service.isLibraryReady)
        #expect(service.downloadBlocker == nil)
        #expect(service.isDownloadReady)
    }

    @Test("Everything green with a resolvable grant is ready")
    func allGreenResolvableIsReady() throws {
        let service = try makeService()
        let grant = try resolvableBookmark()
        defer { try? FileManager.default.removeItem(at: grant.directory) }
        configureAllGreen(service, bookmark: grant.bookmark)

        #expect(service.downloadBlocker == nil)
        #expect(service.isDownloadReady)
    }
}
private enum AdoptionMutation: String, CaseIterable, Sendable {
    case unchanged, cancelled, accountChanged, accountChangedBack, libraryChanged, libraryChangedBack, symlinkSwap
}

private enum AdoptionInventoryPhase: CaseIterable, Sendable {
    case enumeration, revalidation
}

private final class BlockingAdoptionInventory: SteamCMDWorkshopFileInventoryServing {
    private struct State {
        var started = false
        var finished = false
        var ranOnMainThread = false
    }

    private let state = OSAllocatedUnfairLock(initialState: State())
    private let semaphore = DispatchSemaphore(value: 0)
    private let base: any SteamCMDWorkshopFileInventoryServing = SteamCMDWorkshopFileInventory()
    private let phase: AdoptionInventoryPhase

    init(phase: AdoptionInventoryPhase) {
        self.phase = phase
    }

    var hasStarted: Bool {
        state.withLock { $0.started }
    }

    var hasFinished: Bool {
        state.withLock { $0.finished }
    }

    var ranOnMainThread: Bool {
        state.withLock { $0.ranOnMainThread }
    }

    private func park() {
        state.withLock {
            $0.started = true
            $0.ranOnMainThread = Thread.isMainThread
        }
        // The synchronous negative control must fail instead of hanging the test host.
        _ = semaphore.wait(timeout: .now() + 2)
        state.withLock { $0.finished = true }
    }

    func projectFolders(under steamRoot: URL, anchoredTo trustAnchor: URL, skipping seen: Set<String>) -> [SteamCMDValidatedWorkshopItem] {
        if phase == .enumeration {
            park()
        }
        return base.projectFolders(under: steamRoot, anchoredTo: trustAnchor, skipping: seen)
    }

    func revalidatedURL(for candidate: SteamCMDValidatedWorkshopItem, requiringProjectJSON: Bool) -> URL? {
        if phase == .revalidation {
            park()
        }
        return base.revalidatedURL(for: candidate, requiringProjectJSON: requiringProjectJSON)
    }

    func release() {
        semaphore.signal()
    }
}

@MainActor
private struct AdoptionLibraryFixture {
    let root: URL
    let steamRoot: URL
    let item: URL
    let outside: URL
    let bookmark: Data
    let otherBookmark: Data
    let suite: TestScratch.DefaultsSuite

    init() throws {
        let fm = FileManager.default
        root = fm.temporaryDirectory.appendingPathComponent("AdoptionInventory-\(UUID())")
        steamRoot = root.appendingPathComponent("Steam")
        item = steamRoot.appendingPathComponent("steamapps/workshop/content/431960/100")
        outside = root.appendingPathComponent("outside")
        let otherRoot = root.appendingPathComponent("OtherSteam")
        try fm.createDirectory(at: item, withIntermediateDirectories: true)
        try fm.createDirectory(at: outside, withIntermediateDirectories: true)
        try fm.createDirectory(at: otherRoot, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: item.appendingPathComponent("project.json"))
        try Data("{}".utf8).write(to: outside.appendingPathComponent("project.json"))
        bookmark = try steamRoot.bookmarkData()
        otherBookmark = try otherRoot.bookmarkData()
        suite = try TestScratch.defaultsSuite(prefix: "LiveWallpaperTests.DownloadAdoption")
    }

    func discard() {
        suite.discard()
        try? FileManager.default.removeItem(at: root)
    }
}

@MainActor
private final class AdoptionCallbackLog {
    var paths: [String] = []
}

private actor AdoptionReplyGate {
    private(set) var hasStarted = false
    private var isReleased = false
    private var continuation: CheckedContinuation<SteamWorkshopDownloadResult, Never>?

    func wait() async -> SteamWorkshopDownloadResult {
        hasStarted = true
        if isReleased {
            return Self.reply
        }
        return await withCheckedContinuation { continuation = $0 }
    }

    func release() {
        isReleased = true
        continuation?.resume(returning: Self.reply)
        continuation = nil
    }

    private static var reply: SteamWorkshopDownloadResult {
        SteamWorkshopDownloadResult(
            outcome: .downloaded, itemPath: "/untrusted/reported-path", diagnosticTail: "",
            executedBinaryPath: "/tmp/fixture-execution-receipt"
        )
    }
}
#endif
