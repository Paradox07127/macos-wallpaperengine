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
            deadline: SteamCMDRunDeadline(timeout: 60),
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

    @Test("Remaining time follows monotonic elapsed time and clamps after expiry")
    func monotonicRemaining() {
        let start = DispatchTime(uptimeNanoseconds: 1_000_000_000)
        let deadline = SteamCMDRunDeadline(timeout: 2, start: start)
        #expect(deadline.remaining(at: start) == 2)
        #expect(deadline.remaining(at: DispatchTime(uptimeNanoseconds: 2_500_000_000)) == 0.5)
        #expect(deadline.remaining(at: DispatchTime(uptimeNanoseconds: 3_000_000_000)) == 0)
        #expect(deadline.remaining(at: DispatchTime(uptimeNanoseconds: 4_000_000_000)) == 0)
    }

    @Test("An expired or cancelled admission never launches a child")
    func expiredAdmission() {
        let now = DispatchTime(uptimeNanoseconds: 1_000_000_000)
        let deadline = SteamCMDRunDeadline(timeout: 0, start: now)
        for cancelled in [false, true] {
            var calls = 0
            let outcome = SteamCMDSelfUpdateRestartPolicy.run(deadline: deadline, now: { now },
                                                              isCancelled: { cancelled }, execute: { calls += 1; return FakeRun(exitCode: 0) },
                                                              exitCode: { $0.exitCode }, timedOut: { $0.timedOut }, revalidate: { calls += 1; return nil })
            if cancelled {
                guard case .cancelled = outcome else { Issue.record("expected cancellation"); continue }
            } else {
                guard case .deadlineExceeded(nil) = outcome else { Issue.record("expected empty expiry"); continue }
            }
            #expect(calls == 0)
        }
    }

    @Test("A restart consumes the first attempt's elapsed time before any new trust helper")
    func attemptExhaustsSharedBudget() {
        let start = DispatchTime(uptimeNanoseconds: 1_000_000_000)
        let deadline = SteamCMDRunDeadline(timeout: 1, start: start)
        var clock = start
        var executions = 0
        var validations = 0
        let outcome = SteamCMDSelfUpdateRestartPolicy.run(deadline: deadline, now: { clock }, execute: {
            executions += 1
            clock = deadline.time
            return FakeRun(exitCode: 42)
        }, exitCode: { $0.exitCode }, timedOut: { $0.timedOut }, revalidate: { validations += 1; return nil })
        guard case let .deadlineExceeded(last) = outcome else { Issue.record("must retain expiry diagnosis"); return }
        #expect(last?.exitCode == 42)
        #expect(executions == 1)
        #expect(validations == 0)
    }

    @Test("Signature budget expiry is a timeout, even if the helper reports an invalid signature")
    func signatureExhaustsSharedBudget() {
        let start = DispatchTime(uptimeNanoseconds: 1_000_000_000)
        let deadline = SteamCMDRunDeadline(timeout: 1, start: start)
        var clock = start
        var executions = 0
        let outcome = SteamCMDSelfUpdateRestartPolicy.run(deadline: deadline, now: { clock }, execute: {
            executions += 1
            return FakeRun(exitCode: 42)
        }, exitCode: { $0.exitCode }, timedOut: { $0.timedOut }, revalidate: {
            clock = deadline.time
            return "codesign timed out"
        })
        guard case let .deadlineExceeded(last) = outcome else { Issue.record("expiry must take precedence over trust failure"); return }
        #expect(last?.exitCode == 42)
        #expect(executions == 1)
    }

    @Test("Cancellation during replacement verification cannot relaunch or become a trust failure")
    func cancellationDuringVerification() {
        let deadline = SteamCMDRunDeadline(timeout: 60)
        var cancelled = false
        var executions = 0
        let outcome = SteamCMDSelfUpdateRestartPolicy.run(deadline: deadline, isCancelled: { cancelled }, execute: {
            executions += 1
            return FakeRun(exitCode: 42)
        }, exitCode: { $0.exitCode }, timedOut: { $0.timedOut }, revalidate: {
            cancelled = true
            return "terminated verification"
        })
        guard case .cancelled = outcome else { Issue.record("must preserve cancellation"); return }
        #expect(executions == 1)
    }

    @Test("The connector's funnel is the one place restarts happen")
    func funnelRoutesThroughRestartEngine() throws {
        let source = try RepositoryRoot.source("SteamConnector/SteamConnector.swift")
        let start = try #require(
            source.range(of: "static func runSteamCMD("),
            "SteamConnector.swift has no runSteamCMD — the scan is misconfigured, not passing."
        )
        let end = try #require(source.range(of: "private static func spawn(", range: start.upperBound ..< source.endIndex))
        let body = String(source[start.lowerBound ..< end.lowerBound])
        #expect(body.contains("SteamCMDSelfUpdateRestartPolicy.run"))
        #expect(body.contains("verifySignature"))
        #expect(body.contains("rejectIfQuarantined"))
        #expect(!source.contains("SteamCMDSelfUpdateRetryPolicy"))
    }
}
