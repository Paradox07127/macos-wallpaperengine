#if !LITE_BUILD
import Foundation
import LiveWallpaperCore
import os
import Security

enum SteamCMDOperationScope {
    @TaskLocal static var currentID: String?
}

/// One connector call that ended without a usable reply.
struct SteamConnectorFailure: Error, Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        case cancelled
        case timedOut(seconds: Int)
        case interrupted
        /// `hostSignatureStatus` is this app's own static signature check at the moment of failure; 0 = valid.
        case invalid(hostSignatureStatus: OSStatus)
        /// The connector replied, but with data this build cannot decode.
        case undecodable
        case other

        var label: String {
            switch self {
            case .cancelled: "cancelled"
            case let .timedOut(seconds): "timedOut(\(seconds)s)"
            case .interrupted: "interrupted"
            case let .invalid(status): "invalid(hostSignatureStatus=\(status))"
            case .undecodable: "undecodable"
            case .other: "other"
            }
        }
    }

    let date: Date
    let call: String
    let kind: Kind
    let errorDomain: String?
    let errorCode: Int?
    let debugDescription: String?

    var userFacingReason: String {
        switch kind {
        case .cancelled:
            String(localized: "The request was cancelled before Loomscreen's Steam connector replied.", bundle: .appLanguage, comment: "Steam connector failure when the caller cancelled the request before a reply arrived.")
        case .undecodable:
            String(localized: "Loomscreen's Steam connector sent a reply this version of Loomscreen can't read. Download Loomscreen again and reinstall it.", bundle: .appLanguage, comment: "Steam connector failure when the XPC reply could not be decoded, usually a mismatched app and connector build.")
        case .interrupted:
            String(localized: "Loomscreen's Steam connector quit unexpectedly while handling the request (XPC error 4097). Try again. If it keeps happening, use Copy reports under Diagnostics and send the result to the developer.", bundle: .appLanguage, comment: "Steam connector failure when the XPC service process exited mid-request.")
        case let .invalid(status) where status != errSecSuccess:
            String(localized: "Loomscreen's Steam connector refused the connection because Loomscreen's own code signature failed verification (OSStatus \(String(status))). Download Loomscreen again and reinstall it.", bundle: .appLanguage, comment: "Steam connector failure when the app's own code signature is broken; %@ is the Security framework status code, unformatted so it can be searched.")
        case .invalid:
            String(localized: "Loomscreen's Steam connector could not be started, or macOS closed the connection (XPC error 4099). Quit Loomscreen and open it again.", bundle: .appLanguage, comment: "Steam connector failure when the XPC connection was invalidated while the app's signature is intact.")
        case let .timedOut(seconds):
            String(localized: "Loomscreen's Steam connector did not reply within \(seconds) seconds.", bundle: .appLanguage, comment: "Steam connector failure when no reply arrived in time; %lld is the number of seconds.")
        case .other:
            String(localized: "Loomscreen's Steam connector failed to communicate (\(errorDomain ?? "XPC") error \(String(errorCode ?? 0))).", bundle: .appLanguage, comment: "Steam connector failure for any other XPC error; %1$@ is the error domain, %2$@ the error code, unformatted so it can be searched.")
        }
    }
}

@MainActor
enum SteamConnectorClient {
    private static let serviceName = "com.loomscreen.pro.SteamConnector"

    static func discoverAccounts() async -> [SteamAccountSummary] {
        let reply = await call(retryOnInterrupt: true) { connector, reply in
            connector.discoverAccounts(with: reply)
        }
        return (try? decode([SteamAccountSummary].self, reply).get()) ?? []
    }

    static func probeCachedLogin(accountName: String) async -> Result<SteamCachedLoginResult, SteamConnectorFailure> {
        let reply = await call { connector, reply in
            connector.probeCachedLogin(accountName: accountName, with: reply)
        }
        return decode(SteamCachedLoginResult.self, reply)
    }

    static func inspectSteamCMDBinary(path: String) async -> Result<SteamCMDBinaryInspection, SteamConnectorFailure> {
        let reply = await call(retryOnInterrupt: true) { connector, reply in
            connector.inspectSteamCMDBinary(path: path, with: reply)
        }
        return decode(SteamCMDBinaryInspection.self, reply)
    }

    static func bindManualSteamCMDBinary(path: String) async -> Result<SteamCMDManualBindResult, SteamConnectorFailure> {
        let reply = await call { connector, reply in
            connector.bindManualSteamCMDBinary(path: path, with: reply)
        }
        return decode(SteamCMDManualBindResult.self, reply)
    }

    @discardableResult
    static func clearManualSteamCMDBinary() async -> SteamCMDManualBindResult? {
        let reply = await call { connector, reply in
            connector.clearManualSteamCMDBinary(with: reply)
        }
        return try? decode(SteamCMDManualBindResult.self, reply).get()
    }

    /// The Mach-O the connector would execute, resolved from its own candidate
    /// list. Takes no path: the app does not get to name what runs.
    static func locateSteamCMDBinary() async -> Result<SteamCMDBinaryLocation, SteamConnectorFailure> {
        let reply = await call(retryOnInterrupt: true) { connector, reply in
            connector.locateSteamCMDBinary(with: reply)
        }
        return decode(SteamCMDBinaryLocation.self, reply)
    }

    static func installManagedSteamCMD() async -> Result<SteamCMDManagedInstallResult, SteamConnectorFailure> {
        let reply = await call { connector, reply in
            connector.installManagedSteamCMD(with: reply)
        }
        return decode(SteamCMDManagedInstallResult.self, reply)
    }

    static func signInSteamAccount(
        accountName: String,
        password: String,
        guardCode: String? = nil
    ) async -> Result<SteamCMDLoginResult, SteamConnectorFailure> {
        let request = SteamCMDLoginRequest(
            accountName: accountName, password: password, guardCode: guardCode
        )
        let payload: Data
        do {
            payload = try JSONEncoder().encode(request)
        } catch {
            return .failure(recordFailure(CallFailure(cause: .transport, error: error as NSError), call: #function))
        }
        let reply = await call { connector, reply in
            connector.signInSteamAccount(payload, with: reply)
        }
        return decode(SteamCMDLoginResult.self, reply)
    }

    static func removeManagedSteamCMD() async -> Result<SteamCMDManagedRemovalResult, SteamConnectorFailure> {
        let reply = await call { connector, reply in
            connector.removeManagedSteamCMD(with: reply)
        }
        return decode(SteamCMDManagedRemovalResult.self, reply)
    }

    static func removeAccountSession(accountName: String) async -> Result<SteamAccountSessionRemovalResult, SteamConnectorFailure> {
        let reply = await call { connector, reply in
            connector.removeAccountSession(accountName: accountName, with: reply)
        }
        return decode(SteamAccountSessionRemovalResult.self, reply)
    }

    static func diagnoseSteamCMD(
        launchTimeout: TimeInterval = SteamCMDDiagnosisProbe.defaultLaunchTimeout
    ) async -> Result<SteamCMDDiagnosis, SteamConnectorFailure> {
        let request = SteamCMDDiagnosisRequest(launchTimeout: launchTimeout)
        let payload: Data
        do {
            payload = try JSONEncoder().encode(request)
        } catch {
            return .failure(recordFailure(CallFailure(cause: .transport, error: error as NSError), call: #function))
        }
        let reply = await call { connector, reply in
            connector.diagnoseSteamCMD(payload, with: reply)
        }
        return decode(SteamCMDDiagnosis.self, reply)
    }

    static func runSteamCMDProbe(
        arguments: [String],
        timeout: TimeInterval
    ) async -> Result<SteamCMDProbeRun, SteamConnectorFailure> {
        let request = SteamCMDProbeRequest(arguments: arguments, timeout: timeout)
        let payload: Data
        do {
            payload = try JSONEncoder().encode(request)
        } catch {
            return .failure(recordFailure(CallFailure(cause: .transport, error: error as NSError), call: #function))
        }
        let reply = await call { connector, reply in
            connector.runSteamCMDProbe(payload, with: reply)
        }
        return decode(SteamCMDProbeRun.self, reply)
    }

    // MARK: - Long operations

    static func installWallpaperEngineAssets(
        accountName: String,
        libraryPath: String,
        operationID: String,
        onProgress: @escaping @Sendable (SteamOperationProgress) -> Void
    ) async -> Result<SteamEngineAssetsResult, SteamConnectorFailure> {
        let reply = await call(onProgress: onProgress) { connector, reply in
            connector.installWallpaperEngineAssets(
                accountName: accountName,
                libraryPath: libraryPath,
                operationID: operationID,
                with: reply
            )
        }
        return decode(SteamEngineAssetsResult.self, reply)
    }

    /// Cancel identity comes from SteamCMDOperationScope, not a parameter. Outside a scope the run still registers under an id nobody holds — uncancellable.
    static func downloadWorkshopItem(
        workshopID: String,
        accountName: String,
        libraryPath: String,
        onProgress: @escaping @Sendable (SteamOperationProgress) -> Void
    ) async -> Result<SteamWorkshopDownloadResult, SteamConnectorFailure> {
        let operationID = SteamCMDOperationScope.currentID ?? UUID().uuidString
        let reply = await call(onProgress: onProgress) { connector, reply in
            connector.downloadWorkshopItem(
                workshopID: workshopID,
                accountName: accountName,
                libraryPath: libraryPath,
                operationID: operationID,
                with: reply
            )
        }
        return decode(SteamWorkshopDownloadResult.self, reply)
    }

    static func listSubscribedWorkshopItems(accountName: String) async -> Result<SteamSubscribedItemsResult, SteamConnectorFailure> {
        let reply = await call { connector, reply in
            connector.listSubscribedWorkshopItems(accountName: accountName, with: reply)
        }
        return decode(SteamSubscribedItemsResult.self, reply)
    }

    static func deleteWorkshopItem(workshopID: String, libraryPath: String) async -> SteamDeleteResult? {
        let reply = await call { connector, reply in
            connector.deleteWorkshopItem(workshopID: workshopID, libraryPath: libraryPath, with: reply)
        }
        return try? decode(SteamDeleteResult.self, reply).get()
    }

    /// true = something was signalled; false = a different operation (or none) holds the queue; nil = connector unreachable.
    @discardableResult
    static func cancelActiveSteamCMD(operationID: String) async -> Bool? {
        let reply = await call { connector, reply in
            connector.cancelActiveSteamCMD(operationID: operationID, with: reply)
        }
        return try? decode(Bool.self, reply).get()
    }

    static func latestWallpaperEngineBuildID(operationID: String) async -> Result<SteamEngineBuildLookup, SteamConnectorFailure> {
        let reply = await call { connector, reply in
            connector.latestWallpaperEngineBuildID(operationID: operationID, with: reply)
        }
        // A reply we cannot decode still proves Steam was asked; the caller reports it as unparsed output.
        return reply.map { data in
            (try? JSONDecoder().decode(SteamEngineBuildLookup.self, from: data))
                ?? SteamEngineBuildLookup(outcome: .unrecognized, buildID: nil)
        }
    }

    /// nil means the connector was unreachable.
    static func recentCrashReports() async -> [SteamConnectorCrashSummary]? {
        let reply = await call(timeout: 5, retryOnInterrupt: true) { connector, reply in
            connector.recentCrashReports(with: reply)
        }
        return try? decode([SteamConnectorCrashSummary].self, reply).get()
    }

    /// A reply that does not decode is recorded as its own failure, so the caller never reports someone else's.
    private static func decode<Value: Decodable>(
        _ type: Value.Type,
        _ reply: Result<Data, SteamConnectorFailure>,
        caller: String = #function
    ) -> Result<Value, SteamConnectorFailure> {
        reply.flatMap { data in
            do {
                return try .success(JSONDecoder().decode(type, from: data))
            } catch {
                return .failure(recordFailure(CallFailure(cause: .undecodable), call: caller))
            }
        }
    }

    // MARK: - Failure record

    private struct CallFailure: Error {
        enum Cause {
            case cancelled
            case timedOut(Int)
            case transport
            case undecodable
        }

        let cause: Cause
        /// nil when no XPC error was delivered: cancellation, the timer, a proxy of the wrong type, or an undecodable reply.
        var error: NSError?
    }

    private nonisolated static let failureLimit = 20
    private nonisolated static let failures = OSAllocatedUnfairLock<[SteamConnectorFailure]>(initialState: [])
    private nonisolated static let crashLogPending = OSAllocatedUnfairLock(initialState: false)
    /// The newest report is returned even when no new crash happened; this keeps it from being logged again.
    private static var lastLoggedCrashTimestamp: String?

    /// Oldest first.
    nonisolated static var recentFailures: [SteamConnectorFailure] {
        failures.withLock { $0 }
    }

    private nonisolated static func recordFailure(_ failure: CallFailure, call: String) -> SteamConnectorFailure {
        let error = failure.error
        let kind: SteamConnectorFailure.Kind
        switch failure.cause {
        case .cancelled: kind = .cancelled
        case let .timedOut(seconds): kind = .timedOut(seconds: seconds)
        case .undecodable: kind = .undecodable
        case .transport where error?.domain == NSCocoaErrorDomain && error?.code == NSXPCConnectionInterrupted:
            // A connector that refuses this app's broken signature reads as 4097 here, not 4099.
            let status = hostSignatureStatus()
            kind = status == errSecSuccess ? .interrupted : .invalid(hostSignatureStatus: status)
        case .transport where error?.domain == NSCocoaErrorDomain && error?.code == NSXPCConnectionInvalid:
            kind = .invalid(hostSignatureStatus: hostSignatureStatus())
        case .transport: kind = .other
        }
        let record = SteamConnectorFailure(
            date: Date(), call: call, kind: kind,
            errorDomain: error?.domain, errorCode: error?.code,
            debugDescription: error?.userInfo[NSDebugDescriptionErrorKey] as? String
        )
        failures.withLock { list in
            list.append(record)
            list.removeFirst(max(0, list.count - failureLimit))
        }
        let line = "Steam connector call \(call) failed: \(kind.label)"
            + (error.map { " \($0.domain) \($0.code)" } ?? "")
            + (record.debugDescription.map { " — \($0)" } ?? "")
        if kind == .cancelled {
            Logger.notice(line, category: .workshop)
        } else {
            Logger.warning(line, category: .workshop)
        }
        if kind == .interrupted {
            scheduleCrashSummaryLog()
        }
        return record
    }

    /// This app's own static signature check; 0 = valid.
    private nonisolated static func hostSignatureStatus() -> OSStatus {
        #if DEBUG
        if let hostSignatureStatusForTesting {
            return hostSignatureStatusForTesting()
        }
        #endif
        var code: SecStaticCode?
        var status = SecStaticCodeCreateWithPath(Bundle.main.bundleURL as CFURL, [], &code)
        if status == errSecSuccess, let code {
            status = SecStaticCodeCheckValidity(code, [], nil)
        }
        return status
    }

    /// macOS writes the `.ips` a few seconds after the process dies, so the fetch waits before asking.
    private nonisolated static func scheduleCrashSummaryLog() {
        let alreadyPending = crashLogPending.withLock { pending in
            defer { pending = true }
            return pending
        }
        guard !alreadyPending else { return }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 10) {
            Task { @MainActor in
                defer { crashLogPending.withLock { $0 = false } }
                guard let latest = await recentCrashReports()?.first,
                      latest.timestamp != lastLoggedCrashTimestamp else { return }
                lastLoggedCrashTimestamp = latest.timestamp
                let frames = latest.crashedThreadFrames
                    .map { "\($0.image) \($0.symbol)" + ($0.source.map { " (\($0))" } ?? "") }
                    .joined(separator: " | ")
                Logger.warning(
                    "Steam connector crash \(latest.timestamp ?? "?"): \(latest.exceptionType ?? "?") \(latest.signal ?? "?")"
                        + " asi=\(latest.asi.joined(separator: " / ")) frames=\(frames)",
                    category: .workshop
                )
            }
        }
    }

    // MARK: - Transport

    private final class ProgressReceiver: NSObject, SteamConnectorProgressProtocol {
        private let closed = OSAllocatedUnfairLock(initialState: false)
        private let handler: @Sendable (SteamOperationProgress) -> Void

        init(handler: @escaping @Sendable (SteamOperationProgress) -> Void) {
            self.handler = handler
        }

        func connectorDidReportProgress(_ payload: Data) {
            guard let progress = try? JSONDecoder().decode(SteamOperationProgress.self, from: payload) else { return }
            // Delivered under the lock so that once `close()` returns, no progress can follow the terminal result.
            closed.withLock { isClosed in
                guard !isClosed else { return }
                handler(progress)
            }
        }

        func close() {
            closed.withLock { $0 = true }
        }
    }

    #if DEBUG
    static func probeEnvironmentForTesting() async -> SteamConnectorEnvironmentProbe? {
        let reply = await call(timeout: 30) { connector, reply in
            connector.probeEnvironment(with: reply)
        }
        return try? decode(SteamConnectorEnvironmentProbe.self, reply).get()
    }

    /// Tests substitute an in-process anonymous listener for the XPC service.
    nonisolated(unsafe) static var connectionFactoryForTesting: (@Sendable () -> NSXPCConnection)?
    /// Tests substitute this app's signature check. `nonisolated(unsafe)`: only the `.serialized` connector suite sets it, before its calls start and after they end.
    nonisolated(unsafe) static var hostSignatureStatusForTesting: (@Sendable () -> OSStatus)?
    #endif

    /// Sticky: a wait cancelled by termination has already returned, yet the child it started may still be running.
    private static var didUseConnector = false

    static var hasUsedConnector: Bool {
        didUseConnector
    }

    /// The app is quitting: SIGTERM whatever SteamCMD child is running. The connection-invalidation path in the connector covers a crash on its own; this makes Cmd+Q and Sparkle's quit deterministic instead of a race with launchd reaping the service.
    static func terminateActiveSteamCMDForHostExit() async {
        guard hasUsedConnector else { return }
        _ = await call(timeout: 1) { connector, reply in
            connector.terminateActiveSteamCMDForHostExit(with: reply)
        }
    }

    private static func makeConnection() -> NSXPCConnection {
        #if DEBUG
        if let connectionFactoryForTesting {
            return connectionFactoryForTesting()
        }
        #endif
        return NSXPCConnection(serviceName: serviceName)
    }

    /// One-shot request; a failure means the connector gave no reply (not a Steam "no"). Honours `Task` cancellation: the connection is invalidated, which is how the connector learns the caller is gone — a cancelled operation still waiting in its queue then never runs.
    private static func call(
        // Client timeout above connector's 900s so the service expires first.
        timeout: TimeInterval = 7200,
        onProgress: (@Sendable (SteamOperationProgress) -> Void)? = nil,
        // Only for calls that never start SteamCMD: a crashed connector can leave its steamcmd child running, and a second one would share its directory.
        retryOnInterrupt: Bool = false,
        caller: String = #function,
        _ body: @escaping @Sendable (any SteamConnectorProtocol, @escaping @Sendable (Data) -> Void) -> Void
    ) async -> Result<Data, SteamConnectorFailure> {
        if retryOnInterrupt {
            precondition(onProgress == nil, "a retried call would replay progress the caller already saw")
            let first = await call(timeout: timeout, caller: caller, body)
            guard case let .failure(failure) = first, failure.kind == .interrupted, !Task.isCancelled else { return first }
            let second = await call(timeout: timeout, caller: caller, body)
            if case .success = second {
                Logger.notice("Steam connector call \(caller) succeeded on retry after the connector quit", category: .workshop)
            }
            return second
        }
        // `nonisolated(unsafe)`: the cancellation handler is the only off-actor user and it calls `invalidate()`, which NSXPCConnection serves from any thread.
        nonisolated(unsafe) let connection = makeConnection()
        connection.remoteObjectInterface = NSXPCInterface(with: (any SteamConnectorProtocol).self)
        let progressReceiver = onProgress.map { ProgressReceiver(handler: $0) }
        if let progressReceiver {
            connection.exportedInterface = NSXPCInterface(with: (any SteamConnectorProgressProtocol).self)
            connection.exportedObject = progressReceiver
        }
        didUseConnector = true
        connection.resume()
        defer { connection.invalidate() }

        // The reply, the error handler, the timeout and cancellation can all
        // fire; whichever takes the continuation out of the box owns it.
        let pending = OSAllocatedUnfairLock<CheckedContinuation<Result<Data, SteamConnectorFailure>, Never>?>(initialState: nil)
        let finish: @Sendable (Result<Data, CallFailure>) -> Void = { outcome in
            let continuation = pending.withLock { box -> CheckedContinuation<Result<Data, SteamConnectorFailure>, Never>? in
                defer { box = nil }
                return box
            }
            guard let continuation else { return }
            progressReceiver?.close()
            continuation.resume(returning: outcome.mapError { recordFailure($0, call: caller) })
        }

        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                pending.withLock { $0 = continuation }
                // The cancellation handler may already have run before the box was filled.
                if Task.isCancelled {
                    finish(.failure(CallFailure(cause: .cancelled)))
                    return
                }
                // Runs on the XPC queue: explicitly @Sendable, or it inherits this function's main-actor isolation and traps there.
                let proxy = connection.remoteObjectProxyWithErrorHandler { @Sendable error in
                    finish(.failure(CallFailure(cause: .transport, error: error as NSError)))
                }
                guard let connector = proxy as? any SteamConnectorProtocol else {
                    finish(.failure(CallFailure(cause: .transport)))
                    return
                }
                DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout) {
                    finish(.failure(CallFailure(cause: .timedOut(Int(timeout)))))
                }
                body(connector) { finish(.success($0)) }
            }
        } onCancel: {
            finish(.failure(CallFailure(cause: .cancelled)))
            connection.invalidate()
        }
    }
}
#endif
