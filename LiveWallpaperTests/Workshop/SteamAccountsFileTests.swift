import Foundation
import Testing
@testable import LiveWallpaper

/// Steam's `config.vdf` is the only account source available to this app: the
/// GUI client's `loginusers.vdf` (the file with `MostRecent`) is never written
/// on a steamcmd-only Mac. Parsing is pure so it can be exercised without a
/// Steam install or an XPC round trip.
@Suite("Steam accounts file")
struct SteamAccountsFileTests {

    /// Shaped like the real file: `Accounts` is nested several levels deep and
    /// sits next to auth material that must not be mistaken for an account.
    private static let realisticConfig = """
    "InstallConfigStore"
    {
        "Software"
        {
            "Valve"
            {
                "Steam"
                {
                    "Accounts"
                    {
                        "alice_01"
                        {
                            "SteamID"\t\t"76561199227397828"
                        }
                        "bob"
                        {
                            "SteamID"\t\t"76561198000000001"
                        }
                    }
                    "cip"\t\t"deadbeefdeadbeefdeadbeefdeadbeef"
                    "ConnectCache"
                    {
                        "360acbc21"
                        {
                            "MachineAuth"\t\t"eyAidHlwIjogIkpXVCIgfQ.payload"
                        }
                    }
                }
            }
        }
    }
    """

    @Test("Accounts are read in file order with their SteamIDs")
    func parsesAccountsInOrder() {
        let accounts = SteamAccountsFile.parseAccounts(fromConfigVDF: Self.realisticConfig)
        #expect(accounts == [
            SteamAccountSummary(accountName: "alice_01", steamID64: "76561199227397828"),
            SteamAccountSummary(accountName: "bob", steamID64: "76561198000000001")
        ])
    }

    @Test("Sibling auth material is never mistaken for an account")
    func ignoresNeighbouringSecrets() {
        let accounts = SteamAccountsFile.parseAccounts(fromConfigVDF: Self.realisticConfig)
        let names = accounts.map(\.accountName)
        #expect(!names.contains("cip"))
        #expect(!names.contains("ConnectCache"))
        #expect(!names.contains("360acbc21"))
    }

    @Test("A profile with no Accounts block yields nothing rather than guessing")
    func missingAccountsBlockYieldsEmpty() {
        #expect(SteamAccountsFile.parseAccounts(fromConfigVDF: "").isEmpty)
        #expect(SteamAccountsFile.parseAccounts(fromConfigVDF: #""Steam" { "cip" "x" }"#).isEmpty)
    }

    @Test("Entries without a numeric SteamID are skipped")
    func skipsEntriesWithoutUsableSteamID() {
        let text = """
        "Accounts"
        {
            "no_id" { "Rate" "5" }
            "bad_id" { "SteamID" "not-a-number" }
            "good" { "SteamID" "76561198000000002" }
        }
        """
        #expect(SteamAccountsFile.parseAccounts(fromConfigVDF: text).map(\.accountName) == ["good"])
    }

    /// The name is interpolated into a generated SteamCMD script, so a
    /// hand-edited `config.vdf` must not be able to smuggle script syntax
    /// through account discovery.
    @Test("Account names outside SteamCMD's grammar are rejected")
    func rejectsNamesOutsideSteamCMDGrammar() {
        let text = """
        "Accounts"
        {
            "evil name" { "SteamID" "76561198000000003" }
            "quit\\nlogin other" { "SteamID" "76561198000000004" }
            "hyphen-name" { "SteamID" "76561198000000005" }
            "ok_name" { "SteamID" "76561198000000006" }
        }
        """
        #expect(SteamAccountsFile.parseAccounts(fromConfigVDF: text).map(\.accountName) == ["ok_name"])

        #expect(!SteamAccountsFile.isValidAccountName(""))
        #expect(!SteamAccountsFile.isValidAccountName(String(repeating: "a", count: 33)))
        #expect(SteamAccountsFile.isValidAccountName(String(repeating: "a", count: 32)))
        #expect(SteamAccountsFile.isValidAccountName("ok_name"))
    }

    @Test("A duplicated account name collapses to its first entry")
    func duplicateNamesCollapse() {
        let text = """
        "Accounts"
        {
            "dup" { "SteamID" "76561198000000007" }
            "dup" { "SteamID" "76561198000000008" }
        }
        """
        #expect(SteamAccountsFile.parseAccounts(fromConfigVDF: text) == [
            SteamAccountSummary(accountName: "dup", steamID64: "76561198000000007")
        ])
    }

    /// A brace inside a quoted value must not unbalance the block scan, or the
    /// parser would run off the end of `Accounts` and read unrelated keys.
    @Test("Braces inside quoted values do not unbalance the scan")
    func bracesInsideValuesAreInert() {
        let text = """
        "Accounts"
        {
            "first" { "Note" "a { brace }" "SteamID" "76561198000000009" }
            "second" { "SteamID" "76561198000000010" }
        }
        """
        #expect(SteamAccountsFile.parseAccounts(fromConfigVDF: text).map(\.accountName) == ["first", "second"])
    }
}
