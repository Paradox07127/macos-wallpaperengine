import Foundation
import Testing
@testable import LiveWallpaper

private struct FakeRun {
    let exitCode: Int32
    var timedOut = false
}

private final class ScriptedSteamCMD {
    private(set) var events: [String] = []
    private var script: [FakeRun]
    var revalidationFailure: String?

    init(_ script: [FakeRun]) { self.script = script }
    convenience init(exitCodes: [Int32]) {
        self.init(exitCodes.map { FakeRun(exitCode: $0) })
    }

    func run() -> SteamCMDSelfUpdateRestartPolicy.Outcome<FakeRun> {
        SteamCMDSelfUpdateRestartPolicy.run(
            execute: {
                events.append("execute")
                guard !script.isEmpty else { return FakeRun(exitCode: -99) }
                return script.removeFirst()
            },
            exitCode: { $0.exitCode },
            timedOut: { $0.timedOut },
            revalidate: {
                events.append("revalidate")
                return revalidationFailure
            }
        )
    }
}

@Suite("SteamCMD self-update restart")
struct SteamCMDSelfUpdateRestartTests {
    @Test("A fresh install's two exit-42 restart requests are absorbed")
    func freshInstallNeedsTwoRestarts() {
        let steamCMD = ScriptedSteamCMD(exitCodes: [42, 42, 0])
        guard case .completed(let final) = steamCMD.run() else {
            Issue.record("two restart requests must not be reported as failure")
            return
        }
        #expect(final.exitCode == 0)
        // The rewritten binary is re-gated before EACH relaunch, never after
        // the final run — that re-check belongs to the callers that need it.
        #expect(steamCMD.events == [
            "execute", "revalidate", "execute", "revalidate", "execute"
        ])
    }

    @Test("One restart request beyond the measured case still completes")
    func headroomAboveTheMeasuredCase() {
        // The measured fresh install needs two restarts; the budget carries one
        // spare execution beyond that.
        let steamCMD = ScriptedSteamCMD(exitCodes: [42, 42, 42, 0])
        guard case .completed(let final) = steamCMD.run() else {
            Issue.record("three restart requests must not be reported as failure")
            return
        }
        #expect(final.exitCode == 0)
        #expect(steamCMD.events.filter { $0 == "execute" }.count == 4)
    }

    @Test("The restart loop is still bounded")
    func loopIsBounded() {
        let steamCMD = ScriptedSteamCMD(exitCodes: [42, 42, 42, 42, 0])
        guard case .completed(let final) = steamCMD.run() else {
            Issue.record("an exhausted loop reports the last run, not a gate failure")
            return
        }
        // The fifth run (which would have succeeded) must never happen: a
        // binary still asking after four is broken, not slow.
        #expect(final.exitCode == 42)
        #expect(steamCMD.events.filter { $0 == "execute" }.count == 4)
    }

    @Test("Control: a clean first run executes once and never re-gates")
    func cleanRunExecutesOnce() {
        let steamCMD = ScriptedSteamCMD(exitCodes: [0])
        guard case .completed(let final) = steamCMD.run() else {
            Issue.record("a clean run is not a gate failure")
            return
        }
        #expect(final.exitCode == 0)
        #expect(steamCMD.events == ["execute"])
    }

    @Test("Control: only 42 is a restart request, not any non-zero exit")
    func ordinaryFailureIsNotRestarted() {
        let steamCMD = ScriptedSteamCMD(exitCodes: [7, 0])
        guard case .completed(let final) = steamCMD.run() else {
            Issue.record("an ordinary failure is not a gate failure")
            return
        }
        #expect(final.exitCode == 7)
        #expect(steamCMD.events == ["execute"])
    }

    @Test("A killed run's exit status is not a restart request")
    func timedOutRunIsNotRestarted() {
        let steamCMD = ScriptedSteamCMD([FakeRun(exitCode: 42, timedOut: true)])
        guard case .completed(let final) = steamCMD.run() else {
            Issue.record("a timeout is not a gate failure")
            return
        }
        #expect(final.timedOut)
        #expect(steamCMD.events == ["execute"])
    }

    @Test("A failed trust gate stops the loop before any relaunch")
    func gateFailureStopsRelaunch() {
        let steamCMD = ScriptedSteamCMD(exitCodes: [42, 0])
        steamCMD.revalidationFailure = "signed by team EVIL"
        guard case .gateFailed(let reason) = steamCMD.run() else {
            Issue.record("an untrusted rewritten binary must not be relaunched")
            return
        }
        #expect(reason == "signed by team EVIL")
        #expect(steamCMD.events == ["execute", "revalidate"])
    }

    @Test("A fresh install's diagnosis probe is usable, not exitedNonZero")
    func freshInstallDiagnosesAsUsable() {
        let steamCMD = ScriptedSteamCMD(exitCodes: [42, 42, 0])
        guard case .completed(let final) = steamCMD.run() else {
            Issue.record("fresh install must complete")
            return
        }
        let probe = SteamCMDLaunchProbe(
            outcome: SteamCMDLaunchProbe.classify(
                exitCode: final.exitCode, timedOut: final.timedOut
            ),
            arguments: SteamCMDDiagnosisProbe.arguments,
            exitCode: final.exitCode,
            timeout: SteamCMDDiagnosisProbe.defaultLaunchTimeout,
            outputTail: ""
        )
        let diagnosis = SteamCMDDiagnosis(
            source: .managedInstall,
            canonicalPath: "/Users/probe/Library/Application Support/Loomscreen/SteamCMD/MacOS/steamcmd",
            resolutionFailure: nil,
            sha256: String(repeating: "a", count: 64),
            signature: SteamCMDSignatureVerdict(
                isValid: true,
                teamIdentifier: SteamCMDBootstrapPackage.expectedTeamIdentifier,
                isHardenedRuntime: true
            ),
            isQuarantined: false,
            launch: probe,
            unavailableReason: nil
        )
        #expect(diagnosis.isUsable)
    }

    @Test("The connector's funnel is the one place restarts happen")
    func funnelRoutesThroughRestartEngine() throws {
        let source = try RepositoryRoot.source("SteamConnector/SteamConnector.swift")
        let start = try #require(
            source.range(of: "static func runSteamCMD("),
            "SteamConnector.swift has no runSteamCMD — the scan is misconfigured, not passing."
        )
        let body = String(source[start.lowerBound...].prefix(3_500))
        #expect(body.contains("SteamCMDSelfUpdateRestartPolicy.run"))
        #expect(body.contains("verifySignature"))
        #expect(body.contains("rejectIfQuarantined"))
        #expect(!source.contains("SteamCMDSelfUpdateRetryPolicy"))
    }
}
