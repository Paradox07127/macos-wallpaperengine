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
        let healthy = diagnosis()
        #expect(healthy.isUsable)
        #expect(healthy.remedy == nil)
    }

    @Test("Nothing weaker than a completed run counts as usable")
    func noLaunchIsNeverUsable() {
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
        #expect(SteamCMDLaunchProbe.classify(exitCode: 0, timedOut: false) == .succeeded)
    }

    @Test("A failed spawn is distinguished from a non-zero exit")
    func classifySeparatesSpawnFailure() {
        // `spawn` reports a `Process.run()` throw as -1 (a quarantined Mach-O is
        // the case that produces it).
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
        #expect(SteamCMDDiagnosisProbe.clampedLaunchTimeout(120) == 120)
    }

    @Test("The diagnosis argv is inside the connector's own read-only probe set")
    func launchArgumentsAreAnAllowedProbe() {
        #expect(SteamCMDProbeArgumentPolicy.isAllowed(SteamCMDDiagnosisProbe.arguments))
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

    /// Passed explicitly: the default reads the real filesystem, so the branch
    /// would otherwise depend on the test machine's SteamCMD.
    @Test("Not found, with nothing on disk, tells the user how to get one")
    func notFoundAdvisesInstalling() {
        let advice = SteamCMDDiagnosis.notFound(
            resolutionFailure: "userPicked: notMachO", rejectedExisting: []
        ).remedy
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

    /// Passed explicitly so the ordering pinned here does not depend on what the
    /// machine running the tests happens to have under `/opt/homebrew`.
    private static let discovered = [
        URL(fileURLWithPath: "/opt/homebrew/bin/steamcmd"),
        URL(fileURLWithPath: "/usr/local/bin/steamcmd"),
        URL(fileURLWithPath: "/opt/local/bin/steamcmd")
    ]

    @Test("The managed install is tried before the package managers, in that order")
    func planOrder() {
        let plan = SteamCMDDiagnosisPlan.candidates(
            managedInstall: Self.managedBinary, discovered: Self.discovered
        )
        #expect(plan.map(\.source) == [.managedInstall, .homebrew, .usrLocal, .macPorts])
        #expect(plan.first?.path == Self.managedBinary.path(percentEncoded: false))
    }

    @Test("Control: with no managed install the three package-manager paths are still tried")
    func planWithoutManagedInstall() {
        let plan = SteamCMDDiagnosisPlan.candidates(
            managedInstall: nil, discovered: Self.discovered
        )
        #expect(plan.map(\.source) == [.homebrew, .usrLocal, .macPorts])
        #expect(plan.map(\.path) == [
            "/opt/homebrew/bin/steamcmd",
            "/usr/local/bin/steamcmd",
            "/opt/local/bin/steamcmd"
        ])
    }

    @Test("The request carries no path of any kind")
    func requestCannotNameAnExecutable() throws {
        let wire = try JSONEncoder().encode(SteamCMDDiagnosisRequest())
        let fields = try #require(
            try JSONSerialization.jsonObject(with: wire) as? [String: Any]
        )
        #expect(fields["pickedPath"] == nil)
        #expect(fields["managedInstallPath"] == nil)
        #expect(fields.keys.sorted() == ["launchTimeout"])
    }

    @Test("Resolution and diagnosis take no path from the app")
    func resolutionSurfaceTakesNoPath() throws {
        let body = try Self.connectorProtocolSource()
        #expect(!body.contains("pickedPath"))
        #expect(!body.contains("managedInstallPath"))
        // Control: the method that no longer takes one is still on the surface.
        #expect(body.contains("func locateSteamCMDBinary(with reply:"))
    }

    /// Exactly two methods may take a path; a third appearing here must be a
    /// deliberate edit to this test.
    @Test("Only inspection and manual binding take a path")
    func pathTakingMethodsAreTheKnownTwo() throws {
        let body = try Self.connectorProtocolSource()
        let pathTakers = body
            .components(separatedBy: "func ")
            .dropFirst()
            .filter { $0.contains("path: String") }
            .map { String($0.prefix(while: { $0 != "(" })) }
        #expect(pathTakers.sorted() == ["bindManualSteamCMDBinary", "inspectSteamCMDBinary"])

        #expect(!body.contains("steamCMDPath"))
        #expect(!body.contains("tarballPath"))
        #expect(!body.contains("pickedPath"))
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

    /// The Caskroom and command-wrapper candidates carry a version directory,
    /// so a switch over whole paths would label them `.notFound`.
    @Test("Caskroom and command-wrapper candidates are still labelled Homebrew")
    func homebrewLabelSurvivesTheVersionDirectory() {
        #expect(SteamCMDDiagnosisPlan.packageManagerSource(
            forCandidatePath: "/opt/homebrew/Caskroom/steamcmd/1779919584/MacOS/steamcmd"
        ) == .homebrew)
        #expect(SteamCMDDiagnosisPlan.packageManagerSource(
            forCandidatePath: "/opt/homebrew/.homebrew-command-wrappers/steamcmd"
        ) == .homebrew)
        // Control: `/usr/local` alone is not Homebrew.
        #expect(SteamCMDDiagnosisPlan.packageManagerSource(
            forCandidatePath: "/usr/local/bin/steamcmd") == .usrLocal)
    }
}

@Suite("SteamCMD manual binding")
struct SteamCMDManualBindingTests {
    private static let manual = URL(fileURLWithPath: "/Volumes/Tools/steamcmd/steamcmd")
    private static let managed = URL(fileURLWithPath: "/Users/p/Library/Application Support/Loomscreen/SteamCMD/MacOS/steamcmd")
    private static let discovered = [URL(fileURLWithPath: "/opt/homebrew/bin/steamcmd")]

    @Test("A manual pick is tried before everything auto-detection found")
    func manualGoesFirst() {
        let plan = SteamCMDDiagnosisPlan.candidates(
            managedInstall: Self.managed, manual: Self.manual, discovered: Self.discovered
        )
        #expect(plan.map(\.source) == [.manual, .managedInstall, .homebrew])
        #expect(plan.first?.path == Self.manual.path(percentEncoded: false))
    }

    @Test("Control: with no manual pick the order is unchanged")
    func withoutManualPick() {
        let plan = SteamCMDDiagnosisPlan.candidates(
            managedInstall: Self.managed, manual: nil, discovered: Self.discovered
        )
        #expect(plan.map(\.source) == [.managedInstall, .homebrew])
    }

    @Test("A manual pick that fails its gates falls through to the next candidate")
    func untrustedManualPickFallsThrough() {
        let plan = SteamCMDDiagnosisPlan.candidates(
            managedInstall: Self.managed, manual: Self.manual, discovered: Self.discovered
        ).map(\.path)

        let picked = SteamCMDDiagnosisPlan.firstTrusted(
            in: plan,
            resolve: { $0 },
            isTrusted: { $0 != Self.manual.path(percentEncoded: false) }
        )
        #expect(picked == Self.managed.path(percentEncoded: false))
    }

    @Test("A relative path is never stored")
    func relativePathsAreRefused() throws {
        let home = try Fixture.home()
        defer { try? FileManager.default.removeItem(at: home) }

        try SteamCMDManualBinding.store("../../etc/steamcmd", home: home)
        #expect(SteamCMDManualBinding.load(home: home) == nil)
        try SteamCMDManualBinding.store("/opt/tools/steamcmd", home: home)
        #expect(SteamCMDManualBinding.load(home: home)?.path == "/opt/tools/steamcmd")
    }

    @Test("Clearing the binding returns resolution to auto-detection")
    func clearingRestoresAutoDetection() throws {
        let home = try Fixture.home()
        defer { try? FileManager.default.removeItem(at: home) }

        try SteamCMDManualBinding.store("/opt/tools/steamcmd", home: home)
        SteamCMDManualBinding.clear(home: home)
        #expect(SteamCMDManualBinding.load(home: home) == nil)
    }

    @Test("The record lives under the connector's own root in the real home")
    func recordLivesOutsideTheContainer() {
        let path = SteamCMDManualBinding.recordURL(
            home: URL(fileURLWithPath: "/Users/p")
        ).path
        #expect(path == "/Users/p/Library/Application Support/Loomscreen/manual-steamcmd-path")
    }

    private enum Fixture {
        static func home() throws -> URL {
            let url = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("steamcmd-manual-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            return url
        }
    }
}

@Suite("SteamCMD Homebrew discovery")
struct SteamCMDHomebrewDiscoveryTests {

    @Test("A cask that only exists in the Caskroom is found")
    func caskroomOnlyInstallIsFound() throws {
        let prefix = try Fixture.homebrewPrefix(versions: ["1779919584"])
        defer { Fixture.remove(prefix) }

        let paths = SteamCMDBinaryResolver.autoDetectCandidates(
            roots: .init(homebrewPrefixes: [prefix.path], macPortsPrefix: "/nonexistent")
        ).map(\.path)

        #expect(paths.contains(
            prefix.appendingPathComponent("Caskroom/steamcmd/1779919584/MacOS/steamcmd").path
        ))
    }

    @Test("The Caskroom's .metadata sibling is not offered as a binary")
    func metadataIsSkipped() throws {
        let prefix = try Fixture.homebrewPrefix(versions: ["1779919584"], withMetadata: true)
        defer { Fixture.remove(prefix) }

        let paths = SteamCMDBinaryResolver.autoDetectCandidates(
            roots: .init(homebrewPrefixes: [prefix.path], macPortsPrefix: "/nonexistent")
        ).map(\.path)

        #expect(!paths.contains { $0.contains(".metadata") })
        // Control: the real version directory beside it did come through.
        #expect(paths.contains { $0.contains("/1779919584/") })
    }

    @Test("Newer Caskroom versions are tried before the ones an upgrade left behind")
    func newestVersionFirst() throws {
        let prefix = try Fixture.homebrewPrefix(versions: ["1000000000", "2000000000"])
        defer { Fixture.remove(prefix) }
        // Explicit mtimes: directory-listing order is not sorted by anything.
        try Fixture.touch(prefix, version: "1000000000", daysAgo: 30)
        try Fixture.touch(prefix, version: "2000000000", daysAgo: 1)

        let caskroom = SteamCMDBinaryResolver.autoDetectCandidates(
            roots: .init(homebrewPrefixes: [prefix.path], macPortsPrefix: "/nonexistent")
        ).map(\.path).filter { $0.contains("/Caskroom/") }

        // Each version contributes every known entry point, so compare the
        // version blocks rather than a flat count.
        #expect(caskroom.count == 2 * SteamCMDBinaryResolver.caskroomEntryPoints.count)
        let newestBlock = caskroom.prefix(SteamCMDBinaryResolver.caskroomEntryPoints.count)
        #expect(newestBlock.allSatisfy { $0.contains("/2000000000/") })
        #expect(caskroom.last?.contains("/1000000000/") == true)
    }

    @Test("A cask version offers its wrapper as well as the Mach-O paths")
    func caskVersionOffersEveryKnownEntryPoint() throws {
        let prefix = try Fixture.homebrewPrefix(versions: ["1779919584"])
        defer { Fixture.remove(prefix) }

        let paths = SteamCMDBinaryResolver.autoDetectCandidates(
            roots: .init(homebrewPrefixes: [prefix.path], macPortsPrefix: "/nonexistent")
        ).map(\.path)

        let version = prefix.appendingPathComponent("Caskroom/steamcmd/1779919584")
        #expect(paths.contains(version.appendingPathComponent("steamcmd.wrapper.sh").path))
        #expect(paths.contains(version.appendingPathComponent("MacOS/steamcmd").path))
        #expect(paths.contains(version.appendingPathComponent("steamcmd").path))
        #expect(paths.contains(version.appendingPathComponent("osx32/steamcmd").path))
    }

    @Test("Not-found advice names the install it could not use instead of saying to install it")
    func notFoundAdviceDoesNotLoopBackToBrew() {
        let nothingOnDisk = SteamCMDDiagnosis.notFound(
            resolutionFailure: "not a Mach-O", rejectedExisting: []
        )
        #expect(nothingOnDisk.remedy?.contains("brew install --cask steamcmd") == true)

        let onDisk = SteamCMDDiagnosis.notFound(
            resolutionFailure: "not a Mach-O",
            rejectedExisting: ["/opt/homebrew/Caskroom/steamcmd/1779919584/MacOS/steamcmd"]
        )
        #expect(onDisk.remedy?.contains("/opt/homebrew/Caskroom/steamcmd/1779919584/MacOS/steamcmd") == true)
        #expect(onDisk.remedy?.contains("brew reinstall") == true)
        #expect(onDisk.remedy?.contains("brew install --cask steamcmd") == false)
    }

    @Test("A diagnosis without the new field still decodes, with no rejected paths")
    func legacyDiagnosisDecodes() throws {
        let legacy = """
        {"source":"notFound","isQuarantined":false,"resolutionFailure":"not a Mach-O"}
        """
        let decoded = try JSONDecoder().decode(
            SteamCMDDiagnosis.self, from: Data(legacy.utf8)
        )
        #expect(decoded.rejectedExistingPaths.isEmpty)
        #expect(decoded.remedy?.contains("brew install --cask steamcmd") == true)
    }

    @Test("The bin symlink is still tried before the Caskroom behind it")
    func binSymlinkOutranksCaskroom() throws {
        let prefix = try Fixture.homebrewPrefix(versions: ["1779919584"])
        defer { Fixture.remove(prefix) }

        let paths = SteamCMDBinaryResolver.autoDetectCandidates(
            roots: .init(homebrewPrefixes: [prefix.path], macPortsPrefix: "/nonexistent")
        ).map(\.path)

        let bin = try #require(paths.firstIndex(of: prefix.appendingPathComponent("bin/steamcmd").path))
        let cask = try #require(paths.firstIndex { $0.contains("/Caskroom/") })
        #expect(bin < cask)
    }

    @Test("The Command Wrapper location is searched")
    func commandWrapperIsSearched() {
        let paths = SteamCMDBinaryResolver.autoDetectCandidates().map(\.path)
        #expect(paths.contains("/opt/homebrew/.homebrew-command-wrappers/steamcmd"))
    }

    @Test("A prefix with nothing installed yields the fixed paths and no more")
    func absentHomebrewIsNotAnError() {
        let paths = SteamCMDBinaryResolver.autoDetectCandidates(
            roots: .init(homebrewPrefixes: ["/nonexistent-prefix"], macPortsPrefix: "/nonexistent")
        ).map(\.path)

        #expect(paths == [
            "/nonexistent-prefix/bin/steamcmd",
            "/nonexistent/bin/steamcmd",
            "/nonexistent-prefix/.homebrew-command-wrappers/steamcmd"
        ])
    }

    /// Homebrew's wrapper does not sit anywhere near the Mach-O, so neither the
    /// `STEAMEXE=` parse nor the sibling search can reach it.
    @Test("A wrapper that only execs another path is followed to the Mach-O")
    func execChainIsFollowed() throws {
        let prefix = try Fixture.homebrewPrefix(versions: ["1779919584"])
        defer { Fixture.remove(prefix) }
        let version = prefix.appendingPathComponent("Caskroom/steamcmd/1779919584")

        // Two hops, the way the cask really is: wrapper → MacOS/steamcmd.sh → Mach-O.
        let inner = version.appendingPathComponent("MacOS/steamcmd.sh")
        try Fixture.script(
            "#!/bin/sh\nexec '\(version.appendingPathComponent("MacOS/steamcmd").path)' \"$@\"\n",
            at: inner
        )
        let outer = version.appendingPathComponent("steamcmd.wrapper.sh")
        try Fixture.script("#!/bin/sh\nexec '\(inner.path)' \"$@\"\n", at: outer)

        let resolved = SteamCMDBinaryResolver.resolveCanonicalBinary(at: outer)
        #expect(try resolved.get().path
            == version.appendingPathComponent("MacOS/steamcmd").path)
    }

    /// `exec "$0" "$@"` is the restart line at the bottom of Valve's own script;
    /// following it would resolve the wrapper to itself.
    @Test("Control: a self-exec restart line is not followed")
    func selfExecIsNotFollowed() throws {
        let root = try Fixture.directory()
        defer { Fixture.remove(root) }
        let script = root.appendingPathComponent("steamcmd")
        try Fixture.script("#!/bin/sh\nexec \"$0\" \"$@\"\n", at: script)

        #expect(throws: SteamCMDBinaryError.self) {
            try SteamCMDBinaryResolver.resolveCanonicalBinary(at: script).get()
        }
    }

    private enum Fixture {
        /// 64-bit little-endian Mach-O magic — enough for `isMachO`.
        static let machOMagic = Data([0xcf, 0xfa, 0xed, 0xfe])

        static func directory() throws -> URL {
            let url = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("steamcmd-discovery-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            return url
        }

        static func homebrewPrefix(versions: [String], withMetadata: Bool = false) throws -> URL {
            let prefix = try directory()
            let cask = prefix.appendingPathComponent("Caskroom/steamcmd", isDirectory: true)
            for version in versions {
                let macOS = cask.appendingPathComponent("\(version)/MacOS", isDirectory: true)
                try FileManager.default.createDirectory(at: macOS, withIntermediateDirectories: true)
                let binary = macOS.appendingPathComponent("steamcmd")
                try machOMagic.write(to: binary)
                try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: binary.path)
            }
            if withMetadata {
                try FileManager.default.createDirectory(
                    at: cask.appendingPathComponent(".metadata", isDirectory: true),
                    withIntermediateDirectories: true
                )
            }
            return prefix
        }

        static func touch(_ prefix: URL, version: String, daysAgo: Int) throws {
            let url = prefix.appendingPathComponent("Caskroom/steamcmd/\(version)")
            try FileManager.default.setAttributes(
                [.modificationDate: Date(timeIntervalSinceNow: -Double(daysAgo) * 86_400)],
                ofItemAtPath: url.path
            )
        }

        static func script(_ body: String, at url: URL) throws {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            try Data(body.utf8).write(to: url)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        }

        static func remove(_ url: URL) {
            try? FileManager.default.removeItem(at: url)
        }
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

        // A link the caller can write, aiming at bytes it cannot: judging the
        // link's own path would refuse it.
        let link = root.appendingPathComponent("steamcmd-link")
        try FileManager.default.createSymbolicLink(
            at: link, withDestinationURL: URL(fileURLWithPath: "/usr/bin/true")
        )
        #expect(!SteamCMDExecutionFence.refusesExecution(of: link.path(percentEncoded: false)))
    }

    @Test("The connector routes every SteamCMD spawn through the fence")
    func runSteamCMDIsFenced() throws {
        let source = try RepositoryRoot.source("SteamConnector/SteamConnector.swift")
        let start = try #require(source.range(of: "static func runSteamCMD("))
        let body = String(source[start.upperBound...].prefix(3500))
        let gate = try #require(body.range(of: "SteamCMDExecutionFence.refusesExecution"))
        // Formatting-insensitive: this scan cares about order, not line breaks.
        let spawn = try #require(body.range(of: "executable: steamCMDPath"))
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
        #expect(body.contains("Self.runSteamCMD("))
        #expect(body.contains("arguments: SteamCMDDiagnosisProbe.arguments"))
        #expect(body.contains("SteamCMDDiagnosisProbe.clampedLaunchTimeout("))
        #expect(body.contains("Self.steamCMDQueue.async"))
        #expect(body.contains("Self.callerAbandoned(enqueuedAt: enqueuedAt)"))
    }

    @Test("Control: the scan reads one method, and a method that spawns nothing shows it")
    func scanDiscriminates() throws {
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
        // these all arrive with `launch == nil`.
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
        let source = try RepositoryRoot.source("SteamConnector/SteamConnector.swift")
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
        let picked = walk(
            ["/managed/steamcmd", "/opt/homebrew/bin/steamcmd"],
            trusted: ["/opt/homebrew/bin/steamcmd"]
        )
        #expect(picked == "/opt/homebrew/bin/steamcmd")
    }

    @Test("Control: the first candidate wins when it is trustworthy")
    func trustedFirstCandidateWins() {
        let picked = walk(
            ["/managed/steamcmd", "/opt/homebrew/bin/steamcmd"],
            trusted: ["/managed/steamcmd", "/opt/homebrew/bin/steamcmd"]
        )
        #expect(picked == "/managed/steamcmd")
    }

    @Test("Nothing trustworthy means nothing runs")
    func noTrustedCandidateYieldsNil() {
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
