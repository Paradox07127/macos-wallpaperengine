import CryptoKit
import Foundation
import Testing
@testable import LiveWallpaper

/// Isolated defaults so a test never reads or writes the real install record.
private func scratchDefaults() -> UserDefaults {
    let suite = "steamcmd-managed-\(UUID().uuidString)"
    guard let defaults = UserDefaults(suiteName: suite) else {
        fatalError("Could not create a scratch defaults suite")
    }
    defaults.removePersistentDomain(forName: suite)
    return defaults
}

@MainActor
private func storeRecord(
    _ record: SteamCMDManagedInstallCoordinator.ManagedInstallRecord,
    in defaults: UserDefaults
) throws {
    defaults.set(
        try JSONEncoder().encode(record),
        forKey: SteamCMDManagedInstallCoordinator.managedInstallDefaultsKey
    )
}

@MainActor
@Suite("Managed install record")
struct SteamCMDManagedInstallRecordTests {
    private let record = SteamCMDManagedInstallCoordinator.ManagedInstallRecord(
        canonicalPath: "/Users/probe/Library/Application Support/Loomscreen/SteamCMD/MacOS/steamcmd",
        bootstrapSHA256: SteamCMDBootstrapPackage.sha256
    )

    /// Never reached: the tests below must not perform a real removal.
    private func refusingRemoval() -> SteamCMDManagedRemovalResult? {
        Issue.record("A test tried to remove a real managed install")
        return nil
    }

    @Test("Control: with nothing stored, there is no install to offer removing")
    func absentRecordReadsAsNil() {
        let coordinator = SteamCMDManagedInstallCoordinator(
            defaults: scratchDefaults(), remove: { nil }
        )
        #expect(coordinator.managedInstall == nil)
        #expect(coordinator.status == .idle)
    }

    @Test("A record written by an earlier launch is visible to this one")
    func storedRecordLoadsAtInit() throws {
        let defaults = scratchDefaults()
        try storeRecord(record, in: defaults)

        let coordinator = SteamCMDManagedInstallCoordinator(
            defaults: defaults, remove: { self.refusingRemoval() }
        )
        #expect(coordinator.managedInstall == record)
    }

    @Test("Forgetting clears the stored record and the value the UI reads")
    func forgetClearsBothTheDefaultsAndTheMirror() async throws {
        let defaults = scratchDefaults()
        try storeRecord(record, in: defaults)
        let coordinator = SteamCMDManagedInstallCoordinator(
            defaults: defaults,
            remove: { SteamCMDManagedRemovalResult(outcome: .removed, failureReason: nil) }
        )
        #expect(coordinator.managedInstall != nil)

        #expect(await coordinator.forget())

        // Both, not just the defaults: the menu offers "Remove" off the
        // in-memory value, so a stale mirror keeps offering to delete something
        // that is already gone.
        #expect(coordinator.managedInstall == nil)
        #expect(defaults.data(
            forKey: SteamCMDManagedInstallCoordinator.managedInstallDefaultsKey
        ) == nil)
        #expect(SteamCMDManagedInstallCoordinator.recordedInstall(defaults: defaults) == nil)
    }

    @Test("Nothing to remove is success, not an error the user must act on")
    func notInstalledCountsAsRemoved() async {
        let coordinator = SteamCMDManagedInstallCoordinator(
            defaults: scratchDefaults(),
            remove: { SteamCMDManagedRemovalResult(outcome: .notInstalled, failureReason: nil) }
        )
        #expect(await coordinator.forget())
    }

    @Test("A refused removal is reported as failure, and the record stays put")
    func refusedRemovalReportsFailure() async throws {
        let defaults = scratchDefaults()
        try storeRecord(record, in: defaults)
        let coordinator = SteamCMDManagedInstallCoordinator(
            defaults: defaults,
            remove: { SteamCMDManagedRemovalResult(outcome: .refused, failureReason: "nope") }
        )

        #expect(await coordinator.forget() == false)
        // The files are still there. Dropping the record here would take the
        // Remove command out of the menu — it is shown off `managedInstall` —
        // so a delete that did not happen would also become un-retryable.
        #expect(coordinator.managedInstall == record)
        #expect(SteamCMDManagedInstallCoordinator.recordedInstall(defaults: defaults) == record)
    }

    @Test("An unreachable connector is a failure, not a silent success")
    func unreachableConnectorReportsFailure() async throws {
        let defaults = scratchDefaults()
        try storeRecord(record, in: defaults)
        let coordinator = SteamCMDManagedInstallCoordinator(
            defaults: defaults, remove: { nil }
        )
        #expect(await coordinator.forget() == false)
        #expect(coordinator.managedInstall == record)
    }
}

/// The bytes the digest gate is meant to accept. Built to the pinned length so
/// a size check alone cannot be what makes these tests pass.
private func bootstrapSizedData(seed: UInt8) -> Data {
    Data(repeating: seed, count: SteamCMDBootstrapPackage.byteCount)
}

private func sha256Hex(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}

@Suite("SteamCMD bootstrap download gate")
struct SteamCMDBootstrapDownloaderTests {
    private func downloader(returning data: Data, status: Int = 200) -> SteamCMDBootstrapDownloader {
        SteamCMDBootstrapDownloader(fetch: { url in
            (data, HTTPURLResponse(
                url: url, statusCode: status, httpVersion: nil, headerFields: nil
            )!)
        })
    }

    private func scratchDestination() -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("steamcmd-probe-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("steamcmd_osx.tar.gz")
    }

    @Test("A short response is rejected before anything is stored")
    func rejectsShortResponse() async {
        let destination = scratchDestination()
        await #expect(throws: SteamCMDBootstrapDownloader.DownloadError.self) {
            _ = try await downloader(returning: Data("nope".utf8)).download(to: destination)
        }
        #expect(!FileManager.default.fileExists(atPath: destination.path))
    }

    @Test("Right length, wrong bytes is still rejected")
    func rejectsCorrectLengthWrongDigest() async {
        let destination = scratchDestination()
        let payload = bootstrapSizedData(seed: 0x41)
        // Guard the guard: if this ever equalled the pinned digest the test
        // below would be proving nothing.
        #expect(sha256Hex(payload) != SteamCMDBootstrapPackage.sha256)

        await #expect(throws: SteamCMDBootstrapDownloader.DownloadError.digestMismatch) {
            _ = try await downloader(returning: payload).download(to: destination)
        }
        #expect(!FileManager.default.fileExists(atPath: destination.path))
    }

    @Test("A single flipped byte fails the digest gate")
    func rejectsSingleFlippedByte() {
        var payload = bootstrapSizedData(seed: 0x00)
        payload[0] = 0x01
        #expect(SteamCMDBootstrapDownloader.verify(payload) == .digestMismatch)
    }

    @Test("An HTTP error is reported as such, not as a corrupt archive")
    func reportsHTTPStatusDistinctly() async {
        await #expect(throws: SteamCMDBootstrapDownloader.DownloadError.httpStatus(503)) {
            _ = try await downloader(returning: Data(), status: 503)
                .download(to: scratchDestination())
        }
    }

    @Test("Consent terms quote the installed size, not just the bootstrap archive")
    func termsDoNotUnderstateTheDownload() {
        let terms = SteamCMDBootstrapDownloader.DownloadTerms.current
        #expect(terms.archiveBytes == SteamCMDBootstrapPackage.byteCount)
        // The archive is a bootstrapper; quoting 2.4 MB as the cost would be a
        // lie by a factor of ~35.
        #expect(terms.installedBytesApproximate > terms.archiveBytes * 10)
        #expect(terms.sourceHost.hasSuffix("akamaihd.net"))
    }
}

@Suite("SteamCMD managed install containment")
struct SteamCMDManagedInstallContainmentTests {
    private let home = URL(fileURLWithPath: "/Users/probe")

    private func contained(_ path: String) -> Bool {
        if case .success = SteamCMDManagedInstaller.containedInstallRoot(path, home: home) {
            return true
        }
        return false
    }

    private var canonical: String {
        SteamCMDManagedInstaller.normalisedPath(
            SteamCMDManagedInstaller.canonicalInstallRoot(home: home)
        )
    }

    @Test("Control: the connector's own canonical path is accepted")
    func acceptsCanonicalPath() {
        // Without this the whole suite would pass on an implementation that
        // refuses everything.
        #expect(contained(canonical))
    }

    @Test("The install root is outside every app container")
    func installRootIsOutsideContainers() {
        // The container is writable by the sandboxed app, which makes every
        // check here check-then-use: the leaf can become a symlink between the
        // lstat walk and `tar -C`.
        #expect(!canonical.contains("/Library/Containers/"))
        #expect(canonical == "/Users/probe/Library/Application Support/Loomscreen/SteamCMD")
        #expect(!contained("/Users/probe/Library/Containers/com.loomscreen.pro/Data/Library/Application Support/SteamCMD"))
    }

    @Test("Another app's container is refused")
    func refusesForeignContainer() {
        // The connector is unsandboxed; accepting any path under Containers
        // would let it write through other apps' isolation.
        #expect(!contained("/Users/probe/Library/Containers/com.apple.Safari/Data/SteamCMD"))
    }

    @Test("Neighbouring paths in Application Support are refused")
    func refusesOutsidePaths() {
        #expect(!contained("/tmp/SteamCMD"))
        #expect(!contained("/Users/probe/Library/Application Support/SteamCMD"))
        #expect(!contained("/Users/probe/Library/Application Support/Loomscreen"))
        #expect(!contained("/Users/probe/Library/Application Support/Loomscreen/SteamCMD/../../Steam"))
        #expect(!contained("/Applications"))
    }

    @Test("A sibling directory sharing the prefix is not inside it")
    func refusesPrefixLookalike() {
        #expect(!contained("/Users/probe/Library/Application Support/LoomscreenEvil/SteamCMD"))
    }

    @Test("A symlink anywhere along the install path is refused")
    func refusesSymlinkedPathComponent() throws {
        // Real filesystem, because the bug this guards is precisely that
        // standardizedFileURL resolves ".." but never follows links.
        // Resolved first: `/var` is itself a symlink to `/private/var`, so an
        // unresolved temp root makes the walk trip on that instead of on the
        // link this test plants.
        let sandbox = URL(fileURLWithPath: NSTemporaryDirectory())
            .resolvingSymlinksInPath()
            .appendingPathComponent("symprobe-\(UUID().uuidString)", isDirectory: true)
        let support = sandbox.appendingPathComponent(
            "Library/Application Support/Loomscreen", isDirectory: true
        )
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: sandbox) }

        let elsewhere = sandbox.appendingPathComponent("elsewhere", isDirectory: true)
        try FileManager.default.createDirectory(at: elsewhere, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            at: support.appendingPathComponent("SteamCMD", isDirectory: true),
            withDestinationURL: elsewhere
        )

        let requested = SteamCMDManagedInstaller.normalisedPath(
            SteamCMDManagedInstaller.canonicalInstallRoot(home: sandbox)
        )
        // Control: the path is lexically exactly right — only the lstat walk
        // separates it from the accepted case.
        #expect(requested.hasSuffix("Application Support/Loomscreen/SteamCMD"))

        guard case .failure(let result) = SteamCMDManagedInstaller.containedInstallRoot(
            requested, home: sandbox
        ) else {
            Issue.record("A symlinked install root must be refused")
            return
        }
        #expect(result.outcome == .extractionFailed)
    }

    @Test("Payload lands one level down so SteamCMD's own symlink stays contained")
    func payloadIsNested() {
        let root = SteamCMDManagedInstaller.canonicalInstallRoot(home: home)
        let payload = SteamCMDManagedInstaller.payloadDirectory(installRoot: root)
        #expect(payload.lastPathComponent == "MacOS")
        #expect(payload.deletingLastPathComponent().path == root.path)
    }
}

@Suite("SteamCMD managed install archive gate")
struct SteamCMDManagedInstallTarballTests {
    /// Real bytes of Valve's pinned bootstrap archive, if this machine has a
    /// Homebrew SteamCMD cask whose download cache still holds it. Used only for
    /// the positive control; absent on CI, where that one test is skipped rather
    /// than faked.
    private static func pinnedArchive() -> Data? {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)
        for base in caches + [URL(fileURLWithPath: "/Users/\(NSUserName())/Library/Caches")] {
            let downloads = base.appendingPathComponent("Homebrew/downloads", isDirectory: true)
            guard let entries = try? FileManager.default.contentsOfDirectory(
                at: downloads, includingPropertiesForKeys: nil
            ) else { continue }
            for entry in entries where entry.lastPathComponent.contains("steamcmd_osx") {
                guard let data = try? Data(contentsOf: entry),
                      SteamCMDBootstrapDownloader.verify(data) == nil else { continue }
                return data
            }
        }
        return nil
    }

    private func staged(_ data: Data) -> (tarball: String, staging: URL) {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("tarball-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let file = root.appendingPathComponent("in.tar.gz")
        try? data.write(to: file)
        return (file.path, root.appendingPathComponent("staging", isDirectory: true))
    }

    @Test("Control: a matching archive passes and is copied into connector staging")
    func acceptsMatchingArchive() throws {
        // Deterministic fixture rather than Valve's real 2.4 MB archive: the
        // previous control silently returned wherever no Homebrew copy existed,
        // so an implementation that rejected every archive stayed green there.
        let payload = Data("loomscreen-deterministic-archive-fixture".utf8)
        let expectation = SteamCMDManagedInstaller.ArchiveExpectation(
            sha256: sha256Hex(payload), byteCount: payload.count
        )
        let (path, staging) = staged(payload)
        defer { try? FileManager.default.removeItem(at: staging.deletingLastPathComponent()) }

        guard case .success(let copy) = SteamCMDManagedInstaller.stageAndVerifyTarball(
            at: path, stagingRoot: staging, expected: expectation
        ) else {
            Issue.record("An archive matching its expectation must be accepted")
            return
        }
        #expect(copy.path.hasPrefix(staging.path))
        #expect(try Data(contentsOf: copy) == payload)
    }

    @Test("The shipping expectation is still Valve's pinned archive")
    func pinnedExpectationIsUnchanged() {
        // The injectable expectation exists for the control above; it must not
        // become a way for the real path to accept something else.
        #expect(SteamCMDManagedInstaller.ArchiveExpectation.pinned.sha256
            == SteamCMDBootstrapPackage.sha256)
        #expect(SteamCMDManagedInstaller.ArchiveExpectation.pinned.byteCount
            == SteamCMDBootstrapPackage.byteCount)
    }

    @Test("The connector re-hashes rather than trusting the app's verdict")
    func rejectsTamperedArchive() {
        let (path, staging) = staged(bootstrapSizedData(seed: 0x42))
        defer { try? FileManager.default.removeItem(at: staging.deletingLastPathComponent()) }

        guard case .failure(let result) = SteamCMDManagedInstaller.stageAndVerifyTarball(
            at: path, stagingRoot: staging
        ) else {
            Issue.record("A correctly sized but wrong-digest archive must be refused")
            return
        }
        #expect(result.outcome == .tarballRejected)
    }

    @Test("A wrong-length archive is refused with a size-specific reason")
    func rejectsWrongLength() {
        let (path, staging) = staged(Data("too short".utf8))
        defer { try? FileManager.default.removeItem(at: staging.deletingLastPathComponent()) }

        guard case .failure(let result) = SteamCMDManagedInstaller.stageAndVerifyTarball(
            at: path, stagingRoot: staging
        ) else {
            Issue.record("A short archive must be refused")
            return
        }
        #expect(result.outcome == .tarballRejected)
        #expect(result.failureReason?.contains("bytes") == true)
    }

    @Test("An oversized archive is refused mid-stream, not buffered whole")
    func rejectsOversizedArchive() {
        let (path, staging) = staged(
            Data(repeating: 0, count: SteamCMDBootstrapPackage.byteCount + 4096)
        )
        defer { try? FileManager.default.removeItem(at: staging.deletingLastPathComponent()) }

        guard case .failure(let result) = SteamCMDManagedInstaller.stageAndVerifyTarball(
            at: path, stagingRoot: staging
        ) else {
            Issue.record("An oversized archive must be refused")
            return
        }
        #expect(result.outcome == .tarballRejected)
        #expect(result.failureReason?.contains("larger") == true)
    }

    @Test("A symlinked archive path is refused instead of followed")
    func rejectsSymlinkedArchivePath() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("symarchive-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let real = root.appendingPathComponent("real.tar.gz")
        try bootstrapSizedData(seed: 0x11).write(to: real)
        let link = root.appendingPathComponent("link.tar.gz")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)

        guard case .failure(let result) = SteamCMDManagedInstaller.stageAndVerifyTarball(
            at: link.path, stagingRoot: root.appendingPathComponent("staging", isDirectory: true)
        ) else {
            Issue.record("A symlinked archive path must be refused (O_NOFOLLOW)")
            return
        }
        #expect(result.outcome == .tarballRejected)
    }

    @Test("A missing archive is refused, not treated as empty")
    func rejectsMissingArchive() {
        guard case .failure(let result) = SteamCMDManagedInstaller.stageAndVerifyTarball(
            at: "/nonexistent/steamcmd_osx.tar.gz",
            stagingRoot: URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("missing-\(UUID().uuidString)", isDirectory: true)
        ) else {
            Issue.record("A missing archive must be refused")
            return
        }
        #expect(result.outcome == .tarballRejected)
    }
}

@Suite("SteamCMD managed install symlink containment")
struct SteamCMDManagedInstallSymlinkTests {
    @Test("A symlink escaping the payload is detected")
    func detectsEscapingSymlink() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("escape-\(UUID().uuidString)", isDirectory: true)
        let payload = root.appendingPathComponent("MacOS", isDirectory: true)
        try FileManager.default.createDirectory(at: payload, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        // Control: a clean payload reports nothing.
        try Data("x".utf8).write(to: payload.appendingPathComponent("steamcmd"))
        #expect(SteamCMDManagedInstaller.firstEscapingSymlink(under: payload) == nil)

        try FileManager.default.createSymbolicLink(
            at: payload.appendingPathComponent("escape"),
            withDestinationURL: URL(fileURLWithPath: "/etc")
        )
        #expect(SteamCMDManagedInstaller.firstEscapingSymlink(under: payload) != nil)
    }

    @Test("A symlink pointing inside the payload is allowed")
    func allowsInternalSymlink() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("internal-\(UUID().uuidString)", isDirectory: true)
        let payload = root.appendingPathComponent("MacOS", isDirectory: true)
        try FileManager.default.createDirectory(at: payload, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let target = payload.appendingPathComponent("real")
        try Data("x".utf8).write(to: target)
        try FileManager.default.createSymbolicLink(
            at: payload.appendingPathComponent("alias"), withDestinationURL: target
        )
        // SteamCMD's own layout uses internal links; rejecting those would
        // break every install.
        #expect(SteamCMDManagedInstaller.firstEscapingSymlink(under: payload) == nil)
    }

    @Test("An executable resolving outside the payload is refused")
    func refusesBinaryOutsidePayload() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("outside-\(UUID().uuidString)", isDirectory: true)
        let payload = root.appendingPathComponent("MacOS", isDirectory: true)
        try FileManager.default.createDirectory(at: payload, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        // A wrapper whose STEAMEXE names an absolute path elsewhere is exactly
        // how a swapped archive would aim the signature check at some other
        // Valve-signed binary.
        let outside = root.appendingPathComponent("elsewhere", isDirectory: false)
        FileManager.default.createFile(
            atPath: outside.path,
            contents: Data([0xCF, 0xFA, 0xED, 0xFE] + Array(repeating: 0, count: 64)),
            attributes: [.posixPermissions: 0o755]
        )
        try "#!/bin/sh\nSTEAMEXE=\(outside.path)\n".write(
            to: payload.appendingPathComponent("steamcmd.sh"), atomically: true, encoding: .utf8
        )

        guard case .failure(let result) = SteamCMDManagedInstaller.locateBinary(in: payload) else {
            Issue.record("An executable outside the payload must be refused")
            return
        }
        #expect(result.outcome == .binaryNotFound)
    }
}

@Suite("SteamCMD managed install signature gate")
struct SteamCMDManagedInstallSignatureTests {
    private func spawnStub(
        verifyExit: Int32,
        describeOutput: String
    ) -> (String, [String], TimeInterval) -> (output: String, exitCode: Int32, timedOut: Bool) {
        { _, arguments, _ in
            if arguments.contains("--verify") {
                return ("", verifyExit, false)
            }
            return (describeOutput, 0, false)
        }
    }

    private let valveOutput = """
    Executable=/x/steamcmd
    Identifier=com.valvesoftware.steam
    TeamIdentifier=MXGJJ98X76
    Authority=Developer ID Application: Valve Corporation (MXGJJ98X76)
    """

    @Test("Valve's Developer ID signature is accepted")
    func acceptsValveSignature() {
        let outcome = SteamCMDManagedInstaller.verifySignature(
            binaryPath: "/x/steamcmd",
            spawn: spawnStub(verifyExit: 0, describeOutput: valveOutput)
        )
        guard case .success = outcome else {
            Issue.record("Valve's own signature must pass")
            return
        }
    }

    @Test("A valid signature from someone else is refused")
    func refusesForeignTeam() {
        let outcome = SteamCMDManagedInstaller.verifySignature(
            binaryPath: "/x/steamcmd",
            spawn: spawnStub(
                verifyExit: 0,
                describeOutput: "TeamIdentifier=ABCDE12345\nAuthority=Developer ID Application: Someone"
            )
        )
        guard case .failure(let result) = outcome else {
            Issue.record("A non-Valve team must be refused even with an intact signature")
            return
        }
        #expect(result.outcome == .signatureRejected)
        #expect(result.failureReason?.contains("MXGJJ98X76") == true)
    }

    @Test("A broken signature is refused before the team is even consulted")
    func refusesBrokenSignature() {
        let outcome = SteamCMDManagedInstaller.verifySignature(
            binaryPath: "/x/steamcmd",
            spawn: spawnStub(verifyExit: 1, describeOutput: valveOutput)
        )
        guard case .failure(let result) = outcome else {
            Issue.record("An invalid signature must be refused")
            return
        }
        #expect(result.outcome == .signatureRejected)
    }

    @Test("An ad-hoc signature carries no team and is refused")
    func refusesAdHocSignature() {
        // `codesign --verify` passes on ad-hoc signed binaries; only the absent
        // TeamIdentifier separates one from Valve's. This is exactly the case a
        // spctl-based gate would get wrong in the other direction.
        let outcome = SteamCMDManagedInstaller.verifySignature(
            binaryPath: "/x/steamcmd",
            spawn: spawnStub(verifyExit: 0, describeOutput: "Signature=adhoc\nIdentifier=steamcmd")
        )
        guard case .failure(let result) = outcome else {
            Issue.record("An ad-hoc signed binary must be refused")
            return
        }
        #expect(result.outcome == .signatureRejected)
    }
}

@Suite("Managed install unpack containment", .serialized)
struct SteamCMDManagedInstallUnpackTests {
    private func archive(containing entries: [(String, String)]) throws -> (URL, URL) {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("unpack-\(UUID().uuidString)", isDirectory: true)
        let source = root.appendingPathComponent("src", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        for (name, contents) in entries {
            try Data(contents.utf8).write(to: source.appendingPathComponent(name))
        }
        let tarball = root.appendingPathComponent("a.tar.gz")
        let tar = Process()
        tar.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        tar.arguments = ["-czf", tarball.path, "-C", source.path] + entries.map(\.0)
        try tar.run()
        tar.waitUntilExit()
        return (root, tarball)
    }

    private let spawn: (String, [String], TimeInterval) -> (output: String, exitCode: Int32, timedOut: Bool) = {
        executable, arguments, _ in
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do { try process.run() } catch { return (error.localizedDescription, -1, false) }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (String(decoding: data, as: UTF8.self), process.terminationStatus, false)
    }

    @Test("Control: a clean archive lands in the payload directory")
    func unpacksIntoPayload() throws {
        let (root, tarball) = try archive(containing: [("steamcmd.sh", "#!/bin/sh\n")])
        defer { try? FileManager.default.removeItem(at: root) }
        let installRoot = root.appendingPathComponent("install", isDirectory: true)

        guard case .success(let installed) = SteamCMDManagedInstaller.extract(
            stagedTarball: tarball, installRoot: installRoot, spawn: spawn
        ) else {
            Issue.record("A clean archive must unpack")
            return
        }
        #expect(installed.payload.lastPathComponent == "MacOS")
        #expect(FileManager.default.fileExists(
            atPath: installed.payload.appendingPathComponent("steamcmd.sh").path
        ))
        // Nothing was displaced, so there is nothing to roll back to.
        #expect(installed.retired == nil)
    }

    @Test("A reinstall keeps the previous tree until the caller commits")
    func retiredTreeSurvivesUntilCommit() throws {
        let (root, tarball) = try archive(containing: [("steamcmd.sh", "#!/bin/sh\n")])
        defer { try? FileManager.default.removeItem(at: root) }
        let installRoot = root.appendingPathComponent("install", isDirectory: true)
        let payload = SteamCMDManagedInstaller.payloadDirectory(installRoot: installRoot)
        try FileManager.default.createDirectory(at: payload, withIntermediateDirectories: true)
        try Data("old".utf8).write(to: payload.appendingPathComponent("marker.txt"))

        guard case .success(let installed) = SteamCMDManagedInstaller.extract(
            stagedTarball: tarball, installRoot: installRoot, spawn: spawn
        ) else {
            Issue.record("A clean archive must unpack over a previous install")
            return
        }
        // The post-extraction checks (`+quit`, re-verify) all run in the caller,
        // so the old tree has to still exist when extract returns.
        guard let retired = installed.retired else {
            Issue.record("A displaced install must be handed back for rollback")
            return
        }
        #expect(FileManager.default.fileExists(
            atPath: retired.appendingPathComponent("marker.txt").path
        ))

        SteamCMDManagedInstaller.commit(installed)
        #expect(!FileManager.default.fileExists(atPath: retired.path))
    }

    @Test("Rolling back restores the previous install and drops the new one")
    func rollBackRestoresPreviousInstall() throws {
        let (root, tarball) = try archive(containing: [("steamcmd.sh", "#!/bin/sh\n")])
        defer { try? FileManager.default.removeItem(at: root) }
        let installRoot = root.appendingPathComponent("install", isDirectory: true)
        let payload = SteamCMDManagedInstaller.payloadDirectory(installRoot: installRoot)
        try FileManager.default.createDirectory(at: payload, withIntermediateDirectories: true)
        try Data("old".utf8).write(to: payload.appendingPathComponent("marker.txt"))

        guard case .success(let installed) = SteamCMDManagedInstaller.extract(
            stagedTarball: tarball, installRoot: installRoot, spawn: spawn
        ) else {
            Issue.record("A clean archive must unpack over a previous install")
            return
        }
        SteamCMDManagedInstaller.rollBack(installed)

        // The working install the user already had is what must survive a
        // reinstall that fails its post-extraction checks.
        #expect(FileManager.default.fileExists(
            atPath: payload.appendingPathComponent("marker.txt").path
        ))
        #expect(!FileManager.default.fileExists(
            atPath: payload.appendingPathComponent("steamcmd.sh").path
        ))
    }

    @Test("Rolling back a first install leaves nothing behind")
    func rollBackOfFirstInstallRemovesPayload() throws {
        let (root, tarball) = try archive(containing: [("steamcmd.sh", "#!/bin/sh\n")])
        defer { try? FileManager.default.removeItem(at: root) }
        let installRoot = root.appendingPathComponent("install", isDirectory: true)

        guard case .success(let installed) = SteamCMDManagedInstaller.extract(
            stagedTarball: tarball, installRoot: installRoot, spawn: spawn
        ) else {
            Issue.record("A clean archive must unpack")
            return
        }
        SteamCMDManagedInstaller.rollBack(installed)

        // Nothing to restore, so the failed payload must not be left as the
        // thing `locateBinary` would find next time.
        #expect(!FileManager.default.fileExists(atPath: installed.payload.path))
    }

    @Test("A payload path pre-planted as a symlink is not written through")
    func doesNotWriteThroughPlantedPayloadSymlink() throws {
        let (root, tarball) = try archive(containing: [("steamcmd.sh", "#!/bin/sh\n")])
        defer { try? FileManager.default.removeItem(at: root) }
        let installRoot = root.appendingPathComponent("install", isDirectory: true)
        let victim = root.appendingPathComponent("victim", isDirectory: true)
        try FileManager.default.createDirectory(at: installRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: victim, withIntermediateDirectories: true)
        // Unpacking straight into the payload path would follow this link and
        // write into `victim`. Unpacking into a freshly created random name and
        // renaming into place cannot.
        try FileManager.default.createSymbolicLink(
            at: installRoot.appendingPathComponent("MacOS"), withDestinationURL: victim
        )

        _ = SteamCMDManagedInstaller.extract(
            stagedTarball: tarball, installRoot: installRoot, spawn: spawn
        )
        #expect(!FileManager.default.fileExists(
            atPath: victim.appendingPathComponent("steamcmd.sh").path
        ))
    }

    @Test("A previous install is replaced, not merged into")
    func replacesPreviousPayload() throws {
        let (root, tarball) = try archive(containing: [("steamcmd.sh", "#!/bin/sh\n")])
        defer { try? FileManager.default.removeItem(at: root) }
        let installRoot = root.appendingPathComponent("install", isDirectory: true)
        let payload = SteamCMDManagedInstaller.payloadDirectory(installRoot: installRoot)
        try FileManager.default.createDirectory(at: payload, withIntermediateDirectories: true)
        try Data("stale".utf8).write(to: payload.appendingPathComponent("leftover.txt"))

        _ = SteamCMDManagedInstaller.extract(
            stagedTarball: tarball, installRoot: installRoot, spawn: spawn
        )
        // A file the archive never mentions surviving would mean we unpacked
        // over the old tree instead of replacing it.
        #expect(!FileManager.default.fileExists(
            atPath: payload.appendingPathComponent("leftover.txt").path
        ))
        #expect(FileManager.default.fileExists(
            atPath: payload.appendingPathComponent("steamcmd.sh").path
        ))
    }
}

/// P1.4 — a managed install is **additive**. Every way it can fail must leave the
/// app exactly as capable as it was before the attempt: no record claiming an
/// install that isn't there, nothing bound to a path that cannot run, and the
/// user able to try again or fall back to a package-manager copy.
@MainActor
@Suite("Managed install fallback")
struct SteamCMDManagedInstallFallbackTests {

    private func coordinator(
        defaults: UserDefaults,
        download: @escaping (URL) async throws -> Void = { _ in },
        install: @escaping (String) async -> SteamCMDManagedInstallResult?
    ) -> SteamCMDManagedInstallCoordinator {
        SteamCMDManagedInstallCoordinator(
            downloadArchive: download,
            defaults: defaults,
            remove: { Issue.record("fallback tests must not remove anything"); return nil },
            performInstall: install
        )
    }

    private func failed(_ status: SteamCMDManagedInstallCoordinator.Status) -> String? {
        if case .failed(let reason) = status { return reason }
        return nil
    }

    @Test("Control: a clean run does record the install")
    func successRecords() async throws {
        // Without this the suite would pass against a coordinator that always
        // fails, which is the opposite of what the other cases are asserting.
        let defaults = scratchDefaults()
        let coordinator = coordinator(defaults: defaults) { _ in
            SteamCMDManagedInstallResult(
                outcome: .installed, canonicalPath: "/probe/steamcmd",
                sha256: "abc", failureReason: nil
            )
        }
        _ = await coordinator.install()
        #expect(coordinator.managedInstall?.canonicalPath == "/probe/steamcmd")
    }

    @Test("A download that never arrives records nothing")
    func downloadFailureLeavesNoRecord() async {
        let defaults = scratchDefaults()
        let coordinator = coordinator(
            defaults: defaults,
            download: { _ in throw SteamCMDBootstrapDownloader.DownloadError.digestMismatch },
            install: { _ in
                Issue.record("the connector must not be asked to install an archive we never got")
                return nil
            }
        )

        let status = await coordinator.install()
        #expect(failed(status) != nil)
        #expect(coordinator.managedInstall == nil)
        #expect(SteamCMDManagedInstallCoordinator.recordedInstall(defaults: defaults) == nil)
    }

    @Test("An unreachable connector records nothing and says so")
    func unreachableConnectorLeavesNoRecord() async {
        let defaults = scratchDefaults()
        let coordinator = coordinator(defaults: defaults) { _ in nil }

        let reason = failed(await coordinator.install())
        #expect(reason != nil)
        #expect(coordinator.managedInstall == nil)
        // A raw enum case name reaching the user would be both untranslated and
        // meaningless; the coordinator maps outcomes to sentences.
        #expect(reason?.contains("unavailable") == false)
    }

    @Test("Every refusing outcome fails closed", arguments: [
        SteamCMDManagedInstallResult.Outcome.tarballRejected,
        .extractionFailed,
        .binaryNotFound,
        .signatureRejected,
        .selfUpdateFailed,
        .unavailable
    ])
    func refusedOutcomesLeaveNoRecord(_ outcome: SteamCMDManagedInstallResult.Outcome) async {
        let defaults = scratchDefaults()
        let coordinator = coordinator(defaults: defaults) { _ in
            SteamCMDManagedInstallResult(
                outcome: outcome, canonicalPath: "/probe/steamcmd",
                sha256: nil, failureReason: nil
            )
        }

        let status = await coordinator.install()
        #expect(failed(status) != nil, "\(outcome) must not be reported as installed")
        // Note the canonicalPath above: a refused install still carries one, so
        // recording on "we got a path back" instead of on the outcome would
        // bind the app to a copy the connector just refused to run.
        #expect(coordinator.managedInstall == nil)
        #expect(SteamCMDManagedInstallCoordinator.recordedInstall(defaults: defaults) == nil)
    }

    @Test("A failure is not terminal — the user can try again")
    func retryAfterFailureIsAllowed() async {
        let defaults = scratchDefaults()
        var attempts = 0
        let coordinator = coordinator(defaults: defaults) { _ in
            attempts += 1
            return attempts == 1
                ? SteamCMDManagedInstallResult.failed(.extractionFailed, "first attempt")
                : SteamCMDManagedInstallResult(
                    outcome: .installed, canonicalPath: "/probe/steamcmd",
                    sha256: "abc", failureReason: nil
                )
        }

        #expect(failed(await coordinator.install()) != nil)
        // The re-entrancy guard rejects a *concurrent* install; it must not latch
        // a failed one into a state the user cannot leave.
        _ = await coordinator.install()
        #expect(attempts == 2)
        #expect(coordinator.managedInstall?.canonicalPath == "/probe/steamcmd")
    }
}

/// Removal and installation both suspend on separate short-lived XPC
/// connections, so their replies can come back in either order. Whichever the
/// user started **last** has to win — the alternative is a record pointing at
/// files that were deleted, or a deletion that takes an install the user
/// requested afterwards.
@MainActor
@Suite("Managed install and removal interleaving")
struct SteamCMDManagedInstallInterleavingTests {

    private let record = SteamCMDManagedInstallCoordinator.ManagedInstallRecord(
        canonicalPath: "/probe/old/steamcmd",
        bootstrapSHA256: SteamCMDBootstrapPackage.sha256
    )

    @Test("An install is refused while a removal is still in flight")
    func installRefusedDuringRemoval() async throws {
        let defaults = scratchDefaults()
        try storeRecord(record, in: defaults)

        // Held open so `forget()` is provably still suspended when install runs.
        let gate = AsyncGate()
        var installAttempts = 0
        let coordinator = SteamCMDManagedInstallCoordinator(
            downloadArchive: { _ in },
            defaults: defaults,
            remove: {
                await gate.wait()
                return SteamCMDManagedRemovalResult(outcome: .removed, failureReason: nil)
            },
            performInstall: { _ in
                installAttempts += 1
                return SteamCMDManagedInstallResult(
                    outcome: .installed, canonicalPath: "/probe/new/steamcmd",
                    sha256: "abc", failureReason: nil
                )
            }
        )

        async let removal = coordinator.forget()
        await Task.yield()
        #expect(coordinator.status == .removing)

        // The whole point: this must not start. Before `.removing` existed the
        // coordinator reported `.idle` here and let it through.
        let refused = await coordinator.install()
        #expect(refused == .removing)
        #expect(installAttempts == 0)

        await gate.open()
        #expect(await removal)
        #expect(coordinator.managedInstall == nil)
        #expect(coordinator.status == .idle)
    }

    @Test("An older removal cannot report success over the one that replaced it")
    func supersededRemovalDoesNotWin() async throws {
        let defaults = scratchDefaults()
        try storeRecord(record, in: defaults)

        // `forget()` has no status guard — clicking Remove twice really does
        // start two, and they finish in whatever order the connector replies.
        // (An install cannot get in here at all: `.removing` refuses it.)
        let first = AsyncGate()
        let second = AsyncGate()
        var call = 0
        let coordinator = SteamCMDManagedInstallCoordinator(
            downloadArchive: { _ in },
            defaults: defaults,
            remove: {
                call += 1
                let mine = call
                await (mine == 1 ? first : second).wait()
                return SteamCMDManagedRemovalResult(
                    outcome: mine == 1 ? .removed : .refused, failureReason: nil
                )
            },
            performInstall: { _ in
                Issue.record("no install may run during a removal")
                return nil
            }
        )

        async let older = coordinator.forget()
        await Task.yield()
        async let newer = coordinator.forget()
        await Task.yield()

        // The older one replies first and claims success. It has been
        // superseded, so its verdict must be discarded rather than clearing a
        // record the newer operation is still deciding about.
        await first.open()
        #expect(await older == false)
        #expect(coordinator.managedInstall == record)

        // The newer one is refused by the connector: the files are still there,
        // so the record has to stay and keep the Remove command reachable.
        await second.open()
        #expect(await newer == false)
        #expect(coordinator.managedInstall == record)
        #expect(coordinator.status == .idle)
    }
}

/// One-shot gate so a test can hold an injected async call open.
private actor AsyncGate {
    private var continuations: [CheckedContinuation<Void, Never>] = []
    private var isOpen = false

    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { continuations.append($0) }
    }

    func open() {
        isOpen = true
        let pending = continuations
        continuations = []
        pending.forEach { $0.resume() }
    }
}
