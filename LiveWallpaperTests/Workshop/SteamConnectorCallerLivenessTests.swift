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
