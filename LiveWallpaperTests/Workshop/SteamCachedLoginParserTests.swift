import Foundation
import Testing
@testable import LiveWallpaper

@Suite("Steam cached-login parser")
struct SteamCachedLoginParserTests {

    /// Verbatim `steamcmd +@NoPromptForPassword 1 +login <acct> +quit` output
    /// with no cached session.
    private static let noCachedSessionOutput = """
    Steam Console Client (c) Valve Corporation - version 1785186678
    -- type 'quit' to exit --
    Loading Steam API...OK
    "@NoPromptForPassword" = "1"
    Cached credentials not found.
    FAILED (No cached credentials and @NoPromptForPassword is set)
    Unloading Steam API...OK
    """

    private static let sessionValidOutput = """
    Steam Console Client (c) Valve Corporation - version 1785186678
    Loading Steam API...OK
    Logging in using cached credentials.
    Logging in user 'alice_01' [U:1:1267132100] to Steam Public...OK
    Waiting for client config...OK
    Waiting for user info...OK
    """

    @Test("A cached session reports valid and resolves who it belongs to")
    func recognisesValidSession() {
        let result = SteamCachedLoginParser.parse(stdout: Self.sessionValidOutput)
        #expect(result.outcome == .sessionValid)
        #expect(result.steamID64 == "76561199227397828")
    }

    @Test("Never having signed in is distinguished from an expired session")
    func distinguishesNeverSignedInFromExpired() {
        #expect(SteamCachedLoginParser.parse(stdout: Self.noCachedSessionOutput).outcome == .noCachedSession)

        // Same refusal line, but Steam did have credentials to invalidate.
        let expired = """
        Loading Steam API...OK
        "@NoPromptForPassword" = "1"
        \(SteamCachedLoginParser.noPromptFailureLine)
        Unloading Steam API...OK
        """
        #expect(SteamCachedLoginParser.parse(stdout: expired).outcome == .sessionExpired)
    }

    @Test("A failed login never reports an account")
    func failedLoginCarriesNoAccount() {
        #expect(SteamCachedLoginParser.parse(stdout: Self.noCachedSessionOutput).steamID64 == nil)
    }

    @Test("Unfamiliar output is reported as unrecognized, not assumed good")
    func unfamiliarOutputIsNotAssumedGood() {
        #expect(SteamCachedLoginParser.parse(stdout: "").outcome == .unrecognized)
        #expect(SteamCachedLoginParser.parse(stdout: "Steam is down for maintenance").outcome == .unrecognized)
        // "cached credentials" alone is not enough — the OK line must be there.
        #expect(SteamCachedLoginParser.parse(stdout: "Logging in using cached credentials.").outcome == .unrecognized)
    }

    /// SteamID3 → SteamID64 is `accountID + 76561197960265728`.
    @Test("SteamID3 in the login line converts to the SteamID64 config.vdf records")
    func convertsSteamID3ToSteamID64() {
        #expect(SteamCachedLoginParser.steamID64(inLoginLine: Self.sessionValidOutput) == "76561199227397828")
        #expect(SteamCachedLoginParser.steamID64(inLoginLine: "no login line here") == nil)
        #expect(
            SteamCachedLoginParser.steamID64(
                inLoginLine: "Logging in user 'x' [U:1:0] to Steam Public...OK"
            ) == "76561197960265728"
        )
    }

    @Test("The diagnostic tail is bounded so exports cannot balloon")
    func diagnosticTailIsBounded() {
        let noisy = String(repeating: "x", count: 5000)
        #expect(SteamCachedLoginParser.parse(stdout: noisy).diagnosticTail.count == 500)
    }

    private static let noConnectionOutput = """
    Loading Steam API...OK
    Cached credentials not found.
    password:
    Proceeding with login using username/password.
    Logging in user 'probe_user_zz' [U:1:0] to Steam Public...Retrying...
    CreateBoundSocket: ::bind to port 0 returned error [no name available](1)
    Retrying...
    ERROR (No Connection)
    Unloading Steam API...OK
    """

    @Test("An unreachable Steam is its own verdict, not unrecognized output")
    func recognisesNoConnection() {
        let result = SteamCachedLoginParser.parse(stdout: Self.noConnectionOutput)
        #expect(result.outcome == .noConnection)
        #expect(result.failureReason == "No Connection")
        let cached = """
        Logging in using cached credentials.
        Logging in user 'alice_01' [U:1:1267132100] to Steam Public...Retrying... Retrying... ERROR (No Connection)
        """
        #expect(SteamCachedLoginParser.parse(stdout: cached).outcome == .noConnection)
        #expect(SteamCachedLoginParser.parse(stdout: cached).steamID64 == nil)
    }

    @Test("Any other Steam refusal keeps its reason instead of the raw tail")
    func keepsRefusalReason() {
        let denied = "Logging in user 'x' [U:1:0] to Steam Public...FAILED (Account Logon Denied)"
        let result = SteamCachedLoginParser.parse(stdout: denied)
        #expect(result.outcome == .loginFailed)
        #expect(result.failureReason == "Account Logon Denied")
        let throttled = "Logging in user 'x' [U:1:0] to Steam Public...FAILED (Rate Limit Exceeded)"
        #expect(SteamCachedLoginParser.parse(stdout: throttled).outcome == .rateLimited)
        #expect(SteamCachedLoginParser.parse(stdout: throttled).failureReason == "Rate Limit Exceeded")
        // Control: the no-prompt refusal is still the cached-session verdict,
        // not a generic refusal, even though it is also a `FAILED (…)` line.
        #expect(SteamCachedLoginParser.parse(stdout: Self.noCachedSessionOutput).outcome == .noCachedSession)
    }
}
