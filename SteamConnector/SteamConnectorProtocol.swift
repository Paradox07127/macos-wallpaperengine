import CryptoKit
import Foundation
import os

/// Wire contract between Loomscreen and its Steam connector.
///
/// Exists so SteamCMD runs with the user's REAL `$HOME` (STEAMROOT = shared
/// `~/Library/Application Support/Steam`): a process the app forks itself
/// inherits the sandbox and container as `$HOME`, and can't resolve a
/// security-scoped bookmark. launchd starts the XPC service fresh instead —
/// with no `com.apple.security.app-sandbox` entitlement, no sandbox at all.
/// `SteamConnectorEnvironmentTests` is the standing proof.
@objc(LWSteamConnectorProtocol)
protocol SteamConnectorProtocol {
    /// Reports the connector's own execution context so the boundary can be
    /// asserted rather than assumed. Replies with a JSON-encoded
    /// `SteamConnectorEnvironmentProbe`.
    func probeEnvironment(with reply: @escaping @Sendable (Data) -> Void)

    /// Lists the Steam accounts cached in the shared profile. Replies with a
    /// JSON-encoded `[SteamAccountSummary]` — account name and SteamID only.
    /// The rest of `config.vdf` (machine-auth tokens, connect-cache secrets)
    /// must never cross this boundary.
    func discoverAccounts(with reply: @escaping @Sendable (Data) -> Void)

    /// Asks SteamCMD whether `accountName` still has a usable cached session,
    /// without ever being able to prompt for a password. Which binary runs is
    /// resolved here, not passed in — see `SteamCMDDiagnosisPlan`.
    /// Replies with a JSON-encoded `SteamCachedLoginResult`.
    func probeCachedLogin(
        accountName: String,
        with reply: @escaping @Sendable (Data) -> Void
    )

    /// Installs or updates Wallpaper Engine into the shared Steam library and
    /// prunes it to `assets/`. Replies with a JSON `SteamEngineAssetsResult`.
    func installWallpaperEngineAssets(
        accountName: String,
        operationID: String,
        with reply: @escaping @Sendable (Data) -> Void
    )

    /// Latest public-branch buildid for app 431960, for update checks.
    /// Replies with a JSON `SteamEngineBuildLookup`.
    func latestWallpaperEngineBuildID(
        accountName: String,
        operationID: String,
        with reply: @escaping @Sendable (Data) -> Void
    )

    /// Deletes one Workshop item's folder from the shared repository. This is a
    /// real delete of the user's Steam content — the app deliberately has no way
    /// to do it itself. Replies with a JSON `SteamDeleteResult`.
    func deleteWorkshopItem(
        workshopID: String,
        with reply: @escaping @Sendable (Data) -> Void
    )

    /// Downloads one Workshop item into the shared repository. Replies with a
    /// JSON `SteamWorkshopDownloadResult` carrying the folder the app should
    /// import from. `operationID` is the app-minted identity a later
    /// `cancelActiveSteamCMD` must name to reach this run's child.
    func downloadWorkshopItem(
        workshopID: String,
        accountName: String,
        operationID: String,
        with reply: @escaping @Sendable (Data) -> Void
    )

    /// Hashes and code-signature-checks the SteamCMD binary. The app never opens
    /// the file itself, which is what lets the main bundle drop its
    /// package-manager read exception. Replies with a JSON
    /// `SteamCMDBinaryInspection`.
    func inspectSteamCMDBinary(path: String, with reply: @escaping @Sendable (Data) -> Void)

    /// Remembers a SteamCMD location the user pointed at, after clearing the
    /// same trust gates every candidate clears — the one entry point where the
    /// app names something later executed, needed because auto-detection can't
    /// cover an unknown install location. See `SteamCMDManualBinding`: bounded
    /// because the path is re-gated every run, not because it was checked
    /// here. Replies with a JSON `SteamCMDManualBindResult`.
    func bindManualSteamCMDBinary(path: String, with reply: @escaping @Sendable (Data) -> Void)

    /// Forgets the manual binding, returning resolution to auto-detection.
    /// Replies with a JSON `SteamCMDManualBindResult`.
    func clearManualSteamCMDBinary(with reply: @escaping @Sendable (Data) -> Void)

    /// Runs one Doctor probe. Takes a JSON `SteamCMDProbeRequest` rather than
    /// loose arguments so the array never crosses as an NSSecureCoding
    /// collection. Replies with a JSON `SteamCMDProbeRun`.
    func runSteamCMDProbe(_ request: Data, with reply: @escaping @Sendable (Data) -> Void)

    /// Decides whether SteamCMD works: resolution, code signature, quarantine,
    /// and a real `steamcmd +quit` run (JSON `SteamCMDDiagnosisRequest` in,
    /// `SteamCMDDiagnosis` out). Lives here because only this process can spawn
    /// the binary — the app's old readiness check inferred health from marker
    /// files and path existence, and reported green while SteamCMD couldn't
    /// launch at all.
    func diagnoseSteamCMD(_ request: Data, with reply: @escaping @Sendable (Data) -> Void)

    /// Resolves the first derived candidate — managed install, then the three
    /// package-manager locations — to the canonical Mach-O we execute (JSON
    /// `SteamCMDBinaryLocation` reply). Takes no path (see
    /// `SteamCMDDiagnosisPlan`): resolution reads the file (Mach-O magic,
    /// wrapper script), and `/opt/homebrew` is outside the app's sandbox.
    func locateSteamCMDBinary(with reply: @escaping @Sendable (Data) -> Void)

    /// Unpacks a SteamCMD bootstrap tarball into a managed install the
    /// connector will execute, from Valve's own update manifest
    /// (`SteamCMDManifest`). Takes nothing: manifest URL, download, install
    /// root and verification all live connector-side, so no input a
    /// compromised app could shape. Downloading here also sidesteps
    /// quarantine — sandboxed files are stamped `com.apple.quarantine`, and a
    /// quarantined bare CLI Mach-O can't spawn at all (`Process.run()` fails
    /// EPERM; a Developer ID signature doesn't exempt it, measured
    /// 2026-08-13). Replies with a JSON `SteamCMDManagedInstallResult`.
    func installManagedSteamCMD(with reply: @escaping @Sendable (Data) -> Void)

    /// Deletes the managed SteamCMD install. Takes no path: the connector owns
    /// the one location this may touch, and the install lives outside the app
    /// container precisely so the app cannot reach it — including to delete it.
    /// Replies with a JSON `SteamCMDManagedRemovalResult`.
    func removeManagedSteamCMD(with reply: @escaping @Sendable (Data) -> Void)

    /// Interactive `steamcmd +login` on a PTY, so the user never opens
    /// Terminal (JSON `SteamCMDLoginRequest` in, `SteamCMDLoginResult` out).
    /// The password crosses once, to steamcmd's own PTY prompt, persisted by
    /// nothing either side — what remains is steamcmd's cached session in the
    /// shared profile, identical to a Terminal login. Never enters argv
    /// (visible via `ps`), a log, or the reply. Stays in flight through Steam
    /// Guard's mobile confirmation, so the app can show "waiting for
    /// approval" until the user acts on their phone.
    func signInSteamAccount(_ request: Data, with reply: @escaping @Sendable (Data) -> Void)

    /// SIGTERMs the SteamCMD child running in the connector, if any — the
    /// app's own `Task` cancel only stops the app-side wait, and the child
    /// keeps downloading for its full timeout otherwise. The interrupted
    /// operation fails through its own reply; this reply is a JSON `Bool` for
    /// whether anything was signalled. `operationID` is the id the app passed
    /// when starting the run it wants to stop; anything else is a no-op.
    func cancelActiveSteamCMD(operationID: String, with reply: @escaping @Sendable (Data) -> Void)
}

/// The one SteamCMD child currently running, so a user cancel can reach the
/// real process, not just the app-side await. The connector serializes every
/// SteamCMD run on one queue, so at most one child exists at a time.
/// Identified by the app's own operation id, not by kind of work: a
/// kind-scoped id could arrive over XPC after the *next* same-kind run
/// registered, and kill that innocent child — exactly what "cancel, then
/// retry" does.
final class SteamCMDActiveProcessRegistry: Sendable {
    private struct Active {
        let pid: pid_t
        let hasOwnGroup: Bool
        let operationID: String
    }

    private let state = OSAllocatedUnfairLock<Active?>(initialState: nil)

    func register(pid: pid_t, hasOwnGroup: Bool, operationID: String) {
        state.withLock { $0 = Active(pid: pid, hasOwnGroup: hasOwnGroup, operationID: operationID) }
    }

    func clear() {
        state.withLock { $0 = nil }
    }

    /// SIGTERM to the active child — its whole process group when it has one,
    /// same form as `spawn`'s timeout kill. Returns whether anything was
    /// signalled; `spawn`'s own EOF/timeout handling reaps the child, so no
    /// SIGKILL escalation belongs here. `operationID` must match what the
    /// child was registered under: a cancel for one operation must never
    /// signal a different one's child (review finding, both models).
    func terminateActive(operationID: String, kill: (pid_t, Int32) -> Int32 = { Darwin.kill($0, $1) }) -> Bool {
        guard let active = state.withLock({ $0 }), active.operationID == operationID else { return false }
        _ = kill(active.hasOwnGroup ? -active.pid : active.pid, SIGTERM)
        return true
    }
}

struct SteamCMDManagedRemovalResult: Codable, Equatable, Sendable {
    enum Outcome: String, Codable, Sendable {
        case removed
        /// Nothing was there — a verdict, not a failure.
        case notInstalled
        case refused
    }
    let outcome: Outcome
    let failureReason: String?
}

/// Valve's published SteamCMD bootstrap archive.
///
enum SteamCMDBootstrapPackage {
    /// Valve Corporation's Developer ID team. The extracted Mach-O must carry
    /// this or the managed install is refused.
    static let expectedTeamIdentifier = "MXGJJ98X76"

    /// SteamCMD writes into its own directory on every run (`logs/`, `package/`,
    /// cached host lists) and, on first launch, creates a `Frameworks` symlink
    /// one level *above* the executable. Keeping the payload one level down
    /// means that symlink lands in the install root instead of beside it.
    static let payloadSubdirectory = "MacOS"
}

/// Valve's own steamcmd update channel — the same manifest SteamCMD's
/// self-update reads. Installing from it directly removed the Rosetta
/// requirement (the historical `steamcmd_osx.tar.gz` bootstrapper is a frozen
/// 2020 Intel-only build; the manifest carries the current universal binary —
/// verified 2026-08-13: lipo x86_64+arm64, Valve team ID). Can't be
/// digest-pinned since it moves every release, so the trust chain is TLS to
/// Valve + per-package sha256 + the usual code-signature gate, which is the
/// authority on what runs; the hashes only confirm what was unpacked is what
/// Valve published.
enum SteamCMDManifest {
    static let url = URL(string: "https://media.steampowered.com/client/steam_cmd_osx")!

    /// What the consent sheet quotes. The real total is the sum of the manifest
    /// sizes and moves with releases; measured ~25 MB on 2026-08-13.
    static let approximateDownloadBytes = 25 * 1024 * 1024
    /// Rough on-disk size once SteamCMD has finished arranging itself.
    static let approximateInstalledBytes = 90 * 1024 * 1024

    /// Every package the manifest must supply. Mirrors what the bootstrapper
    /// downloads on first run; `steamcmd_osx` carries the executable itself.
    static let requiredPackages = [
        "steamcmd_public_all",
        "steamcmd_bins_osx",
        "steamcmd_breakpad_osx",
        "steamcmd_osx",
    ]

    struct Package: Equatable, Sendable {
        let name: String
        /// Plain-zip variant. The manifest also offers `.vz` (Valve LZMA)
        /// alongside; the plain zip needs no custom decompressor.
        let file: String
        let sha256: String
        let byteCount: Int
    }

    /// The filename becomes both a URL path component and a local path, so it
    /// gets the same shape rule as workshop ids: one flat component, nothing
    /// that can traverse.
    static func isSafePackageFileName(_ name: String) -> Bool {
        !name.isEmpty
            && name.count <= 200
            && !name.contains("..")
            && name.range(of: "^[A-Za-z0-9._-]+$", options: .regularExpression) != nil
    }

    /// Parses Valve's VDF-style manifest. All required packages must resolve or
    /// the whole parse fails — a partial install is not a smaller install, it
    /// is a broken one.
    static func parse(_ text: String) -> [Package]? {
        var packages: [Package] = []
        for name in requiredPackages {
            guard let nameRange = text.range(of: "\"\(name)\"") else { return nil }
            guard let open = text.range(of: "{", range: nameRange.upperBound..<text.endIndex),
                  let close = text.range(of: "}", range: open.upperBound..<text.endIndex) else {
                return nil
            }
            let block = text[open.upperBound..<close.lowerBound]
            guard let file = firstQuoted(after: "file", in: block),
                  isSafePackageFileName(file),
                  let sha256 = firstQuoted(after: "sha2", in: block),
                  sha256.count == 64,
                  let sizeText = firstQuoted(after: "size", in: block),
                  let byteCount = Int(sizeText),
                  byteCount > 0
            else { return nil }
            packages.append(Package(
                name: name, file: file, sha256: sha256.lowercased(), byteCount: byteCount
            ))
        }
        return packages
    }

    private static func firstQuoted(after key: String, in block: Substring) -> String? {
        guard let match = block.range(
            of: "\"\(key)\"\\s*\"([^\"]+)\"",
            options: .regularExpression
        ) else { return nil }
        let quoted = block[match]
        // The capture is the second quoted run inside the match.
        let parts = quoted.split(separator: "\"")
        return parts.count >= 3 ? String(parts.last!) : nil
    }
}

/// `Error` so install steps can short-circuit through `Result`; the value is
/// still the wire payload, not a thrown-away diagnostic. The outcome of
/// asking Steam for Wallpaper Engine's current build id — was a bare
/// `String?`, and five unrelated situations produced that nil (invalid
/// account name, a request expired in the queue, no runnable SteamCMD, a
/// login Steam refused, output with no `"public"` block), all rendered as
/// "SteamCMD did not return the latest build". An expired Steam session is
/// by far the most common of the five and the one with an obvious next step,
/// so it has to arrive distinguishable.
struct SteamEngineBuildLookup: Codable, Equatable, Sendable {
    enum Outcome: String, Codable, Sendable {
        case found
        /// Steam refused the cached session. The caller must demote its
        /// cached-login verdict, not just report a failed check.
        case loginRequired
        case timedOut
        /// No SteamCMD to run, or the request expired waiting for the queue.
        case steamCMDUnavailable
        /// SteamCMD ran and said nothing we recognise.
        case unrecognized
    }

    let outcome: Outcome
    let buildID: String?

    static func found(_ buildID: String) -> SteamEngineBuildLookup {
        SteamEngineBuildLookup(outcome: .found, buildID: buildID)
    }

    static func failed(_ outcome: Outcome) -> SteamEngineBuildLookup {
        SteamEngineBuildLookup(outcome: outcome, buildID: nil)
    }
}

struct SteamCMDManagedInstallResult: Codable, Equatable, Sendable, Error {
    enum Outcome: String, Codable, Sendable {
        case installed
        /// A downloaded package disagreed with the manifest's digest. The case
        /// name predates the manifest flow (it once meant the bootstrap
        /// tarball); kept for wire stability.
        case tarballRejected
        case extractionFailed
        case binaryNotFound
        /// Extracted, but not signed by Valve — never executed.
        case signatureRejected
        /// Unpacked and signed, but the first `+quit` run did not finish.
        case selfUpdateFailed
        case unavailable
    }
    let outcome: Outcome
    /// Canonical Mach-O path on success.
    let canonicalPath: String?
    let sha256: String?
    /// English fallback. Kept so an older app build still has something to show.
    let failureReason: String?
    /// Optional so a payload written by an older helper still decodes.
    let failureCode: SteamCMDFailureCode?
    let failureArguments: [String]?
    /// Set only when the install failed *and* the copy it displaced could not be
    /// put back — the user has to be told where the old one went.
    let rollbackRetiredPath: String?
    let rollbackReason: String?

    init(
        outcome: Outcome,
        canonicalPath: String?,
        sha256: String?,
        failureReason: String?,
        failureCode: SteamCMDFailureCode? = nil,
        failureArguments: [String]? = nil,
        rollbackRetiredPath: String? = nil,
        rollbackReason: String? = nil
    ) {
        self.outcome = outcome
        self.canonicalPath = canonicalPath
        self.sha256 = sha256
        self.failureReason = failureReason
        self.failureCode = failureCode
        self.failureArguments = failureArguments
        self.rollbackRetiredPath = rollbackRetiredPath
        self.rollbackReason = rollbackReason
    }

    static func failed(
        _ outcome: Outcome,
        _ reason: String,
        code: SteamCMDFailureCode? = nil,
        arguments: [String]? = nil
    ) -> SteamCMDManagedInstallResult {
        SteamCMDManagedInstallResult(
            outcome: outcome, canonicalPath: nil, sha256: nil, failureReason: reason,
            failureCode: code, failureArguments: arguments
        )
    }

    func withRollbackFailure(retiredPath: String, reason: String) -> SteamCMDManagedInstallResult {
        SteamCMDManagedInstallResult(
            outcome: outcome,
            canonicalPath: canonicalPath,
            sha256: sha256,
            failureReason: "\(failureReason ?? "install rejected"); the previous install could not be restored and is at \(retiredPath): \(reason)",
            failureCode: failureCode,
            failureArguments: failureArguments,
            rollbackRetiredPath: retiredPath,
            rollbackReason: reason
        )
    }
}

/// SteamCMD signals "my self-update replaced the binary — relaunch me" by
/// exiting 42 (a fresh install does it twice before its first clean exit,
/// measured 2026-08-28; the rewritten binary must re-pass signature/
/// quarantine gates before each relaunch). One retry for a package download
/// that failed in transit: the managed install pulls four packages, ~25 MB
/// total, over a single `URLSession` download with no retry, so one dropped
/// connection failed the whole install ("Could not download …", re-running
/// as the only recourse). Scoped to the transport only: a digest disagreeing
/// with the manifest is `.tarballRejected` and is *not* retried — the bytes
/// arrived intact but weren't the published ones, an integrity signal, not a
/// transient one.
enum SteamCMDDownloadRetryPolicy {
    /// The original attempt plus one.
    static let maxAttempts = 2
    /// Long enough to outlast a link renegotiation, short enough that a real
    /// outage still fails the install promptly.
    static let retryDelay: TimeInterval = 2

    /// Runs `attempt` until it reports success or the budget is spent, waiting
    /// between tries. `wait` is injected so tests do not sleep.
    static func run(
        attempt: (Int) -> Bool,
        wait: (TimeInterval) -> Void
    ) -> Bool {
        for number in 1...maxAttempts {
            if attempt(number) { return true }
            if number < maxAttempts { wait(retryDelay) }
        }
        return false
    }
}

enum SteamCMDSelfUpdateRestartPolicy {
    static let restartExitCode: Int32 = 42
    /// A measured fresh install asks twice (42, 42, 0 — 2026-08-28); three
    /// would fit exactly with no spare. Valve decides how many times its
    /// bootstrap asks — one more would misread as "First SteamCMD run
    /// exited 42" (broken) rather than a declined restart. Four keeps one
    /// spare; still asking after that is broken, not slow.
    static let maxExecutions = 4

    enum Outcome<Run> {
        /// The last run, whatever its exit status — the caller judges it.
        case completed(Run)
        /// The rewritten binary failed a trust gate; it was not relaunched.
        case gateFailed(String)
    }

    static func run<Run>(
        execute: () -> Run,
        exitCode: (Run) -> Int32,
        timedOut: (Run) -> Bool,
        revalidate: () -> String?
    ) -> Outcome<Run> {
        var run = execute()
        var executions = 1
        // A timed-out run was killed by us; whatever status the kill produced
        // is not SteamCMD asking to be relaunched.
        while executions < maxExecutions,
              !timedOut(run),
              exitCode(run) == restartExitCode {
            if let reason = revalidate() { return .gateFailed(reason) }
            run = execute()
            executions += 1
        }
        return .completed(run)
    }
}

struct SteamCMDBinaryLocation: Codable, Equatable, Sendable {
    /// Absolute path of the Mach-O, nil when nothing resolved.
    let canonicalPath: String?
    /// Why it did not resolve, for the Doctor's message.
    let failureReason: String?
}

struct SteamWorkshopDownloadResult: Codable, Equatable, Sendable {
    enum Outcome: String, Codable, Sendable {
        case downloaded
        case loginRequired
        /// Steam's "(No Connection)" is its confusing wording for an account
        /// that does not own Wallpaper Engine.
        case notEntitled
        case removedFromSteam
        case timedOut
        case steamCMDUnavailable
        case unrecognized
    }
    let outcome: Outcome
    /// Where the item landed, on success — inside the shared Steam repository.
    let itemPath: String?
    let diagnosticTail: String
    /// Execution receipt: the canonical binary this operation actually spawned.
    /// The connector resolves its own binary per run, so this is the only way
    /// the app learns which one ran. Optional-with-default so a payload from an
    /// older connector (no key) still decodes; nil means nothing was spawned.
    var executedBinaryPath: String? = nil
}

/// Reverse channel: the app exports this so long operations can stream progress
/// instead of freezing behind one reply block.
/// `Sendable` because the connector hands it to background work: the proxy is
/// an XPC remote object, which is thread-safe by construction.
@objc(LWSteamConnectorProgressProtocol)
protocol SteamConnectorProgressProtocol: Sendable {
    func connectorDidReportProgress(_ payload: Data)
}

struct SteamOperationProgress: Codable, Equatable, Sendable {
    enum Phase: String, Codable, Sendable {
        case connecting
        case downloading
        case verifying
        case pruning
    }
    let phase: Phase
    /// 0…1 when SteamCMD reported it, nil while it is silent.
    let fraction: Double?
    let downloadedBytes: UInt64?
    let totalBytes: UInt64?
}

struct SteamEngineAssetsResult: Codable, Equatable, Sendable {
    enum Outcome: String, Codable, Sendable {
        case installed
        case loginRequired
        case notEntitled
        case steamUnreachable
        case pruneRefused
        case steamCMDUnavailable
        case timedOut
        case unrecognized
    }
    let outcome: Outcome
    /// Where the pruned `assets/` tree ended up, on success.
    let assetsPath: String?
    let buildID: String?
    let diagnosticTail: String
    /// Execution receipt — see `SteamWorkshopDownloadResult.executedBinaryPath`.
    var executedBinaryPath: String? = nil
}

struct SteamDeleteResult: Codable, Equatable, Sendable {
    enum Outcome: String, Codable, Sendable {
        case deleted
        case notFound
        case refused
    }
    let outcome: Outcome
    let freedBytes: UInt64
    /// Set when `refused` — the guard that stopped it, for the log.
    let refusalReason: String?
}

/// Parses SteamCMD's progress lines.
///
/// Shared so the connector and the app's own probe runner cannot drift into two
/// different readings of the same output. Format:
/// `Update state (0x61) downloading, progress: 42.34 (12345 / 67890)`.
enum SteamCMDProgressLine {
    static func parse(_ line: String) -> SteamOperationProgress? {
        guard let marker = line.range(of: "progress:") else { return nil }
        let tail = line[marker.upperBound...]
        let phase: SteamOperationProgress.Phase = line.contains("verifying")
            ? .verifying
            : (line.contains("downloading") ? .downloading : .connecting)

        // Preferred form carries byte detail; SteamCMD often omits it.
        if let open = tail.firstIndex(of: "("), let close = tail.firstIndex(of: ")"), open < close {
            let percentText = tail[..<open].trimmingCharacters(in: .whitespacesAndNewlines)
            let bytes = tail[tail.index(after: open)..<close]
                .split(separator: "/")
                .map { $0.trimmingCharacters(in: .whitespaces) }
            if bytes.count == 2,
               let percent = Double(percentText),
               let downloaded = UInt64(bytes[0]),
               let total = UInt64(bytes[1]) {
                return SteamOperationProgress(
                    phase: phase,
                    fraction: clampedFraction(percent),
                    downloadedBytes: downloaded,
                    totalBytes: total
                )
            }
        }

        let numeric = tail.prefix { $0.isNumber || $0 == "." || $0 == " " }
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let percent = Double(numeric), percent.isFinite, percent >= 0 else { return nil }
        return SteamOperationProgress(
            phase: phase,
            fraction: clampedFraction(percent),
            downloadedBytes: nil,
            totalBytes: nil
        )
    }

    private static func clampedFraction(_ percent: Double) -> Double? {
        guard percent.isFinite, percent >= 0 else { return nil }
        return min(max(percent / 100, 0), 1)
    }
}

enum SteamCachedLoginOutcome: String, Codable, Sendable {
    case sessionValid
    case noCachedSession
    case sessionExpired
    case timedOut
    case steamCMDUnavailable
    case unrecognized
}

struct SteamCachedLoginResult: Codable, Equatable, Sendable {
    let outcome: SteamCachedLoginOutcome
    /// Who Steam says the session belongs to, so the caller can catch the case
    /// where the cached session is for a different account than the one picked.
    let steamID64: String?
    /// Bounded tail of SteamCMD's output, for the diagnostics export only.
    let diagnosticTail: String
    /// Execution receipt — see `SteamWorkshopDownloadResult.executedBinaryPath`.
    var executedBinaryPath: String? = nil
}

/// Maps SteamCMD's cached-login output to a verdict.
///
/// Kept pure and in the shared contract so the mapping is unit-testable without
/// spawning SteamCMD or owning a Steam account. Every branch below was captured
/// from a real run rather than inferred from the help text.
enum SteamCachedLoginParser {
    /// SteamCMD prints this whenever `@NoPromptForPassword 1` stops it from
    /// asking — it means "no usable session", not "wrong password".
    static let noPromptFailureLine = "FAILED (No cached credentials and @NoPromptForPassword is set)"

    static func parse(stdout: String) -> SteamCachedLoginResult {
        let steamID = steamID64(inLoginLine: stdout)
        let tail = String(stdout.suffix(500))

        if stdout.contains("Logging in using cached credentials."), steamID != nil {
            return SteamCachedLoginResult(outcome: .sessionValid, steamID64: steamID, diagnosticTail: tail)
        }
        if stdout.contains(noPromptFailureLine) {
            // "Cached credentials not found." distinguishes never-signed-in from
            // a session Steam has since invalidated; the remedy differs only in
            // wording, but conflating them made the old UI misleading.
            let outcome: SteamCachedLoginOutcome =
                stdout.contains("Cached credentials not found.") ? .noCachedSession : .sessionExpired
            return SteamCachedLoginResult(outcome: outcome, steamID64: nil, diagnosticTail: tail)
        }
        return SteamCachedLoginResult(outcome: .unrecognized, steamID64: steamID, diagnosticTail: tail)
    }

    /// `Logging in user 'x' [U:1:1267132100] to Steam Public...OK` carries a
    /// SteamID3 account id; SteamID64 is that plus the individual-account base.
    static func steamID64(inLoginLine stdout: String) -> String? {
        guard let match = stdout.firstMatch(of: /Logging in user '[^']+' \[U:1:(\d+)\] to Steam Public\.\.\.OK/),
              let accountID = UInt64(match.output.1) else { return nil }
        return String(76_561_197_960_265_728 + accountID)
    }
}

/// One Steam account known to the shared profile. Both fields are public
/// identifiers; nothing here is a credential.
struct SteamAccountSummary: Codable, Equatable, Sendable, Identifiable {
    let accountName: String
    let steamID64: String

    var id: String { accountName }
}

/// One in-app sign-in attempt. The password rides here because XPC is
/// local-machine Mach IPC — the alternative (argv) is world-readable.
struct SteamCMDLoginRequest: Codable, Sendable {
    let accountName: String
    let password: String
    /// Steam Guard code from a previous attempt's `guard*Required` outcome.
    let guardCode: String?
    let timeout: TimeInterval

    init(
        accountName: String,
        password: String,
        guardCode: String? = nil,
        timeout: TimeInterval = SteamCMDLoginProbe.defaultTimeout
    ) {
        self.accountName = accountName
        self.password = password
        self.guardCode = guardCode
        self.timeout = timeout
    }
}

struct SteamCMDLoginResult: Codable, Equatable, Sendable {
    enum Outcome: String, Codable, Sendable {
        case success
        case invalidPassword
        /// Steam Guard wants the code Steam just emailed; ask and retry.
        case guardCodeEmailRequired
        /// Steam Guard wants the authenticator app's rotating code.
        case guardCodeTotpRequired
        case invalidGuardCode
        case rateLimited
        /// The mobile-confirmation wait (or anything else) outlived the budget.
        case timedOut
        /// steamcmd refused for a reason we do not classify further.
        case failed
        case unavailable
    }
    let outcome: Outcome
    let steamID64: String?

    static func failed(_ outcome: Outcome) -> SteamCMDLoginResult {
        SteamCMDLoginResult(outcome: outcome, steamID64: nil)
    }
}

/// The argv and prompt grammar of an interactive login.
///
/// `arguments` deliberately has no password parameter — the type system is the
/// guard against the argv leak, not reviewer vigilance. Secrets travel over the
/// PTY answering steamcmd's own prompts.
enum SteamCMDLoginProbe {
    static let defaultTimeout: TimeInterval = 300

    static func arguments(accountName: String) -> [String] {
        ["+login", accountName, "+quit"]
    }

    static func clampedTimeout(_ requested: TimeInterval) -> TimeInterval {
        guard requested.isFinite else { return defaultTimeout }
        // The floor is the mobile-confirmation case: the user has to find
        // their phone. The cap keeps an abandoned prompt from parking the
        // shared SteamCMD queue for an hour.
        return min(max(requested, 60), 600)
    }
}

/// Reads steamcmd's interactive login output. Matching is contains-based over
/// the lowercased transcript — these strings come from real steamcmd
/// sessions with varied casing/prefixes across releases. Anything unmatched
/// falls through to timeout/exit handling, never to a spawn of something else.
enum SteamCMDLoginOutputClassifier {
    enum Event: Equatable {
        case passwordPrompt
        case guardCodeEmailPrompt
        case guardCodeTotpPrompt
        /// Modern Steam Guard: steamcmd polls until the user approves on their
        /// phone. Not a failure — keep waiting.
        case waitingForMobileConfirmation
        case invalidPassword
        case invalidGuardCode
        case rateLimited
        case loggedIn
    }

    /// First terminal event in the transcript, or the most actionable prompt.
    /// Order matters: failure markers outrank prompts (a failed attempt often
    /// re-prompts), and success outranks everything.
    static func event(inTranscript transcript: String) -> Event? {
        let text = transcript.lowercased()
        if text.contains("logged in ok") || text.contains("waiting for user info") {
            return .loggedIn
        }
        if text.contains("rate limit") { return .rateLimited }
        if text.contains("invalid login auth code") || text.contains("two-factor code mismatch") {
            return .invalidGuardCode
        }
        if text.contains("invalid password") { return .invalidPassword }
        if text.contains("confirm the login in the steam mobile app")
            || text.contains("waiting for confirmation") {
            return .waitingForMobileConfirmation
        }
        if text.contains("two-factor code:") { return .guardCodeTotpPrompt }
        if text.contains("steam guard code:") { return .guardCodeEmailPrompt }
        if text.contains("password:") { return .passwordPrompt }
        return nil
    }
}

/// Reads the `Accounts` block out of Steam's `config.vdf` — the only account
/// source that works here: `loginusers.vdf` (which carries `MostRecent`) is
/// written by the Steam GUI client, which can't be installed on the macOS
/// machines this app targets. A steamcmd-only profile records accounts
/// solely under `InstallConfigStore … Accounts`.
enum SteamAccountsFile {
    /// steamcmd's own account-name grammar. Anything else is rejected rather
    /// than surfaced: the name is interpolated into a generated SteamCMD script,
    /// so a hand-edited `config.vdf` must not be able to smuggle syntax in.
    static func isValidAccountName(_ name: String) -> Bool {
        !name.isEmpty && name.count <= 32
            && name.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_") }
    }

    /// Accounts in file order. Malformed or unnamed entries are skipped, never
    /// guessed at. Duplicate names collapse to the first occurrence.
    static func parseAccounts(fromConfigVDF text: String) -> [SteamAccountSummary] {
        guard let block = accountsBlock(in: text) else { return [] }
        var summaries: [SteamAccountSummary] = []
        var seen: Set<String> = []
        var cursor = block.startIndex

        while let name = nextQuoted(in: block, from: &cursor) {
            // Every account entry is `"<name>" { … }`; skip anything else so a
            // stray key/value pair cannot be read as an account.
            guard let body = nextBraceBlock(in: block, from: &cursor) else { break }
            guard isValidAccountName(name), !seen.contains(name) else { continue }
            guard let steamID = steamID(in: body) else { continue }
            seen.insert(name)
            summaries.append(SteamAccountSummary(accountName: name, steamID64: steamID))
        }
        return summaries
    }

    // MARK: - Scanning

    private static func accountsBlock(in text: String) -> Substring? {
        var cursor = text.startIndex
        while let range = text.range(of: "\"Accounts\"", range: cursor..<text.endIndex) {
            cursor = range.upperBound
            var probe = cursor
            if let block = nextBraceBlock(in: text[...], from: &probe) { return block }
        }
        return nil
    }

    private static func steamID(in body: Substring) -> String? {
        guard let key = body.range(of: "\"SteamID\"") else { return nil }
        var cursor = key.upperBound
        guard let value = nextQuoted(in: body, from: &cursor),
              !value.isEmpty,
              value.allSatisfy(\.isNumber) else { return nil }
        return value
    }

    /// Next `"…"` token, advancing `cursor` past it. Handles `\"` escapes.
    private static func nextQuoted(in text: Substring, from cursor: inout Substring.Index) -> String? {
        guard let open = text[cursor...].firstIndex(of: "\"") else { return nil }
        var index = text.index(after: open)
        var value = ""
        while index < text.endIndex {
            let character = text[index]
            if character == "\\" {
                let escaped = text.index(after: index)
                guard escaped < text.endIndex else { return nil }
                value.append(text[escaped])
                index = text.index(after: escaped)
                continue
            }
            if character == "\"" {
                cursor = text.index(after: index)
                return value
            }
            value.append(character)
            index = text.index(after: index)
        }
        return nil
    }

    /// Contents of the next balanced `{ … }`, advancing `cursor` past its close.
    /// Quoted spans are skipped so a brace inside a value can't unbalance it.
    private static func nextBraceBlock(in text: Substring, from cursor: inout Substring.Index) -> Substring? {
        guard let open = text[cursor...].firstIndex(of: "{") else { return nil }
        var depth = 0
        var index = open
        var insideQuotes = false
        while index < text.endIndex {
            let character = text[index]
            if insideQuotes {
                if character == "\\" {
                    index = text.index(index, offsetBy: 2, limitedBy: text.endIndex) ?? text.endIndex
                    continue
                }
                if character == "\"" { insideQuotes = false }
            } else if character == "\"" {
                insideQuotes = true
            } else if character == "{" {
                depth += 1
            } else if character == "}" {
                depth -= 1
                if depth == 0 {
                    cursor = text.index(after: index)
                    return text[text.index(after: open)..<index]
                }
            }
            index = text.index(after: index)
        }
        return nil
    }
}

/// What the connector sees from where it actually runs.
struct SteamConnectorEnvironmentProbe: Codable, Equatable, Sendable {
    let uid: UInt32
    /// Container path when sandboxed, real home when not — the deciding value.
    let nsHomeDirectory: String
    /// The POSIX user database's answer, which the sandbox never rewrites.
    let posixHomeDirectory: String
    let steamConfigPath: String
    /// Probed from inside the connector: the sandboxed host cannot even `stat`
    /// this path, so it cannot decide for itself whether a read *should* work.
    let steamConfigExists: Bool
    let steamConfigByteCount: Int
    /// nil when the read succeeded with no bookmark and no security scope.
    let readErrorDescription: String?

    /// `NSHomeDirectory()` is container-relative under the sandbox; the user
    /// database is not, so the two disagreeing is itself the sandbox signal.
    static func posixHomeDirectory() -> String {
        if let pw = getpwuid(getuid()), let home = pw.pointee.pw_dir {
            return String(cString: home)
        }
        return NSHomeDirectory()
    }

    static func steamConfigURL(realHome: String) -> URL {
        URL(fileURLWithPath: realHome, isDirectory: true)
            .appendingPathComponent("Library/Application Support/Steam/config/config.vdf")
    }
}

/// Everything the app needs to know about a SteamCMD binary. Gathered in the
/// connector so the app never opens the file itself — that's what lets the
/// main bundle drop its package-manager read exception. `exists == false`
/// means the path resolved to nothing; every other field is then unset.
struct SteamCMDBinaryInspection: Codable, Equatable, Sendable {
    let exists: Bool
    /// Hex SHA-256, or nil when the file could not be read.
    let sha256: String?
    let signatureValid: Bool
    let teamIdentifier: String?
    let isHardenedRuntime: Bool
    let isQuarantined: Bool
    /// Set when the connector gave up waiting behind another SteamCMD
    /// operation and produced no verdict at all — distinct from
    /// `exists == false`, a real answer about the file. Conflating the two
    /// made a busy connector look like a deleted binary and cost the caller
    /// its cached trust for no reason.
    let unavailableReason: String?

    /// The file is not there. A verdict, not a failure to reach one.
    static let missing = SteamCMDBinaryInspection(
        exists: false, sha256: nil, signatureValid: false,
        teamIdentifier: nil, isHardenedRuntime: false,
        isQuarantined: false, unavailableReason: nil
    )

    static func unavailable(_ reason: String) -> SteamCMDBinaryInspection {
        SteamCMDBinaryInspection(
            exists: false, sha256: nil, signatureValid: false,
            teamIdentifier: nil, isHardenedRuntime: false,
            isQuarantined: false, unavailableReason: reason
        )
    }
}

/// A Doctor probe run. Carries no path: which binary runs is the connector's
/// decision, derived from `SteamCMDDiagnosisPlan`.
struct SteamCMDProbeRequest: Codable, Equatable, Sendable {
    let arguments: [String]
    let timeout: TimeInterval
}

/// The connector's argv gate for Doctor probes: only the exact directive
/// shapes Doctor sends are executable, `+quit` and `+login anonymous`.
/// Everything else — `+force_install_dir`, `+runscript`, a real account
/// name, any bare word — is refused at the connector, the side of the trust
/// boundary a compromised app process can't edit. Lives in the shared
/// contract so the app's tests exercise the exact rule the connector enforces.
enum SteamCMDProbeArgumentPolicy {
    static func isAllowed(_ arguments: [String]) -> Bool {
        guard !arguments.isEmpty else { return false }
        var index = 0
        while index < arguments.count {
            switch arguments[index] {
            case "+quit":
                index += 1
            case "+login":
                guard index + 1 < arguments.count, arguments[index + 1] == "anonymous" else {
                    return false
                }
                index += 2
            default:
                return false
            }
        }
        return true
    }
}

struct SteamCMDProbeRun: Codable, Equatable, Sendable {
    let output: String
    let exitCode: Int32
    let timedOut: Bool
    /// Set when the connector declined to spawn at all.
    let refusalReason: String?
    /// Execution receipt — see `SteamWorkshopDownloadResult.executedBinaryPath`.
    var executedBinaryPath: String? = nil

    static func refused(_ reason: String) -> SteamCMDProbeRun {
        SteamCMDProbeRun(output: "", exitCode: -1, timedOut: false, refusalReason: reason)
    }
}

// MARK: - SteamCMD diagnosis

/// One `diagnoseSteamCMD` request. The app contributes only the two paths
/// the connector cannot know — the user's own pick and the managed install
/// inside the real Application Support directory; which package-manager
/// paths to try, and every verdict, is the connector's. Carries no path of
/// any kind, only a budget — nothing a sandboxed caller sends may decide
/// what this unsandboxed process executes. Every candidate is derived here
/// (`SteamCMDDiagnosisPlan`), so there's no field to swap a verified binary
/// through.
struct SteamCMDDiagnosisRequest: Codable, Equatable, Sendable {
    let launchTimeout: TimeInterval

    init(launchTimeout: TimeInterval = SteamCMDDiagnosisProbe.defaultLaunchTimeout) {
        self.launchTimeout = launchTimeout
    }
}

/// The run at the centre of the diagnosis.
enum SteamCMDDiagnosisProbe {
    /// The only argv the diagnosis ever spawns. `+quit` takes SteamCMD through
    /// its first-run self-update and exits, which is the cheapest run that still
    /// proves this machine can execute this binary.
    static let arguments = ["+quit"]

    static let defaultLaunchTimeout: TimeInterval = 180

    /// A caller-supplied budget of 0 would make every launch "time out" before
    /// the child got to run — the diagnosis reporting on nothing. Clamped rather
    /// than refused so a bad number degrades to a slow answer, not to no answer.
    static func clampedLaunchTimeout(_ requested: TimeInterval) -> TimeInterval {
        guard requested.isFinite else { return defaultLaunchTimeout }
        return min(max(requested, 30), 900)
    }
}

/// Where the binary under test came from.
enum SteamCMDBinarySource: String, Codable, Sendable {
    /// A location the user pointed at themselves. See `SteamCMDManualBinding`
    /// for what accepting one does and does not promise.
    case manual
    case managedInstall
    case homebrew
    case usrLocal
    case macPorts
    case notFound
}

/// A SteamCMD location the user pointed at, remembered on this side of the
/// XPC boundary — deliberately reopens a hole closed 2026-08-13 at the
/// user's 2026-08-14 direction (`autoDetectCandidates` only covers package
/// managers, so closing it left no recourse). Given up: a path isn't an
/// inode, so a file swapped between our checks and `posix_spawn` runs
/// unchecked (no `fexecve`). Kept: the record lives under the connector's
/// own root in the real home, write-once via XPC; it re-enters
/// `resolvedExecutablePath` and re-clears every gate — signature,
/// quarantine, execution fence — on **every** run; and it's a candidate, not
/// an override, going first with a fall-through on failure.
enum SteamCMDManualBinding {
    static func recordURL(home: URL = URL(fileURLWithPath: NSHomeDirectory())) -> URL {
        home
            .appendingPathComponent("Library/Application Support", isDirectory: true)
            .appendingPathComponent("Loomscreen", isDirectory: true)
            .appendingPathComponent("manual-steamcmd-path", isDirectory: false)
            .standardizedFileURL
    }

    static func load(home: URL = URL(fileURLWithPath: NSHomeDirectory())) -> URL? {
        guard let raw = try? String(contentsOf: recordURL(home: home), encoding: .utf8) else {
            return nil
        }
        let path = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        // Relative paths would resolve against this process's working directory,
        // which the app does not know and we do not control.
        guard path.hasPrefix("/") else { return nil }
        return URL(fileURLWithPath: path)
    }

    static func store(_ path: String, home: URL = URL(fileURLWithPath: NSHomeDirectory())) throws {
        let record = recordURL(home: home)
        try FileManager.default.createDirectory(
            at: record.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try Data(path.utf8).write(to: record, options: .atomic)
    }

    static func clear(home: URL = URL(fileURLWithPath: NSHomeDirectory())) {
        try? FileManager.default.removeItem(at: recordURL(home: home))
    }
}

/// What the connector made of a path the user pointed at. Why a SteamCMD
/// operation failed, as a code the app renders — the helper can't localize
/// (`SteamConnector.xpc` ships no `.lproj`, so `Bundle.main` has no catalog
/// and `String(localized:)` would silently return English); the reason
/// crosses the wire as a code plus arguments and renders app-side, where the
/// catalog is. Raw values are wire format — renaming a case breaks old
/// payloads.
enum SteamCMDFailureCode: String, Codable, Sendable {
    // MARK: Manual bind
    case pathNotAbsolute
    case bindExpiredInQueue
    case notSteamCMDBinary
    case refusesOwnContainer
    case signatureNotValve
    case binaryQuarantined
    /// Argument 0: the underlying error description.
    case couldNotRecordChoice

    // MARK: Managed install
    case installExpiredInQueue
    case stagingDirectoryFailed
    case manifestFetchFailed
    case manifestUnexpectedShape
    case manifestMalformedPackageName
    /// Argument 0: package name.
    case packageDownloadFailed
    /// Argument 0: package name.
    case packageChecksumMismatch
    case firstRunTimedOut
    /// Argument 0: the exit code.
    case firstRunExitedNonZero
    case couldNotHashBinary
    case installRootMismatch
    /// Argument 0: the offending path component.
    case installPathSymlink
    /// Argument 0: the underlying error description.
    case installDirectoryCreateFailed
    case unpackTimedOut
    /// Argument 0: tar's exit code. Argument 1: the first 200 characters of its output.
    case tarExitedNonZero
    /// Argument 0: the escaping symlink's path.
    case archiveSymlinkEscape
    /// Argument 0: the underlying error description.
    case retirePreviousFailed
    /// Argument 0: the underlying error description.
    case moveIntoPlaceFailed
    case executableOutsideInstall
    case noExecutableInArchive
    case codeSignatureInvalid
    /// Argument 0: the team that signed it. Argument 1: the expected team.
    case signedByUnexpectedTeam
    case unpackedBinaryQuarantined
}

struct SteamCMDManualBindResult: Codable, Sendable {
    enum Outcome: String, Codable, Sendable {
        case bound
        /// Resolved to a Mach-O, but one we refuse to run.
        case untrusted
        case notFound
        case refused
    }

    let outcome: Outcome
    /// The Mach-O the picked path resolved to, when it resolved to one.
    let canonicalPath: String?
    /// English fallback. Kept so an older app build still has something to show.
    let failureReason: String?
    /// Optional so a payload written by an older helper still decodes.
    let failureCode: SteamCMDFailureCode?
    let failureArguments: [String]?

    init(
        outcome: Outcome,
        canonicalPath: String?,
        failureReason: String?,
        failureCode: SteamCMDFailureCode? = nil,
        failureArguments: [String]? = nil
    ) {
        self.outcome = outcome
        self.canonicalPath = canonicalPath
        self.failureReason = failureReason
        self.failureCode = failureCode
        self.failureArguments = failureArguments
    }

    var isBound: Bool { outcome == .bound }
}

struct SteamCMDDiagnosisCandidate: Equatable, Sendable {
    let path: String
    let source: SteamCMDBinarySource
}

/// Resolution order, and the label each candidate carries into the report.
/// Every entry is derived, never supplied: the managed install under this
/// process's own root, then three fixed package-manager paths — the whole
/// executable surface, none of it writable by a sandboxed app without a
/// grant this app never asks for. Pure so the app's tests pin the same
/// order the connector walks.
enum SteamCMDDiagnosisPlan {
    /// `managedInstall` is a parameter (not a call to
    /// `SteamCMDManagedInstaller.managedBinary()`) so tests pin ordering
    /// without a real install; `discovered` defaults to a filesystem walk,
    /// but tests pass a fixed list so it doesn't depend on what's under
    /// `/opt/homebrew`. `manual` goes first — pointing at a file is a
    /// stronger statement than anything inferred — but it's only a
    /// position: every entry clears the same gates in `firstTrusted`, so a
    /// failing manual pick falls through rather than breaking downloads.
    static func candidates(
        managedInstall: URL?,
        manual: URL? = SteamCMDManualBinding.load(),
        discovered: [URL] = SteamCMDBinaryResolver.autoDetectCandidates()
    ) -> [SteamCMDDiagnosisCandidate] {
        var plan: [SteamCMDDiagnosisCandidate] = []
        if let manual {
            plan.append(SteamCMDDiagnosisCandidate(
                path: manual.path(percentEncoded: false), source: .manual
            ))
        }
        if let managed = managedInstall {
            plan.append(SteamCMDDiagnosisCandidate(
                path: managed.path(percentEncoded: false), source: .managedInstall
            ))
        }
        for url in discovered {
            let path = url.path(percentEncoded: false)
            plan.append(SteamCMDDiagnosisCandidate(
                path: path, source: packageManagerSource(forCandidatePath: path)
            ))
        }
        return plan
    }

    /// First candidate that survives every gate, skipping the ones that
    /// don't. Split out from the connector so the rule this encodes — **a
    /// rejected candidate must not end the search** — is testable without
    /// planting real Mach-Os on the test machine. Getting it wrong is how a
    /// stale, unsigned copy shadows a working one: the diagnosis skips it
    /// and binds the good binary, while execution stops at the bad one.
    static func firstTrusted(
        in candidates: [String],
        resolve: (String) -> String?,
        isTrusted: (String) -> Bool
    ) -> String? {
        for candidate in candidates {
            guard let resolved = resolve(candidate) else { continue }
            guard !SteamCMDExecutionFence.refusesExecution(of: resolved) else { continue }
            guard isTrusted(resolved) else { continue }
            return resolved
        }
        return nil
    }

    /// Matched on path components, not on absolute prefixes: the Caskroom and
    /// command-wrapper candidates carry a version directory in the middle, and
    /// a custom `HOMEBREW_PREFIX` moves the whole tree.
    static func packageManagerSource(forCandidatePath path: String) -> SteamCMDBinarySource {
        if path.contains("/Caskroom/") || path.contains("/.homebrew-command-wrappers/") {
            return .homebrew
        }
        switch path {
        case "/opt/homebrew/bin/steamcmd": return .homebrew
        case "/usr/local/bin/steamcmd": return .usrLocal
        case "/opt/local/bin/steamcmd": return .macPorts
        default: return .notFound
        }
    }
}

struct SteamCMDSignatureVerdict: Codable, Equatable, Sendable {
    /// `codesign --verify --strict` completed cleanly. Deliberately not
    /// `spctl`: for a bare CLI Mach-O it answers `rejected (the code is
    /// valid but does not seem to be an app)`, a refusal to assess rather
    /// than a verdict, so gating on its exit status rejects every good
    /// binary.
    let isValid: Bool
    let teamIdentifier: String?
    let isHardenedRuntime: Bool

    var isValveSigned: Bool {
        isValid && teamIdentifier == SteamCMDBootstrapPackage.expectedTeamIdentifier
    }
}

/// What happened when the connector actually ran the binary.
struct SteamCMDLaunchProbe: Codable, Equatable, Sendable {
    enum Outcome: String, Codable, Sendable {
        case succeeded
        case timedOut
        case exitedNonZero
        /// `Process.run()` itself failed. The usual cause is a quarantined
        /// Mach-O, which cannot be spawned at all (measured 2026-08-13).
        case couldNotSpawn
    }

    let outcome: Outcome
    /// The argv that was spawned, recorded so a report cannot claim this run
    /// while having done something else — see `SteamCMDDiagnosis.isUsable`.
    let arguments: [String]
    let exitCode: Int32
    let timeout: TimeInterval
    let outputTail: String

    /// A timeout outranks the exit status: the connector kills the process
    /// group, and a child that dies to SIGTERM at the right moment can still
    /// report 0.
    static func classify(exitCode: Int32, timedOut: Bool) -> Outcome {
        if timedOut { return .timedOut }
        if exitCode == 0 { return .succeeded }
        // `spawn` reports a failed `Process.run()` as -1 without a timeout.
        return exitCode < 0 ? .couldNotSpawn : .exitedNonZero
    }
}

/// Everything the app needs to render "can this Mac use SteamCMD", decided in
/// the process that can spawn it.
struct SteamCMDDiagnosis: Codable, Equatable, Sendable {
    let source: SteamCMDBinarySource
    let canonicalPath: String?
    /// Why the resolver refused a path the app named. Auto-detect candidates
    /// that are simply absent are the normal case and are not reported.
    let resolutionFailure: String?
    let sha256: String?
    let signature: SteamCMDSignatureVerdict?
    let isQuarantined: Bool
    /// The real `steamcmd +quit` run. nil means it never happened, which is
    /// never a healthy answer — see `isUsable`.
    let launch: SteamCMDLaunchProbe?
    /// The connector reached no verdict at all (queue expiry, malformed request).
    /// Distinct from a verdict of "broken".
    let unavailableReason: String?
    /// Candidate paths that exist on disk but did not survive resolution. A
    /// fact, not a remedy: `remedy` is computed in the app, which is
    /// sandboxed and can't `stat` `/opt/homebrew` itself — gathered in the
    /// connector, which can. Optional in storage, non-optional to read: a
    /// property default doesn't make the synthesized `Codable` tolerate a
    /// missing key, and the on-disk connector can be older than the app
    /// decoding it after an update.
    private var rejectedExisting: [String]?
    var rejectedExistingPaths: [String] { rejectedExisting ?? [] }

    /// Usable means "we ran it and it came back", nothing weaker.
    ///
    /// Deliberately not derived from the file existing, the signature, or a
    /// marker file: that is exactly what the app-side check did when it reported
    /// green while SteamCMD could not launch.
    var isUsable: Bool {
        guard unavailableReason == nil, let launch else { return false }
        return launch.arguments == SteamCMDDiagnosisProbe.arguments && launch.outcome == .succeeded
    }

    /// Computed rather than carried as its own field: a remedy that travels
    /// separately can disagree with the facts it is supposed to explain.
    var remedy: String? { SteamCMDDiagnosisRemedy.advice(for: self) }

    /// `rejectedExisting` defaults to a live scan because the only caller is the
    /// connector; tests and the app pass their own.
    static func notFound(
        resolutionFailure: String?,
        rejectedExisting: [String] = SteamCMDDiagnosisRemedy.existingCandidates()
    ) -> SteamCMDDiagnosis {
        SteamCMDDiagnosis(
            source: .notFound, canonicalPath: nil, resolutionFailure: resolutionFailure,
            sha256: nil, signature: nil, isQuarantined: false, launch: nil,
            unavailableReason: nil, rejectedExisting: rejectedExisting
        )
    }

    static func unavailable(_ reason: String) -> SteamCMDDiagnosis {
        SteamCMDDiagnosis(
            source: .notFound, canonicalPath: nil, resolutionFailure: nil,
            sha256: nil, signature: nil, isQuarantined: false, launch: nil,
            unavailableReason: reason
        )
    }
}

/// The one thing the user can do about each failure, in English.
enum SteamCMDDiagnosisRemedy {
    /// Candidate paths that exist on disk. Callable only where `/opt/homebrew`
    /// is readable — the connector — which is why the result travels on the
    /// diagnosis rather than being recomputed by the sandboxed app.
    static func existingCandidates(
        candidates: [URL] = SteamCMDBinaryResolver.autoDetectCandidates(),
        fileManager: FileManager = .default
    ) -> [String] {
        candidates
            .map { $0.path(percentEncoded: false) }
            .filter { fileManager.fileExists(atPath: $0) }
    }

    static func advice(for diagnosis: SteamCMDDiagnosis) -> String? {
        let unusableExisting = diagnosis.rejectedExistingPaths
        if let reason = diagnosis.unavailableReason {
            return "The Steam connector did not finish the check (\(reason)). Run it again."
        }
        guard let path = diagnosis.canonicalPath else {
            let detail = diagnosis.resolutionFailure.map { " (\($0))" } ?? ""
            // "Install it with brew" is a dead end when brew already has it:
            // the user runs the command, is told it is installed, and lands
            // back here. Name the copy we found and could not use instead.
            if let found = unusableExisting.first {
                return """
                SteamCMD is installed at \(found), but Loomscreen could not use it\(detail). \
                Reinstall it with `brew reinstall --cask steamcmd`, or choose the steamcmd \
                binary yourself in Workshop settings.
                """
            }
            return """
            SteamCMD was not found on this Mac\(detail). Install it with \
            `brew install --cask steamcmd`, or choose the steamcmd binary yourself in \
            Workshop settings.
            """
        }
        guard let launch = diagnosis.launch else {
            return "SteamCMD at \(path) was never launched, so it cannot be reported as working. Run the check again."
        }

        switch launch.outcome {
        case .couldNotSpawn:
            if diagnosis.isQuarantined {
                return """
                macOS quarantined \(path), and a quarantined command-line binary cannot be \
                launched at all. Clear it with `xattr -d com.apple.quarantine \(path)`, then \
                run the check again.
                """
            }
            if diagnosis.signature?.isValid == false {
                return """
                \(path) could not be launched and its code signature is not valid. Reinstall \
                SteamCMD with `brew reinstall --cask steamcmd`, or let Loomscreen install its \
                own copy.
                """
            }
            return """
            \(path) could not be launched: \(condensed(launch.outputTail)). Check that it is \
            executable with `chmod +x \(path)`.
            """
        case .timedOut:
            return """
            SteamCMD did not finish its first run within \(Int(launch.timeout)) seconds. It \
            self-updates on first launch, so this is usually a network problem — run \
            `\(path) +quit` in Terminal once and let it finish.
            """
        case .exitedNonZero:
            return """
            SteamCMD exited with status \(launch.exitCode): \(condensed(launch.outputTail)). \
            Running `\(path) +quit` in Terminal shows the full log.
            """
        case .succeeded:
            guard let signature = diagnosis.signature, !signature.isValveSigned else { return nil }
            return """
            SteamCMD runs, but \(path) is not signed by Valve (team \
            \(signature.teamIdentifier ?? "unknown")). Replace it with a copy from Valve, or \
            let Loomscreen install its own.
            """
        }
    }

    /// The tail is up to a megabyte and the remedy is one sentence in a label.
    private static func condensed(_ text: String) -> String {
        let flattened = text
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        return flattened.count <= 200 ? flattened : "…" + String(flattened.suffix(200))
    }
}

/// Bounded retention for a child process's output — a ring buffer, not an
/// ever-growing `Data`: SteamCMD can emit hundreds of megabytes on a bad
/// day, and "accumulate everything, take the last 500 characters" is the
/// wrong place to be generous with memory. Ported from the retired in-app
/// process runner when the spawn moved into the connector.
struct SteamCMDOutputTail: Sendable {
    let maxBytes: Int

    private(set) var retainedByteCount = 0
    private(set) var discardedByteCount = 0
    private var buffer: Data
    private var writeIndex = 0

    init(maxBytes: Int) {
        self.maxBytes = max(0, maxBytes)
        self.buffer = Data(repeating: 0, count: max(0, maxBytes))
    }

    mutating func append(_ chunk: Data) {
        guard !chunk.isEmpty else { return }
        guard maxBytes > 0 else {
            discardedByteCount += chunk.count
            return
        }

        if chunk.count >= maxBytes {
            discardedByteCount += retainedByteCount + chunk.count - maxBytes
            buffer.replaceSubrange(0..<maxBytes, with: chunk.suffix(maxBytes))
            writeIndex = 0
            retainedByteCount = maxBytes
            return
        }

        let overflow = max(0, retainedByteCount + chunk.count - maxBytes)
        discardedByteCount += overflow
        retainedByteCount = min(maxBytes, retainedByteCount + chunk.count)

        let firstWriteCount = min(chunk.count, maxBytes - writeIndex)
        buffer.replaceSubrange(
            writeIndex..<(writeIndex + firstWriteCount),
            with: chunk.prefix(firstWriteCount)
        )
        let remaining = chunk.count - firstWriteCount
        if remaining > 0 {
            buffer.replaceSubrange(0..<remaining, with: chunk.suffix(remaining))
        }
        writeIndex = (writeIndex + chunk.count) % maxBytes
    }

    var data: Data {
        guard retainedByteCount > 0 else { return Data() }
        guard retainedByteCount == maxBytes else {
            return Data(buffer.prefix(retainedByteCount))
        }
        guard writeIndex > 0 else { return buffer }

        var result = Data()
        result.reserveCapacity(maxBytes)
        result.append(buffer[writeIndex...])
        result.append(buffer[..<writeIndex])
        return result
    }

    var string: String {
        let bytes = data
        return String(data: bytes, encoding: .utf8) ?? String(decoding: bytes, as: UTF8.self)
    }

}

/// Facts worth keeping even after the tail has evicted them. The diagnostic
/// tail is small on purpose, so a long run can push the version banner, the
/// "Success. Downloaded item" line, or the public `buildid` out of it — and
/// those are exactly the lines callers parse. Holds a fixed number of
/// independent slots so verbose output can't starve them.
struct SteamCMDOutputSemanticSummary: Sendable {
    private static let maxLineBytes = 4 * 1_024

    private var identityLine: String?
    private var cachedLoginLine: String?
    private var loginResultLine: String?
    private var cachedCredentialsMissingLine: String?
    private var failureLine: String?
    private var downloadResultLine: String?
    private var subscriptionLine: String?
    private var teamIdentifierLine: String?
    private var codeFlagsLine: String?
    private var publicBranchContext: [String] = []
    private var publicBranchContextLinesRemaining = 0

    mutating func consume(_ rawLine: String) {
        let line = rawLine.trimmingCharacters(in: .newlines)
        guard line.utf8.count <= Self.maxLineBytes else { return }
        let startsPublicContext = line.contains(#""public""#)
        if startsPublicContext {
            publicBranchContextLinesRemaining = 16
            publicBranchContext = []
        }

        if publicBranchContextLinesRemaining > 0 {
            publicBranchContext.append(line)
            publicBranchContextLinesRemaining -= 1
        }

        // Independent fixed slots prevent one repeated/fabricated marker class
        // from exhausting storage needed by later real facts. Latest wins so
        // the process's terminal state supersedes startup chatter.
        if line.contains("Steam Console Client (c) Valve Corporation") { identityLine = line }
        if line.contains("Logging in using cached credentials.") { cachedLoginLine = line }
        if line.contains("Logging in user '") { loginResultLine = line }
        if line.contains("Cached credentials not found.") { cachedCredentialsMissingLine = line }
        if line.contains("FAILED (") { failureLine = line }
        if line.contains("Success. Downloaded item ") || line.contains("ERROR! Download item ") {
            downloadResultLine = line
        }
        if line.contains("No subscription") { subscriptionLine = line }
        if line.contains("TeamIdentifier=") { teamIdentifierLine = line }
        if line.contains("flags=0x") { codeFlagsLine = line }
    }

    func rendered(with tail: SteamCMDOutputTail) -> String {
        guard tail.discardedByteCount > 0 else { return tail.string }
        let facts = [
            identityLine,
            cachedLoginLine,
            loginResultLine,
            cachedCredentialsMissingLine,
            failureLine,
            downloadResultLine,
            subscriptionLine,
            teamIdentifierLine,
            codeFlagsLine,
        ].compactMap { $0 } + publicBranchContext
        let summary = facts.isEmpty ? "" : facts.joined(separator: "\n") + "\n"
        let marker = "[... \(tail.discardedByteCount) output bytes omitted; showing semantic lines and tail ...]\n"
        return summary + marker + tail.string
    }
}

/// SHA-256 of a file on disk. Shared so the app's tests exercise the exact
/// function the connector re-hashes with, rather than a lookalike.
enum SteamCMDBinaryDigest {
    /// Streams the file: a helper that hashes whatever path it is handed should
    /// not size its memory off that path's contents.
    static func sha256(ofFileAt path: String) -> String? {
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try? handle.read(upToCount: 64 * 1024), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

/// Where this process refuses to execute from, whatever the signature or
/// digest says. Every pre-spawn check — `codesign --verify`, quarantine
/// read, re-hash — opens, decides, and closes the path; the spawn opens it
/// again. macOS has no `fexecve` binding those two opens to one inode, so a
/// caller that can write the path can swap bytes in between (steamcmd also
/// must run from inside its own directory tree, so executing a verified
/// copy elsewhere isn't available). What's left: keep the executable out of
/// the caller's own writable storage — where a compromised app could stage
/// a replacement — including the temp directory it's handed (the sandbox
/// redirects that into the container too); a real SteamCMD never lives in
/// either. Matched on substrings, not prefixes: the home directory varies,
/// and `/Users/x/Library/Containers/…` is the shape that matters.
enum SteamCMDExecutionFence {
    static let callerWritableMarkers = [
        "/Library/Containers/",
        "/Library/Group Containers/"
    ]

    /// Symlinks are resolved first: a link outside a container pointing into one
    /// executes the file inside it, so judging the link's own path would miss.
    static func refusesExecution(of path: String) -> Bool {
        let resolved = URL(fileURLWithPath: path)
            .resolvingSymlinksInPath()
            .standardizedFileURL
            .path(percentEncoded: false)
        return callerWritableMarkers.contains { resolved.contains($0) }
    }
}

/// Reads `codesign` output. Shared so the connector produces the verdict and the
/// app's tests can pin the parsing without spawning anything.
enum SteamCMDCodeSignatureParser {
    /// Fail-closed: anything other than a clean, completed `--verify` is invalid.
    /// A timeout in particular must never read as "signed".
    static func signatureValid(verifyExitCode: Int32, timedOut: Bool) -> Bool {
        verifyExitCode == 0 && !timedOut
    }

    static func teamIdentifier(in text: String) -> String? {
        firstCapture(in: text, pattern: #"TeamIdentifier=([A-Z0-9]+)"#)
    }

    static func isHardenedRuntime(in text: String) -> Bool {
        text.range(
            of: #"flags=0x[0-9a-fA-F]+\([^)]*runtime"#,
            options: .regularExpression
        ) != nil || text.contains("runtime")
    }

    private static func firstCapture(in text: String, pattern: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(text.startIndex ..< text.endIndex, in: text)
        guard let match = regex.firstMatch(in: text, range: range),
              match.numberOfRanges > 1,
              let captureRange = Range(match.range(at: 1), in: text) else { return nil }
        return String(text[captureRange])
    }
}

/// The scrubbed environment handed to the SteamCMD child process — mirrors
/// the main app's `SteamCMDProcessRunner.sanitizedChildEnvironment()`. A
/// bare `Process()` inherits the connector's whole environment, and an
/// unsandboxed helper is the worse place to hand a child `DYLD_*`, not the
/// safer one. Lives here, not the service body, so the rules are testable.
enum SteamCMDChildEnvironment {
    /// Everything the child is allowed to see. Anything absent is dropped.
    static func make(
        home: String = SteamConnectorEnvironmentProbe.posixHomeDirectory(),
        temporaryDirectory: String = NSTemporaryDirectory()
    ) -> [String: String] {
        [
            // Deliberately the real home: it is what puts STEAMROOT on the shared
            // Steam profile instead of the app container, which is the entire
            // reason the connector exists.
            "HOME": home,
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
            "TMPDIR": temporaryDirectory,
            // Pinned to match the app runner. The progress parser reads
            // `progress: 42.34` positionally and stops at the first non-digit, so
            // a comma-decimal rendering would truncate to 42% rather than fail —
            // a silent wrong number, which is the kind worth pinning against.
            "LANG": "en_US.UTF-8",
        ]
    }
}

/// Where Loomscreen may write inside the shared Steam library, and nowhere else.
///
/// Pure rules, shared with the app so the boundary can be asserted in tests
/// without a Steam install. The mutating half lives only in the connector.
enum SteamLibraryPaths {
    static let wallpaperEngineAppID = "431960"

    /// The two subtrees Loomscreen may write, relative to the Steam root.
    private static let writableSubtrees: [[String]] = [
        workshopContentComponents,
        wallpaperEngineComponents
    ]

    static func steamRoot() -> URL {
        URL(fileURLWithPath: SteamConnectorEnvironmentProbe.posixHomeDirectory(), isDirectory: true)
            .appendingPathComponent("Library/Application Support/Steam", isDirectory: true)
    }

    /// The two roots take an injectable Steam root for the same reason
    /// `isWritable` does: the destructive paths must be exercisable against a
    /// scratch tree, never the user's library.
    static func workshopContentRoot(steamRoot root: URL = steamRoot()) -> URL {
        root.appendingPathComponent(
            "steamapps/workshop/content/\(wallpaperEngineAppID)",
            isDirectory: true
        )
    }

    static let workshopContentComponents = ["steamapps", "workshop", "content", wallpaperEngineAppID]
    static let wallpaperEngineComponents = ["steamapps", "common", "wallpaper_engine"]

    static func wallpaperEngineInstallRoot(steamRoot root: URL = steamRoot()) -> URL {
        root.appendingPathComponent("steamapps/common/wallpaper_engine", isDirectory: true)
    }

    /// A Workshop id must be exactly ASCII `0-9`: it becomes a path component
    /// under the user's real Steam library. Not `Character.isNumber` — that
    /// also passes Nd/Nl/No (fullwidth `１２３`, `①`, `٤`), which are not Steam
    /// ids but would still be created or deleted as directories.
    static func isSafeWorkshopID(_ id: String) -> Bool {
        !id.isEmpty && id.count <= 20 && id.utf8.allSatisfy { $0 >= 0x30 && $0 <= 0x39 }
    }

    /// True only for paths at or under one of the two writable subtrees,
    /// with **no symlink anywhere between the Steam root and the target**.
    /// Resolving both sides before comparing was not containment: replacing
    /// `steamapps/workshop/content/431960` with a link to `~/Documents` made
    /// the target and its anchor resolve consistently, so an arbitrary
    /// directory looked "inside" — the path is instead walked one
    /// component at a time with `lstat`, which doesn't follow links.
    /// `steamRoot` is injectable so the walk runs against a scratch tree;
    /// the real library must never be mutated by a test.
    static func isWritable(_ url: URL, steamRoot root: URL) -> Bool {
        // Use the root exactly as given. Canonicalizing it here while the target
        // stays lexical made a legitimately symlinked Steam root fail its own
        // prefix test; the walk below starts after the root, so the root being a
        // link is accepted without ever resolving anything under it.
        var base = root.standardizedFileURL.path(percentEncoded: false)
        while base.count > 1 && base.hasSuffix("/") { base.removeLast() }
        let target = url.standardizedFileURL.path(percentEncoded: false)
        guard target.hasPrefix(base + "/") else { return false }

        let components = String(target.dropFirst(base.count + 1))
            .split(separator: "/").map(String.init)
        guard !components.contains(".."), !components.contains(".") else { return false }
        guard writableSubtrees.contains(where: {
            components.count >= $0.count && Array(components.prefix($0.count)) == $0
        }) else { return false }

        var walked = base
        for component in components {
            walked += "/" + component
            var info = stat()
            // A component that does not exist yet is fine; one that exists as a
            // link is not, whatever it points at.
            guard lstat(walked, &info) == 0 else { return true }
            if (info.st_mode & S_IFMT) == S_IFLNK { return false }
        }
        return true
    }
}

/// Reads Wallpaper Engine build ids out of SteamCMD's `app_info_print` dump.
enum SteamConnectorBuildInfo {
    /// `"buildid"  "23967692"` inside the public branch block. Reads the
    /// buildid from inside the `public` block only — scanning the whole
    /// remainder after `"public"` meant a block with no readable buildid
    /// silently fell to the next branch, reporting a beta build as public
    /// and driving a wrong update verdict.
    static func parsePublicBuildID(from output: String) -> String? {
        guard let publicRange = output.range(of: "\"public\"") else { return nil }
        let afterKey = output[publicRange.upperBound...]
        guard let open = afterKey.firstIndex(of: "{") else { return nil }

        var depth = 0
        var index = open
        while index < afterKey.endIndex {
            let character = afterKey[index]
            if character == "{" { depth += 1 }
            else if character == "}" {
                depth -= 1
                if depth == 0 { break }
            }
            index = afterKey.index(after: index)
        }
        guard depth == 0, index < afterKey.endIndex else { return nil }

        let block = afterKey[afterKey.index(after: open)..<index]
        guard let match = block.firstMatch(of: /"buildid"\s+"(\d+)"/) else { return nil }
        return String(match.output.1)
    }
    
}


/// Resolves a user-selected SteamCMD path to the canonical Mach-O binary we
/// are willing to execute. `steamcmd.sh` wrappers are accepted only as a
/// discovery convenience — we parse them to extract `STEAMEXE` and refuse to
/// execute the wrapper itself (the wrapper is shell code that runs before
/// SteamCMD, so a tampered install could inject arbitrary commands).
enum SteamCMDBinaryResolver {

    static func resolveCanonicalBinary(at userPickedURL: URL) -> Result<URL, SteamCMDBinaryError> {
        let pickedURL = userPickedURL.resolvingSymlinksInPath().standardizedFileURL
        guard fileExists(pickedURL) else {
            return .failure(.fileNotFound)
        }
        // A Mach-O is the executable itself. Anything else — Valve's
        // `steamcmd.sh`, Homebrew's `steamcmd.wrapper.sh`, or a
        // `/opt/homebrew/bin/steamcmd` symlink that resolves to one — is a
        // shell wrapper we follow to the real binary.
        if isMachO(pickedURL) {
            return validateBinary(pickedURL).map { pickedURL }
        }
        return resolveWrapper(pickedURL)
    }

    /// Where the package managers put SteamCMD, in the order tried.
    /// `which steamcmd` isn't an option — launchd starts this XPC service
    /// without sourcing the shell profile, so `/opt/homebrew/bin` isn't on
    /// `PATH` — so these are `stat`s at derived paths instead, covering
    /// Homebrew's three historical cask layouts: (1) `<prefix>/bin/steamcmd`,
    /// the `binary` stanza's symlink, the only thing searched until
    /// 2026-08-14; (2) `<prefix>/.homebrew-command-wrappers/steamcmd`, the
    /// Command Wrapper stanza upstream's cask moved to, which writes no
    /// `bin` symlink so layer 1 alone misreports "not installed"; (3)
    /// `<prefix>/Caskroom/steamcmd/<version>/MacOS/steamcmd`, the real
    /// Mach-O, reached when both links are absent (e.g. after `brew unlink`,
    /// which renames the symlink to `steamcmd.off` — deliberately not
    /// honoured, since `.off` means the user disabled it). Measured
    /// 2026-08-14 on a Homebrew Mac: all three old fixed paths were missing,
    /// reachable only through layer 3. Not searched: `~/steamcmd`, `~/Steam`
    /// (read the sandbox container until 2026-08-02, never matched), nor the
    /// managed install (`SteamCMDManagedInstaller.managedBinary()`, spliced
    /// in by `SteamCMDDiagnosisPlan`).
    static func autoDetectCandidates(
        roots: SearchRoots = SearchRoots(),
        fileManager: FileManager = .default
    ) -> [URL] {
        var candidates: [URL] = []

        for prefix in roots.homebrewPrefixes {
            candidates.append(URL(fileURLWithPath: prefix + "/bin/steamcmd"))
        }
        candidates.append(URL(fileURLWithPath: roots.macPortsPrefix + "/bin/steamcmd"))
        for prefix in roots.homebrewPrefixes {
            candidates.append(URL(fileURLWithPath: prefix + "/.homebrew-command-wrappers/steamcmd"))
        }
        for prefix in roots.homebrewPrefixes {
            candidates.append(contentsOf: caskroomBinaries(homebrewPrefix: prefix, fileManager: fileManager))
        }
        return candidates
    }

    /// The prefixes searched. Injectable so the Caskroom walk can be exercised
    /// against a fixture instead of whatever the test machine happens to have
    /// installed.
    struct SearchRoots: Sendable {
        var homebrewPrefixes: [String]
        var macPortsPrefix: String

        /// `HOMEBREW_PREFIX` deliberately absent: it lives in the user's
        /// shell profile, and launchd starts this service without sourcing
        /// one (same reason `which steamcmd` is unusable, see
        /// `autoDetectCandidates`) — reading it would look like
        /// relocated-prefix support while always empty here. A Homebrew
        /// elsewhere is covered by the manual pick instead.
        init(
            homebrewPrefixes: [String] = ["/opt/homebrew", "/usr/local"],
            macPortsPrefix: String = "/opt/local"
        ) {
            self.homebrewPrefixes = homebrewPrefixes
            self.macPortsPrefix = macPortsPrefix
        }
    }

    /// Entry points inside one Caskroom version directory, in the order
    /// tried. The wrapper comes first, Mach-O paths after: `resolveWrapper`
    /// already follows the cask's `steamcmd.wrapper.sh` to whatever the
    /// payload contains, covering layouts this list has never seen.
    /// Offering only `MacOS/steamcmd` — all this used to do — made
    /// discovery depend on one internal path Homebrew is free to change,
    /// and when it did the app reported "not found" for an install sitting
    /// right there.
    static let caskroomEntryPoints = [
        "steamcmd.wrapper.sh",
        "MacOS/steamcmd",
        "steamcmd",
        "osx32/steamcmd"
    ]

    /// Every installed cask version's entry points, newest version first —
    /// all versions, not just the newest: Homebrew leaves older version
    /// directories behind after an upgrade, and if the newest fails a trust
    /// gate, `SteamCMDDiagnosisPlan.firstTrusted` should get to try the one
    /// that passes.
    private static func caskroomBinaries(homebrewPrefix: String, fileManager: FileManager) -> [URL] {
        let cask = URL(fileURLWithPath: homebrewPrefix + "/Caskroom/steamcmd", isDirectory: true)
        guard let versions = try? fileManager.contentsOfDirectory(
            at: cask,
            includingPropertiesForKeys: [.contentModificationDateKey],
            // Skips `.metadata`, which is a sibling of the version directories.
            options: [.skipsHiddenFiles]
        ) else { return [] }

        return versions
            .sorted { modificationDate(of: $0) > modificationDate(of: $1) }
            .flatMap { version in
                caskroomEntryPoints.map {
                    version.appendingPathComponent($0, isDirectory: false)
                }
            }
    }

    private static func modificationDate(of url: URL) -> Date {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
            ?? .distantPast
    }

    /// `depth` bounds the wrapper chain. Homebrew's cask is genuinely two deep
    /// (`steamcmd.wrapper.sh` execs `MacOS/steamcmd.sh`, which execs the Mach-O),
    /// and a wrapper that execs itself would otherwise spin here.
    private static func resolveWrapper(_ wrapperURL: URL, depth: Int = 0) -> Result<URL, SteamCMDBinaryError> {
        let wrapperDir = wrapperURL.deletingLastPathComponent()

        // 1) An explicit `STEAMEXE=<path>` line (Valve's tarball `steamcmd.sh`).
        if let value = try? steamExecutableValue(in: wrapperURL) {
            let target = resolveShellPath(value, relativeTo: wrapperDir)
                .resolvingSymlinksInPath()
                .standardizedFileURL
            if fileExists(target), isMachO(target), case .success = validateBinary(target) {
                return .success(target)
            }
        }

        // 2) Otherwise locate the `steamcmd` Mach-O next to the wrapper. Covers
        //    Homebrew's `steamcmd.wrapper.sh` (binary under `MacOS/`) and
        //    Valve's tarball layout (alongside, or under `osx32/`).
        for relative in ["steamcmd", "MacOS/steamcmd", "osx32/steamcmd"] {
            let candidate = wrapperDir.appendingPathComponent(relative, isDirectory: false).standardizedFileURL
            if fileExists(candidate), isMachO(candidate), case .success = validateBinary(candidate) {
                return .success(candidate)
            }
        }

        // 3) Follow a bare `exec '<path>' "$@"`. Homebrew's Command Wrapper
        //    stanza and its cask wrapper are both this shape, and neither sits
        //    anywhere near the Mach-O, so neither (1) nor (2) can reach it.
        if depth < 2, let target = execTarget(in: wrapperURL, relativeTo: wrapperDir) {
            if isMachO(target) {
                return validateBinary(target).map { target }
            }
            if fileExists(target) {
                return resolveWrapper(target, depth: depth + 1)
            }
        }

        return .failure(.wrapperParseFailed(reason: "Couldn't find the SteamCMD Mach-O binary near \(wrapperURL.lastPathComponent)."))
    }

    /// The path from the first `exec <path>` line, quoted or not.
    private static func execTarget(in wrapperURL: URL, relativeTo wrapperDir: URL) -> URL? {
        guard let data = try? Data(contentsOf: wrapperURL, options: .mappedIfSafe),
              let script = String(data: data.prefix(64 * 1024), encoding: .utf8) else { return nil }

        for rawLine in script.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard line.hasPrefix("exec ") else { continue }
            let argument = String(line.dropFirst("exec ".count)).trimmingCharacters(in: .whitespaces)
            guard let value = firstShellWord(argument) else { continue }
            // `exec "$0"` is the restart line at the bottom of Valve's script.
            guard !value.isEmpty, !value.contains("$") else { continue }
            return resolveShellPath(value, relativeTo: wrapperDir)
                .resolvingSymlinksInPath()
                .standardizedFileURL
        }
        return nil
    }

    private static func steamExecutableValue(in wrapperURL: URL) throws -> String {
        let data = try Data(contentsOf: wrapperURL, options: .mappedIfSafe)
        guard let script = String(data: data.prefix(64 * 1024), encoding: .utf8) else {
            throw SteamCMDBinaryError.wrapperParseFailed(reason: "steamcmd.sh is not valid UTF-8")
        }

        for rawLine in script.components(separatedBy: .newlines) {
            var line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty, !line.hasPrefix("#") else { continue }
            if line.hasPrefix("export ") {
                line.removeFirst("export ".count)
                line = line.trimmingCharacters(in: .whitespaces)
            }
            guard line.hasPrefix("STEAMEXE=") else { continue }
            let stripped = stripShellQuoting(String(line.dropFirst("STEAMEXE=".count)).trimmingCharacters(in: .whitespaces))
            guard !stripped.isEmpty else {
                throw SteamCMDBinaryError.wrapperParseFailed(reason: "STEAMEXE is empty")
            }
            return stripped
        }
        throw SteamCMDBinaryError.wrapperParseFailed(reason: "STEAMEXE assignment not found")
    }

    /// The first argument of a command line, unquoted. Everything after it —
    /// `"$@"` in practice — is dropped.
    private static func firstShellWord(_ argument: String) -> String? {
        guard let first = argument.first else { return nil }
        if first == "'" || first == "\"" {
            let body = argument.dropFirst()
            guard let end = body.firstIndex(of: first) else { return nil }
            return String(body[body.startIndex..<end])
        }
        return String(argument.prefix(while: { !$0.isWhitespace }))
    }

    private static func stripShellQuoting(_ value: String) -> String {
        var output = value
        if let commentRange = output.range(of: #"\s+#"#, options: .regularExpression) {
            output = String(output[..<commentRange.lowerBound])
        }
        if output.count >= 2,
           let first = output.first,
           let last = output.last,
           (first == "\"" && last == "\"") || (first == "'" && last == "'") {
            output.removeFirst()
            output.removeLast()
        }
        return output
    }

    private static func resolveShellPath(_ value: String, relativeTo wrapperDirectory: URL) -> URL {
        let wrapperPath = wrapperDirectory.path(percentEncoded: false)
        var expanded = value
            .replacingOccurrences(of: "${STEAMROOT}", with: wrapperPath)
            .replacingOccurrences(of: "$STEAMROOT", with: wrapperPath)

        if expanded.hasPrefix("~/") {
            expanded = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(String(expanded.dropFirst(2)))
                .path(percentEncoded: false)
        }
        if expanded.hasPrefix("/") {
            return URL(fileURLWithPath: expanded)
        }
        let direct = wrapperDirectory.appendingPathComponent(expanded, isDirectory: false)
        if fileExists(direct) { return direct }

        for child in ["MacOS", "osx32"] {
            let candidate = wrapperDirectory
                .appendingPathComponent(child, isDirectory: true)
                .appendingPathComponent((expanded as NSString).lastPathComponent, isDirectory: false)
            if fileExists(candidate) { return candidate }
        }
        return direct
    }

    private static func validateBinary(_ url: URL) -> Result<Void, SteamCMDBinaryError> {
        guard isMachO(url) else { return .failure(.notMachO) }
        guard FileManager.default.isExecutableFile(atPath: url.path(percentEncoded: false)) else {
            return .failure(.notExecutable)
        }
        return .success(())
    }

    private static func isMachO(_ url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: 4), data.count == 4 else { return false }
        let bytes = Array(data)
        return bytes == [0xfe, 0xed, 0xfa, 0xce]
            || bytes == [0xce, 0xfa, 0xed, 0xfe]
            || bytes == [0xfe, 0xed, 0xfa, 0xcf]
            || bytes == [0xcf, 0xfa, 0xed, 0xfe]
            || bytes == [0xca, 0xfe, 0xba, 0xbe]
            || bytes == [0xbe, 0xba, 0xfe, 0xca]
            || bytes == [0xca, 0xfe, 0xba, 0xbf]
            || bytes == [0xbf, 0xba, 0xfe, 0xca]
    }

    private static func fileExists(_ url: URL) -> Bool {
        var isDirectory = ObjCBool(false)
        return FileManager.default.fileExists(atPath: url.path(percentEncoded: false), isDirectory: &isDirectory)
            && !isDirectory.boolValue
    }

}

enum SteamCMDBinaryError: Error, Equatable, Sendable {
    case fileNotFound
    case notMachO
    case wrapperParseFailed(reason: String)
    case notExecutable
}

/// Unpacks and validates a managed SteamCMD install. Runs only in the
/// connector, which is unsandboxed, so every step assumes app-supplied
/// inputs are hostile: the app is the one process that can write into the
/// container these paths point at, so "the app already checked it" is not
/// a property this code may rely on.
enum SteamCMDManagedInstaller {
    /// The one directory a managed install may occupy. Derived here, not
    /// accepted from the caller: an unsandboxed service unpacking wherever
    /// it's told is an arbitrary-write primitive, and the caller has no
    /// info about a destination this process lacks. Deliberately *not* the
    /// app's container — writable by the sandboxed app, so every check
    /// would be check-then-use: the app could replace the leaf with a
    /// symlink after the `lstat` walk and before `removeItem`/`tar -C`
    /// runs, making this process recursively delete/rewrite whatever it
    /// points at. A path the app can't write is the only closed version of
    /// that window.
    static func canonicalInstallRoot(
        home: URL = URL(fileURLWithPath: NSHomeDirectory())
    ) -> URL {
        home
            .appendingPathComponent("Library/Application Support", isDirectory: true)
            .appendingPathComponent("Loomscreen", isDirectory: true)
            .appendingPathComponent("SteamCMD", isDirectory: true)
            .standardizedFileURL
    }

    /// Accepts the caller's install root only if it's byte-for-byte the one
    /// directory we would have chosen, and no path component is a symlink.
    /// Both halves matter: without the equality check, an unsandboxed
    /// service unpacks wherever the caller points it; without the symlink
    /// walk, a link planted at `…/Loomscreen/SteamCMD` sends the recursive
    /// delete and rewrite elsewhere (`standardizedFileURL` resolves `..`
    /// but never follows links).
    static func containedInstallRoot(
        _ path: String,
        home: URL = URL(fileURLWithPath: NSHomeDirectory())
    ) -> Result<URL, SteamCMDManagedInstallResult> {
        let requested = URL(fileURLWithPath: path).standardizedFileURL
        let expected = canonicalInstallRoot(home: home)
        // Compare trailing-slash-normalised strings: a directory URL renders its
        // path with a trailing "/" and a caller-supplied string does not, so a
        // raw comparison rejects even the one path this is meant to accept.
        guard Self.normalisedPath(requested) == Self.normalisedPath(expected) else {
            return .failure(.failed(
                .extractionFailed,
                "Install root is not the managed SteamCMD directory",
                code: .installRootMismatch
            ))
        }
        if let offending = firstSymlinkComponent(of: expected) {
            return .failure(.failed(
                .extractionFailed,
                "Install path component is a symbolic link: \(offending)",
                code: .installPathSymlink, arguments: [offending]
            ))
        }
        return .success(expected)
    }

    static func normalisedPath(_ url: URL) -> String {
        var path = url.path(percentEncoded: false)
        while path.count > 1, path.hasSuffix("/") { path.removeLast() }
        return path
    }

    /// `lstat`s every component so a link anywhere along the path is caught,
    /// not just a link at the leaf.
    static func firstSymlinkComponent(of url: URL) -> String? {
        var walked = URL(fileURLWithPath: "/")
        for component in url.pathComponents.dropFirst() {
            walked.appendPathComponent(component)
            let path = walked.path(percentEncoded: false)
            // lstat, not attributesOfItem: ENOENT means "not created yet"
            // (fine, we will make it), but any other error means we could not
            // establish that this component is safe — which must read as unsafe,
            // not as absent.
            var info = stat()
            if lstat(path, &info) != 0 {
                if errno == ENOENT { continue }
                return path
            }
            if (info.st_mode & S_IFMT) == S_IFLNK { return path }
        }
        return nil
    }

    static func payloadDirectory(installRoot: URL) -> URL {
        installRoot.appendingPathComponent(
            SteamCMDBootstrapPackage.payloadSubdirectory, isDirectory: true
        )
    }

    /// The managed install's Mach-O, found under the root this process derives
    /// rather than one the caller names. The install root sits in the real home
    /// directory, which an unsandboxed service can see — so there is nothing the
    /// app needs to tell us, and taking its word would mean spawning whatever
    /// path its defaults happen to hold.
    static func managedBinary(home: URL = URL(fileURLWithPath: NSHomeDirectory())) -> URL? {
        let payload = payloadDirectory(installRoot: canonicalInstallRoot(home: home))
        guard case .success(let binary) = locateBinary(in: payload) else { return nil }
        return binary
    }

    /// Replaces any previous payload so a half-finished install can't be
    /// mistaken for a good one, then unpacks into `MacOS/`. Takes a list
    /// because the manifest ships one zip per package; they all unpack into
    /// the same staging tree, as SteamCMD's own updater arranges them —
    /// bsdtar detects the container format, so tarball and zip callers
    /// share this path.
    static func extract(
        archives: [URL],
        installRoot: URL,
        spawn: (String, [String], TimeInterval) -> (output: String, exitCode: Int32, timedOut: Bool)
    ) -> Result<ExtractedInstall, SteamCMDManagedInstallResult> {
        let payload = payloadDirectory(installRoot: installRoot)

        // Unpack under an unpredictable name, then move into place:
        // extracting straight into the payload path let a symlink be
        // planted between the check and the write. A name nobody can
        // predict can't be pre-planted, and `mkdir` (no
        // `withIntermediateDirectories`) adopts nothing already there.
        let staging = installRoot.appendingPathComponent(
            ".unpack-\(UUID().uuidString)", isDirectory: true
        )
        do {
            try FileManager.default.createDirectory(
                at: installRoot, withIntermediateDirectories: true
            )
            try FileManager.default.createDirectory(
                at: staging, withIntermediateDirectories: false
            )
        } catch {
            return .failure(.failed(
                .extractionFailed,
                "Could not create the install directory: \(error.localizedDescription)",
                code: .installDirectoryCreateFailed, arguments: [error.localizedDescription]
            ))
        }

        func discardStaging() { try? FileManager.default.removeItem(at: staging) }
        for archive in archives {
            let run = spawn(
                "/usr/bin/tar",
                [
                    "-xf", archive.path(percentEncoded: false),
                    "-C", staging.path(percentEncoded: false)
                ],
                300
            )
            guard !run.timedOut else {
                discardStaging()
                return .failure(.failed(.extractionFailed, "Unpacking timed out", code: .unpackTimedOut))
            }
            guard run.exitCode == 0 else {
                discardStaging()
                return .failure(.failed(
                    .extractionFailed,
                    "tar exited \(run.exitCode): \(run.output.prefix(200))",
                    code: .tarExitedNonZero,
                    arguments: ["\(run.exitCode)", String(run.output.prefix(200))]
                ))
            }
        }
        // Valve's manifest zips carry no unix permissions (measured 2026-08-13:
        // everything lands 0644), and `steamcmd.sh` checks `-x` without ever
        // chmodding — the bootstrapper used to set these bits. Without this the
        // freshly installed steamcmd cannot be spawned at all.
        for name in ["steamcmd", "steamcmd.sh"] {
            let executable = staging.appendingPathComponent(name, isDirectory: false)
            if FileManager.default.fileExists(atPath: executable.path(percentEncoded: false)) {
                try? FileManager.default.setAttributes(
                    [.posixPermissions: NSNumber(value: Int16(0o755))],
                    ofItemAtPath: executable.path(percentEncoded: false)
                )
            }
        }

        // bsdtar refuses `..` members and strips leading `/`, but it happily
        // creates a symlink pointing outside the destination. On its own that is
        // inert; combined with a later write through it, it is an escape. The
        // archive is digest-pinned, so this is belt-and-braces — but the digest
        // gate is exactly the kind of thing that gets relaxed later.
        if let escaping = firstEscapingSymlink(under: staging) {
            discardStaging()
            return .failure(.failed(
                .extractionFailed,
                "Archive contains a symbolic link escaping the install directory: \(escaping)",
                code: .archiveSymlinkEscape, arguments: [escaping]
            ))
        }

        // Swap into place. The audited tree is what becomes the payload; the
        // previous one is moved aside first so a failure never leaves a
        // half-replaced install behind.
        let retired = installRoot.appendingPathComponent(
            ".retired-\(UUID().uuidString)", isDirectory: true
        )
        let payloadPath = payload.path(percentEncoded: false)
        var hadPrevious = false
        if FileManager.default.fileExists(atPath: payloadPath) {
            do {
                try FileManager.default.moveItem(at: payload, to: retired)
                hadPrevious = true
            } catch {
                discardStaging()
                return .failure(.failed(
                    .extractionFailed,
                    "Could not retire the previous install: \(error.localizedDescription)",
                code: .retirePreviousFailed, arguments: [error.localizedDescription]
                ))
            }
        }
        do {
            try FileManager.default.moveItem(at: staging, to: payload)
        } catch {
            if hadPrevious { try? FileManager.default.moveItem(at: retired, to: payload) }
            discardStaging()
            return .failure(.failed(
                .extractionFailed,
                "Could not move the unpacked install into place: \(error.localizedDescription)",
                code: .moveIntoPlaceFailed, arguments: [error.localizedDescription]
            ))
        }
        // The previous tree stays on disk. Everything that decides whether this
        // install is usable — the `+quit` self-update, and re-verifying the
        // binary it rewrites — runs in the caller, and deleting the old copy
        // here would leave a reinstall that fails those checks with nothing to
        // fall back to.
        return .success(ExtractedInstall(payload: payload, retired: hadPrevious ? retired : nil))
    }

    /// A freshly unpacked payload plus the install it displaced, if any.
    struct ExtractedInstall {
        let payload: URL
        /// Previous install, moved aside. `commit` deletes it; `rollBack`
        /// puts it back. Exactly one of the two must run.
        let retired: URL?
    }

    /// Accepts the new install and discards the old one.
    static func commit(_ install: ExtractedInstall) {
        guard let retired = install.retired else { return }
        try? FileManager.default.removeItem(at: retired)
    }

    /// What a rollback actually managed to do. Reported rather than swallowed:
    /// the canonical path holding a payload that just failed its checks, or the
    /// working copy stranded under a random `.retired-*` name, are both states
    /// the user has to be told about — silently they read as "nothing happened".
    enum RollbackOutcome: Equatable, Sendable {
        case restored
        /// Nothing was displaced; the failed payload is gone.
        case noPreviousInstall
        case recoveryFailed(retiredPath: String, reason: String)
    }

    /// Puts the previous install back after a post-extraction check failed.
    /// The new payload is cleared out first — it is the one that just proved
    /// itself unusable, and leaving it would win the next `locateBinary`.
    @discardableResult
    static func rollBack(_ install: ExtractedInstall) -> RollbackOutcome {
        guard let retired = install.retired else {
            try? FileManager.default.removeItem(at: install.payload)
            let installRoot = install.payload.deletingLastPathComponent()
            if let remaining = try? FileManager.default.contentsOfDirectory(
                at: installRoot,
                includingPropertiesForKeys: nil
            ), remaining.isEmpty {
                try? FileManager.default.removeItem(at: installRoot)
            }
            return .noPreviousInstall
        }
        let retiredPath = retired.path(percentEncoded: false)
        do {
            try FileManager.default.removeItem(at: install.payload)
        } catch {
            // Undeletable (file flags, ACL, I/O): moving it aside still frees
            // the canonical path, which is what the old copy needs back.
            let failed = install.payload.deletingLastPathComponent()
                .appendingPathComponent(".failed-\(UUID().uuidString)", isDirectory: true)
            do {
                try FileManager.default.moveItem(at: install.payload, to: failed)
            } catch {
                return .recoveryFailed(
                    retiredPath: retiredPath,
                    reason: "the new payload could not be cleared: \(error.localizedDescription)"
                )
            }
        }
        do {
            try FileManager.default.moveItem(at: retired, to: install.payload)
            return .restored
        } catch {
            return .recoveryFailed(
                retiredPath: retiredPath,
                reason: error.localizedDescription
            )
        }
    }

    /// Any symlink under `root` whose target resolves outside `root`.
    static func firstEscapingSymlink(under root: URL) -> String? {
        let rootComponents = root.resolvingSymlinksInPath().standardizedFileURL.pathComponents
        guard let walker = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isSymbolicLinkKey]
        ) else { return nil }
        for case let entry as URL in walker {
            guard (try? entry.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true else {
                continue
            }
            let resolved = entry.resolvingSymlinksInPath().standardizedFileURL
            if !isDescendant(resolved.pathComponents, of: rootComponents) {
                return entry.path(percentEncoded: false)
            }
        }
        return nil
    }

    static func isDescendant(_ components: [String], of root: [String]) -> Bool {
        components.count > root.count && Array(components.prefix(root.count)) == root
    }

    /// Locates the Mach-O inside a freshly unpacked payload, and refuses one
    /// that resolves outside it. The shared resolver honours `STEAMEXE=`
    /// from the wrapper script and resolves symlinks, both of which can
    /// name an absolute path elsewhere on disk — without this check a
    /// swapped archive could aim the signature check and the spawn at some
    /// other Valve-signed binary.
    static func locateBinary(in payload: URL) -> Result<URL, SteamCMDManagedInstallResult> {
        let payloadComponents = payload.resolvingSymlinksInPath().standardizedFileURL.pathComponents
        for candidate in ["steamcmd.sh", "steamcmd"] {
            let url = payload.appendingPathComponent(candidate, isDirectory: false)
            guard FileManager.default.fileExists(atPath: url.path(percentEncoded: false)),
                  case .success(let resolved) = SteamCMDBinaryResolver.resolveCanonicalBinary(at: url) else {
                continue
            }
            let resolvedComponents = resolved.resolvingSymlinksInPath()
                .standardizedFileURL.pathComponents
            guard isDescendant(resolvedComponents, of: payloadComponents) else {
                return .failure(.failed(
                    .binaryNotFound,
                    "Archive points its executable outside the install directory",
                    code: .executableOutsideInstall
                ))
            }
            return .success(resolved)
        }
        return .failure(.failed(
            .binaryNotFound, "No SteamCMD executable in the unpacked archive",
            code: .noExecutableInArchive
        ))
    }

    /// `codesign --verify` alone isn't enough: it answers "is this signature
    /// intact", not "is this Valve's binary" — both halves are required.
    /// Deliberately not `spctl`: for a bare CLI Mach-O it reports `rejected
    /// (the code is valid but does not seem to be an app)`, a refusal to
    /// assess, not a verdict, so gating on its exit status rejects every
    /// good binary.
    static func verifySignature(
        binaryPath: String,
        spawn: (String, [String], TimeInterval) -> (output: String, exitCode: Int32, timedOut: Bool)
    ) -> Result<Void, SteamCMDManagedInstallResult> {
        let verify = spawn("/usr/bin/codesign", ["--verify", "--strict", binaryPath], 30)
        guard SteamCMDCodeSignatureParser.signatureValid(
            verifyExitCode: verify.exitCode, timedOut: verify.timedOut
        ) else {
            return .failure(.failed(
                .signatureRejected, "Code signature is not valid", code: .codeSignatureInvalid
            ))
        }

        let describe = spawn("/usr/bin/codesign", ["-dv", "--verbose=4", binaryPath], 30)
        let team = SteamCMDCodeSignatureParser.teamIdentifier(in: describe.output)
        guard team == SteamCMDBootstrapPackage.expectedTeamIdentifier else {
            return .failure(.failed(
                .signatureRejected,
                "Signed by team \(team ?? "unknown"), expected \(SteamCMDBootstrapPackage.expectedTeamIdentifier)",
                code: .signedByUnexpectedTeam,
                arguments: [team ?? "unknown", SteamCMDBootstrapPackage.expectedTeamIdentifier]
            ))
        }
        return .success(())
    }

    /// A quarantine stamp on the unpacked binary means it was produced by a
    /// sandboxed process after all, and `Process.run()` would fail EPERM at
    /// first use. Reported as an extraction problem, not a signature one — the
    /// signature is fine, the file just cannot be executed.
    static func rejectIfQuarantined(binaryPath: String) -> Result<Void, SteamCMDManagedInstallResult> {
        let quarantined = (try? URL(fileURLWithPath: binaryPath)
            .resourceValues(forKeys: [.quarantinePropertiesKey]).quarantineProperties) ?? nil
        guard quarantined == nil else {
            return .failure(.failed(
                .extractionFailed,
                "Unpacked binary is quarantined and could not be executed",
                code: .unpackedBinaryQuarantined
            ))
        }
        return .success(())
    }
}
