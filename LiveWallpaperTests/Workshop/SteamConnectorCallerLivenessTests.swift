import Foundation
@testable import LiveWallpaper
import Testing

@Suite("SteamConnector caller liveness")
struct SteamConnectorCallerLivenessTests {
    @Test("a caller is live until its queue wait exceeds the budget")
    func queueWaitBudget() {
        let liveness = SteamConnectorCallerLiveness(maxQueueWait: 900)
        let enqueued = Date(timeIntervalSince1970: 1000)
        #expect(liveness.isLive(enqueuedAt: enqueued, now: enqueued.addingTimeInterval(899)))
        #expect(!liveness.isLive(enqueuedAt: enqueued, now: enqueued.addingTimeInterval(901)))
    }

    @Test("an invalidated connection abandons its queued work and signals the child it started")
    func invalidationAbandonsAndSignalsOwnChild() {
        let registry = SteamCMDActiveProcessRegistry()
        let liveness = SteamConnectorCallerLiveness(maxQueueWait: 900)
        let mine = UUID().uuidString
        liveness.own(operationID: mine)
        registry.register(pid: 100, hasOwnGroup: true, operationID: mine)
        var signalled: [pid_t] = []

        liveness.markAbandoned { operationID in
            _ = registry.terminateActive(operationID: operationID, kill: { pid, _ in
                signalled.append(pid)
                return 0
            })
        }
        #expect(signalled == [-100])
        let now = Date()
        #expect(!liveness.isLive(enqueuedAt: now, now: now))
    }

    @Test("a login cancelled between spawn and registration is signalled, while its retry survives")
    func loginCancellationDuringSpawnDoesNotReachRetry() {
        let registry = SteamCMDActiveProcessRegistry()
        let cancelled = SteamConnectorCallerLiveness(maxQueueWait: 900)
        let cancelledID = UUID().uuidString
        cancelled.own(operationID: cancelledID)
        cancelled.markAbandoned { operationID in
            #expect(!registry.terminateActive(operationID: operationID, kill: { _, _ in
                Issue.record("the child has not registered yet")
                return 0
            }))
        }
        #expect(!cancelled.canContinue)
        var signals: [pid_t] = []
        registry.register(
            pid: 101, hasOwnGroup: false, operationID: cancelledID,
            isCancelled: { !cancelled.canContinue },
            kill: { pid, signal in
                #expect(signal == SIGTERM)
                signals.append(pid)
                return 0
            }
        )
        #expect(signals == [101])
        registry.clear()
        let retry = SteamConnectorCallerLiveness(maxQueueWait: 900)
        let retryID = UUID().uuidString
        retry.own(operationID: retryID)
        registry.register(
            pid: 102, hasOwnGroup: false, operationID: retryID,
            isCancelled: { !retry.canContinue },
            kill: { _, _ in
                Issue.record("the new login must remain live")
                return 0
            }
        )
        cancelled.markAbandoned { operationID in
            #expect(!registry.terminateActive(operationID: operationID, kill: { _, _ in
                Issue.record("late cancellation of the first login killed its retry")
                return 0
            }))
        }
        #expect(retry.canContinue)
        retry.markAbandoned { operationID in
            let terminated = registry.terminateActive(operationID: operationID, kill: { pid, signal in
                #expect(pid == 102)
                #expect(signal == SIGTERM)
                return 0
            })
            #expect(terminated)
        }
    }

    @Test("host exit makes every caller's queued work bail")
    func hostExitFailsEveryCaller() {
        defer { SteamCMDActiveProcessRegistry.resetHostExitForTesting() }
        let liveness = SteamConnectorCallerLiveness(maxQueueWait: 900)
        let now = Date()
        #expect(liveness.isLive(enqueuedAt: now, now: now))
        _ = SteamCMDActiveProcessRegistry().terminateActiveForHostExit(kill: { _, _ in 0 })
        #expect(!liveness.isLive(enqueuedAt: now, now: now))
    }

    @Test("a disowned operation is not signalled when the connection later goes away")
    func disownedOperationIsNotSignalled() {
        let registry = SteamCMDActiveProcessRegistry()
        let liveness = SteamConnectorCallerLiveness(maxQueueWait: 900)
        let attempt = UUID().uuidString
        liveness.own(operationID: attempt)
        // The reply went out; the app started the next download of the same attempt on a new connection.
        liveness.disown(operationID: attempt)
        registry.register(pid: 300, hasOwnGroup: true, operationID: attempt)

        liveness.markAbandoned { operationID in
            _ = registry.terminateActive(operationID: operationID, kill: { _, _ in
                Issue.record("a completed connection's late invalidation signalled its successor's child")
                return 0
            })
        }
    }

    @Test("an invalidated connection never signals another caller's child")
    func invalidationSparesOtherCallersChild() {
        let registry = SteamCMDActiveProcessRegistry()
        let liveness = SteamConnectorCallerLiveness(maxQueueWait: 900)
        liveness.own(operationID: UUID().uuidString)
        registry.register(pid: 99, hasOwnGroup: true, operationID: UUID().uuidString)

        liveness.markAbandoned { operationID in
            _ = registry.terminateActive(operationID: operationID, kill: { _, _ in
                Issue.record("another connection's run must survive this one going away")
                return 0
            })
        }
        let now = Date()
        #expect(!liveness.isLive(enqueuedAt: now, now: now))
    }
}
