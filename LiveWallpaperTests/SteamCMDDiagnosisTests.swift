import Foundation
import Testing
@testable import LiveWallpaper

private func launch(
    _ outcome: SteamCMDLaunchProbe.Outcome,
    arguments: [String] = SteamCMDDiagnosisProbe.arguments,
    exitCode: Int32 = 0,
    timeout: TimeInterval = SteamCMDDiagnosisProbe.defaultLaunchTimeout,
    tail: String = ""
) -> SteamCMDLaunchProbe {
    SteamCMDLaunchProbe(
        outcome: outcome,
        arguments: arguments,
        exitCode: exitCode,
        timeout: timeout,
        outputTail: tail
    )
}

private func diagnosis(
    source: SteamCMDBinarySource = .homebrew,
    path: String? = "/opt/homebrew/bin/steamcmd",
    resolutionFailure: String? = nil,
    signature: SteamCMDSignatureVerdict? = SteamCMDSignatureVerdict(
        isValid: true,
        teamIdentifier: SteamCMDBootstrapPackage.expectedTeamIdentifier,
        isHardenedRuntime: true
    ),
    quarantined: Bool = false,
    launch probe: SteamCMDLaunchProbe? = launch(.succeeded),
    unavailableReason: String? = nil
) -> SteamCMDDiagnosis {
    SteamCMDDiagnosis(
        source: source,
        canonicalPath: path,
        resolutionFailure: resolutionFailure,
        sha256: String(repeating: "a", count: 64),
        signature: signature,
        isQuarantined: quarantined,
        launch: probe,
        unavailableReason: unavailableReason
    )
}

@Suite("SteamCMD diagnosis verdict")
struct SteamCMDDiagnosisVerdictTests {
    @Test("Control: a binary that resolved, verified, and ran is usable")
    func healthyDiagnosisIsUsable() {
        // The control group for this whole suite: without it every assertion
        // below would still pass on an `isUsable` that returns false always.
        let healthy = diagnosis()
        #expect(healthy.isUsable)
        #expect(healthy.remedy == nil)
    }

    @Test("Nothing weaker than a completed run counts as usable")
    func noLaunchIsNeverUsable() {
        // Every field except the run says "fine" — path resolved, signature
        // valid, no quarantine. This is exactly the shape the app's old
        // existence-check produced when steamcmd could not spawn at all.
        #expect(!diagnosis(launch: nil).isUsable)
    }

    @Test("A failed run is not usable, whatever the failure was")
    func failedLaunchIsNotUsable() {
        #expect(!diagnosis(launch: launch(.timedOut, exitCode: 0)).isUsable)
        #expect(!diagnosis(launch: launch(.exitedNonZero, exitCode: 7)).isUsable)
        #expect(!diagnosis(launch: launch(.couldNotSpawn, exitCode: -1)).isUsable)
    }

    @Test("A run of some other command cannot stand in for the launch probe")
    func foreignArgumentsAreNotTheLaunchProbe() {
        // Guards against the verdict being satisfied by whatever spawn happens
        // to be nearby — the codesign runs both exit 0 too.
        let borrowed = diagnosis(launch: launch(.succeeded, arguments: ["-dv", "--verbose=4"]))
        #expect(!borrowed.isUsable)
        // Control: same record, the real argv.
        #expect(diagnosis(launch: launch(.succeeded, arguments: ["+quit"])).isUsable)
    }

    @Test("A connector that reached no verdict is not a healthy verdict")
    func unavailableIsNotUsable() {
        #expect(!diagnosis(unavailableReason: "queued too long").isUsable)
        #expect(SteamCMDDiagnosis.unavailable("busy").remedy?.contains("busy") == true)
    }

    @Test("A timeout outranks the exit status")
    func classifyPrefersTimeout() {
        // A process killed by the connector's own SIGTERM can still report 0.
        #expect(SteamCMDLaunchProbe.classify(exitCode: 0, timedOut: true) == .timedOut)
        // Control: the same exit code without a timeout is the healthy answer.
        #expect(SteamCMDLaunchProbe.classify(exitCode: 0, timedOut: false) == .succeeded)
    }

    @Test("A failed spawn is distinguished from a non-zero exit")
    func classifySeparatesSpawnFailure() {
        // `spawn` reports a `Process.run()` throw as -1; a quarantined Mach-O is
        // the case that produces it, and it needs different advice than a
        // SteamCMD that ran and complained.
        #expect(SteamCMDLaunchProbe.classify(exitCode: -1, timedOut: false) == .couldNotSpawn)
        #expect(SteamCMDLaunchProbe.classify(exitCode: 1, timedOut: false) == .exitedNonZero)
    }

    @Test("The launch budget cannot be shrunk into a guaranteed timeout")
    func clampedLaunchTimeout() {
        #expect(SteamCMDDiagnosisProbe.clampedLaunchTimeout(0) >= 30)
        #expect(SteamCMDDiagnosisProbe.clampedLaunchTimeout(-5) >= 30)
        #expect(SteamCMDDiagnosisProbe.clampedLaunchTimeout(.nan)
            == SteamCMDDiagnosisProbe.defaultLaunchTimeout)
        #expect(SteamCMDDiagnosisProbe.clampedLaunchTimeout(100_000) <= 900)
        // Control: a sane budget passes through untouched.
        #expect(SteamCMDDiagnosisProbe.clampedLaunchTimeout(120) == 120)
    }

    @Test("The diagnosis argv is inside the connector's own read-only probe set")
    func launchArgumentsAreAnAllowedProbe() {
        #expect(SteamCMDProbeArgumentPolicy.isAllowed(SteamCMDDiagnosisProbe.arguments))
        // Control: the policy does discriminate.
        #expect(!SteamCMDProbeArgumentPolicy.isAllowed(["+force_install_dir", "/tmp"]))
    }

    @Test("The verdict survives the wire")
    func wireRoundTrip() throws {
        let original = diagnosis(
            source: .managedInstall,
            path: "/Users/probe/Library/Application Support/Loomscreen/SteamCMD/MacOS/steamcmd",
            launch: launch(.succeeded, tail: "Steam Console Client (c) Valve Corporation")
        )
        let decoded = try JSONDecoder().decode(
            SteamCMDDiagnosis.self, from: JSONEncoder().encode(original)
        )
        #expect(decoded == original)
        #expect(decoded.source == .managedInstall)
        #expect(decoded.isUsable)
        #expect(decoded.launch?.arguments == ["+quit"])
    }
}

@Suite("SteamCMD diagnosis remedies")
struct SteamCMDDiagnosisRemedyTests {
    @Test("Control: a healthy diagnosis has nothing to advise")
    func healthyHasNoRemedy() {
        #expect(SteamCMDDiagnosisRemedy.advice(for: diagnosis()) == nil)
    }

    @Test("Not found tells the user how to get one")
    func notFoundAdvisesInstalling() {
        let advice = SteamCMDDiagnosis.notFound(resolutionFailure: "userPicked: notMachO").remedy
        #expect(advice?.contains("brew install --cask steamcmd") == true)
        #expect(advice?.contains("notMachO") == true)
    }

    @Test("Quarantine gets the command that clears it")
    func quarantineAdvisesXattr() {
        let advice = diagnosis(
            quarantined: true, launch: launch(.couldNotSpawn, exitCode: -1)
        ).remedy
        #expect(advice?.contains("xattr -d com.apple.quarantine") == true)
        #expect(advice?.contains("/opt/homebrew/bin/steamcmd") == true)
    }

    @Test("A spawn failure with a bad signature advises reinstalling, not xattr")
    func brokenSignatureAdvisesReinstall() {
        let advice = diagnosis(
            signature: SteamCMDSignatureVerdict(
                isValid: false, teamIdentifier: nil, isHardenedRuntime: false
            ),
            launch: launch(.couldNotSpawn, exitCode: -1)
        ).remedy
        #expect(advice?.contains("reinstall") == true)
        #expect(advice?.contains("xattr") == false)
    }

    @Test("A timeout quotes the budget it blew")
    func timeoutQuotesBudget() {
        let advice = diagnosis(launch: launch(.timedOut, timeout: 180)).remedy
        #expect(advice?.contains("180 seconds") == true)
        #expect(advice?.contains("+quit") == true)
    }

    @Test("A non-zero exit quotes the status and the output")
    func nonZeroExitQuotesStatus() {
        let advice = diagnosis(
            launch: launch(.exitedNonZero, exitCode: 42, tail: "Error! App '431960' state is 0x2")
        ).remedy
        #expect(advice?.contains("42") == true)
        #expect(advice?.contains("state is 0x2") == true)
    }

    @Test("A megabyte of output does not become a megabyte of advice")
    func remedyTailIsBounded() {
        let advice = diagnosis(
            launch: launch(.exitedNonZero, exitCode: 1, tail: String(repeating: "noise\n", count: 50_000))
        ).remedy
        #expect((advice?.count ?? 0) < 600)
    }

    @Test("A binary that runs but is not Valve's is reported even though it works")
    func unsignedButWorkingIsFlagged() {
        let advice = diagnosis(
            signature: SteamCMDSignatureVerdict(
                isValid: true, teamIdentifier: "ABCDE12345", isHardenedRuntime: false
            )
        ).remedy
        #expect(advice?.contains("ABCDE12345") == true)
        // It still ran, so the verdict itself stays usable — the advice is a
        // warning, not a failure.
        #expect(diagnosis(
            signature: SteamCMDSignatureVerdict(
                isValid: true, teamIdentifier: "ABCDE12345", isHardenedRuntime: false
            )
        ).isUsable)
    }
}

@Suite("SteamCMD diagnosis resolution plan")
struct SteamCMDDiagnosisPlanTests {
    private static let managedBinary = URL(
        fileURLWithPath: "/Users/probe/Library/Application Support/Loomscreen/SteamCMD/MacOS/steamcmd"
    )

    @Test("The managed install is tried before the package managers, in that order")
    func planOrder() {
        let plan = SteamCMDDiagnosisPlan.candidates(managedInstall: Self.managedBinary)
        #expect(plan.map(\.source) == [.managedInstall, .homebrew, .usrLocal, .macPorts])
        #expect(plan.first?.path == Self.managedBinary.path(percentEncoded: false))
    }

    @Test("Control: with no managed install the three package-manager paths are still tried")
    func planWithoutManagedInstall() {
        let plan = SteamCMDDiagnosisPlan.candidates(managedInstall: nil)
        #expect(plan.map(\.source) == [.homebrew, .usrLocal, .macPorts])
        #expect(plan.map(\.path) == [
            "/opt/homebrew/bin/steamcmd",
            "/usr/local/bin/steamcmd",
            "/opt/local/bin/steamcmd"
        ])
    }

    /// Both a picked path and the managed path used to ride in on the request,
    /// which meant a compromised app chose what this unsandboxed process spawns.
    /// The wire format is the guarantee: there is no field left to swap through.
    @Test("The request carries no path of any kind")
    func requestCannotNameAnExecutable() throws {
        let wire = try JSONEncoder().encode(SteamCMDDiagnosisRequest())
        let fields = try #require(
            try JSONSerialization.jsonObject(with: wire) as? [String: Any]
        )
        #expect(fields["pickedPath"] == nil)
        #expect(fields["managedInstallPath"] == nil)
        // Control: the one thing the app may still say is how long to wait.
        #expect(fields.keys.sorted() == ["launchTimeout"])
    }

    /// Pinned at the protocol rather than at today's call sites: a path-shaped
    /// argument re-appearing here is what would re-open the hole.
    ///
    @Test("Resolution and diagnosis take no path from the app")
    func resolutionSurfaceTakesNoPath() throws {
        let body = try Self.connectorProtocolSource()
        #expect(!body.contains("pickedPath"))
        #expect(!body.contains("managedInstallPath"))
        // Control: the method that no longer takes one is still on the surface.
        #expect(body.contains("func locateSteamCMDBinary(with reply:"))
    }

    /// The gap this used to mark is closed: the executing entry points no
    /// longer take a path either. Pinned as an absence so it cannot come back.
    @Test("No entry point on the whole surface takes a binary path")
    func operationalMethodsTakeNoPath() throws {
        let body = try Self.connectorProtocolSource()
        #expect(!body.contains("steamCMDPath"))
        // Control: the surface is really being read, and the one path-shaped
        // parameter that remains is a read-only inspection, never a spawn.
        #expect(body.contains("func inspectSteamCMDBinary(path: String"))
    }

    private static func connectorProtocolSource() throws -> String {
        let source = try RepositoryRoot.source("SteamConnector/SteamConnectorProtocol.swift")
        let surface = try #require(source.range(of: "protocol SteamConnectorProtocol"))
        let end = try #require(source.range(of: "\n}", range: surface.upperBound..<source.endIndex))
        return String(source[surface.lowerBound..<end.lowerBound])
    }

    @Test("Each package-manager path keeps its own label")
    func packageManagerLabels() {
        #expect(SteamCMDDiagnosisPlan.packageManagerSource(
            forCandidatePath: "/opt/local/bin/steamcmd") == .macPorts)
        #expect(SteamCMDDiagnosisPlan.packageManagerSource(
            forCandidatePath: "/usr/local/bin/steamcmd") == .usrLocal)
        #expect(SteamCMDDiagnosisPlan.packageManagerSource(
            forCandidatePath: "/somewhere/else/steamcmd") == .notFound)
    }
}

@Suite("SteamCMD execution fence")
struct SteamCMDExecutionFenceTests {
    @Test("Paths inside the caller's own writable storage are refused")
    func refusesCallerWritablePaths() {
        #expect(SteamCMDExecutionFence.refusesExecution(
            of: "/Users/probe/Library/Containers/com.loomscreen.pro/Data/steamcmd"
        ))
        #expect(SteamCMDExecutionFence.refusesExecution(
            of: "/Users/probe/Library/Group Containers/group.loomscreen/steamcmd"
        ))
        // The sandbox redirects the app's temporary directory into the
        // container, so that case is the same one.
        #expect(SteamCMDExecutionFence.refusesExecution(
            of: "/Users/probe/Library/Containers/com.loomscreen.pro/Data/tmp/steamcmd"
        ))
    }

    @Test("Control: the paths a real SteamCMD lives at are allowed")
    func allowsRealInstallPaths() {
        #expect(!SteamCMDExecutionFence.refusesExecution(of: "/opt/homebrew/bin/steamcmd"))
        #expect(!SteamCMDExecutionFence.refusesExecution(of: "/usr/local/bin/steamcmd"))
        #expect(!SteamCMDExecutionFence.refusesExecution(
            of: "/Users/probe/Library/Application Support/Loomscreen/SteamCMD/MacOS/steamcmd"
        ))
    }

    /// The verdict is about the file that would actually be executed, so it has
    /// to be taken after symlink resolution. This test process runs inside the
    /// app's own container, which makes it the right place to build both halves:
    /// a real file there, and a link there aiming somewhere else.
    @Test("A symlink is judged by its target, not by where the link sits")
    func followsSymlinksBeforeDeciding() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("fence-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        // Precondition: the fixture really is in caller-writable storage, or
        // neither assertion below means anything.
        try #require(root.path(percentEncoded: false).contains("/Library/Containers/"))

        let planted = root.appendingPathComponent("steamcmd")
        try Data().write(to: planted)
        #expect(SteamCMDExecutionFence.refusesExecution(of: planted.path(percentEncoded: false)))

        // A link the caller can write, aiming at bytes it cannot: the target is
        // what gets executed, so this one is allowed. Judging the link's own
        // path would refuse it.
        let link = root.appendingPathComponent("steamcmd-link")
        try FileManager.default.createSymbolicLink(
            at: link, withDestinationURL: URL(fileURLWithPath: "/usr/bin/true")
        )
        #expect(!SteamCMDExecutionFence.refusesExecution(of: link.path(percentEncoded: false)))
    }

    /// Source-level, like the other connector-target assertions here: the fence
    /// is only a fence if the one function that spawns SteamCMD consults it
    /// before spawning.
    @Test("The connector routes every SteamCMD spawn through the fence")
    func runSteamCMDIsFenced() throws {
        let source = try RepositoryRoot.source("SteamConnector/SteamConnector.swift")
        let start = try #require(source.range(of: "static func runSteamCMD("))
        let body = String(source[start.upperBound...].prefix(1200))
        let gate = try #require(body.range(of: "SteamCMDExecutionFence.refusesExecution"))
        let spawn = try #require(body.range(of: "spawn(executable: steamCMDPath"))
        #expect(gate.lowerBound < spawn.lowerBound)
    }
}

// MARK: - The run itself

private enum ConnectorSource: Error, CustomStringConvertible {
    case methodNotFound(String)

    var description: String {
        switch self {
        case let .methodNotFound(name):
            return "SteamConnector.swift has no `func \(name)` — the scan is misconfigured, not passing."
        }
    }

    /// The body of one connector method, read from source. The connector target
    /// is not linked into the test bundle, so this is the only way to assert
    /// what its implementation actually does.
    static func methodBody(_ name: String) throws -> String {
        let source = try RepositoryRoot.source("SteamConnector/SteamConnector.swift")
        guard let start = source.range(of: "    func \(name)(") else {
            throw ConnectorSource.methodNotFound(name)
        }
        let rest = source[start.upperBound...]
        guard let next = rest.range(of: "\n    func ") else { return String(rest) }
        return String(rest[..<next.lowerBound])
    }
}

@Suite("SteamCMD diagnosis actually runs the binary")
struct SteamCMDDiagnosisExecutionTests {
    @Test("The diagnosis spawns SteamCMD with the probe argv")
    func diagnosisSpawnsSteamCMD() throws {
        let body = try ConnectorSource.methodBody("diagnoseSteamCMD")
        // The point of the whole API: a verdict from the process that can run
        // the binary. Replacing this with a stat is the regression this pins.
        #expect(body.contains("Self.runSteamCMD("))
        #expect(body.contains("arguments: SteamCMDDiagnosisProbe.arguments"))
        #expect(body.contains("SteamCMDDiagnosisProbe.clampedLaunchTimeout("))
        // Queued like every other spawn, and it gives up rather than running for
        // a caller that has gone.
        #expect(body.contains("Self.steamCMDQueue.async"))
        #expect(body.contains("Self.callerAbandoned(enqueuedAt: enqueuedAt)"))
    }

    @Test("Control: the scan reads one method, and a method that spawns nothing shows it")
    func scanDiscriminates() throws {
        // Without this pair, the assertions above would pass just as well on a
        // scan that returned the whole file.
        let spawner = try ConnectorSource.methodBody("runSteamCMDProbe")
        let nonSpawner = try ConnectorSource.methodBody("deleteWorkshopItem")
        #expect(spawner.contains("Self.runSteamCMD("))
        #expect(!nonSpawner.contains("Self.runSteamCMD("))
    }

    @Test("A misconfigured scan throws instead of quietly passing")
    func scanFailsLoudly() {
        #expect(throws: ConnectorSource.self) {
            try ConnectorSource.methodBody("noSuchConnectorMethod")
        }
    }
}

@Suite("SteamCMD archive staging refuses what it cannot read")
struct SteamCMDStagingInputTypeTests {
    private func scratch() -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("staging-input-\(UUID().uuidString)", isDirectory: true)
    }

    @Test("A FIFO is refused instead of parking the shared SteamCMD queue", .timeLimit(.minutes(1)))
    func refusesFIFO() throws {
        let root = scratch()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let fifo = root.appendingPathComponent("in.tar.gz").path(percentEncoded: false)
        #expect(mkfifo(fifo, 0o600) == 0)

        // With a blocking open this call never returns and the time limit fires;
        // that is the failure mode being pinned, not a slow test.
        guard case .failure(let result) = SteamCMDManagedInstaller.stageAndVerifyTarball(
            at: fifo, stagingRoot: root.appendingPathComponent("staging", isDirectory: true)
        ) else {
            Issue.record("A FIFO must be refused")
            return
        }
        #expect(result.outcome == .tarballRejected)
        #expect(result.failureReason?.contains("regular file") == true)
    }

    @Test("A directory is refused for the same reason")
    func refusesDirectory() throws {
        let root = scratch()
        let directory = root.appendingPathComponent("in.tar.gz", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        guard case .failure(let result) = SteamCMDManagedInstaller.stageAndVerifyTarball(
            at: directory.path(percentEncoded: false),
            stagingRoot: root.appendingPathComponent("staging", isDirectory: true)
        ) else {
            Issue.record("A directory must be refused")
            return
        }
        #expect(result.outcome == .tarballRejected)
    }

    @Test("Control: a regular file gets past the type gate and is judged on its bytes")
    func regularFileReachesTheDigestGate() throws {
        let root = scratch()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("in.tar.gz")
        try Data(repeating: 0x5A, count: 4_096).write(to: file)

        guard case .failure(let result) = SteamCMDManagedInstaller.stageAndVerifyTarball(
            at: file.path(percentEncoded: false),
            stagingRoot: root.appendingPathComponent("staging", isDirectory: true)
        ) else {
            Issue.record("A 4 KB file is not the pinned archive and must be refused")
            return
        }
        // Refused for its size, not its type: without this the type gate could
        // be rejecting every input and the two tests above would prove nothing.
        #expect(result.failureReason?.contains("regular file") == false)
        #expect(result.failureReason?.contains("bytes") == true)
    }
}


@Suite("Diagnosis refuses to launch untrusted binaries")
struct SteamCMDDiagnosisTrustGateTests {
    private func diagnosis(
        signatureValid: Bool,
        team: String?,
        quarantined: Bool,
        launched: Bool
    ) -> SteamCMDDiagnosis {
        SteamCMDDiagnosis(
            source: .managedInstall,
            canonicalPath: "/x/steamcmd",
            resolutionFailure: nil,
            sha256: "abc",
            signature: SteamCMDSignatureVerdict(
                isValid: signatureValid, teamIdentifier: team, isHardenedRuntime: true
            ),
            isQuarantined: quarantined,
            launch: launched ? SteamCMDLaunchProbe(
                outcome: .succeeded,
                arguments: SteamCMDDiagnosisProbe.arguments,
                exitCode: 0,
                timeout: 180,
                outputTail: ""
            ) : nil,
            unavailableReason: nil
        )
    }

    @Test("Control: a Valve-signed, unquarantined binary that ran is usable")
    func trustedAndLaunchedIsUsable() {
        #expect(diagnosis(
            signatureValid: true,
            team: SteamCMDBootstrapPackage.expectedTeamIdentifier,
            quarantined: false,
            launched: true
        ).isUsable)
    }

    @Test("A refused launch is never usable, however healthy the rest looks")
    func refusedLaunchIsNotUsable() {
        // The connector must not spawn a binary that failed the trust gates, so
        // these all arrive with `launch == nil`. Diagnosing is not a channel for
        // asking an unsandboxed service to execute something.
        for probe in [
            diagnosis(signatureValid: false, team: SteamCMDBootstrapPackage.expectedTeamIdentifier,
                      quarantined: false, launched: false),
            diagnosis(signatureValid: true, team: "ABCDE12345", quarantined: false, launched: false),
            diagnosis(signatureValid: true, team: SteamCMDBootstrapPackage.expectedTeamIdentifier,
                      quarantined: true, launched: false)
        ] {
            #expect(!probe.isUsable)
            #expect(probe.launch == nil)
        }
    }

    @Test("The connector gates the spawn on signature and quarantine")
    func spawnIsGatedInSource() throws {
        // Source-level guard: the connector target is not linked into this test
        // bundle, so this is the only way to hold that ordering.
        let source = try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("SteamConnector/SteamConnector.swift"),
            encoding: .utf8
        )
        let body = try #require(source.range(of: "func diagnoseSteamCMD"))
        let tail = String(source[body.lowerBound...].prefix(6000))
        let gate = try #require(tail.range(of: "guard signature.isValid"))
        let spawn = try #require(tail.range(of: "Self.runSteamCMD("))
        // Ordering is the whole property: computing the verdict after the spawn
        // would report the same fields and still have executed the binary.
        #expect(gate.lowerBound < spawn.lowerBound)
        #expect(tail.contains("expectedTeamIdentifier"))
        #expect(tail.contains("quarantined == nil"))
    }
}

/// The rule that keeps execution and diagnosis agreeing on which binary is
/// trustworthy. Before this, execution took the first Mach-O outside a
/// container while diagnosis applied the signature and quarantine gates — so a
/// copy the diagnosis had refused could still be the one that ran.
@Suite("Trusted candidate walk")
struct SteamCMDTrustedCandidateWalkTests {

    private func walk(
        _ candidates: [String],
        trusted: Set<String>,
        unresolvable: Set<String> = []
    ) -> String? {
        SteamCMDDiagnosisPlan.firstTrusted(
            in: candidates,
            resolve: { unresolvable.contains($0) ? nil : $0 },
            isTrusted: { trusted.contains($0) }
        )
    }

    @Test("A rejected first candidate does not end the search")
    func rejectedCandidateFallsThrough() {
        // The case that motivated this: a stale managed install that no longer
        // passes the signature gate, with a working Homebrew copy behind it.
        let picked = walk(
            ["/managed/steamcmd", "/opt/homebrew/bin/steamcmd"],
            trusted: ["/opt/homebrew/bin/steamcmd"]
        )
        #expect(picked == "/opt/homebrew/bin/steamcmd")
    }

    @Test("Control: the first candidate wins when it is trustworthy")
    func trustedFirstCandidateWins() {
        // Without this the walk could be "always take the last one" and the
        // test above would still pass.
        let picked = walk(
            ["/managed/steamcmd", "/opt/homebrew/bin/steamcmd"],
            trusted: ["/managed/steamcmd", "/opt/homebrew/bin/steamcmd"]
        )
        #expect(picked == "/managed/steamcmd")
    }

    @Test("Nothing trustworthy means nothing runs")
    func noTrustedCandidateYieldsNil() {
        // Fail closed: returning an untrusted path here would hand it straight
        // to a spawn in an unsandboxed process.
        #expect(walk(["/a/steamcmd", "/b/steamcmd"], trusted: []) == nil)
    }

    @Test("A candidate that will not resolve is skipped, not fatal")
    func unresolvableCandidateIsSkipped() {
        let picked = walk(
            ["/gone/steamcmd", "/opt/homebrew/bin/steamcmd"],
            trusted: ["/opt/homebrew/bin/steamcmd"],
            unresolvable: ["/gone/steamcmd"]
        )
        #expect(picked == "/opt/homebrew/bin/steamcmd")
    }

    @Test("A candidate resolving into an app container is refused even if trusted")
    func containerCandidateRefused() {
        // The fence exists because the sandboxed caller can write there; a
        // "trusted" verdict must not be able to override it.
        let picked = walk(
            ["/Users/p/Library/Containers/com.loomscreen.pro/Data/steamcmd", "/opt/homebrew/bin/steamcmd"],
            trusted: [
                "/Users/p/Library/Containers/com.loomscreen.pro/Data/steamcmd",
                "/opt/homebrew/bin/steamcmd"
            ]
        )
        #expect(picked == "/opt/homebrew/bin/steamcmd")
    }
}
