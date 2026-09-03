#if !LITE_BUILD
import Foundation
@testable import LiveWallpaper
import Testing

/// A blocked network used to surface as "unrecognized response" with a raw
/// tail, and the user was sent to sign in again. These verdicts have to say
/// what happened and what would help.
@Suite("Steam cached-login verdicts")
struct SteamCachedLoginVerdictTests {
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
        let binary = URL(fileURLWithPath: "/displayed/steamcmd")

        doctor.applyCachedLoginOutcome(
            SteamCachedLoginResult(
                outcome: .noConnection, steamID64: nil, diagnosticTail: "", failureReason: "No Connection"
            ),
            username: "user", binary: binary
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
            username: "user", binary: binary
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
