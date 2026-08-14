import CryptoKit
import Foundation

/// Wire contract between Loomscreen and its Steam connector.
///
/// The connector exists for one structural reason: SteamCMD must run with the
/// user's REAL `$HOME` so its STEAMROOT is the shared `~/Library/Application
/// Support/Steam` profile. A process the sandboxed app spawns itself inherits
/// the sandbox and gets the container as `$HOME`, and SteamCMD is a third-party
/// binary that cannot resolve a security-scoped bookmark. An XPC service is
/// launched by launchd rather than forked by the app, so it starts with a fresh
/// sandbox — and with no `com.apple.security.app-sandbox` entitlement it starts
/// with none at all. `SteamConnectorEnvironmentTests` is the standing proof.
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
        with reply: @escaping @Sendable (Data) -> Void
    )

    /// Latest public-branch buildid for app 431960, for update checks.
    /// Replies with a JSON `String?`.
    func latestWallpaperEngineBuildID(
        accountName: String,
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
    /// import from.
    func downloadWorkshopItem(
        workshopID: String,
        accountName: String,
        with reply: @escaping @Sendable (Data) -> Void
    )

    /// Hashes and code-signature-checks the SteamCMD binary. The app never opens
    /// the file itself, which is what lets the main bundle drop its
    /// package-manager read exception. Replies with a JSON
    /// `SteamCMDBinaryInspection`.
    func inspectSteamCMDBinary(path: String, with reply: @escaping @Sendable (Data) -> Void)

    /// Remembers a SteamCMD location the user pointed at, after clearing the
    /// same trust gates every other candidate clears.
    ///
    /// This is the one entry point on this surface through which the app names
    /// something that later gets executed, and it exists because auto-detection
    /// cannot cover an install in a location we have never heard of. Read
    /// `SteamCMDManualBinding` before changing it: what makes this bounded is
    /// that the path is re-gated on every run, not that it was checked here.
    /// Replies with a JSON `SteamCMDManualBindResult`.
    func bindManualSteamCMDBinary(path: String, with reply: @escaping @Sendable (Data) -> Void)

    /// Forgets the manual binding, returning resolution to auto-detection.
    /// Replies with a JSON `SteamCMDManualBindResult`.
    func clearManualSteamCMDBinary(with reply: @escaping @Sendable (Data) -> Void)

    /// Runs one Doctor probe. Takes a JSON `SteamCMDProbeRequest` rather than
    /// loose arguments so the array never crosses as an NSSecureCoding
    /// collection. Replies with a JSON `SteamCMDProbeRun`.
    func runSteamCMDProbe(_ request: Data, with reply: @escaping @Sendable (Data) -> Void)

    /// Decides whether SteamCMD works on this Mac: resolution, code signature,
    /// quarantine, and a real `steamcmd +quit` run. Takes a JSON
    /// `SteamCMDDiagnosisRequest`, replies with a JSON `SteamCMDDiagnosis`.
    ///
    /// The whole judgement lives here because only this process can spawn the
    /// binary. The app's own readiness check inferred health from marker files
    /// and path existence, and reported green while SteamCMD could not launch at
    /// all; a caller that cannot run the thing cannot know that it runs.
    func diagnoseSteamCMD(_ request: Data, with reply: @escaping @Sendable (Data) -> Void)

    /// Resolves the first derived candidate — managed install, then the three
    /// package-manager locations — to the canonical Mach-O we are willing to
    /// execute. Replies with a JSON `SteamCMDBinaryLocation`.
    ///
    /// Takes no path: see `SteamCMDDiagnosisPlan`. Lives here because
    /// resolution reads the file (Mach-O magic, wrapper script) and
    /// `/opt/homebrew` is outside the app's sandbox.
    func locateSteamCMDBinary(with reply: @escaping @Sendable (Data) -> Void)

    /// Unpacks a SteamCMD bootstrap tarball the app downloaded and verified into
    /// a managed install the connector is willing to execute.
    ///
    /// Installs SteamCMD from Valve's own update manifest (`SteamCMDManifest`).
    ///
    /// Takes nothing: the manifest URL, every download, the install root and
    /// every verification live on this side of the boundary, so there is no
    /// input a compromised app could shape. Downloading here rather than in the
    /// app also sidesteps quarantine entirely — files a sandboxed process
    /// writes are stamped `com.apple.quarantine`, and a quarantined bare CLI
    /// Mach-O cannot be spawned at all (`Process.run()` fails EPERM; a
    /// Developer ID signature does not exempt it, measured 2026-08-13).
    /// Replies with a JSON `SteamCMDManagedInstallResult`.
    func installManagedSteamCMD(with reply: @escaping @Sendable (Data) -> Void)

    /// Deletes the managed SteamCMD install. Takes no path: the connector owns
    /// the one location this may touch, and the install lives outside the app
    /// container precisely so the app cannot reach it — including to delete it.
    /// Replies with a JSON `SteamCMDManagedRemovalResult`.
    func removeManagedSteamCMD(with reply: @escaping @Sendable (Data) -> Void)

    /// Interactive `steamcmd +login` on a PTY, so the user can sign in without
    /// ever opening Terminal. Takes a JSON `SteamCMDLoginRequest`; replies with
    /// a JSON `SteamCMDLoginResult`.
    ///
    /// The password crosses this boundary once, goes to steamcmd's own prompt
    /// over the PTY, and is persisted by nothing on either side — what remains
    /// afterwards is steamcmd's own cached session in the shared Steam profile,
    /// identical to a login typed in Terminal. It never enters argv (argv is
    /// visible to every process via `ps`), never a log, and never the reply.
    /// The call stays in flight through Steam Guard's mobile confirmation, so
    /// the app can show "waiting for approval" until the user acts on their
    /// phone.
    func signInSteamAccount(_ request: Data, with reply: @escaping @Sendable (Data) -> Void)
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
/// self-update reads. Installing from it directly is what removed the Rosetta
/// requirement: the historical `steamcmd_osx.tar.gz` bootstrapper is a frozen
/// 2020 Intel-only build, while the manifest's packages carry the current
/// universal binary (verified 2026-08-13: lipo x86_64+arm64, Valve team ID).
///
/// The manifest cannot be digest-pinned — it moves with every release — so the
/// trust chain is: TLS to Valve, per-package sha256 from the manifest, and the
/// same code-signature gate as always before anything is executed. The
/// signature check is the authority on what runs; the manifest hashes only
/// establish that what was unpacked is what Valve published.
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
/// still the wire payload, not a thrown-away diagnostic.
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
    let failureReason: String?

    static func failed(_ outcome: Outcome, _ reason: String) -> SteamCMDManagedInstallResult {
        SteamCMDManagedInstallResult(
            outcome: outcome, canonicalPath: nil, sha256: nil, failureReason: reason
        )
    }
}

/// A fresh SteamCMD bootstrap can replace itself and exit before it ever prints
/// its normal banner. That is an intermediate state, not a failed install. The
/// replacement must still pass the signature/quarantine gates before one retry.
enum SteamCMDSelfUpdateRetryPolicy {
    static let markers = [
        "Checking for available updates",
        "Downloading update",
        "Verifying installation"
    ]

    static func shouldRetry(
        output: String,
        exitCode: Int32,
        timedOut: Bool,
        attempt: Int
    ) -> Bool {
        guard attempt == 0, !timedOut, exitCode != 0 else { return false }
        return markers.contains { output.localizedCaseInsensitiveContains($0) }
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
/// the lowercased transcript: these strings come from real steamcmd sessions,
/// and steamcmd has varied casing and prefixes across releases. Anything
/// unmatched falls through to the timeout/exit handling — never to a spawn of
/// something else.
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

/// Reads the `Accounts` block out of Steam's `config.vdf`.
///
/// This is the only account source that works here: `loginusers.vdf` — the
/// file that carries `MostRecent` — is written by the Steam GUI client, which
/// cannot be installed on the macOS machines this app targets. A steamcmd-only
/// profile records accounts solely under `InstallConfigStore … Accounts`.
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

/// Everything the app needs to know about a SteamCMD binary.
///
/// Gathered in the connector so the app never opens the file itself — that is
/// what lets the main bundle drop its package-manager read exception. `exists`
/// false means the path resolved to nothing; every other field is then unset.
struct SteamCMDBinaryInspection: Codable, Equatable, Sendable {
    let exists: Bool
    /// Hex SHA-256, or nil when the file could not be read.
    let sha256: String?
    let signatureValid: Bool
    let teamIdentifier: String?
    let isHardenedRuntime: Bool
    let isQuarantined: Bool
    /// Set when the connector produced no verdict at all — it gave up waiting
    /// behind another SteamCMD operation.
    ///
    /// Distinct from `exists == false`, which is a real answer about the file.
    /// Conflating the two made a busy connector look like a deleted binary, and
    /// cost the caller its cached trust for no reason.
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

/// The connector's argv gate for Doctor probes.
///
/// Probes are read-only diagnostics, so only the exact directive shapes the
/// Doctor sends are executable: `+quit` and `+login anonymous`. Everything
/// else — `+force_install_dir`, `+runscript`, a real account name, any bare
/// word — is refused at the connector, the side of the trust boundary a
/// compromised app process cannot edit. Lives in the shared contract so the
/// app's tests exercise the exact rule the connector enforces.
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

    static func refused(_ reason: String) -> SteamCMDProbeRun {
        SteamCMDProbeRun(output: "", exitCode: -1, timedOut: false, refusalReason: reason)
    }
}

// MARK: - SteamCMD diagnosis

/// One `diagnoseSteamCMD` request.
///
/// The app contributes only the two paths the connector cannot know — the user's
/// own pick and the managed install inside the real Application Support directory. Which
/// package-manager paths to try, and every verdict, is the connector's.
/// Deliberately carries no path of any kind — only a budget.
///
/// Nothing a sandboxed caller sends may decide what this unsandboxed process
/// executes. Every candidate is derived here (`SteamCMDDiagnosisPlan`), so
/// there is no field to swap a verified binary through.
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

/// A SteamCMD location the user pointed at, remembered on this side of the XPC
/// boundary.
///
/// **This deliberately reopens a hole that was closed on 2026-08-13**, at the
/// user's explicit direction (2026-08-14), because closing it left no recourse
/// for an install we cannot find on our own: `autoDetectCandidates` covers the
/// package managers, and nothing else.
///
/// What is given up: the app names a path once, and a path is not an inode. A
/// file swapped between our checks and `posix_spawn` is executed unchecked, and
/// macOS has no `fexecve` to bind the two.
///
/// What is kept, so the window is a window and not a door:
///
/// - The record lives here, under the connector's own root in the real home. A
///   sandboxed app cannot write it; it can only ask, once, via XPC.
/// - Nothing is trusted at bind time and remembered. The stored path re-enters
///   `resolvedExecutablePath` on **every** run and re-clears the same gates as
///   any other candidate — Valve's signature, no quarantine, and the execution
///   fence. A path that stops passing simply stops being chosen.
/// - It is a candidate, not an override: it goes first, and a failure falls
///   through to the managed install and the package managers.
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

/// What the connector made of a path the user pointed at.
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
    let failureReason: String?

    var isBound: Bool { outcome == .bound }
}

struct SteamCMDDiagnosisCandidate: Equatable, Sendable {
    let path: String
    let source: SteamCMDBinarySource
}

/// Resolution order, and the label each candidate carries into the report.
///
/// Every entry is derived, never supplied: the managed install under this
/// process's own root, then three fixed package-manager paths. That is the
/// whole executable surface, and none of it is writable by a sandboxed app
/// without a grant this app never asks for.
///
/// Pure so the app's tests pin the same order the connector walks.
enum SteamCMDDiagnosisPlan {
    /// `managedInstall` is a parameter rather than a call to
    /// `SteamCMDManagedInstaller.managedBinary()` so tests pin the ordering
    /// without a real install on disk.
    /// `discovered` defaults to a real filesystem walk; tests pass a fixed list
    /// so the ordering they pin does not depend on what the test machine has
    /// installed under `/opt/homebrew`.
    ///
    /// `manual` goes first — the user pointing at a file is a stronger statement
    /// than anything we inferred — but it is only a position in this list. Every
    /// entry clears the same gates in `firstTrusted`, so a manual pick that stops
    /// passing them falls through to the rest rather than breaking downloads.
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

    /// First candidate that survives every gate, skipping the ones that do not.
    ///
    /// Split out from the connector so the rule this encodes — **a rejected
    /// candidate must not end the search** — is testable without planting real
    /// Mach-Os on the machine running the tests. Getting it wrong is how a
    /// stale, unsigned copy shadows a working one: the diagnosis skips it and
    /// binds the good binary, while execution stops at the bad one.
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
    /// `codesign --verify --strict` completed cleanly.
    ///
    /// Deliberately not `spctl`: for a bare CLI Mach-O it answers `rejected (the
    /// code is valid but does not seem to be an app)`, which is a refusal to
    /// assess rather than a verdict, so gating on its exit status rejects every
    /// good binary.
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

    static func notFound(resolutionFailure: String?) -> SteamCMDDiagnosis {
        SteamCMDDiagnosis(
            source: .notFound, canonicalPath: nil, resolutionFailure: resolutionFailure,
            sha256: nil, signature: nil, isQuarantined: false, launch: nil,
            unavailableReason: nil
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
    static func advice(for diagnosis: SteamCMDDiagnosis) -> String? {
        if let reason = diagnosis.unavailableReason {
            return "The Steam connector did not finish the check (\(reason)). Run it again."
        }
        guard let path = diagnosis.canonicalPath else {
            let detail = diagnosis.resolutionFailure.map { " (\($0))" } ?? ""
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

/// Bounded retention for a child process's output.
///
/// A ring buffer, not an ever-growing `Data`: SteamCMD can emit hundreds of
/// megabytes on a bad day, and the connector is unsandboxed, so "accumulate
/// everything and take the last 500 characters" is the wrong place to be
/// generous with memory. Ported here from the retired in-app process runner
/// when the spawn moved into the connector.
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

/// Facts worth keeping even after the tail has evicted them.
///
/// The diagnostic tail is small on purpose, which means a long run can push the
/// version banner, the "Success. Downloaded item" line, or the public `buildid`
/// out of it — and those are exactly the lines callers parse. This holds a fixed
/// number of independent slots so verbose output cannot starve them.
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

/// Where this process refuses to execute from, whatever the file's signature or
/// digest says.
///
/// Every pre-spawn check here — `codesign --verify`, the quarantine read, the
/// re-hash — opens the path, decides, and closes it; the spawn opens it again.
/// macOS has no `fexecve`, so nothing binds those two opens to one inode, and a
/// caller that can write the path can swap the bytes in between. steamcmd also
/// has to run from inside its own directory tree, so executing a verified copy
/// somewhere else is not available either.
///
/// What is left is to keep the executable out of the caller's own writable
/// storage, which is where a compromised sandboxed app can actually stage a
/// replacement. A real SteamCMD never lives in one of these.
/// A sandboxed caller's own storage, including the temporary directory it is
/// handed — the sandbox redirects that into the container too, so these two
/// cover everything the app can write without the user granting a path.
///
/// Substrings rather than prefixes: the home directory in front of them varies,
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

/// The scrubbed environment handed to the SteamCMD child process.
///
/// Mirrors the main app's `SteamCMDProcessRunner.sanitizedChildEnvironment()`.
/// A bare `Process()` inherits the connector's whole environment, and an
/// unsandboxed helper is the worse place to hand a child `DYLD_*`, not the safer
/// one. Lives here rather than in the service body so the rules are testable.
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

    /// A Workshop id must be exactly digits: it becomes a path component, and
    /// anything else could climb out of the content root.
    static func isSafeWorkshopID(_ id: String) -> Bool {
        !id.isEmpty && id.count <= 20 && id.allSatisfy(\.isNumber)
    }

    /// True only for paths at or under one of the two writable subtrees, with
    /// **no symlink anywhere between the Steam root and the target**.
    ///
    /// Resolving both sides before comparing was not containment: replacing
    /// `steamapps/workshop/content/431960` with a link to `~/Documents` made the
    /// target and its own anchor resolve consistently, so an arbitrary directory
    /// looked "inside" the allowed subtree. The path is therefore walked one
    /// component at a time with `lstat`, which does not follow links.
    ///
    /// `steamRoot` is injectable so the walk can be exercised against a scratch
    /// tree — the user's real library must never be mutated by a test.
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
    /// `"buildid"  "23967692"` inside the public branch block.
    /// Reads the buildid from inside the `public` block only.
    ///
    /// Scanning the whole remainder after `"public"` meant a public block with
    /// no readable buildid silently fell through to the next branch — reporting
    /// a beta build as the public one, which drives a wrong update verdict.
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

    /// Where the package managers put SteamCMD, in the order we try them.
    ///
    /// `which steamcmd` is not an option: an XPC service is started by launchd
    /// without ever sourcing the user's shell profile, so `/opt/homebrew/bin` is
    /// not on its `PATH` and `which` finds nothing for the case that matters
    /// most. These are `stat`s at derived paths instead.
    ///
    /// Three layers, because Homebrew has had three answers to "where does a
    /// cask's CLI live" and a machine can be in any of them:
    ///
    /// 1. `<prefix>/bin/steamcmd` — the `binary` stanza's symlink. Was the only
    ///    thing searched until 2026-08-14.
    /// 2. `<prefix>/.homebrew-command-wrappers/steamcmd` — the Command Wrapper
    ///    stanza, which upstream's cask moved to. It writes no `bin` symlink at
    ///    all, so layer 1 alone reports "not installed" for a current
    ///    `brew install --cask steamcmd`.
    /// 3. `<prefix>/Caskroom/steamcmd/<version>/MacOS/steamcmd` — the real
    ///    Mach-O. Reached directly because both links above are absent on a
    ///    machine where the cask was ever `brew unlink`ed (the symlink is
    ///    renamed to `steamcmd.off`, which we deliberately do not honour: `.off`
    ///    means the user disabled that entry point).
    ///
    /// Measured 2026-08-14 on a Mac with `steamcmd` installed by Homebrew: all
    /// three of the old fixed paths were missing and the binary was only
    /// reachable through layer 3.
    ///
    /// Not searched: `~/steamcmd`, `~/Steam`. Those read the sandbox container
    /// until 2026-08-02 and so never matched anything.
    ///
    /// Nor the managed install: that root is derived by
    /// `SteamCMDManagedInstaller.managedBinary()` and spliced in by
    /// `SteamCMDDiagnosisPlan`.
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

        init(
            homebrewPrefixes: [String] = ["/opt/homebrew", "/usr/local"],
            macPortsPrefix: String = "/opt/local"
        ) {
            self.homebrewPrefixes = homebrewPrefixes
            self.macPortsPrefix = macPortsPrefix
        }
    }

    /// Every installed cask version's Mach-O, newest first.
    ///
    /// All of them rather than just the newest: Homebrew leaves older version
    /// directories behind after an upgrade, and if the newest one fails a trust
    /// gate the walk in `SteamCMDDiagnosisPlan.firstTrusted` should get to try
    /// the one that passes.
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
            .map { $0.appendingPathComponent("MacOS/steamcmd", isDirectory: false) }
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

/// Unpacks and validates a managed SteamCMD install.
///
/// Runs only in the connector, which is unsandboxed. Every step therefore
/// assumes the app-supplied inputs are hostile: the app is the one process that
/// can write into the container these paths point at, so "the app already
/// checked it" is not a property this code may rely on.
enum SteamCMDManagedInstaller {
    /// The one directory a managed install may occupy. Derived here rather than
    /// accepted from the caller: an unsandboxed service that unpacks wherever it
    /// is told is an arbitrary-write primitive, and the caller has no
    /// information about the destination that this process lacks.
    ///
    /// Deliberately *not* the app's container. That directory is writable by the
    /// sandboxed app, so every check here would be check-then-use: the app can
    /// replace the leaf with a symlink after the lstat walk passes and before
    /// `removeItem`/`tar -C` runs, and this process would recursively delete and
    /// rewrite whatever it points at. A path the app cannot write is the only
    /// version of that window that is actually closed.
    static func canonicalInstallRoot(
        home: URL = URL(fileURLWithPath: NSHomeDirectory())
    ) -> URL {
        home
            .appendingPathComponent("Library/Application Support", isDirectory: true)
            .appendingPathComponent("Loomscreen", isDirectory: true)
            .appendingPathComponent("SteamCMD", isDirectory: true)
            .standardizedFileURL
    }

    /// Accepts the caller's install root only if it is byte-for-byte the one
    /// directory we would have chosen, and only if no component of the path is
    /// a symlink.
    ///
    /// Both halves matter. Without the equality check, an unsandboxed service
    /// unpacks wherever the caller points it. Without the symlink walk, a link
    /// planted at `…/Loomscreen/SteamCMD` sends the recursive delete and rewrite
    /// somewhere else: `standardizedFileURL` resolves `..` but never follows
    /// links.
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
                "Install root is not the managed SteamCMD directory"
            ))
        }
        if let offending = firstSymlinkComponent(of: expected) {
            return .failure(.failed(
                .extractionFailed,
                "Install path component is a symbolic link: \(offending)"
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

    /// Replaces any previous payload so a half-finished install cannot be
    /// mistaken for a good one, then unpacks into `MacOS/`.
    ///
    /// Takes a list because the manifest ships one zip per package; they all
    /// unpack into the same staging tree, exactly as SteamCMD's own updater
    /// arranges them. bsdtar detects the container format, so tarball and zip
    /// callers share this path.
    static func extract(
        archives: [URL],
        installRoot: URL,
        spawn: (String, [String], TimeInterval) -> (output: String, exitCode: Int32, timedOut: Bool)
    ) -> Result<ExtractedInstall, SteamCMDManagedInstallResult> {
        let payload = payloadDirectory(installRoot: installRoot)

        // Unpack into a directory this call just created under an unpredictable
        // name, then move it into place. Extracting straight into the payload
        // path meant the path could be a symlink planted between the check and
        // the write; a name nobody can predict cannot be pre-planted, and
        // `mkdir` without `withIntermediateDirectories` fails rather than
        // adopting anything already sitting there.
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
                "Could not create the install directory: \(error.localizedDescription)"
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
                return .failure(.failed(.extractionFailed, "Unpacking timed out"))
            }
            guard run.exitCode == 0 else {
                discardStaging()
                return .failure(.failed(
                    .extractionFailed,
                    "tar exited \(run.exitCode): \(run.output.prefix(200))"
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
                "Archive contains a symbolic link escaping the install directory: \(escaping)"
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
                    "Could not retire the previous install: \(error.localizedDescription)"
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
                "Could not move the unpacked install into place: \(error.localizedDescription)"
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
    /// that resolves outside it.
    ///
    /// The shared resolver honours `STEAMEXE=` from the wrapper script and
    /// resolves symlinks, both of which can name an absolute path elsewhere on
    /// disk. Without this check a swapped archive could aim the signature check
    /// and the spawn at some other Valve-signed binary.
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
                    "Archive points its executable outside the install directory"
                ))
            }
            return .success(resolved)
        }
        return .failure(.failed(.binaryNotFound, "No SteamCMD executable in the unpacked archive"))
    }

    /// `codesign --verify` alone is not enough: it answers "is this signature
    /// intact", not "is this Valve's binary". Both halves are required.
    ///
    /// Deliberately not `spctl`: for a bare CLI Mach-O it reports
    /// `rejected (the code is valid but does not seem to be an app)` — a refusal
    /// to assess, not a verdict — so gating on its exit status rejects every
    /// good binary.
    static func verifySignature(
        binaryPath: String,
        spawn: (String, [String], TimeInterval) -> (output: String, exitCode: Int32, timedOut: Bool)
    ) -> Result<Void, SteamCMDManagedInstallResult> {
        let verify = spawn("/usr/bin/codesign", ["--verify", "--strict", binaryPath], 30)
        guard SteamCMDCodeSignatureParser.signatureValid(
            verifyExitCode: verify.exitCode, timedOut: verify.timedOut
        ) else {
            return .failure(.failed(.signatureRejected, "Code signature is not valid"))
        }

        let describe = spawn("/usr/bin/codesign", ["-dv", "--verbose=4", binaryPath], 30)
        let team = SteamCMDCodeSignatureParser.teamIdentifier(in: describe.output)
        guard team == SteamCMDBootstrapPackage.expectedTeamIdentifier else {
            return .failure(.failed(
                .signatureRejected,
                "Signed by team \(team ?? "unknown"), expected \(SteamCMDBootstrapPackage.expectedTeamIdentifier)"
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
                "Unpacked binary is quarantined and could not be executed"
            ))
        }
        return .success(())
    }
}
