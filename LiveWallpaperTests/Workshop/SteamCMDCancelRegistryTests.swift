import Foundation
import Testing
@testable import LiveWallpaper

@Suite("SteamCMD active-process cancel registry")
struct SteamCMDCancelRegistryTests {
    @Test("registered group is SIGTERMed as a group; cleared registry kills nothing")
    func terminateActiveGroupThenClear() {
        let registry = SteamCMDActiveProcessRegistry()
        let operationID = UUID().uuidString
        var signals: [(pid: pid_t, signal: Int32)] = []

        registry.register(pid: 4242, hasOwnGroup: true, operationID: operationID)
        #expect(registry.terminateActive(operationID: operationID, kill: { pid, sig in
            signals.append((pid, sig))
            return 0
        }))
        #expect(signals.count == 1)
        #expect(signals[0].pid == -4242)
        #expect(signals[0].signal == SIGTERM)

        registry.clear()
        #expect(!registry.terminateActive(operationID: operationID, kill: { pid, sig in
            signals.append((pid, sig))
            return 0
        }))
        #expect(signals.count == 1)
    }

    @Test("child without its own group is signalled by bare pid")
    func terminateActiveWithoutOwnGroup() {
        let registry = SteamCMDActiveProcessRegistry()
        let operationID = UUID().uuidString
        var signalled: pid_t?

        registry.register(pid: 777, hasOwnGroup: false, operationID: operationID)
        #expect(registry.terminateActive(operationID: operationID, kill: { pid, _ in
            signalled = pid
            return 0
        }))
        #expect(signalled == 777)
    }

    /// The retry race: the cancel for a superseded attempt reaches the connector
    /// only after the next attempt's child has registered.
    @Test("a cancel for a superseded operation never kills the run that replaced it")
    func supersededOperationCancelIsANoOp() {
        let registry = SteamCMDActiveProcessRegistry()
        let cancelled = UUID().uuidString
        let retry = UUID().uuidString

        registry.register(pid: 555, hasOwnGroup: true, operationID: retry)
        #expect(!registry.terminateActive(operationID: cancelled, kill: { _, _ in
            Issue.record("a stale cancel must not signal the operation that replaced it")
            return 0
        }))
    }
}
