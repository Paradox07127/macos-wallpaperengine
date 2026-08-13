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
    /// without ever being able to prompt for a password. `expectedSHA256` is
    /// re-verified before spawning, same gate as every other spawn entry.
    /// Replies with a JSON-encoded `SteamCachedLoginResult`.
    func probeCachedLogin(
        accountName: String,
        steamCMDPath: String,
        expectedSHA256: String,
        with reply: @escaping @Sendable (Data) -> Void
    )

    /// Installs or updates Wallpaper Engine into the shared Steam library and
    /// prunes it to `assets/`. `expectedSHA256` is the digest the app verified;
    /// the connector re-hashes immediately before spawning and refuses on any
    /// difference, same gate as `runSteamCMDProbe`. Replies with a JSON
    /// `SteamEngineAssetsResult`.
    func installWallpaperEngineAssets(
        accountName: String,
        steamCMDPath: String,
        expectedSHA256: String,
        with reply: @escaping @Sendable (Data) -> Void
    )

    /// Latest public-branch buildid for app 431960, for update checks.
    /// `expectedSHA256` is re-verified before spawning. Replies with a JSON
    /// `String?`.
    func latestWallpaperEngineBuildID(
        accountName: String,
        steamCMDPath: String,
        expectedSHA256: String,
        with reply: @escaping @Sendable (Data) -> Void
    )

    /// Deletes one Workshop item's folder from the shared repository. This is a
    /// real delete of the user's Steam content — the app deliberately has no way
    /// to do it itself. Replies with a JSON `SteamDeleteResult`.
    func deleteWorkshopItem(
        workshopID: String,
        with reply: @escaping @Sendable (Data) -> Void
    )

    /// Downloads one Workshop item into the shared repository. `expectedSHA256`
    /// is digest-gated like `installWallpaperEngineAssets`. Replies with a
    /// JSON `SteamWorkshopDownloadResult` carrying the folder the app should
    /// import from.
    func downloadWorkshopItem(
        workshopID: String,
        accountName: String,
        steamCMDPath: String,
        expectedSHA256: String,
        with reply: @escaping @Sendable (Data) -> Void
    )

    /// Hashes and code-signature-checks the SteamCMD binary. The app never opens
    /// the file itself, which is what lets the main bundle drop its
    /// package-manager read exception. Replies with a JSON
    /// `SteamCMDBinaryInspection`.
    func inspectSteamCMDBinary(path: String, with reply: @escaping @Sendable (Data) -> Void)

    /// Runs one Doctor probe. Takes a JSON `SteamCMDProbeRequest` rather than
    /// loose arguments so the array never crosses as an NSSecureCoding
    /// collection. Replies with a JSON `SteamCMDProbeRun`.
    func runSteamCMDProbe(_ request: Data, with reply: @escaping @Sendable (Data) -> Void)

    /// Resolves a path — an auto-detect candidate or the user's own pick — to the
    /// canonical Mach-O we are willing to execute. Pass nil to try the three
    /// package-manager locations. Replies with a JSON `SteamCMDBinaryLocation`.
    ///
    /// Lives here because resolution reads the file (Mach-O magic, wrapper
    /// script) and `/opt/homebrew` is outside the app's sandbox.
    func locateSteamCMDBinary(pickedPath: String?, with reply: @escaping @Sendable (Data) -> Void)
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

/// A Doctor probe run: the app decides *whether* to trust the binary, the
/// connector proves the file has not changed since that decision.
struct SteamCMDProbeRequest: Codable, Equatable, Sendable {
    let path: String
    /// What the app hashed when it granted trust. The connector re-hashes
    /// immediately before spawning and refuses on any difference — that window
    /// is the whole point of carrying the digest across.
    let expectedSHA256: String
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

    /// The pre-spawn gate. Separated from the spawn so the rule can be tested
    /// against a real file that really changes underneath it.
    static func mayExecute(path: String, expectedSHA256: String) -> Bool {
        guard let digest = sha256(ofFileAt: path) else { return false }
        return digest == expectedSHA256
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

    /// The three canonical package-manager symlinks, and nothing else.
    ///
    /// This is what `which steamcmd` would return — except `which` reads `$PATH`,
    /// and an XPC service is started by launchd without ever sourcing the user's
    /// shell profile, so `/opt/homebrew/bin` is not on its `PATH` and `which`
    /// finds nothing for the case that matters most. Three `stat`s at fixed
    /// absolute paths get the same answer without spawning a login shell to
    /// execute the user's rc files.
    ///
    /// Deliberately not searched: `~/steamcmd`, `~/Steam`, the Homebrew Caskroom
    /// version directories. The home guesses read the sandbox container until
    /// 2026-08-02 and so never matched anything; the Caskroom listing only helped
    /// when the `bin` symlink was missing. Anything outside these three is the
    /// user's explicit "Select…" pick — the picker stays the source of truth.
    static func autoDetectCandidates() -> [URL] {
        [
            URL(fileURLWithPath: "/opt/homebrew/bin/steamcmd"),
            URL(fileURLWithPath: "/usr/local/bin/steamcmd"),
            URL(fileURLWithPath: "/opt/local/bin/steamcmd")
        ]
    }

    private static func resolveWrapper(_ wrapperURL: URL) -> Result<URL, SteamCMDBinaryError> {
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

        return .failure(.wrapperParseFailed(reason: "Couldn't find the SteamCMD Mach-O binary near \(wrapperURL.lastPathComponent)."))
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
