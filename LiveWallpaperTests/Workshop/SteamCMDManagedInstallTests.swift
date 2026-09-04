import Foundation
import Testing
@testable import LiveWallpaper

/// Isolated defaults so a test never reads or writes the real install record.
private func scratchDefaults(function: String = #function) -> UserDefaults {
    guard let scratch = try? TestScratch.defaultsSuite(prefix: "steamcmd-managed", function: function) else {
        fatalError("Could not create a scratch defaults suite")
    }
    return scratch.defaults
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
        bootstrapSHA256: String(repeating: "ab", count: 32)
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

        #expect(await coordinator.forget() == .removed)

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
        #expect(await coordinator.forget() == .removed)
    }

    @Test("A refused removal is reported as failure, and the record stays put")
    func refusedRemovalReportsFailure() async throws {
        let defaults = scratchDefaults()
        try storeRecord(record, in: defaults)
        let coordinator = SteamCMDManagedInstallCoordinator(
            defaults: defaults,
            remove: { SteamCMDManagedRemovalResult(outcome: .refused, failureReason: "nope") }
        )

        #expect(await coordinator.forget() == .refused)
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
        // Named apart from a refusal: nothing was deleted and nothing was
        // even asked, so the two need different sentences on screen.
        #expect(await coordinator.forget() == .connectorUnavailable)
        #expect(coordinator.managedInstall == record)
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
            archives: [tarball], installRoot: installRoot, spawn: spawn
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

    /// Valve's manifest zips carry no unix permissions — everything extracts
    /// 0644 (measured 2026-08-13), and steamcmd.sh checks `-x` without ever
    /// chmodding. A zip fixture, not tar: tar archives preserve mode bits, so
    /// they cannot reproduce the failure.
    @Test("Executables extracted from a permissionless zip become spawnable")
    func zipWithoutExecBitsYieldsRunnableBinaries() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("zipmode-\(UUID().uuidString)", isDirectory: true)
        let source = root.appendingPathComponent("src", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        for name in ["steamcmd", "steamcmd.sh"] {
            let file = source.appendingPathComponent(name)
            try Data("#!/bin/sh\n".utf8).write(to: file)
            try FileManager.default.setAttributes(
                [.posixPermissions: NSNumber(value: Int16(0o644))], ofItemAtPath: file.path
            )
        }
        let zip = root.appendingPathComponent("a.zip")
        let make = Process()
        make.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        make.arguments = ["-a", "-cf", zip.path, "-C", source.path, "steamcmd", "steamcmd.sh"]
        try make.run()
        make.waitUntilExit()

        let installRoot = root.appendingPathComponent("install", isDirectory: true)
        guard case .success(let installed) = SteamCMDManagedInstaller.extract(
            archives: [zip], installRoot: installRoot, spawn: spawn
        ) else {
            Issue.record("A clean zip must unpack")
            return
        }
        for name in ["steamcmd", "steamcmd.sh"] {
            #expect(
                FileManager.default.isExecutableFile(
                    atPath: installed.payload.appendingPathComponent(name).path
                ),
                "\(name) must be spawnable after extraction"
            )
        }
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
            archives: [tarball], installRoot: installRoot, spawn: spawn
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
            archives: [tarball], installRoot: installRoot, spawn: spawn
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
            archives: [tarball], installRoot: installRoot, spawn: spawn
        ) else {
            Issue.record("A clean archive must unpack")
            return
        }
        SteamCMDManagedInstaller.rollBack(installed)

        // Nothing to restore, so the failed payload must not be left as the
        // thing `locateBinary` would find next time.
        #expect(!FileManager.default.fileExists(atPath: installed.payload.path))
        #expect(
            !FileManager.default.fileExists(atPath: installRoot.path),
            "A failed first install must not leave an unexplained empty SteamCMD folder"
        )
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
            archives: [tarball], installRoot: installRoot, spawn: spawn
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
            archives: [tarball], installRoot: installRoot, spawn: spawn
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
        install: @escaping () async -> SteamCMDManagedInstallResult?
    ) -> SteamCMDManagedInstallCoordinator {
        SteamCMDManagedInstallCoordinator(
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
        let coordinator = coordinator(defaults: defaults) {
            SteamCMDManagedInstallResult(
                outcome: .installed, canonicalPath: "/probe/steamcmd",
                sha256: "abc", failureReason: nil
            )
        }
        _ = await coordinator.install()
        #expect(coordinator.managedInstall?.canonicalPath == "/probe/steamcmd")
        // The record's digest is the installed binary's, handed back by the
        // connector — there is no app-side download left to hash.
        #expect(coordinator.managedInstall?.bootstrapSHA256 == "abc")
    }

    @Test("An unreachable connector records nothing and says so")
    func unreachableConnectorLeavesNoRecord() async {
        let defaults = scratchDefaults()
        let coordinator = coordinator(defaults: defaults) { nil }

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
        let coordinator = coordinator(defaults: defaults) {
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
        let coordinator = coordinator(defaults: defaults) {
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
        bootstrapSHA256: String(repeating: "ab", count: 32)
    )

    @Test("An install is refused while a removal is still in flight")
    func installRefusedDuringRemoval() async throws {
        let defaults = scratchDefaults()
        try storeRecord(record, in: defaults)

        // Held open so `forget()` is provably still suspended when install runs.
        let gate = AsyncGate()
        var installAttempts = 0
        let coordinator = SteamCMDManagedInstallCoordinator(
            defaults: defaults,
            remove: {
                await gate.wait()
                return SteamCMDManagedRemovalResult(outcome: .removed, failureReason: nil)
            },
            performInstall: {
                installAttempts += 1
                return SteamCMDManagedInstallResult(
                    outcome: .installed, canonicalPath: "/probe/new/steamcmd",
                    sha256: "abc", failureReason: nil
                )
            }
        )

        async let removal = coordinator.forget()
        #expect(await gateReached(gate), "the removal never reached the gate")
        #expect(coordinator.status == .removing)

        // The whole point: this must not start. Before `.removing` existed the
        // coordinator reported `.idle` here and let it through.
        let refused = await coordinator.install()
        #expect(refused == .removing)
        #expect(installAttempts == 0)

        await gate.open()
        #expect(await removal == .removed)
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
            defaults: defaults,
            remove: {
                call += 1
                let mine = call
                await (mine == 1 ? first : second).wait()
                return SteamCMDManagedRemovalResult(
                    outcome: mine == 1 ? .removed : .refused, failureReason: nil
                )
            },
            performInstall: {
                Issue.record("no install may run during a removal")
                return nil
            }
        )

        async let older = coordinator.forget()
        #expect(await gateReached(first), "the first removal never reached its gate")
        async let newer = coordinator.forget()
        #expect(await gateReached(second), "the second removal never reached its gate")

        // The older one replies first and claims success. It has been
        // superseded, so its verdict must be discarded rather than clearing a
        // record the newer operation is still deciding about.
        await first.open()
        #expect(await older == .superseded)
        #expect(coordinator.managedInstall == record)

        // The newer one is refused by the connector: the files are still there,
        // so the record has to stay and keep the Remove command reachable.
        await second.open()
        #expect(await newer == .refused)
        #expect(coordinator.managedInstall == record)
        #expect(coordinator.status == .idle)
    }
}

/// One-shot gate so a test can hold an injected async call open.
private actor AsyncGate {
    private var continuations: [CheckedContinuation<Void, Never>] = []
    private var isOpen = false
    /// How many callers have entered `wait()`. Reaching the gate is the only
    /// observable proof that the task holding it actually started.
    private(set) var arrivals = 0

    func wait() async {
        arrivals += 1
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

/// `Task.yield()` only reschedules the caller — it does not promise a child
/// task has been scheduled, let alone run far enough to reach the gate. Waiting
/// on the arrival itself is what makes the interleaving deterministic; the
/// deadline keeps a regression a failure rather than a hang.
private func gateReached(
    _ gate: AsyncGate, arrivals count: Int = 1, within seconds: Double = 5
) async -> Bool {
    let deadline = ContinuousClock.now + .seconds(seconds)
    while await gate.arrivals < count {
        if ContinuousClock.now >= deadline { return false }
        try? await Task.sleep(for: .milliseconds(1))
    }
    return true
}

/// The manifest is Valve's own steamcmd update channel; installing from it is
/// what removed the Rosetta requirement. The fixture is the real manifest shape
/// captured 2026-08-13, values shortened but structure verbatim.
@Suite("SteamCMD manifest parsing")
struct SteamCMDManifestTests {
    private static func fixture(
        binsFile: String = "steamcmd_bins_osx.zip.fea7987a78b17131a8303508b1627668dab372b0"
    ) -> String {
        """
        "osx"
        {
        \t"version"\t\t"1785799152"
        \t"ostype"\t\t"macos1015"
        \t"steamcmd_public_all"
        \t{
        \t\t"file"\t\t"steamcmd_public_all.zip.9acb456879ee932518117972e2b09b938f19063b"
        \t\t"size"\t\t"60352"
        \t\t"sha2"\t\t"6fad0bff904dac6cce1c56d9bdf60915e8041e9e3d12b3ca3baeca31d1e00acc"
        \t}
        \t"steamcmd_bins_osx"
        \t{
        \t\t"file"\t\t"\(binsFile)"
        \t\t"size"\t\t"19923594"
        \t\t"sha2"\t\t"d53da9a68e578a775ae18553c82152b925ae9c932cc37442552cc0eeebd78e0e"
        \t\t"zipvz"\t\t"steamcmd_bins_osx.zip.vz.90b482c24f1fafb2292d0e0da3d700fd30c342b1_12839892"
        \t\t"sha2vz"\t\t"2b9dd13b59e35721b1244583e395bcd24996e5a9b8d1c9606d85fddcdf8c3c82"
        \t}
        \t"steamcmd_breakpad_osx"
        \t{
        \t\t"file"\t\t"steamcmd_breakpad_osx.zip.eda848a2329cdc8b369885c20dc3e8fdee83088e"
        \t\t"size"\t\t"576242"
        \t\t"sha2"\t\t"e8b83bb0ecf683a77c3c5c78320b9d894251ad7339ee002a446f238dfc950675"
        \t}
        \t"steamcmd_osx"
        \t{
        \t\t"file"\t\t"steamcmd_osx.zip.1ddda071ccfbd4628f40ff1306122b01d354b060"
        \t\t"size"\t\t"4009303"
        \t\t"sha2"\t\t"7aa24b9739ad12ecba7d91bcd0f982e0cc7514e767cb2b3ab77124c2726277e4"
        \t}
        }
        """
    }

    @Test("Control: the captured real manifest parses into all four packages")
    func realShapeParses() throws {
        let packages = try #require(SteamCMDManifest.parse(Self.fixture()))
        #expect(packages.map(\.name) == SteamCMDManifest.requiredPackages)
        let main = try #require(packages.first { $0.name == "steamcmd_osx" })
        #expect(main.file == "steamcmd_osx.zip.1ddda071ccfbd4628f40ff1306122b01d354b060")
        #expect(main.sha256 == "7aa24b9739ad12ecba7d91bcd0f982e0cc7514e767cb2b3ab77124c2726277e4")
        #expect(main.byteCount == 4_009_303)
        // The plain zip is chosen, never the .vz variant we cannot decompress.
        #expect(packages.allSatisfy { !$0.file.contains(".vz.") })
    }

    @Test("A manifest missing any required package fails whole")
    func missingPackageFailsWhole() {
        let truncated = Self.fixture()
            .replacingOccurrences(of: "\"steamcmd_osx\"", with: "\"steamcmd_other\"")
        #expect(SteamCMDManifest.parse(truncated) == nil)
    }

    @Test("A traversal-shaped package filename is refused")
    func traversalFileNameRefused() {
        #expect(SteamCMDManifest.parse(Self.fixture(binsFile: "../../etc/evil.zip")) == nil)
        #expect(SteamCMDManifest.parse(Self.fixture(binsFile: "a/b.zip")) == nil)
        // Control: the shape rule itself accepts the real names.
        #expect(SteamCMDManifest.isSafePackageFileName(
            "steamcmd_osx.zip.1ddda071ccfbd4628f40ff1306122b01d354b060"
        ))
    }

    @Test("A malformed digest or size fails the parse")
    func malformedFieldsRefused() {
        #expect(SteamCMDManifest.parse(Self.fixture()
            .replacingOccurrences(
                of: "7aa24b9739ad12ecba7d91bcd0f982e0cc7514e767cb2b3ab77124c2726277e4",
                with: "short"
            )) == nil)
        #expect(SteamCMDManifest.parse(Self.fixture()
            .replacingOccurrences(of: "\"4009303\"", with: "\"zero\"")) == nil)
    }
}

/// The in-app sign-in's two safety properties: the password can never enter
/// argv (the type system has no parameter for it), and the transcript
/// classifier steers the PTY exchange from real steamcmd output shapes.
@Suite("SteamCMD interactive login")
struct SteamCMDLoginTests {
    @Test("The login argv carries the account and +quit, and nothing secret")
    func argvHasNoSecretSlot() {
        let arguments = SteamCMDLoginProbe.arguments(accountName: "probe_user")
        #expect(arguments == ["+login", "probe_user", "+quit"])
    }

    @Test("The timeout survives the mobile-confirmation wait but stays bounded")
    func timeoutClamp() {
        #expect(SteamCMDLoginProbe.clampedTimeout(0) >= 60)
        #expect(SteamCMDLoginProbe.clampedTimeout(.nan) == SteamCMDLoginProbe.defaultTimeout)
        #expect(SteamCMDLoginProbe.clampedTimeout(10_000) <= 600)
        #expect(SteamCMDLoginProbe.clampedTimeout(300) == 300)
    }

    private typealias Classifier = SteamCMDLoginOutputClassifier

    @Test("Real steamcmd transcript shapes classify to the right event")
    func transcriptShapes() {
        #expect(Classifier.event(inTranscript:
            "Steam Console Client (c) Valve Corporation\nLogging in user 'x' to Steam Public...\npassword:"
        ) == .passwordPrompt)
        #expect(Classifier.event(inTranscript:
            "password:\nThis account is protected by Steam Guard.\nSteam Guard code:"
        ) == .guardCodeEmailPrompt)
        #expect(Classifier.event(inTranscript: "password:\nTwo-factor code:") == .guardCodeTotpPrompt)
        #expect(Classifier.event(inTranscript:
            "password:\nPlease confirm the login in the Steam Mobile app on your phone."
        ) == .waitingForMobileConfirmation)
        #expect(Classifier.event(inTranscript: "password:\nFAILED (Invalid Password)") == .invalidPassword)
        #expect(Classifier.event(inTranscript: "Steam Guard code:\nFAILED (Invalid Login Auth Code)") == .invalidGuardCode)
        #expect(Classifier.event(inTranscript: "FAILED (Rate Limit Exceeded)") == .rateLimited)
        #expect(Classifier.event(inTranscript:
            "Logging in using cached credentials...\nWaiting for user info...OK"
        ) == .loggedIn)
    }

    @Test("Terminal outcomes outrank the prompts that preceded them")
    func terminalOutranksPrompt() {
        // The transcript keeps the old "password:" prompt forever; once a
        // verdict lands, re-answering the prompt would loop.
        #expect(Classifier.event(inTranscript:
            "password:\nInvalid Password\npassword:"
        ) == .invalidPassword)
        #expect(Classifier.event(inTranscript:
            "password:\nPlease confirm the login in the Steam Mobile app\nLogged in OK"
        ) == .loggedIn)
    }

    @Test("Control: an unclassified transcript yields no event")
    func silenceYieldsNothing() {
        #expect(Classifier.event(inTranscript: "Redirecting stderr to logs...") == nil)
    }

    /// Verbatim 2026-09-03 capture under `sandbox-exec (deny network*)`. The
    /// password prompt stays in the transcript, so without a verdict of its
    /// own this read as "still waiting for the password" until the deadline.
    @Test("A blocked network is a verdict, not a prompt to keep answering")
    func noConnectionIsTerminal() {
        let transcript = "password: \nProceeding with login using username/password.\n"
            + "Logging in user 'x' [U:1:0] to Steam Public...Retrying... \nRetrying... \nERROR (No Connection)"
        #expect(Classifier.event(inTranscript: transcript) == .noConnection)
    }

    /// Source-level, connector target is not linked here: the login session may
    /// only build its argv through the parameterless-secret builder, and every
    /// secret write goes to the PTY.
    @Test("The connector's login body has no other argv source")
    func loginBodyUsesTheBuilder() throws {
        let source = try RepositoryRoot.source("SteamConnector/SteamConnector.swift")
        let start = try #require(source.range(of: "private static func runLoginSession"))
        let body = String(source[start.lowerBound...].prefix(5_000))
        #expect(body.contains("SteamCMDLoginProbe.arguments(accountName:"))
        #expect(!body.contains("request.password]"))
        #expect(body.contains("SteamCMDExecutionFence.refusesExecution"))
    }
}
