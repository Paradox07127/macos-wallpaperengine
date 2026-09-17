#if !LITE_BUILD
import Foundation
@testable import LiveWallpaper
import os
import Testing

/// `.serialized`: the test-only connection factory is process-wide state.
@Suite("SteamConnectorClient cancellation", .serialized)
struct SteamConnectorClientCancellationTests {
    /// Holds every reply block and never invokes it, so the client's wait can end only by cancellation (or the 7200 s timer).
    private final class SilentConnector: NSObject, SteamConnectorProtocol {
        let invoked = OSAllocatedUnfairLock(initialState: false)
        let sawHostExit = OSAllocatedUnfairLock(initialState: false)
        private let held = OSAllocatedUnfairLock<[@Sendable (Data) -> Void]>(initialState: [])

        private func hold(_ reply: @escaping @Sendable (Data) -> Void) {
            invoked.withLock { $0 = true }
            held.withLock { $0.append(reply) }
        }

        func probeEnvironment(with reply: @escaping @Sendable (Data) -> Void) {
            hold(reply)
        }

        func discoverAccounts(with reply: @escaping @Sendable (Data) -> Void) {
            hold(reply)
        }

        func probeCachedLogin(accountName _: String, with reply: @escaping @Sendable (Data) -> Void) {
            hold(reply)
        }

        func installWallpaperEngineAssets(accountName _: String, libraryPath _: String, operationID _: String, with reply: @escaping @Sendable (Data) -> Void) {
            hold(reply)
        }

        func latestWallpaperEngineBuildID(operationID _: String, with reply: @escaping @Sendable (Data) -> Void) {
            hold(reply)
        }

        func deleteWorkshopItem(workshopID _: String, libraryPath _: String, with reply: @escaping @Sendable (Data) -> Void) {
            hold(reply)
        }

        func downloadWorkshopItem(workshopID _: String, accountName _: String, libraryPath _: String, operationID _: String, with reply: @escaping @Sendable (Data) -> Void) {
            hold(reply)
        }

        func listSubscribedWorkshopItems(accountName _: String, with reply: @escaping @Sendable (Data) -> Void) {
            hold(reply)
        }

        func inspectSteamCMDBinary(path _: String, with reply: @escaping @Sendable (Data) -> Void) {
            hold(reply)
        }

        func bindManualSteamCMDBinary(path _: String, with reply: @escaping @Sendable (Data) -> Void) {
            hold(reply)
        }

        func clearManualSteamCMDBinary(with reply: @escaping @Sendable (Data) -> Void) {
            hold(reply)
        }

        func runSteamCMDProbe(_: Data, with reply: @escaping @Sendable (Data) -> Void) {
            hold(reply)
        }

        func diagnoseSteamCMD(_: Data, with reply: @escaping @Sendable (Data) -> Void) {
            hold(reply)
        }

        func locateSteamCMDBinary(with reply: @escaping @Sendable (Data) -> Void) {
            hold(reply)
        }

        func installManagedSteamCMD(with reply: @escaping @Sendable (Data) -> Void) {
            hold(reply)
        }

        func removeManagedSteamCMD(with reply: @escaping @Sendable (Data) -> Void) {
            hold(reply)
        }

        func removeAccountSession(accountName _: String, with reply: @escaping @Sendable (Data) -> Void) {
            hold(reply)
        }

        func signInSteamAccount(_: Data, with reply: @escaping @Sendable (Data) -> Void) {
            hold(reply)
        }

        func cancelActiveSteamCMD(operationID _: String, with reply: @escaping @Sendable (Data) -> Void) {
            hold(reply)
        }

        func terminateActiveSteamCMDForHostExit(with reply: @escaping @Sendable (Data) -> Void) {
            sawHostExit.withLock { $0 = true }
            hold(reply)
        }
    }

    private final class Delegate: NSObject, NSXPCListenerDelegate {
        let connector = SilentConnector()
        func listener(_: NSXPCListener, shouldAcceptNewConnection newConnection: NSXPCConnection) -> Bool {
            newConnection.exportedInterface = NSXPCInterface(with: (any SteamConnectorProtocol).self)
            newConnection.exportedObject = connector
            newConnection.resume()
            return true
        }
    }

    @Test("cancelling the task ends the wait at once, not at the 7200 s timer", .timeLimit(.minutes(1)))
    @MainActor
    func cancelResumesPromptly() async throws {
        let listener = NSXPCListener.anonymous()
        let delegate = Delegate()
        listener.delegate = delegate
        listener.resume()
        // `nonisolated(unsafe)`: the endpoint is only read to build a connection; the listener lives for the whole test.
        nonisolated(unsafe) let endpoint = listener.endpoint
        SteamConnectorClient.connectionFactoryForTesting = { NSXPCConnection(listenerEndpoint: endpoint) }
        defer {
            SteamConnectorClient.connectionFactoryForTesting = nil
            listener.invalidate()
        }

        // Polled, never awaited: a call() that ignores cancellation must fail this test, not hang it.
        let finished = OSAllocatedUnfairLock(initialState: false)
        let call = Task {
            _ = await SteamConnectorClient.discoverAccounts()
            finished.withLock { $0 = true }
        }
        // The request must have reached the stub: a transport failure would end the wait on its own and prove nothing.
        for _ in 0 ..< 50 where !delegate.connector.invoked.withLock({ $0 }) {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(delegate.connector.invoked.withLock { $0 })
        #expect(!finished.withLock { $0 })

        call.cancel()
        for _ in 0 ..< 150 where !finished.withLock({ $0 }) {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(finished.withLock { $0 }, "call() ignored Task.cancel and is waiting for a reply that will never come")
    }

    @Test("quitting signals the connector even when the call in flight has no progress channel", .timeLimit(.minutes(1)))
    @MainActor
    func hostExitReachesAChildStartedWithoutProgress() async throws {
        let listener = NSXPCListener.anonymous()
        let delegate = Delegate()
        listener.delegate = delegate
        listener.resume()
        // `nonisolated(unsafe)`: the endpoint is only read to build a connection; the listener lives for the whole test.
        nonisolated(unsafe) let endpoint = listener.endpoint
        SteamConnectorClient.connectionFactoryForTesting = { NSXPCConnection(listenerEndpoint: endpoint) }
        defer {
            SteamConnectorClient.connectionFactoryForTesting = nil
            listener.invalidate()
        }

        // `probeCachedLogin` spawns SteamCMD but streams no progress, so it is exactly the shape
        // the in-flight gate has to notice.
        let probe = Task { _ = await SteamConnectorClient.probeCachedLogin(accountName: "someone") }
        defer { probe.cancel() }
        for _ in 0 ..< 50 where !delegate.connector.invoked.withLock({ $0 }) {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(delegate.connector.invoked.withLock { $0 })

        await SteamConnectorClient.terminateActiveSteamCMDForHostExit()
        #expect(
            delegate.connector.sawHostExit.withLock { $0 },
            "quitting never asked the connector to signal its child, so a SteamCMD run with no progress channel outlives the app"
        )
    }

    @Test("quitting still reaches the connector after the only in-flight call was cancelled", .timeLimit(.minutes(1)))
    @MainActor
    func hostExitReachesTheConnectorAfterACancelledCall() async throws {
        let listener = NSXPCListener.anonymous()
        let delegate = Delegate()
        listener.delegate = delegate
        listener.resume()
        // `nonisolated(unsafe)`: the endpoint is only read to build a connection; the listener lives for the whole test.
        nonisolated(unsafe) let endpoint = listener.endpoint
        SteamConnectorClient.connectionFactoryForTesting = { NSXPCConnection(listenerEndpoint: endpoint) }
        defer {
            SteamConnectorClient.connectionFactoryForTesting = nil
            listener.invalidate()
        }

        // Termination cancels startup tasks first; the child the probe started is still running.
        let probe = Task { _ = await SteamConnectorClient.probeCachedLogin(accountName: "someone") }
        for _ in 0 ..< 50 where !delegate.connector.invoked.withLock({ $0 }) {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(delegate.connector.invoked.withLock { $0 })
        probe.cancel()
        _ = await probe.value

        await SteamConnectorClient.terminateActiveSteamCMDForHostExit()
        #expect(
            delegate.connector.sawHostExit.withLock { $0 },
            "a cancelled wait took the in-flight count back to zero, so quitting skipped the only RPC that can signal the child"
        )
    }

    // MARK: - Source guards

    @Test("the interactive login child is registered like every other SteamCMD child")
    func connectorRegistersTheLoginChild() throws {
        let connector = try RepositoryRoot.source("SteamConnector/SteamConnector.swift")
        let login = try #require(connector.range(of: "static func runLoginSession("))
        let body = connector[login.upperBound...]
        let run = try #require(body.range(of: "try process.run()"))
        let afterRun = body[run.upperBound...].prefix(600)
        #expect(
            afterRun.contains("activeSteamCMD.register("),
            "a login child that is never registered cannot be signalled on host exit"
        )
    }

    @Test("SteamCMD termination runs alongside app shutdown, not ahead of it on the same 2 s fuse")
    func hostExitDoesNotSerialiseAheadOfShutdown() throws {
        let app = try RepositoryRoot.source("LiveWallpaper/App/LiveWallpaperApp.swift")
        let terminate = try #require(app.range(of: "func applicationShouldTerminate("))
        let body = app[terminate.upperBound...]
        let hostExit = try #require(body.range(of: "terminateActiveSteamCMDForHostExit"))
        let line = body[..<hostExit.lowerBound].split(separator: "\n").last ?? ""
        #expect(line.contains("async let"), "a 1 s XPC wait awaited before shutdownForApplication() eats half of the watchdog budget")
    }

    @Test("the connector treats an invalidated client connection as an abandoned caller")
    func connectorWiresInvalidation() throws {
        let main = try RepositoryRoot.source("SteamConnector/main.swift")
        #expect(main.contains("newConnection.invalidationHandler"))
        // The connection is the only strong reference, and XPC releases the exported object on
        // invalidation without documenting whether that happens before or after the handler runs.
        #expect(
            !main.contains("[weak exportedObject]"),
            "a weakly captured exported object may already be nil when the handler fires, which silently disables the whole abandoned-caller path"
        )
    }

    @Test("every SteamCMD child is registered, so host exit can reach one started without an operation id")
    func connectorRegistersEveryChild() throws {
        let connector = try RepositoryRoot.source("SteamConnector/SteamConnector.swift")
        #expect(
            !connector.contains("if let activeOperationID {"),
            "a child registered only when the caller passed an operation id is invisible to terminateActiveForHostExit"
        )
        #expect(!connector.contains("if activeOperationID != nil {"))
    }

    @Test("app termination signals the active SteamCMD child before the termination coordinator runs")
    func hostExitPrecedesTerminationCoordinator() throws {
        let app = try RepositoryRoot.source("LiveWallpaper/App/LiveWallpaperApp.swift")
        let terminate = try #require(app.range(of: "func applicationShouldTerminate("))
        let body = app[terminate.upperBound...]
        let hostExit = try #require(body.range(of: "terminateActiveSteamCMDForHostExit"))
        let coordinator = try #require(body.range(of: "AppTerminationCoordinator.shutdownForApplication()"))
        #expect(hostExit.lowerBound < coordinator.lowerBound)
    }
}
#endif
