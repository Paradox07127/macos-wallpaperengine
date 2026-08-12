import Foundation
import Testing
@testable import LiveWallpaper

/// Maps SteamCMD's cached-login output to a verdict. Pure, so every branch is
/// exercised without spawning SteamCMD or owning a Steam account.
@Suite("Steam cached-login parser")
struct SteamCachedLoginParserTests {

    /// Captured verbatim from `steamcmd +@NoPromptForPassword 1 +login <acct>
    /// +quit` against a HOME with no cached session.
    private static let noCachedSessionOutput = """
    Steam Console Client (c) Valve Corporation - version 1785186678
    -- type 'quit' to exit --
    Loading Steam API...OK
    "@NoPromptForPassword" = "1"
    Cached credentials not found.
    FAILED (No cached credentials and @NoPromptForPassword is set)
    Unloading Steam API...OK
    """

    /// Reconstructed from the matcher that shipped in the retired in-app probe,
    /// with the SteamID3 this Mac's `connection_log.txt` actually recorded. The
    /// success line is printed to stdout only, so it cannot be captured from a
    /// log after the fact.
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

    /// Guessing "signed in" from output nobody has seen before is how the old
    /// Doctor produced confident-but-wrong greens.
    @Test("Unfamiliar output is reported as unrecognized, not assumed good")
    func unfamiliarOutputIsNotAssumedGood() {
        #expect(SteamCachedLoginParser.parse(stdout: "").outcome == .unrecognized)
        #expect(SteamCachedLoginParser.parse(stdout: "Steam is down for maintenance").outcome == .unrecognized)
        // "cached credentials" alone is not enough — the OK line must be there.
        #expect(SteamCachedLoginParser.parse(stdout: "Logging in using cached credentials.").outcome == .unrecognized)
    }

    /// SteamID3 → SteamID64 is `accountID + 76561197960265728`. This pair is
    /// cross-checked: `1267132100` appears in this Mac's connection log and
    /// `76561199227397828` is the SteamID recorded in its `config.vdf`.
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
}
