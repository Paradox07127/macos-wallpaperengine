#if !LITE_BUILD
import Foundation
@testable import LiveWallpaper
import os
import Testing

/// `.serialized`: the test-only connection factory is process-wide state.
@Suite("SteamConnectorClient cancellation", .serialized)
struct SteamConnectorClientCancellationTests {
    @Test("login owns one cancellation identity through its interactive and verification children")
    func loginCancellationReachesBothChildren() throws {
        let source = try RepositoryRoot.source("SteamConnector/SteamConnector.swift")
        let entryStart = try #require(source.range(of: "    func signInSteamAccount("))
        let loginStart = try #require(source.range(of: "    static func runLoginSession("))
        let loginEnd = try #require(source.range(of: "    func removeManagedSteamCMD("))
        let entry = String(source[entryStart.lowerBound ..< loginStart.lowerBound])
        let login = String(source[loginStart.lowerBound ..< loginEnd.lowerBound])
        #expect(entry.contains("let operationID = UUID().uuidString"))
        #expect(entry.contains("liveness.own(operationID: operationID)"))
        #expect(entry.contains("liveness.disown(operationID: operationID)"))
        #expect(entry.contains("isCancelled: { !liveness.canContinue }"))
        #expect(login.contains("hasOwnGroup: false, operationID: operationID"))
        #expect(!login.contains("operationID: nil"))
        let verifyStart = try #require(login.range(of: "let cached = runCachedLoginProbe("))
        #expect(login[verifyStart.lowerBound...].contains("operationID: operationID, isCancelled: isCancelled"))
        #expect(login.contains("guard !isCancelled() else { break }"))
        let spawnStart = try #require(source.range(of: "    private static func spawn("))
        let spawnEnd = try #require(source.range(of: "    func probeEnvironment("))
        let spawn = String(source[spawnStart.lowerBound ..< spawnEnd.lowerBound])
        let run = try #require(spawn.range(of: "try process.run()"))
        #expect(spawn[..<run.lowerBound].contains("guard !isCancelled()"))
        let register = try #require(spawn.range(of: "activeSteamCMD.register("))
        #expect(spawn[register.lowerBound...].prefix(220).contains("isCancelled: isCancelled"))
    }

    @Test("Downloads and engine queries carry connection cancellation through child registration")
    func ownedOperationsCheckCancellationAtSpawn() throws {
        let source = try RepositoryRoot.source("SteamConnector/SteamConnector.swift")
        for (start, end, expectedCalls) in [
            ("    func downloadWorkshopItem(", "    func listSubscribedWorkshopItems(", 1),
            ("    func latestWallpaperEngineBuildID(", "    func installWallpaperEngineAssets(", 1),
            ("    func installWallpaperEngineAssets(", "    private static func discardStagedWorkshopTree(", 2),
        ] {
            let lower = try #require(source.range(of: start))
            let upper = try #require(source.range(of: end, range: lower.upperBound ..< source.endIndex))
            let body = source[lower.lowerBound ..< upper.lowerBound]
            #expect(body.components(separatedBy: "isCancelled: { !liveness.canContinue }").count - 1 == expectedCalls)
            #expect(body.components(separatedBy: "operationID: operationID,").count - 1 >= expectedCalls)
        }
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

    /// Holds every reply block and never invokes it, so the client's wait can end only by cancellation (or the 7200 s timer).
    private final class SilentConnector: NSObject, SteamConnectorProtocol {
        let invoked = OSAllocatedUnfairLock(initialState: false)
        let sawHostExit = OSAllocatedUnfairLock(initialState: false)
        private let held = OSAllocatedUnfairLock<[@Sendable (Data) -> Void]>(initialState: [])

        var hasReply: Bool {
            held.withLock { !$0.isEmpty }
        }

        func reply(_ data: Data) {
            held.withLock { $0.last }?(data)
        }

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
        let endpoint = listener.endpoint
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
        let endpoint = listener.endpoint
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
        let endpoint = listener.endpoint
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

    @MainActor
    private func progressFixture() -> (NSXPCListener, Delegate, NSXPCConnection) {
        let listener = NSXPCListener.anonymous()
        let delegate = Delegate()
        listener.delegate = delegate
        listener.resume()
        // The endpoint and connection remain alive until the isolated test completes.
        nonisolated(unsafe) let connection = NSXPCConnection(listenerEndpoint: listener.endpoint)
        SteamConnectorClient.connectionFactoryForTesting = { connection }
        return (listener, delegate, connection)
    }

    @MainActor
    private func receiver(from connection: NSXPCConnection, delegate: Delegate) async throws -> any SteamConnectorProgressProtocol {
        for _ in 0 ..< 50 where !delegate.connector.hasReply {
            try await Task.sleep(for: .milliseconds(20))
        }
        try #require(delegate.connector.hasReply)
        return try #require(connection.exportedObject as? any SteamConnectorProgressProtocol)
    }

    private func progressPayload(_ bytes: UInt64) throws -> Data {
        try JSONEncoder().encode(SteamOperationProgress(
            phase: .downloading, fraction: Double(bytes) / 10000,
            downloadedBytes: bytes, totalBytes: 10000
        ))
    }

    enum CallEnd: CaseIterable {
        case reply, cancellation, transportError
    }

    @Test("progress arriving after the call ends is not delivered", .timeLimit(.minutes(1)), arguments: CallEnd.allCases)
    @MainActor
    func lateProgressIsDropped(end: CallEnd) async throws {
        let (listener, delegate, connection) = progressFixture()
        defer { SteamConnectorClient.connectionFactoryForTesting = nil; listener.invalidate() }
        let published = OSAllocatedUnfairLock<[UInt64?]>(initialState: [])
        let call = Task {
            await SteamConnectorClient.downloadWorkshopItem(workshopID: "1", accountName: "someone", libraryPath: "/tmp") { update in
                published.withLock { $0.append(update.downloadedBytes) }
            }
        }
        defer { call.cancel() }
        let receiver = try await receiver(from: connection, delegate: delegate)
        try receiver.connectorDidReportProgress(progressPayload(99))
        switch end {
        case .reply: delegate.connector.reply(Data("{}".utf8))
        case .cancellation: call.cancel()
        case .transportError: connection.invalidate()
        }
        _ = await call.value
        try receiver.connectorDidReportProgress(progressPayload(100))
        #expect(published.withLock { $0 } == [99])
    }


}
#endif
