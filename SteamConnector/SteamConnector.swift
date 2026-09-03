import CryptoKit
import Foundation
import os

/// Steam connector service body. Currently only reports its own execution
/// context; login / download / prune land on top of a verified boundary.
final class SteamConnector: NSObject, SteamConnectorProtocol {
    /// Set by the listener when the app exports a progress sink. Long operations
    /// stream through it instead of holding one reply block for minutes.
    var progressSink: (any SteamConnectorProgressProtocol)?

    struct SteamCMDRun {
        let output: String
        let timedOut: Bool
        var exitCode: Int32 = -1
    }

    /// Every SteamCMD run in this process is serialized here. The app used
    /// to hold one operation lease across all of them; once work moved
    /// behind XPC, requests arrived independently, so an engine install and
    /// a Workshop download could drive two SteamCMD processes at the same
    /// real Steam profile (sharing its lock and staging directory) and one
    /// loses. Serializing here is the only place the guarantee survives an
    /// arbitrary number of clients.
    private static let steamCMDQueue = DispatchQueue(label: "com.loomscreen.pro.SteamConnector.steamcmd")

    /// Registered by `spawn` only on the SteamCMD path — codesign shares
    /// `spawn` and must never be what a user cancel kills.
    static let activeSteamCMD = SteamCMDActiveProcessRegistry()

    /// How long a queued request may wait before the client is assumed to have
    /// given up. Serializing everything means a request can sit behind a long
    /// install; without this it would still run — deleting or downloading with
    /// nobody listening, after the UI already reported failure.
    private static let maxQueueWait: TimeInterval = 900

    /// True when this request waited so long that its caller has certainly
    /// timed out. Must be checked at the top of every queued body.
    private static func callerAbandoned(enqueuedAt: Date) -> Bool {
        Date().timeIntervalSince(enqueuedAt) > maxQueueWait
    }

    /// One wording for every entry point that could not produce a binary, so
    /// the diagnostics export reads the same whichever operation tripped it.
    private static let noExecutableReason =
        "No SteamCMD available at any location this process is willing to run"

    /// The binary every operation actually spawns, resolved from its own
    /// candidate list. Callers used to name it and pass a digest to
    /// re-check before the spawn — that gate proved nothing: the caller
    /// supplied both the path and the digest compared against, so a
    /// compromised app passed trivially by naming its own file (macOS has
    /// no `fexecve` to bind a verdict to the inode that ends up executed).
    /// Deriving the path closes it: everything reachable here sits outside
    /// the app's sandbox, so there's nothing for it to replace. Applies the
    /// SAME trust gates the diagnosis does — Valve's signature, no
    /// quarantine — moving to the next candidate on failure; without them
    /// this picked the first Mach-O outside a container, so a copy the
    /// diagnosis had explicitly refused still executed here while the app
    /// showed a healthy Homebrew binding. Deliberately not cached: a
    /// managed install rewrites its own binary during `+quit`, so a cache
    /// keyed on path alone could answer for a file that no longer exists,
    /// and the two `codesign` spawns cost microseconds beside the SteamCMD
    /// run they gate. `spawn` is injected so the candidate walk runs
    /// without invoking `codesign` on whatever the test machine has
    /// installed.
    static func resolvedExecutablePath(
        spawn: ((String, [String], TimeInterval) -> (output: String, exitCode: Int32, timedOut: Bool))? = nil
    ) -> String? {
        let spawn = spawn ?? { path, arguments, timeout in
            let run = SteamConnector.spawn(executable: path, arguments: arguments, timeout: timeout)
            return (run.output, run.exitCode, run.timedOut)
        }
        return SteamCMDDiagnosisPlan.firstTrusted(
            in: SteamCMDDiagnosisPlan.candidates(
                managedInstall: SteamCMDManagedInstaller.managedBinary()
            ).map(\.path),
            resolve: { candidate in
                guard case .success(let url) = SteamCMDBinaryResolver.resolveCanonicalBinary(
                    at: URL(fileURLWithPath: candidate)
                ) else { return nil }
                return url.path(percentEncoded: false)
            },
            isTrusted: { path in
                guard case .success = SteamCMDManagedInstaller.verifySignature(
                    binaryPath: path, spawn: spawn
                ) else { return false }
                guard case .success = SteamCMDManagedInstaller.rejectIfQuarantined(
                    binaryPath: path
                ) else { return false }
                return true
            }
        )
    }

    /// SteamCMD runs go through here. Directives travel in argv so nothing is
    /// written to disk, and progress lines are parsed as they arrive.
    static func runSteamCMD(
        steamCMDPath: String,
        arguments: [String],
        timeout: TimeInterval,
        operationID: String? = nil,
        onProgress: (@Sendable (SteamOperationProgress) -> Void)? = nil
    ) -> SteamCMDRun {
        // Every SteamCMD execution in this process funnels through here, so this
        // is the one place the fence has to hold. Reported as a failed spawn,
        // which is what a refused path already looks like to every caller.
        guard !SteamCMDExecutionFence.refusesExecution(of: steamCMDPath) else {
            return SteamCMDRun(
                output: "refused: \(steamCMDPath) is inside the calling app's writable storage",
                timedOut: false
            )
        }
        // Exit 42 is SteamCMD's "my self-update replaced the binary —
        // relaunch me"; a fresh install needs two restarts before its first
        // 0 (measured 2026-08-28). Each attempt gets the full timeout, so
        // worst-case wall clock is maxExecutions × timeout, and the
        // rewritten binary is re-gated before every relaunch: earlier trust
        // verdicts describe a file that no longer exists.
        let verifySpawn: (String, [String], TimeInterval) -> (output: String, exitCode: Int32, timedOut: Bool) = { path, verifyArguments, verifyTimeout in
            let run = spawn(executable: path, arguments: verifyArguments, timeout: verifyTimeout)
            return (run.output, run.exitCode, run.timedOut)
        }
        let outcome = SteamCMDSelfUpdateRestartPolicy.run(
            execute: {
                spawn(
                    executable: steamCMDPath,
                    arguments: arguments,
                    timeout: timeout,
                    activeOperationID: operationID
                ) { line in
                    guard let onProgress, let progress = SteamCMDProgressLine.parse(line) else { return }
                    onProgress(progress)
                }
            },
            exitCode: { $0.exitCode },
            timedOut: { $0.timedOut },
            revalidate: {
                if case .failure(let failure) = SteamCMDManagedInstaller.verifySignature(
                    binaryPath: steamCMDPath, spawn: verifySpawn
                ) {
                    return failure.failureReason ?? "code signature rejected"
                }
                if case .failure(let failure) = SteamCMDManagedInstaller.rejectIfQuarantined(
                    binaryPath: steamCMDPath
                ) {
                    return failure.failureReason ?? "binary is quarantined"
                }
                return nil
            }
        )
        switch outcome {
        case .completed(let run):
            return run
        case .gateFailed(let reason):
            // Reported as a failed spawn (exit -1), which is what a refused
            // binary already looks like to every caller.
            return SteamCMDRun(
                output: "refused: self-update rewrote \(steamCMDPath) and the replacement failed a trust gate: \(reason)",
                timedOut: false
            )
        }
    }

    /// The one place this process creates a child. SteamCMD and `codesign`
    /// share it: two spawn implementations would mean two places to forget
    /// the scrubbed environment or process-group teardown. stdin is closed
    /// so SteamCMD's `@NoPromptForPassword` can never be bypassed by an
    /// interactive prompt.
    private static func spawn(
        executable: String,
        arguments: [String],
        timeout: TimeInterval,
        activeOperationID: String? = nil,
        onLine: (@Sendable (String) -> Void)? = nil
    ) -> SteamCMDRun {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.environment = SteamCMDChildEnvironment.make()
        process.standardInput = FileHandle.nullDevice
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        do { try process.run() } catch {
            return SteamCMDRun(output: error.localizedDescription, timedOut: false)
        }
        let pid = process.processIdentifier
        // Give SteamCMD its own process group so the whole tree can be
        // signalled — its self-update helper outlives a plain terminate()
        // and keeps the pipe write end open, which previously held the
        // reader past the deadline even after the parent was gone. Racy by
        // nature (the child may already have exec'd), so the signalling
        // below falls back to the bare pid when the group was never created.
        let hasOwnGroup = setpgid(pid, pid) == 0 || getpgid(pid) == pid
        if let activeOperationID {
            activeSteamCMD.register(pid: pid, hasOwnGroup: hasOwnGroup, operationID: activeOperationID)
        }

        // Bounded, not accumulating. SteamCMD can emit hundreds of megabytes on a
        // bad run, and this process is unsandboxed; the semantic summary keeps the
        // handful of lines callers actually parse (version banner, "Success.
        // Downloaded item", public buildid) even after the ring has evicted them.
        let state = OSAllocatedUnfairLock(
            initialState: (
                output: SteamCMDOutputTail(maxBytes: 1 << 20),
                summary: SteamCMDOutputSemanticSummary(),
                pending: "",
                timedOut: false,
                finished: false
            )
        )
        let done = DispatchSemaphore(value: 0)
        let handle = pipe.fileHandleForReading

        // Non-blocking: a silent child no longer parks a queue worker in the
        // kernel, so the deadline below is always able to fire.
        handle.readabilityHandler = { source in
            // Already torn down: never touch shared state after the waiter left.
            guard !state.withLock({ $0.finished }) else { return }
            let chunk = source.availableData
            guard !chunk.isEmpty else {
                let alreadyFinished = state.withLock { s -> Bool in
                    if s.finished { return true }
                    s.finished = true
                    return false
                }
                if !alreadyFinished { done.signal() }
                return
            }
            let lines: [String] = state.withLock { s in
                s.output.append(chunk)
                s.pending += String(decoding: chunk, as: UTF8.self)
                var complete: [String] = []
                while let newline = s.pending.firstIndex(of: "\n") {
                    complete.append(String(s.pending[..<newline]))
                    s.pending = String(s.pending[s.pending.index(after: newline)...])
                }
                // Every line is offered to the summary, whether or not anyone is
                // listening for progress — the facts it keeps are read from the
                // final output, not streamed.
                for line in complete { s.summary.consume(line) }
                return complete
            }
            guard let onLine else { return }
            for line in lines { onLine(line) }
        }

        if done.wait(timeout: .now() + timeout) == .timedOut {
            state.withLock { $0.timedOut = true }
            kill(hasOwnGroup ? -pid : pid, SIGTERM)
            if done.wait(timeout: .now() + 10) == .timedOut {
                kill(hasOwnGroup ? -pid : pid, SIGKILL)
                _ = done.wait(timeout: .now() + 5)
            }
        }

        // Mark finished before detaching: the handler runs on its own queue and
        // may be mid-callback right now, so it must see a state that tells it to
        // do nothing rather than race the teardown.
        state.withLock { $0.finished = true }
        handle.readabilityHandler = nil
        process.waitUntilExit()
        if activeOperationID != nil {
            activeSteamCMD.clear()
        }
        // Close deterministically rather than waiting for the Pipe to be
        // deallocated; a leaked descriptor per run adds up over a session.
        try? handle.close()

        let snapshot = state.withLock { (output: $0.output, summary: $0.summary, timedOut: $0.timedOut) }
        return SteamCMDRun(
            output: snapshot.summary.rendered(with: snapshot.output),
            timedOut: snapshot.timedOut,
            exitCode: process.terminationStatus
        )
    }

    func probeEnvironment(with reply: @escaping @Sendable (Data) -> Void) {
        let realHome = SteamConnectorEnvironmentProbe.posixHomeDirectory()
        let config = SteamConnectorEnvironmentProbe.steamConfigURL(realHome: realHome)

        var byteCount = 0
        var readError: String?
        do {
            // Deliberately a plain read: no bookmark, no security scope. It
            // succeeding is what proves the connector is outside the sandbox.
            byteCount = try Data(contentsOf: config).count
        } catch {
            readError = error.localizedDescription
        }

        let probe = SteamConnectorEnvironmentProbe(
            uid: getuid(),
            nsHomeDirectory: NSHomeDirectory(),
            posixHomeDirectory: realHome,
            steamConfigPath: config.path(percentEncoded: false),
            steamConfigExists: FileManager.default.fileExists(
                atPath: config.path(percentEncoded: false)
            ),
            steamConfigByteCount: byteCount,
            readErrorDescription: readError
        )
        reply((try? JSONEncoder().encode(probe)) ?? Data())
    }

    func discoverAccounts(with reply: @escaping @Sendable (Data) -> Void) {
        let realHome = SteamConnectorEnvironmentProbe.posixHomeDirectory()
        let config = SteamConnectorEnvironmentProbe.steamConfigURL(realHome: realHome)
        // Only the parsed summaries leave this process. `config.vdf` also holds
        // machine-auth tokens and connect-cache secrets, so the raw text must
        // never be handed back across the XPC boundary.
        let text = (try? String(contentsOf: config, encoding: .utf8)) ?? ""
        let accounts = SteamAccountsFile.parseAccounts(fromConfigVDF: text)
        reply((try? JSONEncoder().encode(accounts)) ?? Data())
    }

    func probeCachedLogin(
        accountName: String,
        with reply: @escaping @Sendable (Data) -> Void
    ) {
        @Sendable func respond(_ result: SteamCachedLoginResult) {
            reply((try? JSONEncoder().encode(result)) ?? Data())
        }

        // The name is about to become an argv element, so re-validate here even
        // though discovery already filtered: this entry point is reachable with
        // whatever the caller passes.
        guard SteamAccountsFile.isValidAccountName(accountName) else {
            respond(SteamCachedLoginResult(
                outcome: .steamCMDUnavailable,
                steamID64: nil,
                diagnosticTail: ""
            ))
            return
        }

        // Off the XPC handler queue: this blocks on a child process.
        let enqueuedAt = Date()
        Self.steamCMDQueue.async {
            guard !Self.callerAbandoned(enqueuedAt: enqueuedAt) else {
                respond(SteamCachedLoginResult(outcome: .timedOut, steamID64: nil, diagnosticTail: ""))
                return
            }
            // Resolved after the queue wait, not before: the wait can outlast a
            // managed install landing, and the answer should be the binary that
            // exists now.
            guard let steamCMDPath = Self.resolvedExecutablePath() else {
                respond(SteamCachedLoginResult(
                    outcome: .steamCMDUnavailable,
                    steamID64: nil,
                    diagnosticTail: Self.noExecutableReason
                ))
                return
            }
            respond(Self.runCachedLoginProbe(accountName: accountName, steamCMDPath: steamCMDPath))
        }
    }

    func downloadWorkshopItem(
        workshopID: String,
        accountName: String,
        operationID: String,
        with reply: @escaping @Sendable (Data) -> Void
    ) {
        @Sendable func respond(_ outcome: SteamWorkshopDownloadResult.Outcome, tail: String = "", path: String? = nil, executed: String? = nil) {
            let result = SteamWorkshopDownloadResult(
                outcome: outcome,
                itemPath: path,
                diagnosticTail: String(tail.suffix(500)),
                executedBinaryPath: executed
            )
            reply((try? JSONEncoder().encode(result)) ?? Data())
        }
        guard SteamLibraryPaths.isSafeWorkshopID(workshopID),
              SteamAccountsFile.isValidAccountName(accountName) else {
            respond(.steamCMDUnavailable)
            return
        }

        let sink = progressSink
        let enqueuedAt = Date()
        Self.steamCMDQueue.async {
            guard !Self.callerAbandoned(enqueuedAt: enqueuedAt) else { respond(.timedOut); return }
            // Same pre-spawn resolution as every other entry: after the queue
            // wait, so a managed install that landed while this was queued is
            // the one that runs.
            guard let steamCMDPath = Self.resolvedExecutablePath() else {
                respond(.steamCMDUnavailable, tail: Self.noExecutableReason)
                return
            }
            let run = Self.runSteamCMD(
                steamCMDPath: steamCMDPath,
                arguments: [
                    "+@NoPromptForPassword", "1",
                    "+login", accountName,
                    "+workshop_download_item", SteamLibraryPaths.wallpaperEngineAppID, workshopID,
                    "+quit"
                ],
                timeout: 3600,
                operationID: operationID,
                onProgress: { progress in
                    guard let data = try? JSONEncoder().encode(progress) else { return }
                    sink?.connectorDidReportProgress(data)
                }
            )
            let out = run.output
            if run.timedOut { respond(.timedOut, tail: out, executed: steamCMDPath); return }
            if out.contains("FAILED (No cached credentials") || out.contains("Login Failure") {
                respond(.loginRequired, tail: out, executed: steamCMDPath); return
            }
            if out.contains("ERROR! Download item \(workshopID) failed (No Connection).") {
                respond(.notEntitled, tail: out, executed: steamCMDPath); return
            }
            if out.contains("ERROR! Download item \(workshopID) failed (No match).") {
                respond(.removedFromSteam, tail: out, executed: steamCMDPath); return
            }
            // Trust the tree, not the log line: SteamCMD prints the destination
            // it *intended*, and a partial run can leave that path absent.
            let folder = SteamLibraryPaths.workshopContentRoot()
                .appendingPathComponent(workshopID, isDirectory: true)
            let project = folder.appendingPathComponent("project.json", isDirectory: false)
            guard out.contains("Success. Downloaded item \(workshopID)"),
                  FileManager.default.fileExists(atPath: project.path(percentEncoded: false)) else {
                respond(.unrecognized, tail: out, executed: steamCMDPath); return
            }
            respond(.downloaded, tail: out, path: folder.path(percentEncoded: false), executed: steamCMDPath)
        }
    }

    func deleteWorkshopItem(workshopID: String, with reply: @escaping @Sendable (Data) -> Void) {
        let result = SteamLibraryWriter.deleteWorkshopItem(workshopID: workshopID)
        reply((try? JSONEncoder().encode(result)) ?? Data())
    }

    /// Deliberately NOT on `steamCMDQueue`: the point is to interrupt the run
    /// that queue is currently executing, so this must not wait behind it.
    /// A SIGTERMed child exits with a non-42 status, which also stops the
    /// self-update restart loop in `runSteamCMD`.
    func cancelActiveSteamCMD(operationID: String, with reply: @escaping @Sendable (Data) -> Void) {
        let killed = Self.activeSteamCMD.terminateActive(operationID: operationID)
        reply((try? JSONEncoder().encode(killed)) ?? Data())
    }

    // MARK: - Doctor probes

    func inspectSteamCMDBinary(path: String, with reply: @escaping @Sendable (Data) -> Void) {
        @Sendable func send(_ inspection: SteamCMDBinaryInspection) {
            reply((try? JSONEncoder().encode(inspection)) ?? Data())
        }
        guard FileManager.default.isExecutableFile(atPath: path) else {
            send(.missing)
            return
        }
        // codesign spawns, so it belongs behind the same serial queue as
        // SteamCMD: a self-updating binary must not be read mid-rewrite by an
        // inspection racing an install.
        let enqueuedAt = Date()
        Self.steamCMDQueue.async {
            guard !Self.callerAbandoned(enqueuedAt: enqueuedAt) else {
                send(.unavailable("inspection expired while queued behind another SteamCMD operation"))
                return
            }
            let digest = SteamCMDBinaryDigest.sha256(ofFileAt: path)
            let verify = Self.spawn(
                executable: "/usr/bin/codesign",
                arguments: ["--verify", "--strict", path],
                timeout: 30
            )
            let display = Self.spawn(
                executable: "/usr/bin/codesign",
                arguments: ["-dv", "--verbose=4", path],
                timeout: 30
            )
            let quarantined = (try? URL(fileURLWithPath: path)
                .resourceValues(forKeys: [.quarantinePropertiesKey]).quarantineProperties) ?? nil
            send(SteamCMDBinaryInspection(
                exists: true,
                sha256: digest,
                signatureValid: SteamCMDCodeSignatureParser.signatureValid(
                    verifyExitCode: verify.exitCode, timedOut: verify.timedOut
                ),
                teamIdentifier: SteamCMDCodeSignatureParser.teamIdentifier(in: display.output),
                isHardenedRuntime: SteamCMDCodeSignatureParser.isHardenedRuntime(in: display.output),
                isQuarantined: quarantined != nil,
                unavailableReason: nil
            ))
        }
    }

    func bindManualSteamCMDBinary(path: String, with reply: @escaping @Sendable (Data) -> Void) {
        @Sendable func send(_ result: SteamCMDManualBindResult) {
            reply((try? JSONEncoder().encode(result)) ?? Data())
        }
        // The app is sandboxed and this process is not, so a relative path would
        // be resolved against a working directory the caller cannot see.
        guard path.hasPrefix("/") else {
            return send(SteamCMDManualBindResult(
                outcome: .refused, canonicalPath: nil,
                failureReason: "A SteamCMD path must be absolute.",
                failureCode: .pathNotAbsolute
            ))
        }
        let enqueuedAt = Date()
        // codesign spawns; same serial queue as every other binary read.
        Self.steamCMDQueue.async {
            guard !Self.callerAbandoned(enqueuedAt: enqueuedAt) else {
                return send(SteamCMDManualBindResult(
                    outcome: .refused, canonicalPath: nil,
                    failureReason: "bind expired while queued behind another SteamCMD operation",
                    failureCode: .bindExpiredInQueue
                ))
            }
            let resolution = SteamCMDBinaryResolver.resolveCanonicalBinary(
                at: URL(fileURLWithPath: path)
            )
            guard case .success(let binary) = resolution else {
                return send(SteamCMDManualBindResult(
                    outcome: .notFound, canonicalPath: nil,
                    failureReason: "That file isn't SteamCMD, and no SteamCMD binary was found next to it.",
                    failureCode: .notSteamCMDBinary
                ))
            }
            let canonical = binary.path(percentEncoded: false)
            // Exactly the gates `resolvedExecutablePath` applies on every run.
            // Refusing here is not what makes the pick safe — re-gating at run
            // time is — but binding something we would never execute would
            // report success for a setup that cannot download anything.
            guard !SteamCMDExecutionFence.refusesExecution(of: canonical) else {
                return send(SteamCMDManualBindResult(
                    outcome: .untrusted, canonicalPath: canonical,
                    failureReason: "Loomscreen won't run a SteamCMD from inside its own container.",
                    failureCode: .refusesOwnContainer
                ))
            }
            let verify: (String, [String], TimeInterval) -> (output: String, exitCode: Int32, timedOut: Bool) = {
                let run = Self.spawn(executable: $0, arguments: $1, timeout: $2)
                return (run.output, run.exitCode, run.timedOut)
            }
            guard case .success = SteamCMDManagedInstaller.verifySignature(
                binaryPath: canonical, spawn: verify
            ) else {
                return send(SteamCMDManualBindResult(
                    outcome: .untrusted, canonicalPath: canonical,
                    failureReason: "That binary isn't signed by Valve.",
                    failureCode: .signatureNotValve
                ))
            }
            guard case .success = SteamCMDManagedInstaller.rejectIfQuarantined(binaryPath: canonical) else {
                return send(SteamCMDManualBindResult(
                    outcome: .untrusted, canonicalPath: canonical,
                    failureReason: "That binary is quarantined. Open it once in Finder, or remove the quarantine flag.",
                    failureCode: .binaryQuarantined
                ))
            }
            do {
                try SteamCMDManualBinding.store(canonical)
            } catch {
                return send(SteamCMDManualBindResult(
                    outcome: .refused, canonicalPath: canonical,
                    failureReason: "Couldn't record the choice: \(error.localizedDescription)",
                    failureCode: .couldNotRecordChoice,
                    failureArguments: [error.localizedDescription]
                ))
            }
            send(SteamCMDManualBindResult(
                outcome: .bound, canonicalPath: canonical, failureReason: nil
            ))
        }
    }

    func clearManualSteamCMDBinary(with reply: @escaping @Sendable (Data) -> Void) {
        SteamCMDManualBinding.clear()
        reply((try? JSONEncoder().encode(SteamCMDManualBindResult(
            outcome: .bound, canonicalPath: nil, failureReason: nil
        ))) ?? Data())
    }

    func locateSteamCMDBinary(with reply: @escaping @Sendable (Data) -> Void) {
        func send(_ location: SteamCMDBinaryLocation) {
            reply((try? JSONEncoder().encode(location)) ?? Data())
        }
        // Same derived list the diagnosis walks, so "what would we bind" and
        // "what would we run" can never drift apart.
        let candidates = SteamCMDDiagnosisPlan.candidates(
            managedInstall: SteamCMDManagedInstaller.managedBinary()
        ).map { URL(fileURLWithPath: $0.path) }
        var firstFailure: String?
        for candidate in candidates {
            switch SteamCMDBinaryResolver.resolveCanonicalBinary(at: candidate) {
            case .success(let url):
                send(SteamCMDBinaryLocation(
                    canonicalPath: url.path(percentEncoded: false),
                    failureReason: nil
                ))
                return
            case .failure(let error):
                // Only a managed install we believe exists is worth explaining;
                // an absent package-manager candidate is the normal case.
                if firstFailure == nil, candidate == candidates.first,
                   SteamCMDManagedInstaller.managedBinary() != nil {
                    firstFailure = "\(error)"
                }
            }
        }
        send(SteamCMDBinaryLocation(canonicalPath: nil, failureReason: firstFailure))
    }

    /// Blocking fetch for the SteamCMD queue, which is serial by design — an
    /// install already occupies it for a `+quit` run's length, so waiting
    /// synchronously changes nothing about concurrency. A package download,
    /// retried once if it fails in transit: the retry lives here rather than
    /// around the whole install, since re-running would re-fetch the
    /// manifest and re-download packages that already landed, and a failure
    /// after the digest gate isn't a transport problem to begin with.
    private static func download(
        from url: URL,
        to destination: URL,
        expectedBytes: Int,
        timeout: TimeInterval = 600
    ) -> Bool {
        SteamCMDDownloadRetryPolicy.run(
            attempt: { _ in
                downloadOnce(
                    from: url, to: destination, expectedBytes: expectedBytes, timeout: timeout
                )
            },
            wait: { Thread.sleep(forTimeInterval: $0) }
        )
    }

    /// `URLSession.download` streams to disk; the size gate runs on the file
    /// before a byte of it is read back.
    private static func downloadOnce(
        from url: URL,
        to destination: URL,
        expectedBytes: Int,
        timeout: TimeInterval = 600
    ) -> Bool {
        let semaphore = DispatchSemaphore(value: 0)
        nonisolated(unsafe) var succeeded = false
        let task = URLSession.shared.downloadTask(with: url) { temporary, response, _ in
            defer { semaphore.signal() }
            guard let temporary,
                  (response as? HTTPURLResponse)?.statusCode == 200,
                  let size = (try? FileManager.default.attributesOfItem(
                      atPath: temporary.path(percentEncoded: false)
                  )[.size] as? NSNumber)?.intValue,
                  size == expectedBytes else { return }
            do {
                try? FileManager.default.removeItem(at: destination)
                try FileManager.default.moveItem(at: temporary, to: destination)
                succeeded = true
            } catch {}
        }
        task.resume()
        guard semaphore.wait(timeout: .now() + timeout) == .success else {
            task.cancel()
            return false
        }
        return succeeded
    }

    private static func fetchString(from url: URL, maximumBytes: Int) -> String? {
        let semaphore = DispatchSemaphore(value: 0)
        nonisolated(unsafe) var result: String?
        let task = URLSession.shared.dataTask(with: url) { data, response, _ in
            defer { semaphore.signal() }
            guard let data,
                  data.count <= maximumBytes,
                  (response as? HTTPURLResponse)?.statusCode == 200 else { return }
            result = String(data: data, encoding: .utf8)
        }
        task.resume()
        guard semaphore.wait(timeout: .now() + 60) == .success else {
            task.cancel()
            return nil
        }
        return result
    }

    func installManagedSteamCMD(with reply: @escaping @Sendable (Data) -> Void) {
        @Sendable func send(_ result: SteamCMDManagedInstallResult) {
            reply((try? JSONEncoder().encode(result)) ?? Data())
        }

        // Same serial queue as every other SteamCMD entry point: the final step
        // is a real SteamCMD run, and replacing the payload underneath a
        // download in flight would break it.
        let enqueuedAt = Date()
        Self.steamCMDQueue.async {
            guard !Self.callerAbandoned(enqueuedAt: enqueuedAt) else {
                send(.failed(
                    .unavailable, "install expired while queued behind another SteamCMD operation",
                    code: .installExpiredInQueue
                ))
                return
            }

            let spawn: (String, [String], TimeInterval) -> (output: String, exitCode: Int32, timedOut: Bool) = {
                let run = Self.spawn(executable: $0, arguments: $1, timeout: $2)
                return (run.output, run.exitCode, run.timedOut)
            }

            let root: URL
            switch SteamCMDManagedInstaller.containedInstallRoot(
                SteamCMDManagedInstaller.normalisedPath(
                    SteamCMDManagedInstaller.canonicalInstallRoot()
                )
            ) {
            case .success(let value): root = value
            case .failure(let failure): return send(failure)
            }

            // Everything lands in this process's own tmp before any of it is
            // trusted; the app never touches these bytes at any point.
            let staging = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent(
                    "loomscreen-steamcmd-staging-\(UUID().uuidString)", isDirectory: true
                )
            defer { try? FileManager.default.removeItem(at: staging) }
            do {
                try FileManager.default.createDirectory(
                    at: staging, withIntermediateDirectories: true
                )
            } catch {
                return send(.failed(
                    .unavailable, "Could not create a staging directory",
                    code: .stagingDirectoryFailed
                ))
            }

            // Valve's manifest names the current packages and their digests.
            // Fetched fresh per install — it moves with every SteamCMD release,
            // so there is nothing stable to pin; the code-signature gate below
            // remains the authority on what may execute.
            guard let manifestText = Self.fetchString(
                from: SteamCMDManifest.url, maximumBytes: 1_048_576
            ) else {
                return send(.failed(
                    .unavailable, "Could not fetch Valve's SteamCMD manifest",
                    code: .manifestFetchFailed
                ))
            }
            guard let packages = SteamCMDManifest.parse(manifestText) else {
                return send(.failed(
                    .unavailable,
                    "Valve's SteamCMD manifest did not describe the expected packages",
                    code: .manifestUnexpectedShape
                ))
            }

            var archives: [URL] = []
            for package in packages {
                let destination = staging.appendingPathComponent(
                    package.name + ".zip", isDirectory: false
                )
                guard let packageURL = URL(
                    string: package.file,
                    relativeTo: SteamCMDManifest.url.deletingLastPathComponent()
                )?.absoluteURL else {
                    return send(.failed(
                        .unavailable, "Malformed package name in manifest",
                        code: .manifestMalformedPackageName
                    ))
                }
                guard Self.download(
                    from: packageURL, to: destination, expectedBytes: package.byteCount
                ) else {
                    return send(.failed(
                        .unavailable,
                        "Could not download \(package.name) from Valve's server",
                        code: .packageDownloadFailed, arguments: [package.name]
                    ))
                }
                // The digest gate: what was written must be what the manifest
                // published, hashed from our own copy in our own tmp.
                guard let digest = SteamCMDBinaryDigest.sha256(
                    ofFileAt: destination.path(percentEncoded: false)
                ), digest == package.sha256 else {
                    return send(.failed(
                        .tarballRejected,
                        "\(package.name) did not match the manifest's checksum",
                        code: .packageChecksumMismatch, arguments: [package.name]
                    ))
                }
                archives.append(destination)
            }

            let installed: SteamCMDManagedInstaller.ExtractedInstall
            switch SteamCMDManagedInstaller.extract(
                archives: archives, installRoot: root, spawn: spawn
            ) {
            case .success(let value): installed = value
            case .failure(let failure): return send(failure)
            }
            let payload = installed.payload

            // Every exit from here on has to choose: keep the new tree, or put
            // the one it displaced back. Reinstalling over a working copy and
            // failing a later check must not leave the user with neither.
            @Sendable func reject(_ failure: SteamCMDManagedInstallResult) {
                switch SteamCMDManagedInstaller.rollBack(installed) {
                case .restored, .noPreviousInstall:
                    send(failure)
                case .recoveryFailed(let retiredPath, let reason):
                    // The install failed *and* the copy that used to work is not
                    // back. Reporting only the first half would tell the user to
                    // retry against a SteamCMD that is no longer there.
                    send(failure.withRollbackFailure(retiredPath: retiredPath, reason: reason))
                }
            }

            let binary: URL
            switch SteamCMDManagedInstaller.locateBinary(in: payload) {
            case .success(let value): binary = value
            case .failure(let failure): return reject(failure)
            }
            let binaryPath = binary.path(percentEncoded: false)

            if case .failure(let failure) = SteamCMDManagedInstaller.verifySignature(
                binaryPath: binaryPath, spawn: spawn
            ) {
                return reject(failure)
            }
            if case .failure(let failure) = SteamCMDManagedInstaller.rejectIfQuarantined(
                binaryPath: binaryPath
            ) {
                return reject(failure)
            }

            // First real run — the manifest already delivered current
            // binaries, but steamcmd still arranges its own `package/`
            // bookkeeping here, surfacing a broken install now rather than
            // later. Exit-42 self-update restarts (re-gating the rewritten
            // binary each relaunch) happen inside `runSteamCMD` itself.
            let bootstrap = Self.runSteamCMD(
                steamCMDPath: binaryPath, arguments: ["+quit"], timeout: 600
            )
            guard !bootstrap.timedOut else {
                return reject(.failed(
                    .selfUpdateFailed, "First SteamCMD run timed out", code: .firstRunTimedOut
                ))
            }
            // A failed spawn reports exitCode -1 without timing out, and a
            // self-update that dies mid-way exits non-zero: reporting either as
            // `.installed` would record a broken install as good.
            guard bootstrap.exitCode == 0 else {
                return reject(.failed(
                    .selfUpdateFailed,
                    "First SteamCMD run exited \(bootstrap.exitCode)",
                    code: .firstRunExitedNonZero, arguments: ["\(bootstrap.exitCode)"]
                ))
            }

            // The self-update rewrites the binary that was just verified, so the
            // signature and quarantine verdicts above describe a file that no
            // longer exists. Re-check what will actually be executed from now on.
            let finalBinary: URL
            switch SteamCMDManagedInstaller.locateBinary(in: payload) {
            case .success(let value): finalBinary = value
            case .failure(let failure): return reject(failure)
            }
            let finalPath = finalBinary.path(percentEncoded: false)
            if case .failure(let failure) = SteamCMDManagedInstaller.verifySignature(
                binaryPath: finalPath, spawn: spawn
            ) {
                return reject(failure)
            }
            if case .failure(let failure) = SteamCMDManagedInstaller.rejectIfQuarantined(
                binaryPath: finalPath
            ) {
                return reject(failure)
            }

            guard let digest = SteamCMDBinaryDigest.sha256(ofFileAt: finalPath) else {
                return reject(.failed(
                    .selfUpdateFailed, "Could not hash the installed binary",
                    code: .couldNotHashBinary
                ))
            }
            SteamCMDManagedInstaller.commit(installed)
            send(SteamCMDManagedInstallResult(
                outcome: .installed,
                canonicalPath: finalPath,
                sha256: digest,
                failureReason: nil
            ))
        }
    }

    func signInSteamAccount(_ request: Data, with reply: @escaping @Sendable (Data) -> Void) {
        @Sendable func send(_ result: SteamCMDLoginResult) {
            reply((try? JSONEncoder().encode(result)) ?? Data())
        }
        guard let payload = try? JSONDecoder().decode(SteamCMDLoginRequest.self, from: request),
              SteamAccountsFile.isValidAccountName(payload.accountName) else {
            send(.failed(.unavailable))
            return
        }
        // Same serial queue as every other steamcmd run: an interactive login
        // and a download share one Steam profile and must not interleave.
        let enqueuedAt = Date()
        Self.steamCMDQueue.async {
            guard !Self.callerAbandoned(enqueuedAt: enqueuedAt) else {
                send(.failed(.unavailable))
                return
            }
            guard let binaryPath = Self.resolvedExecutablePath() else {
                send(.failed(.unavailable))
                return
            }
            send(Self.runLoginSession(binaryPath: binaryPath, request: payload))
        }
    }

    /// The one interactive steamcmd session in this process. A PTY, not a
    /// pipe, because the password prompt requires a terminal and lets
    /// steamcmd disable echo itself, as in Terminal. Secrets hygiene: the
    /// password and guard code go to the PTY answering steamcmd's own
    /// prompts and nowhere else — not argv, the transcript (prompts echo
    /// nothing), the reply, or a log. The verdict doesn't trust the
    /// transcript alone: success only if the account then appears in the
    /// shared profile's `config.vdf`, the same ground truth
    /// `discoverAccounts` reads.
    private static func runLoginSession(
        binaryPath: String,
        request: SteamCMDLoginRequest
    ) -> SteamCMDLoginResult {
        guard !SteamCMDExecutionFence.refusesExecution(of: binaryPath) else {
            return .failed(.unavailable)
        }
        func knownAccounts() -> [SteamAccountSummary] {
            let realHome = SteamConnectorEnvironmentProbe.posixHomeDirectory()
            let config = SteamConnectorEnvironmentProbe.steamConfigURL(realHome: realHome)
            let text = (try? String(contentsOf: config, encoding: .utf8)) ?? ""
            return SteamAccountsFile.parseAccounts(fromConfigVDF: text)
        }
        func summary(in accounts: [SteamAccountSummary]) -> SteamAccountSummary? {
            accounts.first { $0.accountName.lowercased() == request.accountName.lowercased() }
        }
        // Snapshot, not a plain "is it there afterwards": for an account that
        // was already cached, presence proves nothing about THIS attempt — a
        // wrong password would read as success.
        let accountKnownBefore = summary(in: knownAccounts()) != nil

        var master: Int32 = -1
        var slave: Int32 = -1
        guard openpty(&master, &slave, nil, nil, nil) == 0 else {
            return .failed(.unavailable)
        }
        defer { close(master) }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: binaryPath)
        process.arguments = SteamCMDLoginProbe.arguments(accountName: request.accountName)
        process.environment = SteamCMDChildEnvironment.make()
        let slaveHandle = FileHandle(fileDescriptor: slave, closeOnDealloc: false)
        process.standardInput = slaveHandle
        process.standardOutput = slaveHandle
        process.standardError = slaveHandle
        do {
            try process.run()
        } catch {
            close(slave)
            return .failed(.unavailable)
        }
        close(slave)

        func write(secret: String) {
            var data = Data((secret + "\n").utf8)
            data.withUnsafeBytes { raw in
                var offset = 0
                while offset < raw.count {
                    let written = Darwin.write(
                        master, raw.baseAddress!.advanced(by: offset), raw.count - offset
                    )
                    guard written > 0 else { break }
                    offset += written
                }
            }
            data.resetBytes(in: 0..<data.count)
        }

        var transcript = ""
        var sentPassword = false
        var sentGuardCode = false
        let deadline = Date().addingTimeInterval(
            SteamCMDLoginProbe.clampedTimeout(request.timeout)
        )
        // `.failed` until a verdict lands; `.timedOut` is set below only when
        // steamcmd is still running at the deadline. Starting at `.timedOut`
        // made a child that exited on its own with no recognised line — a
        // blocked network, typically — read as "approve it on your phone".
        var outcome: SteamCMDLoginResult.Outcome = .failed
        var refusalReason: String?

        readLoop: while Date() < deadline {
            var pollDescriptor = pollfd(fd: master, events: Int16(POLLIN), revents: 0)
            let ready = poll(&pollDescriptor, 1, 500)
            if ready > 0 {
                var buffer = [UInt8](repeating: 0, count: 4096)
                let count = read(master, &buffer, buffer.count)
                // EOF/EIO: the child closed its side — it exited.
                guard count > 0 else { break }
                transcript += String(decoding: buffer[0..<count], as: UTF8.self)
            }
            guard let event = SteamCMDLoginOutputClassifier.event(inTranscript: transcript) else {
                if !process.isRunning { break }
                continue
            }
            switch event {
            case .passwordPrompt:
                if !sentPassword {
                    sentPassword = true
                    write(secret: request.password)
                }
                if !process.isRunning { break readLoop }
            case .guardCodeEmailPrompt, .guardCodeTotpPrompt:
                if let code = request.guardCode, !sentGuardCode {
                    sentGuardCode = true
                    write(secret: code)
                } else if !sentGuardCode {
                    // No code on hand: stop the session and tell the app which
                    // kind to ask for. The password will ride the retry.
                    outcome = event == .guardCodeEmailPrompt
                        ? .guardCodeEmailRequired : .guardCodeTotpRequired
                    break readLoop
                }
                if !process.isRunning { break readLoop }
            case .waitingForMobileConfirmation:
                // Not an outcome — the user is reaching for their phone.
                if !process.isRunning { break readLoop }
            case .invalidPassword:
                outcome = .invalidPassword
                break readLoop
            case .invalidGuardCode:
                outcome = .invalidGuardCode
                break readLoop
            case .rateLimited:
                outcome = .rateLimited
                break readLoop
            case .noConnection:
                outcome = .noConnection
                break readLoop
            case let .refused(reason):
                outcome = .failed
                refusalReason = reason
                break readLoop
            case .loggedIn:
                outcome = .success
                break readLoop
            }
        }
        if process.isRunning {
            if outcome == .failed {
                outcome = .timedOut
            }
            process.terminate()
            // Grace, then the same hard stop every other runner uses.
            let graceDeadline = Date().addingTimeInterval(3)
            while process.isRunning, Date() < graceDeadline {
                usleep(100_000)
            }
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        }

        // Two independent success signals: the transcript's banner, and the
        // account newly appearing in the shared profile's `config.vdf` (the
        // ground truth `discoverAccounts` reads — catches a success whose
        // banner line we failed to match). "Newly": see the snapshot above.
        let accountAfter = summary(in: knownAccounts())
        if outcome == .success || (!accountKnownBefore && accountAfter != nil) {
            return SteamCMDLoginResult(outcome: .success, steamID64: accountAfter?.steamID64)
        }
        return .failed(outcome, reason: refusalReason)
    }

    func removeManagedSteamCMD(with reply: @escaping @Sendable (Data) -> Void) {
        @Sendable func send(_ result: SteamCMDManagedRemovalResult) {
            reply((try? JSONEncoder().encode(result)) ?? Data())
        }
        let enqueuedAt = Date()
        Self.steamCMDQueue.async {
            guard !Self.callerAbandoned(enqueuedAt: enqueuedAt) else {
                return send(SteamCMDManagedRemovalResult(
                    outcome: .refused,
                    failureReason: "removal expired while queued behind another SteamCMD operation"
                ))
            }
            let root = SteamCMDManagedInstaller.canonicalInstallRoot()
            let path = SteamCMDManagedInstaller.normalisedPath(root)
            guard FileManager.default.fileExists(atPath: path) else {
                return send(SteamCMDManagedRemovalResult(outcome: .notInstalled, failureReason: nil))
            }
            // Same symlink walk as install: a link planted along this path would
            // turn a delete of our own directory into a delete of someone's.
            if let offending = SteamCMDManagedInstaller.firstSymlinkComponent(of: root) {
                return send(SteamCMDManagedRemovalResult(
                    outcome: .refused,
                    failureReason: "Install path component is a symbolic link: \(offending)"
                ))
            }
            do {
                try FileManager.default.removeItem(atPath: path)
                send(SteamCMDManagedRemovalResult(outcome: .removed, failureReason: nil))
            } catch {
                send(SteamCMDManagedRemovalResult(
                    outcome: .refused, failureReason: error.localizedDescription
                ))
            }
        }
    }

    func runSteamCMDProbe(_ request: Data, with reply: @escaping @Sendable (Data) -> Void) {
        @Sendable func send(_ run: SteamCMDProbeRun) {
            reply((try? JSONEncoder().encode(run)) ?? Data())
        }
        guard let probe = try? JSONDecoder().decode(SteamCMDProbeRequest.self, from: request) else {
            send(.refused("malformed probe request"))
            return
        }
        // Probes are read-only diagnostics; refuse any argv shape the Doctor
        // does not actually send before anything is queued or hashed.
        guard SteamCMDProbeArgumentPolicy.isAllowed(probe.arguments) else {
            send(.refused("probe arguments are not in the allowed diagnostic set"))
            return
        }
        let enqueuedAt = Date()
        Self.steamCMDQueue.async {
            guard !Self.callerAbandoned(enqueuedAt: enqueuedAt) else {
                send(.refused("probe expired while queued"))
                return
            }
            guard let steamCMDPath = Self.resolvedExecutablePath() else {
                send(.refused(Self.noExecutableReason))
                return
            }
            let run = Self.runSteamCMD(
                steamCMDPath: steamCMDPath,
                arguments: probe.arguments,
                timeout: probe.timeout
            )
            send(SteamCMDProbeRun(
                output: run.output,
                exitCode: run.exitCode,
                timedOut: run.timedOut,
                refusalReason: nil,
                executedBinaryPath: steamCMDPath
            ))
        }
    }

    func diagnoseSteamCMD(_ request: Data, with reply: @escaping @Sendable (Data) -> Void) {
        @Sendable func send(_ diagnosis: SteamCMDDiagnosis) {
            reply((try? JSONEncoder().encode(diagnosis)) ?? Data())
        }
        guard let payload = try? JSONDecoder().decode(
            SteamCMDDiagnosisRequest.self, from: request
        ) else {
            send(.unavailable("malformed diagnosis request"))
            return
        }
        // Ends in a real SteamCMD run, so it queues behind every other one: a
        // diagnosis racing a self-update would report on a half-written binary.
        let enqueuedAt = Date()
        Self.steamCMDQueue.async {
            guard !Self.callerAbandoned(enqueuedAt: enqueuedAt) else {
                send(.unavailable("diagnosis expired while queued behind another SteamCMD operation"))
                return
            }

            var resolutionFailure: String?
            // Every candidate is validated in full. Settling on the first one
            // that merely resolves to a Mach-O meant a stale Homebrew copy that
            // fails signing or `+quit` buried a working install at another
            // path — and with no manual picker left, that state is unrecoverable.
            var firstRejection: SteamCMDDiagnosis?
            let plan = SteamCMDDiagnosisPlan.candidates(
                managedInstall: SteamCMDManagedInstaller.managedBinary()
            )
            candidates: for candidate in plan {
                let resolved: SteamCMDDiagnosisCandidate
                switch SteamCMDBinaryResolver.resolveCanonicalBinary(
                    at: URL(fileURLWithPath: candidate.path)
                ) {
                case .success(let url):
                    // The fence would refuse the spawn anyway; saying so here
                    // turns an unexplained "could not spawn" into a reason.
                    guard !SteamCMDExecutionFence.refusesExecution(
                        of: url.path(percentEncoded: false)
                    ) else {
                        if resolutionFailure == nil {
                            resolutionFailure = "\(candidate.source.rawValue): refused — inside the app's own writable storage"
                        }
                        continue candidates
                    }
                    resolved = SteamCMDDiagnosisCandidate(
                        path: url.path(percentEncoded: false), source: candidate.source
                    )
                case .failure(let error):
                    // Only the install we placed ourselves is worth explaining;
                    // an absent package-manager candidate is the normal case.
                    if resolutionFailure == nil, candidate.source == .managedInstall {
                        resolutionFailure = "\(candidate.source.rawValue): \(error)"
                    }
                    continue candidates
                }

            let verify = Self.spawn(
                executable: "/usr/bin/codesign",
                arguments: ["--verify", "--strict", resolved.path],
                timeout: 30
            )
            let describe = Self.spawn(
                executable: "/usr/bin/codesign",
                arguments: ["-dv", "--verbose=4", resolved.path],
                timeout: 30
            )
            let signature = SteamCMDSignatureVerdict(
                isValid: SteamCMDCodeSignatureParser.signatureValid(
                    verifyExitCode: verify.exitCode, timedOut: verify.timedOut
                ),
                teamIdentifier: SteamCMDCodeSignatureParser.teamIdentifier(in: describe.output),
                isHardenedRuntime: SteamCMDCodeSignatureParser.isHardenedRuntime(in: describe.output)
            )
            let quarantined = (try? URL(fileURLWithPath: resolved.path)
                .resourceValues(forKeys: [.quarantinePropertiesKey]).quarantineProperties) ?? nil
            // Hashed before the run: `+quit` self-updates, so a digest taken
            // afterwards would describe a different file than the one launched.
            let digest = SteamCMDBinaryDigest.sha256(ofFileAt: resolved.path)

            // Launching is a privileged act: this process is unsandboxed and
            // the path came from a sandboxed caller, so diagnosing must not
            // become a way to execute an arbitrary Mach-O — trust gates run
            // BEFORE the spawn. A refusal still reports everything learned;
            // `isUsable` stays false because `launch` is nil.
            guard signature.isValid,
                  signature.teamIdentifier == SteamCMDBootstrapPackage.expectedTeamIdentifier,
                  quarantined == nil else {
                if firstRejection == nil {
                    firstRejection = SteamCMDDiagnosis(
                        source: resolved.source,
                        canonicalPath: resolved.path,
                        resolutionFailure: nil,
                        sha256: digest,
                        signature: signature,
                        isQuarantined: quarantined != nil,
                        launch: nil,
                        unavailableReason: nil
                    )
                }
                continue candidates
            }

            // The verdict. Everything above only explains it — a resolved,
            // signed, unquarantined binary that cannot spawn is exactly the case
            // the app's file-existence checks used to report as healthy.
            let timeout = SteamCMDDiagnosisProbe.clampedLaunchTimeout(payload.launchTimeout)
            let launch = Self.runSteamCMD(
                steamCMDPath: resolved.path,
                arguments: SteamCMDDiagnosisProbe.arguments,
                timeout: timeout
            )
            let diagnosis = SteamCMDDiagnosis(
                source: resolved.source,
                canonicalPath: resolved.path,
                resolutionFailure: nil,
                sha256: digest,
                signature: signature,
                isQuarantined: quarantined != nil,
                launch: SteamCMDLaunchProbe(
                    outcome: SteamCMDLaunchProbe.classify(
                        exitCode: launch.exitCode, timedOut: launch.timedOut
                    ),
                    arguments: SteamCMDDiagnosisProbe.arguments,
                    exitCode: launch.exitCode,
                    timeout: timeout,
                    outputTail: launch.output
                ),
                unavailableReason: nil
            )
            if diagnosis.isUsable {
                send(diagnosis)
                return
            }
            if firstRejection == nil { firstRejection = diagnosis }
            }
            // Nothing worked: report the first real rejection, which carries the
            // signature/launch facts the remedy is derived from. `.notFound` only
            // when no candidate even resolved.
            send(firstRejection ?? .notFound(resolutionFailure: resolutionFailure))
        }
    }

    func latestWallpaperEngineBuildID(
        accountName: String,
        operationID: String,
        with reply: @escaping @Sendable (Data) -> Void
    ) {
        @Sendable func send(_ lookup: SteamEngineBuildLookup) {
            reply((try? JSONEncoder().encode(lookup)) ?? Data())
        }
        guard SteamAccountsFile.isValidAccountName(accountName) else {
            send(.failed(.steamCMDUnavailable))
            return
        }
        // Same profile, same lock: an update check must not race a queued
        // install or download.
        let enqueuedAt = Date()
        Self.steamCMDQueue.async {
            guard !Self.callerAbandoned(enqueuedAt: enqueuedAt) else {
                send(.failed(.timedOut))
                return
            }
            guard let steamCMDPath = Self.resolvedExecutablePath() else {
                send(.failed(.steamCMDUnavailable))
                return
            }
            let run = Self.runSteamCMD(
                steamCMDPath: steamCMDPath,
                arguments: [
                    "+@NoPromptForPassword", "1",
                    "+@sSteamCmdForcePlatformType", "windows",
                    "+login", accountName,
                    "+app_info_update", "1",
                    "+app_info_print", SteamLibraryPaths.wallpaperEngineAppID,
                    "+quit"
                ],
                timeout: 180,
                operationID: operationID
            )
            // Same markers the download and assets-install paths already
            // classify on. This one used to skip the check entirely, so an
            // expired session reached the user as "no build id".
            if run.timedOut { return send(.failed(.timedOut)) }
            let out = run.output
            if out.contains("FAILED (No cached credentials") || out.contains("Login Failure") {
                return send(.failed(.loginRequired))
            }
            // Checked before the parse: with no connection there is no build
            // line to find, and "we could not read the answer" is the wrong
            // story for an answer that never came.
            if out.contains("No Connection") {
                return send(.failed(.steamUnreachable))
            }
            guard let build = SteamConnectorBuildInfo.parsePublicBuildID(from: out) else {
                return send(.failed(.unrecognized))
            }
            send(.found(build))
        }
    }

    func installWallpaperEngineAssets(
        accountName: String,
        operationID: String,
        with reply: @escaping @Sendable (Data) -> Void
    ) {
        @Sendable func respond(_ outcome: SteamEngineAssetsResult.Outcome, tail: String = "", assets: String? = nil, build: String? = nil, executed: String? = nil) {
            let result = SteamEngineAssetsResult(
                outcome: outcome,
                assetsPath: assets,
                buildID: build,
                diagnosticTail: String(tail.suffix(500)),
                executedBinaryPath: executed
            )
            reply((try? JSONEncoder().encode(result)) ?? Data())
        }
        guard SteamAccountsFile.isValidAccountName(accountName) else {
            respond(.steamCMDUnavailable)
            return
        }

        let sink = progressSink
        let enqueuedAt = Date()
        Self.steamCMDQueue.async {
            guard !Self.callerAbandoned(enqueuedAt: enqueuedAt) else { respond(.timedOut); return }
            guard let steamCMDPath = Self.resolvedExecutablePath() else {
                respond(.steamCMDUnavailable, tail: Self.noExecutableReason)
                return
            }
            // `validate` repairs the previous run's pruned tree, so only the
            // files we removed last time come back down the wire.
            let run = Self.runSteamCMD(
                steamCMDPath: steamCMDPath,
                arguments: [
                    "+@NoPromptForPassword", "1",
                    "+@sSteamCmdForcePlatformType", "windows",
                    "+login", accountName,
                    "+app_update", SteamLibraryPaths.wallpaperEngineAppID, "validate",
                    "+quit"
                ],
                timeout: 5400,
                operationID: operationID,
                onProgress: { progress in
                    guard let data = try? JSONEncoder().encode(progress) else { return }
                    sink?.connectorDidReportProgress(data)
                }
            )
            let out = run.output
            if run.timedOut { respond(.timedOut, tail: out, executed: steamCMDPath); return }
            if out.contains("FAILED (No cached credentials") || out.contains("Login Failure") {
                respond(.loginRequired, tail: out, executed: steamCMDPath); return
            }
            if out.contains("No subscription") || out.contains("Invalid Platform") {
                respond(.notEntitled, tail: out, executed: steamCMDPath); return
            }
            guard out.contains("Success! App '\(SteamLibraryPaths.wallpaperEngineAppID)'") else {
                respond(.unrecognized, tail: out, executed: steamCMDPath); return
            }

            if let data = try? JSONEncoder().encode(
                SteamOperationProgress(phase: .pruning, fraction: nil, downloadedBytes: nil, totalBytes: nil)
            ) {
                sink?.connectorDidReportProgress(data)
            }
            do {
                let assets = try SteamLibraryWriter.pruneWallpaperEngineInstall()
                // `app_update`'s output carries a placeholder `"buildid" "0"`,
                // so ask app_info for the branch actually installed instead
                // of scraping the update log. Re-resolved rather than riding
                // the value above: that was read before a 5400s `app_update`,
                // and a self-update inside that window can move the
                // wrapper's target — every spawn resolves for itself.
                guard let infoPath = Self.resolvedExecutablePath() else {
                    respond(.steamCMDUnavailable, tail: Self.noExecutableReason, executed: steamCMDPath)
                    return
                }
                let info = Self.runSteamCMD(
                    steamCMDPath: infoPath,
                    arguments: [
                        "+@NoPromptForPassword", "1",
                        "+@sSteamCmdForcePlatformType", "windows",
                        "+login", accountName,
                        "+app_info_print", SteamLibraryPaths.wallpaperEngineAppID,
                        "+quit"
                    ],
                    timeout: 180
                )
                respond(
                    .installed,
                    tail: out,
                    assets: assets.path(percentEncoded: false),
                    build: SteamConnectorBuildInfo.parsePublicBuildID(from: info.output),
                    // The info run re-resolved; that is the binary that actually
                    // ran last, not the one app_update started with.
                    executed: infoPath
                )
            } catch {
                respond(.pruneRefused, tail: out, executed: steamCMDPath)
            }
        }
    }


    /// Uses the one runner, so a wedged login cannot hold the serial queue: the
    /// previous copy here had only a SIGTERM and then blocked in `readToEnd()`,
    /// which would have stalled every download and install queued behind it.
    private static func runCachedLoginProbe(
        accountName: String,
        steamCMDPath: String
    ) -> SteamCachedLoginResult {
        let run = runSteamCMD(
            steamCMDPath: steamCMDPath,
            arguments: ["+@NoPromptForPassword", "1", "+login", accountName, "+quit"],
            timeout: 60
        )
        if run.timedOut {
            return SteamCachedLoginResult(
                outcome: .timedOut,
                steamID64: nil,
                diagnosticTail: String(run.output.suffix(500)),
                executedBinaryPath: steamCMDPath
            )
        }
        var result = SteamCachedLoginParser.parse(stdout: run.output)
        result.executedBinaryPath = steamCMDPath
        return result
    }
}
