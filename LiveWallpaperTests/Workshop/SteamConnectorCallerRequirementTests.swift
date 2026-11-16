import Foundation
@testable import LiveWallpaper
import Security
import Testing

@Suite("SteamConnector caller requirement")
struct SteamConnectorCallerRequirementTests {
    @Test("a Team ID yields an identifier-and-team requirement")
    func teamRequirement() {
        #expect(
            SteamConnectorCallerRequirement.requirement(hostIdentifier: "com.loomscreen.pro", teamIdentifier: "FWJP4B62U7")
                == #"anchor apple generic and identifier "com.loomscreen.pro" and certificate leaf[subject.OU] = "FWJP4B62U7""#
        )
    }

    @Test("no Team ID yields no requirement")
    func noTeam() {
        #expect(SteamConnectorCallerRequirement.requirement(hostIdentifier: "com.loomscreen.pro", teamIdentifier: nil) == nil)
    }

    @Test("characters outside the identifier alphabet are refused", arguments: [
        (#"com.loomscreen.pro" or anchor apple"#, "FWJP4B62U7"),
        ("com.loomscreen.pro", #"FWJP4B62U7" or true or "x"#),
        ("com loomscreen pro", "FWJP4B62U7"),
        ("com.loomscreen.pro", "FWJP4B62U7 "),
        ("com.loomscreen.pro", "FWJP4B62U7\n"),
        ("com.loomscreen.pró", "FWJP4B62U7"),
        ("com.loomscreen.pro", "FWJP4B62U7)"),
    ])
    func refusesUnsafeInput(hostIdentifier: String, teamIdentifier: String) {
        #expect(
            SteamConnectorCallerRequirement.requirement(hostIdentifier: hostIdentifier, teamIdentifier: teamIdentifier) == nil
        )
    }

    @Test("the built requirement parses as code-signing requirement language")
    func parses() throws {
        let text = try #require(
            SteamConnectorCallerRequirement.requirement(hostIdentifier: "com.loomscreen.pro", teamIdentifier: "FWJP4B62U7")
        )
        var requirement: SecRequirement?
        #expect(SecRequirementCreateWithString(text as CFString, [], &requirement) == errSecSuccess)
        #expect(requirement != nil)
    }

    @Test("the test host fails a requirement naming another team, and passes its own when it has one")
    func checksAgainstTestHost() throws {
        var code: SecCode?
        var staticCode: SecStaticCode?
        var information: CFDictionary?
        try #require(SecCodeCopySelf([], &code) == errSecSuccess)
        let selfCode = try #require(code)
        try #require(SecCodeCopyStaticCode(selfCode, [], &staticCode) == errSecSuccess)
        let selfStaticCode = try #require(staticCode)
        try #require(
            SecCodeCopySigningInformation(
                selfStaticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &information
            ) == errSecSuccess
        )
        let signing = try #require(information as? [String: Any])
        let hostIdentifier = try #require(signing[kSecCodeInfoIdentifier as String] as? String)
        let ownTeam = signing[kSecCodeInfoTeamIdentifier as String] as? String

        let check = { (teamIdentifier: String) throws -> OSStatus in
            let text = try #require(
                SteamConnectorCallerRequirement.requirement(hostIdentifier: hostIdentifier, teamIdentifier: teamIdentifier)
            )
            var requirement: SecRequirement?
            try #require(SecRequirementCreateWithString(text as CFString, [], &requirement) == errSecSuccess)
            return SecCodeCheckValidity(selfCode, [], requirement)
        }
        #expect(try check("ZZZZZZZZZZ") == errSecCSReqFailed)
        if let ownTeam {
            #expect(try check(ownTeam) == errSecSuccess)
        }
    }
}
