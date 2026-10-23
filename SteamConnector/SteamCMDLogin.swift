import Foundation

enum SteamCachedLoginOutcome: String, Codable, Sendable {
    case sessionValid
    case noCachedSession
    case sessionExpired
    /// Steam's servers never answered: the login line ended in
    /// `ERROR (No Connection)`. The remedy is the network, not the session.
    case noConnection
    /// Steam answered and refused; `failureReason` carries its own words.
    case loginFailed
    /// Steam is throttling sign-ins. Waiting is the remedy, so this must not
    /// share `loginFailed`'s "sign in again" instruction.
    case rateLimited
    case timedOut
    case steamCMDUnavailable
    case unrecognized
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
        if let reason = loginFailureReason(in: stdout) {
            let lowered = reason.lowercased()
            let outcome: SteamCachedLoginOutcome = if lowered.contains("no connection") {
                .noConnection
            } else if lowered.contains("rate limit") {
                .rateLimited
            } else {
                .loginFailed
            }
            return SteamCachedLoginResult(
                outcome: outcome, steamID64: nil, diagnosticTail: tail, failureReason: reason
            )
        }
        return SteamCachedLoginResult(outcome: .unrecognized, steamID64: steamID, diagnosticTail: tail)
    }

    /// Steam ends a refused login line with `FAILED (Reason)`, or with
    /// `ERROR (No Connection)` after its own retries when the servers never
    /// answered (captured 2026-09-03 with network access denied). The text in
    /// the parentheses is the only reason it gives.
    static func loginFailureReason(in stdout: String) -> String? {
        guard let match = stdout.firstMatch(of: /(?:FAILED|ERROR) \(([^)\n]+)\)/) else { return nil }
        return String(match.output.1)
    }

    /// `Logging in user 'x' [U:1:1267132100] to Steam Public...OK` carries a
    /// SteamID3 account id; SteamID64 is that plus the individual-account base.
    static func steamID64(inLoginLine stdout: String) -> String? {
        guard let accountID = accountID(inLoginLine: stdout) else { return nil }
        return String(76_561_197_960_265_728 + UInt64(accountID))
    }

    /// The SteamID3 account id, which also names the account's `userdata/<id>` directory.
    static func accountID(inLoginLine stdout: String) -> UInt32? {
        guard let match = stdout.firstMatch(of: /Logging in user '[^']+' \[U:1:(\d+)\] to Steam Public\.\.\.OK/) else {
            return nil
        }
        return UInt32(match.output.1)
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
        /// Steam's servers never answered. Terminal: steamcmd exits right after.
        case noConnection
        /// Steam refused and said why, in words this code does not classify
        /// further (`Account Logon Denied`, `Account Disabled`, …). Terminal.
        case refused(reason: String)
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
        if text.contains("rate limit") {
            return .rateLimited
        }
        if text.contains("no connection") {
            return .noConnection
        }
        if text.contains("invalid login auth code") || text.contains("two-factor code mismatch") {
            return .invalidGuardCode
        }
        if text.contains("invalid password") {
            return .invalidPassword
        }
        // After the named refusals so they keep their own copy — a generic
        // match here would swallow `FAILED (Invalid Password)` — and before the
        // prompts so a refused attempt stops re-answering them.
        if let reason = SteamCachedLoginParser.loginFailureReason(in: transcript) {
            return .refused(reason: reason)
        }
        if text.contains("confirm the login in the steam mobile app")
            || text.contains("waiting for confirmation") {
            return .waitingForMobileConfirmation
        }
        if text.contains("two-factor code:") {
            return .guardCodeTotpPrompt
        }
        if text.contains("steam guard code:") {
            return .guardCodeEmailPrompt
        }
        if text.contains("password:") {
            return .passwordPrompt
        }
        return nil
    }
}

/// Reads public account identities from `config.vdf`. An identity is a picker
/// suggestion, never evidence that SteamCMD has a reusable login session.
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
            guard isValidAccountName(name), !seen.contains(name), let steamID = steamID(in: body) else { continue }
            seen.insert(name)
            summaries.append(SteamAccountSummary(accountName: name, steamID64: steamID))
        }
        return summaries
    }

    // MARK: - Scanning

    private static func accountsBlock(in text: String) -> Substring? {
        var cursor = text.startIndex
        while let range = text.range(of: "\"Accounts\"", range: cursor ..< text.endIndex) {
            cursor = range.upperBound
            var probe = cursor
            if let block = nextBraceBlock(in: text[...], from: &probe) {
                return block
            }
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
    static func nextQuoted(in text: Substring, from cursor: inout Substring.Index) -> String? {
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
    /// Quoted spans and `//` line comments are skipped so a brace inside either can't unbalance it.
    static func nextBraceBlock(in text: Substring, from cursor: inout Substring.Index) -> Substring? {
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
                if character == "\"" {
                    insideQuotes = false
                }
            } else if character == "\"" {
                insideQuotes = true
            } else if character == "/", text[index...].hasPrefix("//") {
                index = text[index...].firstIndex(where: \.isNewline) ?? text.endIndex
                continue
            } else if character == "{" {
                depth += 1
            } else if character == "}" {
                depth -= 1
                if depth == 0 {
                    cursor = text.index(after: index)
                    return text[text.index(after: open) ..< index]
                }
            }
            index = text.index(after: index)
        }
        return nil
    }
}
