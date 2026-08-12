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

    /// Every SteamCMD run in this process is serialized here.
    ///
    /// The app used to hold one operation lease across all of them; once the
    /// work moved behind XPC each request arrived independently, so an engine
    /// install and a Workshop download could drive two SteamCMD processes at the
    /// same real Steam profile. They share its lock and staging directory, and
    /// one of them loses. Serializing at the process that owns the resource is
    /// the only place the guarantee survives an arbitrary number of clients.
    private static let steamCMDQueue = DispatchQueue(label: "com.loomscreen.pro.SteamConnector.steamcmd")

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

    /// One wording for every entry point the digest gate refuses, so the
    /// diagnostics export reads the same whichever operation tripped it.
    private static let digestMismatchReason =
        "SteamCMD binary changed since it was verified, or could not be read"

    /// SteamCMD runs go through here. Directives travel in argv so nothing is
    /// written to disk, and progress lines are parsed as they arrive.
    static func runSteamCMD(
        steamCMDPath: String,
        arguments: [String],
        timeout: TimeInterval,
        onProgress: (@Sendable (SteamOperationProgress) -> Void)? = nil
    ) -> SteamCMDRun {
        spawn(executable: steamCMDPath, arguments: arguments, timeout: timeout) { line in
            guard let onProgress, let progress = SteamCMDProgressLine.parse(line) else { return }
            onProgress(progress)
        }
    }

    /// The one place this process creates a child.
    ///
    /// SteamCMD and `codesign` share it: two spawn implementations would mean two
    /// places to forget the scrubbed environment or the process-group teardown.
    /// stdin is closed so SteamCMD's `@NoPromptForPassword` can never be bypassed
    /// by an interactive prompt.
    private static func spawn(
        executable: String,
        arguments: [String],
        timeout: TimeInterval,
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
        // Give SteamCMD its own process group so the whole tree can be signalled.
        // Its self-update helper outlives a plain terminate() and keeps the pipe
        // write end open, which is what previously held the reader past the
        // deadline even though the parent was gone.
        //
        // Racy by nature — the child may already have exec'd — so the signalling
        // below falls back to the bare pid when the group was never created.
        let hasOwnGroup = setpgid(pid, pid) == 0 || getpgid(pid) == pid

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
        steamCMDPath: String,
        expectedSHA256: String,
        with reply: @escaping @Sendable (Data) -> Void
    ) {
        @Sendable func respond(_ result: SteamCachedLoginResult) {
            reply((try? JSONEncoder().encode(result)) ?? Data())
        }

        // The name is about to become an argv element, so re-validate here even
        // though discovery already filtered: this entry point is reachable with
        // whatever the caller passes.
        guard SteamAccountsFile.isValidAccountName(accountName),
              FileManager.default.isExecutableFile(atPath: steamCMDPath) else {
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
            guard SteamCMDBinaryDigest.mayExecute(path: steamCMDPath, expectedSHA256: expectedSHA256) else {
                respond(SteamCachedLoginResult(
                    outcome: .steamCMDUnavailable,
                    steamID64: nil,
                    diagnosticTail: Self.digestMismatchReason
                ))
                return
            }
            respond(Self.runCachedLoginProbe(accountName: accountName, steamCMDPath: steamCMDPath))
        }
    }

    func downloadWorkshopItem(
        workshopID: String,
        accountName: String,
        steamCMDPath: String,
        expectedSHA256: String,
        with reply: @escaping @Sendable (Data) -> Void
    ) {
        @Sendable func respond(_ outcome: SteamWorkshopDownloadResult.Outcome, tail: String = "", path: String? = nil) {
            let result = SteamWorkshopDownloadResult(
                outcome: outcome,
                itemPath: path,
                diagnosticTail: String(tail.suffix(500))
            )
            reply((try? JSONEncoder().encode(result)) ?? Data())
        }
        guard SteamLibraryPaths.isSafeWorkshopID(workshopID),
              SteamAccountsFile.isValidAccountName(accountName),
              FileManager.default.isExecutableFile(atPath: steamCMDPath) else {
            respond(.steamCMDUnavailable)
            return
        }

        let sink = progressSink
        let enqueuedAt = Date()
        Self.steamCMDQueue.async {
            guard !Self.callerAbandoned(enqueuedAt: enqueuedAt) else { respond(.timedOut); return }
            // Same pre-spawn gate as runSteamCMDProbe: re-hash after the queue
            // wait, because that wait is exactly the window in which the file
            // can be replaced.
            guard SteamCMDBinaryDigest.mayExecute(path: steamCMDPath, expectedSHA256: expectedSHA256) else {
                respond(.steamCMDUnavailable, tail: Self.digestMismatchReason)
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
                onProgress: { progress in
                    guard let data = try? JSONEncoder().encode(progress) else { return }
                    sink?.connectorDidReportProgress(data)
                }
            )
            let out = run.output
            if run.timedOut { respond(.timedOut, tail: out); return }
            if out.contains("FAILED (No cached credentials") || out.contains("Login Failure") {
                respond(.loginRequired, tail: out); return
            }
            if out.contains("ERROR! Download item \(workshopID) failed (No Connection).") {
                respond(.notEntitled, tail: out); return
            }
            if out.contains("ERROR! Download item \(workshopID) failed (No match).") {
                respond(.removedFromSteam, tail: out); return
            }
            // Trust the tree, not the log line: SteamCMD prints the destination
            // it *intended*, and a partial run can leave that path absent.
            let folder = SteamLibraryPaths.workshopContentRoot()
                .appendingPathComponent(workshopID, isDirectory: true)
            let project = folder.appendingPathComponent("project.json", isDirectory: false)
            guard out.contains("Success. Downloaded item \(workshopID)"),
                  FileManager.default.fileExists(atPath: project.path(percentEncoded: false)) else {
                respond(.unrecognized, tail: out); return
            }
            respond(.downloaded, tail: out, path: folder.path(percentEncoded: false))
        }
    }

    func deleteWorkshopItem(workshopID: String, with reply: @escaping @Sendable (Data) -> Void) {
        let result = SteamLibraryWriter.deleteWorkshopItem(workshopID: workshopID)
        reply((try? JSONEncoder().encode(result)) ?? Data())
    }

    // MARK: - Doctor probes

    func inspectSteamCMDBinary(path: String, with reply: @escaping @Sendable (Data) -> Void) {
        func send(_ inspection: SteamCMDBinaryInspection) {
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

    func locateSteamCMDBinary(pickedPath: String?, with reply: @escaping @Sendable (Data) -> Void) {
        func send(_ location: SteamCMDBinaryLocation) {
            reply((try? JSONEncoder().encode(location)) ?? Data())
        }
        // A pick is answered exactly; only auto-detect walks the candidate list,
        // and that list is three fixed paths.
        let candidates = pickedPath.map { [URL(fileURLWithPath: $0)] }
            ?? SteamCMDBinaryResolver.autoDetectCandidates()
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
                // Report the pick's own failure; during auto-detect a missing
                // candidate is the normal case and says nothing useful.
                if firstFailure == nil, pickedPath != nil { firstFailure = "\(error)" }
            }
        }
        send(SteamCMDBinaryLocation(canonicalPath: nil, failureReason: firstFailure))
    }

    func runSteamCMDProbe(_ request: Data, with reply: @escaping @Sendable (Data) -> Void) {
        func send(_ run: SteamCMDProbeRun) {
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
            // Re-hash here, not at the caller: between the app's trust decision
            // and this spawn the file could have been replaced — including by
            // SteamCMD's own self-update, which is exactly the case that makes
            // this window real rather than theoretical.
            guard SteamCMDBinaryDigest.mayExecute(
                path: probe.path, expectedSHA256: probe.expectedSHA256
            ) else {
                send(.refused(Self.digestMismatchReason))
                return
            }
            let run = Self.runSteamCMD(
                steamCMDPath: probe.path,
                arguments: probe.arguments,
                timeout: probe.timeout
            )
            send(SteamCMDProbeRun(
                output: run.output,
                exitCode: run.exitCode,
                timedOut: run.timedOut,
                refusalReason: nil
            ))
        }
    }

    func latestWallpaperEngineBuildID(
        accountName: String,
        steamCMDPath: String,
        expectedSHA256: String,
        with reply: @escaping @Sendable (Data) -> Void
    ) {
        guard SteamAccountsFile.isValidAccountName(accountName),
              FileManager.default.isExecutableFile(atPath: steamCMDPath) else {
            reply((try? JSONEncoder().encode(String?.none)) ?? Data())
            return
        }
        // Same profile, same lock: an update check must not race a queued
        // install or download.
        let enqueuedAt = Date()
        Self.steamCMDQueue.async {
            guard !Self.callerAbandoned(enqueuedAt: enqueuedAt) else {
                reply((try? JSONEncoder().encode(String?.none)) ?? Data())
                return
            }
            guard SteamCMDBinaryDigest.mayExecute(path: steamCMDPath, expectedSHA256: expectedSHA256) else {
                reply((try? JSONEncoder().encode(String?.none)) ?? Data())
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
                timeout: 180
            )
            let build = SteamConnectorBuildInfo.parsePublicBuildID(from: run.output)
            reply((try? JSONEncoder().encode(build)) ?? Data())
        }
    }

    func installWallpaperEngineAssets(
        accountName: String,
        steamCMDPath: String,
        expectedSHA256: String,
        with reply: @escaping @Sendable (Data) -> Void
    ) {
        @Sendable func respond(_ outcome: SteamEngineAssetsResult.Outcome, tail: String = "", assets: String? = nil, build: String? = nil) {
            let result = SteamEngineAssetsResult(
                outcome: outcome,
                assetsPath: assets,
                buildID: build,
                diagnosticTail: String(tail.suffix(500))
            )
            reply((try? JSONEncoder().encode(result)) ?? Data())
        }
        guard SteamAccountsFile.isValidAccountName(accountName),
              FileManager.default.isExecutableFile(atPath: steamCMDPath) else {
            respond(.steamCMDUnavailable)
            return
        }

        let sink = progressSink
        let enqueuedAt = Date()
        Self.steamCMDQueue.async {
            guard !Self.callerAbandoned(enqueuedAt: enqueuedAt) else { respond(.timedOut); return }
            // Same pre-spawn digest gate as runSteamCMDProbe; see downloadWorkshopItem.
            guard SteamCMDBinaryDigest.mayExecute(path: steamCMDPath, expectedSHA256: expectedSHA256) else {
                respond(.steamCMDUnavailable, tail: Self.digestMismatchReason)
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
                onProgress: { progress in
                    guard let data = try? JSONEncoder().encode(progress) else { return }
                    sink?.connectorDidReportProgress(data)
                }
            )
            let out = run.output
            if run.timedOut { respond(.timedOut, tail: out); return }
            if out.contains("FAILED (No cached credentials") || out.contains("Login Failure") {
                respond(.loginRequired, tail: out); return
            }
            if out.contains("No subscription") || out.contains("Invalid Platform") {
                respond(.notEntitled, tail: out); return
            }
            guard out.contains("Success! App '\(SteamLibraryPaths.wallpaperEngineAppID)'") else {
                respond(.unrecognized, tail: out); return
            }

            if let data = try? JSONEncoder().encode(
                SteamOperationProgress(phase: .pruning, fraction: nil, downloadedBytes: nil, totalBytes: nil)
            ) {
                sink?.connectorDidReportProgress(data)
            }
            do {
                let assets = try SteamLibraryWriter.pruneWallpaperEngineInstall()
                // `app_update`'s output carries a placeholder `"buildid" "0"`,
                // so ask app_info for the branch we actually installed rather
                // than scraping the update log.
                //
                // Re-hashed rather than riding the gate above: that one ran
                // before an `app_update` with a 5400s timeout, and a SteamCMD
                // self-update inside that window rewrites this very binary.
                guard SteamCMDBinaryDigest.mayExecute(path: steamCMDPath, expectedSHA256: expectedSHA256) else {
                    respond(.steamCMDUnavailable, tail: Self.digestMismatchReason)
                    return
                }
                let info = Self.runSteamCMD(
                    steamCMDPath: steamCMDPath,
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
                    build: SteamConnectorBuildInfo.parsePublicBuildID(from: info.output)
                )
            } catch {
                respond(.pruneRefused, tail: out)
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
                diagnosticTail: String(run.output.suffix(500))
            )
        }
        return SteamCachedLoginParser.parse(stdout: run.output)
    }
}
