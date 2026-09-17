import Foundation
@testable import LiveWallpaper
import Testing

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

    @Test("host exit signals the active child whatever operation it belongs to")
    func hostExitTerminatesRegardlessOfOperation() {
        let registry = SteamCMDActiveProcessRegistry()
        registry.register(pid: 313, hasOwnGroup: true, operationID: UUID().uuidString)
        var signalled: [(pid: pid_t, signal: Int32)] = []

        #expect(registry.terminateActiveForHostExit(kill: { pid, sig in
            signalled.append((pid, sig))
            return 0
        }))
        #expect(signalled.count == 1)
        #expect(signalled[0].pid == -313)
        #expect(signalled[0].signal == SIGTERM)

        registry.clear()
        #expect(!registry.terminateActiveForHostExit(kill: { _, _ in
            Issue.record("an empty registry must signal nothing")
            return 0
        }))
    }

    @Test("a child the app never named is reachable by host exit and by nothing else")
    func unnamedChildIsReachableOnlyByHostExit() {
        let registry = SteamCMDActiveProcessRegistry()
        registry.register(pid: 414, hasOwnGroup: false, operationID: nil)

        #expect(!registry.terminateActive(operationID: UUID().uuidString, kill: { _, _ in
            Issue.record("an id cancel must never signal a child that was never named")
            return 0
        }))

        var signalled: [(pid: pid_t, signal: Int32)] = []
        #expect(registry.terminateActiveForHostExit(kill: { pid, sig in
            signalled.append((pid, sig))
            return 0
        }))
        #expect(signalled.count == 1)
        #expect(signalled[0].pid == 414)
        #expect(signalled[0].signal == SIGTERM)
    }

    @Test("after host exit, a child that is registered late is signalled at once")
    func hostExitLatchSignalsLaterChildren() {
        let registry = SteamCMDActiveProcessRegistry()
        defer { SteamCMDActiveProcessRegistry.resetHostExitForTesting() }
        #expect(!registry.terminateActiveForHostExit(kill: { _, _ in 0 }))
        #expect(SteamCMDActiveProcessRegistry.hostExiting)

        var signalled: [pid_t] = []
        registry.register(pid: 515, hasOwnGroup: true, operationID: nil, kill: { pid, sig in
            signalled.append(pid)
            #expect(sig == SIGTERM)
            return 0
        })
        #expect(signalled == [-515], "the serial queue started another child after the quit signal and nothing stopped it")
    }

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
