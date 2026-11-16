#if !LITE_BUILD
import Foundation
@testable import LiveWallpaper
import LiveWallpaperCore
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

    @Test("Engine queries and installs carry connection cancellation through child registration")
    func ownedOperationsCheckCancellationAtSpawn() throws {
        let source = try RepositoryRoot.source("SteamConnector/SteamConnector.swift")
        for (start, end, expectedCalls) in [
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
        /// Drops the client's connection from the listener side as soon as any request arrives.
        private let dropsConnection: Bool

        init(dropsConnection: Bool = false) {
            self.dropsConnection = dropsConnection
        }

        var hasReply: Bool {
            held.withLock { !$0.isEmpty }
        }

        func reply(_ data: Data) {
            held.withLock { $0.last }?(data)
        }

        private func hold(_ reply: @escaping @Sendable (Data) -> Void) {
            invoked.withLock { $0 = true }
            held.withLock { $0.append(reply) }
            if dropsConnection {
                NSXPCConnection.current()?.invalidate()
            }
        }

        func recentCrashReports(with reply: @escaping @Sendable (Data) -> Void) {
            hold(reply)
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
        let connector: SilentConnector

        init(dropsConnection: Bool = false) {
            connector = SilentConnector(dropsConnection: dropsConnection)
        }

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
        #expect(
            SteamConnectorClient.recentFailures.last { $0.call == "discoverAccounts()" }?.kind == .cancelled,
            "a cancelled wait was recorded as a connector fault, so the next message blames the connector for the user leaving"
        )
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

    @Test("leaving the page mid-check leaves the identity probe unrun instead of blaming the connector", .timeLimit(.minutes(1)))
    @MainActor
    func cancelledIdentityProbeStaysNotRun() async throws {
        let listener = NSXPCListener.anonymous()
        let delegate = Delegate()
        listener.delegate = delegate
        listener.resume()
        let endpoint = listener.endpoint
        SteamConnectorClient.connectionFactoryForTesting = { NSXPCConnection(listenerEndpoint: endpoint) }
        let scratch = try TestScratch.defaultsSuite(prefix: "connector-cancelled-probe")
        defer {
            SteamConnectorClient.connectionFactoryForTesting = nil
            listener.invalidate()
            scratch.defaults.removePersistentDomain(forName: scratch.name)
        }
        let doctor = SteamCMDDoctorService(defaults: scratch.defaults)
        doctor.binaryPath = "/bin/ls"

        let probe = Task { await doctor.runProbe(.binaryIdentity) }
        for _ in 0 ..< 50 where !delegate.connector.invoked.withLock({ $0 }) {
            try await Task.sleep(for: .milliseconds(20))
        }
        try #require(delegate.connector.invoked.withLock { $0 })
        probe.cancel()
        for _ in 0 ..< 150 where doctor.probes[.binaryIdentity]?.status == .running {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(
            doctor.probes[.binaryIdentity]?.status == .notRun,
            "a cancelled check was stored as a connector failure, and autoConfigureIfNeeded never re-runs a probe that is not .notRun"
        )
    }

    @Test("a connection dropped mid-request records why, and the export carries it", .timeLimit(.minutes(1)))
    @MainActor
    func droppedConnectionIsRecordedAndExported() async throws {
        let listener = NSXPCListener.anonymous()
        let delegate = Delegate(dropsConnection: true)
        listener.delegate = delegate
        listener.resume()
        let endpoint = listener.endpoint
        SteamConnectorClient.connectionFactoryForTesting = { NSXPCConnection(listenerEndpoint: endpoint) }
        let scratch = try TestScratch.defaultsSuite(prefix: "connector-dropped")
        defer {
            SteamConnectorClient.connectionFactoryForTesting = nil
            listener.invalidate()
            scratch.defaults.removePersistentDomain(forName: scratch.name)
        }

        #expect(await SteamConnectorClient.discoverAccounts().isEmpty)
        #expect(delegate.connector.invoked.withLock { $0 })
        let failure = try #require(SteamConnectorClient.recentFailures.last { $0.call == "discoverAccounts()" })
        // The listener dropping the peer is what a crashed service looks like from the client side.
        #expect(failure.errorDomain == NSCocoaErrorDomain)
        #expect(failure.errorCode == NSXPCConnectionInterrupted)
        #expect(failure.kind == .interrupted)
        #expect(failure.userFacingReason.contains("4097"))

        let doctor = SteamCMDDoctorService(defaults: scratch.defaults)
        let json = try #require(await doctor.diagnosticsJSON())
        let report = try #require(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        let exported = try #require(report["connectorFailures"] as? [[String: Any]])
        #expect(exported.contains {
            $0["call"] as? String == "discoverAccounts()" && $0["kind"] as? String == "interrupted"
                && $0["errorCode"] as? Int == NSXPCConnectionInterrupted
        })
        let crashes = try #require(report["connectorCrashReports"] as? [String: Any])
        #expect(crashes["status"] as? String == "unavailable")
    }

    /// `NSXPCListener.delegate` is weak: the caller keeps `delegate` alive for as long as the listener is used.
    @MainActor
    private func listen(_ delegate: Delegate) -> NSXPCListener {
        let listener = NSXPCListener.anonymous()
        listener.delegate = delegate
        listener.resume()
        let endpoint = listener.endpoint
        SteamConnectorClient.connectionFactoryForTesting = { NSXPCConnection(listenerEndpoint: endpoint) }
        return listener
    }

    @Test("a reply the app cannot read is reported as unreadable, not as an earlier call's failure", .timeLimit(.minutes(1)))
    @MainActor
    func undecodableReplyKeepsItsOwnReason() async throws {
        let scratch = try TestScratch.defaultsSuite(prefix: "connector-undecodable")
        defer {
            SteamConnectorClient.connectionFactoryForTesting = nil
            scratch.defaults.removePersistentDomain(forName: scratch.name)
        }
        let dropping = Delegate(dropsConnection: true)
        let droppingListener = listen(dropping)
        defer { droppingListener.invalidate() }
        #expect(await SteamConnectorClient.discoverAccounts().isEmpty)
        try #require(SteamConnectorClient.recentFailures.last?.kind == .interrupted)

        let garbled = Delegate()
        let garbledListener = listen(garbled)
        defer { garbledListener.invalidate() }
        let doctor = SteamCMDDoctorService(defaults: scratch.defaults)
        doctor.binaryPath = "/bin/ls"
        let probe = Task { await doctor.runProbe(.codeSignature) }
        for _ in 0 ..< 50 where !garbled.connector.hasReply {
            try await Task.sleep(for: .milliseconds(20))
        }
        try #require(garbled.connector.hasReply)
        garbled.connector.reply(Data("not json".utf8))
        await probe.value

        guard case let .yellow(message, _) = doctor.probes[.codeSignature]?.status else {
            Issue.record("an unreadable inspection reply must leave the signature unverified"); return
        }
        #expect(!message.contains("4097"), "the probe blamed the earlier dropped connection for a reply it could not read")
        #expect(message == SteamConnectorFailure.fixture(.undecodable).userFacingReason)

        let direct = Delegate()
        let directListener = listen(direct)
        defer { directListener.invalidate() }
        let inspection = Task { await SteamConnectorClient.inspectSteamCMDBinary(path: "/bin/ls") }
        for _ in 0 ..< 50 where !direct.connector.hasReply {
            try await Task.sleep(for: .milliseconds(20))
        }
        try #require(direct.connector.hasReply)
        direct.connector.reply(Data("not json".utf8))
        guard case let .failure(failure) = await inspection.value else {
            Issue.record("a reply that does not decode was returned as an inspection"); return
        }
        #expect(failure.kind == .undecodable)
        #expect(SteamConnectorClient.recentFailures.last { $0.call == "inspectSteamCMDBinary(path:)" } == failure)
    }

    @Test("a usable copy the bind then refuses as busy says busy, not that the connector is silent", .timeLimit(.minutes(1)))
    @MainActor
    func refusedAutoDetectBindShowsTheRefusal() async throws {
        let scratch = try TestScratch.defaultsSuite(prefix: "connector-busy-bind")
        let connected = Delegate()
        let listener = listen(connected)
        defer {
            SteamConnectorClient.connectionFactoryForTesting = nil
            listener.invalidate()
            scratch.defaults.removePersistentDomain(forName: scratch.name)
        }
        let usable = SteamCMDDiagnosis(
            source: .homebrew, canonicalPath: "/opt/homebrew/bin/steamcmd", resolutionFailure: nil, sha256: "digest",
            signature: SteamCMDSignatureVerdict(isValid: true, teamIdentifier: "MXGJJ98X76", isHardenedRuntime: true),
            isQuarantined: false,
            launch: SteamCMDLaunchProbe(outcome: .succeeded, arguments: SteamCMDDiagnosisProbe.arguments, exitCode: 0, timeout: 180, outputTail: ""),
            unavailableReason: nil
        )
        try #require(usable.isUsable && usable.remedy == nil)
        let doctor = SteamCMDDoctorService(defaults: scratch.defaults, diagnoseBinary: { .success(usable) })
        let controller = WorkshopSetupController(doctor: doctor, defaults: scratch.defaults)

        let detect = controller.autoDetectBinary()
        for _ in 0 ..< 50 where !connected.connector.hasReply {
            try await Task.sleep(for: .milliseconds(20))
        }
        try #require(connected.connector.hasReply)
        try connected.connector.reply(JSONEncoder().encode(SteamCMDBinaryInspection.unavailable("busy")))
        await detect.value

        #expect(!doctor.hasBoundBinary)
        #expect(doctor.lastAutoDetectBindError == .connectorBusy)
        #expect(controller.setupError == SteamCMDDoctorError.connectorBusy.localizedDescription)
    }
}

@Suite("Steam connector crash report parsing")
struct SteamConnectorCrashSummaryTests {
    @Test("an .ips report yields the exception, signal, asi and the crashed thread's frames")
    func parsesRealShape() throws {
        let header = #"{"app_name":"SteamConnector","timestamp":"2026-11-16 12:34:56.00 -0500","app_version":"1.0.1","bug_type":"309","name":"SteamConnector"}"#
        let body = #"""
        {
          "uptime" : 100,
          "exception" : {"codes":"0x0000000000000001, 0x00000001a2b3c4d5","type":"EXC_BREAKPOINT","signal":"SIGTRAP"},
          "termination" : {"flags":0,"code":5,"namespace":"SIGNAL","indicator":"Trace/BPT trap: 5","byProc":"exc handler","byPid":4242},
          "asi" : {"libswiftCore.dylib":["SteamConnector/SteamCMDProfile.swift:88: Fatal error: Unexpectedly found nil while unwrapping an Optional value"]},
          "faultingThread" : 1,
          "threads" : [
            {"id":1,"frames":[{"imageOffset":4096,"symbol":"mach_msg2_trap","imageIndex":1}]},
            {"triggered":true,"id":2,"frames":[
              {"imageOffset":30000,"symbol":"_assertionFailure(_:_:file:line:flags:)","imageIndex":1},
              {"imageOffset":5120,"sourceLine":88,"sourceFile":"SteamCMDProfile.swift","symbol":"static SteamCMDProfile.accounts()","imageIndex":0},
              {"imageOffset":2748,"imageIndex":0},
              {"imageOffset":12,"imageIndex":9},
              {"imageOffset":1,"imageIndex":0},
              {"imageOffset":2,"imageIndex":0},
              {"imageOffset":3,"imageIndex":0},
              {"imageOffset":4,"imageIndex":0},
              {"imageOffset":5,"imageIndex":0}
            ]}
          ],
          "usedImages" : [
            {"source":"P","arch":"arm64","name":"SteamConnector","path":"\/Applications\/Loomscreen Pro.app\/Contents\/XPCServices\/SteamConnector.xpc\/Contents\/MacOS\/SteamConnector"},
            {"source":"P","arch":"arm64e","name":"libswiftCore.dylib"}
          ]
        }
        """#
        let summary = try #require(SteamConnectorCrashSummary.parse(ipsText: header + "\n" + body))
        #expect(summary.timestamp == "2026-11-16T12:34:56.00-0500")
        #expect(LogPrivacyRedactor.scrub(summary.timestamp ?? "") == summary.timestamp, "the crash time was redacted as an IPv6 address")
        #expect(summary.appVersion == "1.0.1")
        #expect(summary.exceptionType == "EXC_BREAKPOINT")
        #expect(summary.signal == "SIGTRAP")
        #expect(summary.termination == "Trace/BPT trap: 5")
        #expect(summary.asi == ["SteamConnector/SteamCMDProfile.swift:88: Fatal error: Unexpectedly found nil while unwrapping an Optional value"])
        #expect(summary.crashedThreadFrames.count == SteamConnectorCrashSummary.frameLimit)
        #expect(summary.crashedThreadFrames[0] == .init(image: "libswiftCore.dylib", symbol: "_assertionFailure(_:_:file:line:flags:)", source: nil))
        #expect(summary.crashedThreadFrames[1] == .init(image: "SteamConnector", symbol: "static SteamCMDProfile.accounts()", source: "SteamCMDProfile.swift:88"))
        #expect(summary.crashedThreadFrames[2] == .init(image: "SteamConnector", symbol: "0xabc", source: nil))
        #expect(summary.crashedThreadFrames[3].image == "???")
    }

    @Test("text that is not an .ips report is rejected")
    func rejectsNonJSON() {
        #expect(SteamConnectorCrashSummary.parse(ipsText: "Process: SteamConnector [4242]\nException Type: EXC_CRASH") == nil)
        #expect(SteamConnectorCrashSummary.parse(ipsText: "") == nil)
    }

}
#endif
