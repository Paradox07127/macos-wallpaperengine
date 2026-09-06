#if !LITE_BUILD
import Foundation
@testable import LiveWallpaper
import Testing

/// A blocked network used to surface as "unrecognized response" with a raw
/// tail, and the user was sent to sign in again. These verdicts have to say
/// what happened and what would help.
@Suite("Steam cached-login verdicts")
struct SteamCachedLoginVerdictTests {
    @Test("Recovery commands authenticate the private profile and retain the actual error")
    @MainActor
    func recoveryUsesPrivateProfile() throws {
        let scratch = try TestScratch.defaultsSuite(prefix: "LiveWallpaperTests.PrivateProfileVerdict")
        defer { scratch.discard() }
        let doctor = SteamCMDDoctorService(defaults: scratch.defaults)
        doctor.username = "alice"
        doctor.applyCachedLoginOutcome(
            SteamCachedLoginResult(outcome: .noCachedSession, steamID64: nil,
                                   diagnosticTail: "Cached credentials not found.", exitCode: 5),
            username: "alice", binary: URL(fileURLWithPath: "/opt/homebrew/bin/steamcmd"),
            generation: doctor.accountGeneration
        )
        guard case let .yellow(_, command)? = doctor.probes[.cachedLogin]?.status else {
            Issue.record("Expected private-profile sign-in guidance")
            return
        }
        #expect(command?.contains("SteamCMDProfiles/v1/Accounts/alice") == true)
        #expect(command?.contains("HOME=") == true)
        // Without +quit the Terminal session stays interactive and the login is
        // never persisted.
        #expect(command?.hasSuffix("+quit") == true)
        #expect(doctor.cachedLoginExitCode == 5)
        #expect(doctor.cachedLoginDiagnosticTail == "Cached credentials not found.")
    }

    @Test("A probe result is bound to the account and generation that started it")
    @MainActor
    func staleProbeResultsAreIgnored() throws {
        let scratch = try TestScratch.defaultsSuite(prefix: "LiveWallpaperTests.StaleProbeResult")
        defer { scratch.discard() }
        let doctor = SteamCMDDoctorService(defaults: scratch.defaults)
        let binary = URL(fileURLWithPath: "/opt/homebrew/bin/steamcmd")
        let valid = SteamCachedLoginResult(outcome: .sessionValid, steamID64: nil, diagnosticTail: "")
        try doctor.setUsername("alice")
        let aliceGeneration = doctor.accountGeneration

        // A -> B: alice's probe comes back after the switch to bob.
        try doctor.setUsername("bob")
        doctor.applyCachedLoginOutcome(valid, username: "alice", binary: binary, generation: aliceGeneration)
        #expect(doctor.probes[.cachedLogin]?.status == .notRun)

        // A -> B -> A: same name again, but two generations later.
        try doctor.setUsername("alice")
        #expect(doctor.accountGeneration == aliceGeneration + 2)
        doctor.applyCachedLoginOutcome(valid, username: "alice", binary: binary, generation: aliceGeneration)
        #expect(doctor.probes[.cachedLogin]?.status == .notRun)

        // Control: the live generation colours green.
        doctor.applyCachedLoginOutcome(valid, username: "alice", binary: binary, generation: doctor.accountGeneration)
        #expect(doctor.isGreen(.cachedLogin))
        #expect(doctor.cachedLoginVerdict == .sessionValid)
    }

    @Test("a payload from a connector without failureReason still decodes")
    func legacyPayloadDecodes() throws {
        let login = try JSONDecoder().decode(SteamCachedLoginResult.self, from: Data("""
        {"outcome":"sessionValid","steamID64":"76561197960265728","diagnosticTail":""}
        """.utf8))
        #expect(login.failureReason == nil)
        #expect(login.outcome == .sessionValid)
    }

    @Test("network and refusal verdicts carry their reason into the probe")
    @MainActor
    func networkVerdictsExplainThemselves() throws {
        let defaults = try #require(UserDefaults(
            suiteName: "LiveWallpaperTests.CachedLoginVerdict.\(UUID().uuidString)"
        ))
        let doctor = SteamCMDDoctorService(defaults: defaults)
        doctor.username = "user"
        let binary = URL(fileURLWithPath: "/displayed/steamcmd")

        doctor.applyCachedLoginOutcome(
            SteamCachedLoginResult(
                outcome: .noConnection, steamID64: nil, diagnosticTail: "", failureReason: "No Connection"
            ),
            username: "user", binary: binary, generation: doctor.accountGeneration
        )
        guard case let .red(message, command)? = doctor.probes[.cachedLogin]?.status else {
            Issue.record("no-connection verdict is not red: \(String(describing: doctor.probes[.cachedLogin]?.status))")
            return
        }
        let unreachable = SteamCMDDoctorService.steamUnreachableMessage
        #expect(message == unreachable)
        // No command: signing in again cannot fix a network that is down.
        #expect(command == nil)

        doctor.applyCachedLoginOutcome(
            SteamCachedLoginResult(
                outcome: .loginFailed, steamID64: nil, diagnosticTail: "", failureReason: "Rate Limit Exceeded"
            ),
            username: "user", binary: binary, generation: doctor.accountGeneration
        )
        guard case let .red(refusal, signIn)? = doctor.probes[.cachedLogin]?.status else {
            Issue.record("refusal verdict is not red")
            return
        }
        #expect(refusal.contains("Rate Limit Exceeded"))
        #expect(signIn?.contains("+login") == true)
    }
}
#endif
