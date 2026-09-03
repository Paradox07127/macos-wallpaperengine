#if !LITE_BUILD
import Foundation
@testable import LiveWallpaper
import Testing

@Suite("AF-12: Doctor operation and asset lifecycle", .serialized)
struct SteamCMDDoctorLifecycleTests {
    @Test("operation owner serializes generations and rejects stale completion")
    func operationGenerationsAreExclusive() async throws {
        let coordinator = SteamCMDDoctorOperationCoordinator()
        let firstStarted = AF12Latch()
        let releaseFirst = AF12Latch()
        let secondStarted = AF12Latch()
        let releaseSecond = AF12Latch()
        let secondLeaseBox = AF12LeaseBox()

        let firstTask = Task {
            try await coordinator.withOperation(.appUpdate) { lease in
                await firstStarted.signal()
                await releaseFirst.wait()
                return lease
            }
        }
        await firstStarted.wait()

        let secondTask = Task {
            try await coordinator.withOperation(.workshopDownload) { lease in
                await secondLeaseBox.set(lease)
                await secondStarted.signal()
                await releaseSecond.wait()
                return lease
            }
        }
        for _ in 0 ..< 20 {
            await Task.yield()
        }
        #expect(await !(secondStarted.isSignalled))

        await releaseFirst.signal()
        let firstLease = try await firstTask.value
        await secondStarted.wait()
        let storedSecondLease = await secondLeaseBox.value
        let activeSecondLease = try #require(storedSecondLease)
        #expect(activeSecondLease.generation == firstLease.generation + 1)
        #expect(await coordinator.isCurrent(activeSecondLease))
        #expect(await !(coordinator.isCurrent(firstLease)))
        await releaseSecond.signal()
        let secondLease = try await secondTask.value
        #expect(secondLease.generation == firstLease.generation + 1)
        #expect(await !(coordinator.isCurrent(secondLease)))
    }

    @Test("cancelled waiter consumes no generation and successor can enter")
    func cancelledWaiterDoesNotPublish() async throws {
        let coordinator = SteamCMDDoctorOperationCoordinator()
        let started = AF12Latch()
        let release = AF12Latch()

        let first = Task {
            try await coordinator.withOperation(.appUpdate) { lease in
                await started.signal()
                await release.wait()
                return lease
            }
        }
        await started.wait()
        let cancelled = Task {
            try await coordinator.withOperation(.workshopDownload) { $0 }
        }
        cancelled.cancel()
        do {
            _ = try await cancelled.value
            Issue.record("cancelled operation unexpectedly entered")
        } catch is CancellationError {}

        await release.signal()
        let firstLease = try await first.value
        let successor = try await coordinator.withOperation(.assetsMutation) { $0 }
        #expect(successor.generation == firstLease.generation + 1)
    }

    @Test("cancelled publisher retains the FIFO until durable state precedes its successor")
    func cancelledPublisherCompletesBeforeSuccessor() async throws {
        let coordinator = SteamCMDDoctorOperationCoordinator()
        let commitStarted = AF12Latch()
        let allowPublication = AF12Latch()
        let successorStarted = AF12Latch()
        let durableState = AF12StringBox()

        let publisher = Task {
            try await coordinator.withOperation(.appUpdate) { _ in
                await commitStarted.signal()
                await allowPublication.wait()
                await durableState.set("published-and-marked")
            }
        }
        await commitStarted.wait()
        publisher.cancel()

        let successor = Task {
            try await coordinator.withOperation(.appUpdate) { _ in
                await successorStarted.signal()
                return await durableState.value
            }
        }
        for _ in 0 ..< 20 {
            await Task.yield()
        }
        #expect(await !(successorStarted.isSignalled))

        await allowPublication.signal()
        try await publisher.value
        #expect(try await successor.value == "published-and-marked")
    }

    @Test("same operation inherits its lease while cross-kind nesting fails closed")
    func nestedOperationRules() async throws {
        let coordinator = SteamCMDDoctorOperationCoordinator()
        let inherited = try await coordinator.withOperation(.appUpdate) { outer in
            try await coordinator.withOperation(.appUpdate, inheriting: outer) { inner in
                #expect(inner == outer)
                return inner
            }
        }
        #expect(inherited.generation == 1)

        do {
            _ = try await coordinator.withOperation(.appUpdate) { outer in
                try await coordinator.withOperation(.workshopDownload, inheriting: outer) { $0 }
            }
            Issue.record("cross-kind nested operation unexpectedly entered")
        } catch let error as SteamCMDDoctorOperationError {
            #expect(error == .nestedConflict(active: .appUpdate, requested: .workshopDownload))
        }
    }

    /// The inspection now happens in the connector, so there is no checker to
    /// inject; the rule it fed is tested directly instead.
    private static func inspection(
        sha: String?,
        team: String? = "MXGJJ98X76",
        valid: Bool = true
    ) -> SteamCMDBinaryInspection {
        SteamCMDBinaryInspection(
            exists: sha != nil,
            sha256: sha,
            signatureValid: valid,
            teamIdentifier: team,
            isHardenedRuntime: true,
            isQuarantined: false,
            unavailableReason: nil
        )
    }

    @Test("An unchanged SHA is trusted from cache without re-examining the signature")
    func unchangedBinarySkipsReverification() {
        let decision = SteamCMDDoctorService.evaluateTrust(
            inspection: Self.inspection(sha: "identity-1"),
            cachedSHA256: "identity-1"
        )
        #expect(decision.isTrusted)
        #expect(!decision.didReverify)
        #expect(decision.verifiedSHA256 == "identity-1")
    }

    /// A changed SHA is normal (SteamCMD self-updates) — but it must re-earn
    /// trust, and an attacker-signed replacement must not.
    @Test("A changed SHA is re-verified, and a foreign team identifier is refused")
    func changedBinaryIsReverifiedAgainstValve() {
        let valve = SteamCMDDoctorService.evaluateTrust(
            inspection: Self.inspection(sha: "identity-2"),
            cachedSHA256: "identity-1"
        )
        #expect(valve.isTrusted)
        #expect(valve.didReverify)
        #expect(valve.verifiedSHA256 == "identity-2")

        let attacker = SteamCMDDoctorService.evaluateTrust(
            inspection: Self.inspection(sha: "identity-2", team: "ATTACKER"),
            cachedSHA256: "identity-1"
        )
        #expect(!attacker.isTrusted)
        #expect(attacker.verifiedSHA256 == nil, "a refused binary must not stay cached as verified")

        let unsigned = SteamCMDDoctorService.evaluateTrust(
            inspection: Self.inspection(sha: "identity-2", valid: false),
            cachedSHA256: "identity-1"
        )
        #expect(!unsigned.isTrusted)
    }

    @Test("A binary the connector could not read is never trusted")
    func unreadableBinaryIsRefused() {
        let decision = SteamCMDDoctorService.evaluateTrust(
            inspection: .missing,
            cachedSHA256: "identity-1"
        )
        #expect(!decision.isTrusted)
        #expect(decision.verifiedSHA256 == nil, "a binary that is gone must not stay cached as verified")
    }

    /// "I was too busy to look" is not "the binary is bad". The two shared one
    /// reply shape until 2026-08-02, which made a queued-out inspection read
    /// as a deleted binary and threw away the cached trust with it.
    @Test("A connector that gave up waiting is not a verdict about the binary")
    func unavailableInspectionKeepsCachedTrust() {
        let busy = SteamCMDBinaryInspection.unavailable("expired while queued")
        #expect(!busy.exists, "the flag stays false; the reason is what distinguishes it")

        let decision = SteamCMDDoctorService.evaluateTrust(
            inspection: busy,
            cachedSHA256: "identity-1"
        )
        #expect(!decision.isTrusted, "no verdict means we cannot proceed this round")
        #expect(
            decision.verifiedSHA256 == "identity-1",
            "the cache must survive: nothing said the binary changed"
        )
        #expect(!decision.didReverify)

        // The other direction: a real absence still clears it.
        #expect(SteamCMDBinaryInspection.missing.unavailableReason == nil)
    }

    /// The argv now lives in the connector and cannot be observed from here,
    /// but the reading of what codesign prints is shared — and that is the
    /// part that decides trust.
    @Test("codesign output parses, and a timed-out verify never reads as signed")
    func codesignVerdictParsing() {
        let display = "TeamIdentifier=MXGJJ98X76\nflags=0x10000(runtime)"
        #expect(SteamCMDCodeSignatureParser.teamIdentifier(in: display) == "MXGJJ98X76")
        #expect(SteamCMDCodeSignatureParser.isHardenedRuntime(in: display))
        #expect(SteamCMDCodeSignatureParser.teamIdentifier(in: "no team here") == nil)

        #expect(SteamCMDCodeSignatureParser.signatureValid(verifyExitCode: 0, timedOut: false))
        // Fail-closed: exit 0 on a run that never finished is not a verdict.
        #expect(!SteamCMDCodeSignatureParser.signatureValid(verifyExitCode: 0, timedOut: true))
        #expect(!SteamCMDCodeSignatureParser.signatureValid(verifyExitCode: 1, timedOut: false))
    }

    /// The replace-while-queued window, run against a file that really
    /// changes. The gate moved into the connector with the spawn; this drives
    /// the same function the connector calls immediately before `Process.run`.
    /// The digest gate this used to gate execution with is gone: the app
    /// supplied both the path and the expected digest, so it proved only
    /// that the app agreed with itself. Hashing survives as the Doctor's
    /// self-update detector, and that is what is pinned here.
    @Test("A replaced binary reads as a different digest")
    func replacedBinaryHashesDifferently() throws {
        let fm = FileManager.default
        let root = temporaryRoot("binary-replacement")
        defer { try? fm.removeItem(at: root) }
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        let binary = root.appendingPathComponent("steamcmd")
        try Data("trusted-version".utf8).write(to: binary)

        let path = binary.resolvingSymlinksInPath().path(percentEncoded: false)
        let trusted = try #require(SteamCMDBinaryDigest.sha256(ofFileAt: path))

        try Data("attacker-version".utf8).write(to: binary, options: .atomic)
        #expect(SteamCMDBinaryDigest.sha256(ofFileAt: path) != trusted)

        // A vanished binary reads as nil, not as unchanged.
        try fm.removeItem(at: binary)
        #expect(SteamCMDBinaryDigest.sha256(ofFileAt: path) == nil)
    }

    @Test("The probe argv gate passes exactly the shapes the Doctor sends")
    func probeArgumentAllowlistAcceptsDoctorShapes() {
        #expect(SteamCMDProbeArgumentPolicy.isAllowed(["+quit"]))
        #expect(SteamCMDProbeArgumentPolicy.isAllowed(["+login", "anonymous", "+quit"]))
        #expect(SteamCMDProbeArgumentPolicy.isAllowed(["+login", "anonymous"]))
    }

    @Test("Injection-shaped probe argv is refused")
    func probeArgumentAllowlistRefusesInjection() {
        #expect(!SteamCMDProbeArgumentPolicy.isAllowed([]))
        // Redirecting the install target is a write, not a diagnostic.
        #expect(!SteamCMDProbeArgumentPolicy.isAllowed(["+force_install_dir", "/tmp/x", "+quit"]))
        // Scripts execute arbitrary directive sequences from a file.
        #expect(!SteamCMDProbeArgumentPolicy.isAllowed(["+runscript", "/tmp/evil.txt"]))
        // The probe channel must never log into a real account.
        #expect(!SteamCMDProbeArgumentPolicy.isAllowed(["+login", "realuser", "+quit"]))
        #expect(!SteamCMDProbeArgumentPolicy.isAllowed(["+login"]))
        // Bare words and shell-looking tokens are not SteamCMD directives.
        #expect(!SteamCMDProbeArgumentPolicy.isAllowed(["rm", "-rf", "/"]))
        #expect(!SteamCMDProbeArgumentPolicy.isAllowed(["+quit", ";", "echo", "pwned"]))
        #expect(!SteamCMDProbeArgumentPolicy.isAllowed(["+quit", "+app_update", "431960"]))
        #expect(!SteamCMDProbeArgumentPolicy.isAllowed(["+@ShutdownOnFailedCommand", "1", "+quit"]))
    }

    // MARK: - Launch fast path

    private static func fingerprint(
        path: String = "/opt/homebrew/bin/steamcmd",
        sha: String = "identity-1",
        recordedAt: Date = Date(timeIntervalSince1970: 1_700_000_000)
    ) -> DoctorGreenFingerprint {
        DoctorGreenFingerprint(
            binaryPath: path, sha256: sha, isHardenedRuntime: true, recordedAt: recordedAt
        )
    }

    @Test("An unchanged binary restores the stored green instead of re-probing")
    func unchangedBinaryRestoresGreen() {
        #expect(SteamCMDDoctorService.canRestoreGreen(
            fingerprint: Self.fingerprint(),
            boundBinaryPath: "/opt/homebrew/bin/steamcmd",
            inspection: Self.inspection(sha: "identity-1")
        ))
    }

    /// Everything the three binary probes actually decide on. Any of these
    /// moving while the app was closed has to cost a real probe run —
    /// restoring green here is the one way this optimization can lie.
    @Test("Every input the binary probes judge invalidates the stored green")
    func changedInputsRefuseRestore() {
        let stored = Self.fingerprint()
        let bound = "/opt/homebrew/bin/steamcmd"

        #expect(!SteamCMDDoctorService.canRestoreGreen(
            fingerprint: nil, boundBinaryPath: bound,
            inspection: Self.inspection(sha: "identity-1")
        ), "no record means nothing to restore")

        #expect(!SteamCMDDoctorService.canRestoreGreen(
            fingerprint: stored, boundBinaryPath: bound,
            inspection: Self.inspection(sha: "identity-2")
        ), "SteamCMD self-updated: the new bytes have never been launched")

        #expect(!SteamCMDDoctorService.canRestoreGreen(
            fingerprint: stored, boundBinaryPath: "/usr/local/bin/steamcmd",
            inspection: Self.inspection(sha: "identity-1")
        ), "the record describes a different install")

        #expect(!SteamCMDDoctorService.canRestoreGreen(
            fingerprint: stored, boundBinaryPath: bound,
            inspection: Self.inspection(sha: "identity-1", team: "ATTACKER")
        ))

        #expect(!SteamCMDDoctorService.canRestoreGreen(
            fingerprint: stored, boundBinaryPath: bound,
            inspection: Self.inspection(sha: "identity-1", valid: false)
        ))

        #expect(!SteamCMDDoctorService.canRestoreGreen(
            fingerprint: stored, boundBinaryPath: bound,
            inspection: Self.quarantined(sha: "identity-1")
        ), "quarantine is what the Gatekeeper probe exists to catch")

        #expect(!SteamCMDDoctorService.canRestoreGreen(
            fingerprint: stored, boundBinaryPath: bound, inspection: .missing
        ))

        #expect(!SteamCMDDoctorService.canRestoreGreen(
            fingerprint: stored, boundBinaryPath: bound,
            inspection: .unavailable("queued behind another SteamCMD operation")
        ), "a connector that reached no verdict is not a green light")

        #expect(!SteamCMDDoctorService.canRestoreGreen(
            fingerprint: stored, boundBinaryPath: bound, inspection: nil
        ), "an unreachable connector is not a green light")
    }

    private static func quarantined(sha: String) -> SteamCMDBinaryInspection {
        SteamCMDBinaryInspection(
            exists: true, sha256: sha, signatureValid: true,
            teamIdentifier: "MXGJJ98X76", isHardenedRuntime: true,
            isQuarantined: true, unavailableReason: nil
        )
    }

    @MainActor
    @Test("A failed binary probe retires the record; a restored green keeps its earned date")
    func fingerprintTracksProbeOutcomes() throws {
        let scratch = try TestScratch.defaultsSuite(prefix: "AF12-fingerprint")
        let defaults = scratch.defaults
        defer { scratch.discard() }
        let service = SteamCMDDoctorService(defaults: defaults)
        // Set last: binding a binary is itself a "re-run everything" event.
        service.binaryPath = "/opt/homebrew/bin/steamcmd"

        let earned = Date(timeIntervalSince1970: 1_700_000_000)
        service.greenFingerprint = Self.fingerprint(recordedAt: earned)

        // A restore: three greens, no fresh inspection behind them.
        for kind in SteamCMDDoctorService.binaryProbeKinds {
            service.setProbe(kind, status: .green(detail: nil), lastRun: earned)
        }
        service.updateGreenFingerprint()
        #expect(
            service.greenFingerprint?.recordedAt == earned,
            "a restored green must not re-date a check that never ran"
        )

        service.setProbe(.codeSignature, status: .yellow(message: "unverified", command: nil))
        service.updateGreenFingerprint()
        #expect(service.greenFingerprint == nil)
    }

    @MainActor
    @Test("One run inspects the binary once; a SteamCMD launch retires that answer")
    func inspectionIsReusedWithinARunAndDroppedAcrossALaunch() async throws {
        let scratch = try TestScratch.defaultsSuite(prefix: "AF12-inspection")
        let defaults = scratch.defaults
        defer { scratch.discard() }
        let service = SteamCMDDoctorService(defaults: defaults)
        let path = "/opt/homebrew/bin/steamcmd"
        let answer = Self.inspection(sha: "identity-1")

        // No connector in the test host, so a miss is observable: it is nil.
        service.runScopedInspections[path] = answer
        #expect(await service.inspect(path: path) == answer)

        // SteamCMD rewrites its own executable, so nothing inspected before
        // a launch may be reused after one.
        service.runScopedInspections[path] = answer
        _ = await service.launchSteamCMD(
            SteamCMDDoctorService.SteamCMDBinaryExecutionAuthorization(
                canonicalPath: path, sha256: "identity-1"
            ),
            args: ["+quit"]
        )
        #expect(service.runScopedInspections.isEmpty)

        // And a new run never inherits the previous run's evidence.
        service.runScopedInspections[path] = answer
        await service.runProbe(.workingDirectory)
        #expect(service.runScopedInspections.isEmpty)
    }

    private func temporaryRoot(_ label: String) -> URL {
        FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent("AF12-Lifecycle-\(label)-\(UUID().uuidString)", isDirectory: true)
    }

}

private actor AF12Latch {
    private var signalled = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    var isSignalled: Bool {
        signalled
    }

    func signal() {
        guard !signalled else { return }
        signalled = true
        let current = waiters
        waiters.removeAll(keepingCapacity: false)
        current.forEach { $0.resume() }
    }

    func wait() async {
        if signalled {
            return
        }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }
}

private actor AF12LeaseBox {
    private(set) var value: SteamCMDDoctorOperationLease?

    func set(_ lease: SteamCMDDoctorOperationLease) {
        value = lease
    }
}

private actor AF12StringBox {
    private(set) var value: String?

    func set(_ value: String) {
        self.value = value
    }
}

#endif
