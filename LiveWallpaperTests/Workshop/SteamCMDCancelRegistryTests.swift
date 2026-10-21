import Foundation
@testable import LiveWallpaper
import Testing

@Suite("SteamCMD active-process cancel registry", .serialized)
struct SteamCMDCancelRegistryTests {
    @Test("Cancel and reap one of three children without losing the other registrations")
    func independentChildren() {
        let registry = SteamCMDActiveProcessRegistry()
        defer { SteamCMDActiveProcessRegistry.resetHostExitForTesting() }
        for pid: pid_t in [701, 702, 703] {
            registry.register(pid: pid, hasOwnGroup: true, operationID: String(pid), kill: { _, _ in 0 })
        }
        var signals: [pid_t] = []
        #expect(registry.terminateActive(operationID: "702", kill: { pid, _ in signals.append(pid); return 0 }))
        #expect(signals == [-702])
        #expect(registry.cancellationRequested(for: 702))
        #expect(!registry.cancellationRequested(for: 701))
        registry.clear(pid: 702)
        signals.removeAll()
        #expect(registry.terminateActiveForHostExit(kill: { pid, _ in signals.append(pid); return 0 }))
        #expect(Set(signals) == [-701, -703])
    }

    @Test("Queued cancellation and account removal invalidate only the matching jobs")
    func queuedJobCancellation() {
        let jobs = SteamCMDDownloadJobs()
        _ = jobs.cancel(operationID: "cancel-before-arrival")
        let first = SteamCMDDownloadJob(operationID: "cancel-before-arrival", accountName: "Alice", itemID: "1", libraryPath: "/a")
        let second = SteamCMDDownloadJob(operationID: "b", accountName: "Bob", itemID: "2", libraryPath: "/a")
        let third = SteamCMDDownloadJob(operationID: "c", accountName: "alice", itemID: "3", libraryPath: "/b")
        [first, second, third].forEach(jobs.insert)
        #expect(first.isCancelled)
        #expect(!second.isCancelled)
        #expect(!third.isCancelled)
        #expect(Set(jobs.cancel(accountName: "ALICE")) == [first.operationID, third.operationID])
        #expect(third.isCancelled)
        #expect(!second.isCancelled)
        jobs.remove(first)
        jobs.remove(third)
        #expect(jobs.cancel(itemID: "2", libraryPath: "/b").isEmpty)
        #expect(!second.isCancelled)
    }

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
        defer { SteamCMDActiveProcessRegistry.resetHostExitForTesting() }
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
        defer { SteamCMDActiveProcessRegistry.resetHostExitForTesting() }
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
