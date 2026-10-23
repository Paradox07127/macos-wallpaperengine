import Foundation

/// Wire contract between Loomscreen and its Steam connector.
///
/// The unsandboxed connector owns persistent, isolated SteamCMD profiles and
/// publishes downloaded content to the user's authorized Steam library.
/// Steam client credentials are never copied into those profiles.
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
    /// prunes it to `assets/`. `libraryPath` is the library the user authorized
    /// in the app; the connector validates it before writing there. Replies
    /// with a JSON `SteamEngineAssetsResult`.
    func installWallpaperEngineAssets(
        accountName: String,
        libraryPath: String,
        operationID: String,
        with reply: @escaping @Sendable (Data) -> Void
    )

    /// Latest public-branch buildid for app 431960, for update checks.
    /// Replies with a JSON `SteamEngineBuildLookup`.
    func latestWallpaperEngineBuildID(
        operationID: String,
        with reply: @escaping @Sendable (Data) -> Void
    )

    /// Deletes one Workshop item's folder from the shared repository. This is a
    /// real delete of the user's Steam content — the app deliberately has no way
    /// to do it itself. `libraryPath` is the library the user authorized in the
    /// app; the connector validates it before deleting anything under it.
    /// Replies with a JSON `SteamDeleteResult`.
    func deleteWorkshopItem(
        workshopID: String,
        libraryPath: String,
        with reply: @escaping @Sendable (Data) -> Void
    )

    /// Downloads one Workshop item into the shared repository. Replies with a
    /// JSON `SteamWorkshopDownloadResult` carrying the folder the app should
    /// import from. `libraryPath` is the library the user authorized in the app;
    /// the connector validates it before writing there. `operationID` is the
    /// app-minted identity a later `cancelActiveSteamCMD` must name to reach
    /// this run's child.
    func downloadWorkshopItem(
        workshopID: String,
        accountName: String,
        libraryPath: String,
        operationID: String,
        with reply: @escaping @Sendable (Data) -> Void
    )

    /// Refreshes and reads the subscription list SteamCMD keeps in the account
    /// profile via `workshop_status` in a throwaway install dir deleted before
    /// replying; nothing reaches the shared library. Replies with a JSON `SteamSubscribedItemsResult`.
    func listSubscribedWorkshopItems(
        accountName: String,
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

    /// Deletes only Loomscreen's own private SteamCMD profile for this account,
    /// so the next download signs in again. The user's Steam client profile is
    /// never read, written or removed. Replies with a JSON
    /// `SteamAccountSessionRemovalResult`.
    func removeAccountSession(accountName: String, with reply: @escaping @Sendable (Data) -> Void)

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

    /// The app is quitting: SIGTERMs whatever SteamCMD child is running, no
    /// operation id required — there is no retry to protect after a quit, and
    /// the service name is this app's alone. Reply is a JSON `Bool` for
    /// whether anything was signalled.
    func terminateActiveSteamCMDForHostExit(with reply: @escaping @Sendable (Data) -> Void)
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

struct SteamAccountSessionRemovalResult: Codable, Equatable, Sendable {
    enum Outcome: String, Codable, Sendable {
        case removed
        /// Nothing was stored — a verdict, not a failure.
        case notFound
        case refused
    }

    let outcome: Outcome
    let failureReason: String?
}

/// `Error` so install steps can short-circuit through `Result`; the value is
/// still the wire payload, not a thrown-away diagnostic. The outcome of
/// asking Steam for Wallpaper Engine's current build id — was a bare
/// `String?`, and several unrelated situations produced that nil (a request
/// expired in the queue, no runnable SteamCMD, output with no `"public"`
/// block), all rendered as "SteamCMD did not return the latest build".
struct SteamEngineBuildLookup: Codable, Equatable, Sendable {
    enum Outcome: String, Codable, Sendable {
        case found
        case timedOut
        /// No SteamCMD to run, or the request expired waiting for the queue.
        case steamCMDUnavailable
        /// SteamCMD ran and said nothing we recognise.
        case unrecognized
        /// SteamCMD ran and could not reach Steam's servers. Was folded into
        /// `unrecognized`, whose copy asserts Steam answered.
        case steamUnreachable
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
        /// `ERROR! Download item … failed (No Connection).` — SteamCMD prints
        /// it both when the servers never answered and when the account does
        /// not own Wallpaper Engine, so the app cannot tell the two apart.
        case steamUnreachable
        case removedFromSteam
        case timedOut
        case steamCMDUnavailable
        case unrecognized
    }

    /// Why SteamCMD's reported completion was not accepted; the app words it for the user.
    enum FailureDetail: String, Codable, Sendable {
        case leftInPrivateProfile
        case invalidCommittedItem
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
    /// Actual final-child status; absent in replies from older connectors or when no child ran.
    var exitCode: Int32?
    /// Set only when Foundation reports `.uncaughtSignal`, never inferred from an exit status.
    var terminationSignal: Int32?
    var failureDetail: FailureDetail?
}

struct SteamSubscribedItemsResult: Codable, Equatable, Sendable {
    enum Outcome: String, Codable, Sendable {
        case listed
        case loginRequired
        case steamUnreachable
        case steamCMDUnavailable
        case timedOut
        case unrecognized
    }

    let outcome: Outcome
    /// Workshop ids the account is subscribed to, in subscriptions-file order.
    let workshopIDs: [String]
    let diagnosticTail: String
    /// Execution receipt: the canonical binary this operation actually spawned.
    var executedBinaryPath: String?
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
        case restarting
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

struct SteamCachedLoginResult: Codable, Equatable, Sendable {
    let outcome: SteamCachedLoginOutcome
    /// Who Steam says the session belongs to, so the caller can catch the case
    /// where the cached session is for a different account than the one picked.
    let steamID64: String?
    /// Bounded tail of SteamCMD's output, for the diagnostics export only.
    let diagnosticTail: String
    /// Execution receipt — see `SteamWorkshopDownloadResult.executedBinaryPath`.
    var executedBinaryPath: String? = nil
    /// The parenthesised reason from Steam's `FAILED (…)` / `ERROR (…)` login
    /// line, for `.noConnection` and `.loginFailed`. Optional so a payload
    /// from a connector without the key still decodes.
    var failureReason: String?
    var exitCode: Int32?
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
        /// Steam's servers never answered (`ERROR (No Connection)`).
        case noConnection
        /// steamcmd was still waiting when the budget ran out.
        case timedOut
        /// steamcmd gave up for a reason we do not classify further.
        case failed
        case unavailable
    }
    let outcome: Outcome
    let steamID64: String?
    /// Steam's parenthesised reason, for refusals this code does not classify
    /// further. Optional so a payload from an older connector still decodes.
    var failureReason: String?

    static func failed(_ outcome: Outcome, reason: String? = nil) -> SteamCMDLoginResult {
        SteamCMDLoginResult(outcome: outcome, steamID64: nil, failureReason: reason)
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
    var rejectedExistingPaths: [String] {
        rejectedExisting ?? []
    }

    init(
        source: SteamCMDBinarySource,
        canonicalPath: String?,
        resolutionFailure: String?,
        sha256: String?,
        signature: SteamCMDSignatureVerdict?,
        isQuarantined: Bool,
        launch: SteamCMDLaunchProbe?,
        unavailableReason: String?,
        rejectedExisting: [String]? = nil
    ) {
        self.source = source
        self.canonicalPath = canonicalPath
        self.resolutionFailure = resolutionFailure
        self.sha256 = sha256
        self.signature = signature
        self.isQuarantined = isQuarantined
        self.launch = launch
        self.unavailableReason = unavailableReason
        self.rejectedExisting = rejectedExisting
    }

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

    /// A definitive local failure can be recovered through the managed installer.
    /// A busy connector or a timeout needs a retry, not another installation.
    var needsInAppSetup: Bool {
        guard unavailableReason == nil, canonicalPath != nil, !isUsable else { return false }
        if signature?.isValveSigned != true || isQuarantined {
            return true
        }
        return launch?.outcome == .couldNotSpawn || launch?.outcome == .exitedNonZero
    }

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
