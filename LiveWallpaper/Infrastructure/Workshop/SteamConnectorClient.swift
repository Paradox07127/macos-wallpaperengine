#if !LITE_BUILD
import Foundation
import LiveWallpaperCore
import os
import Security

enum SteamCMDOperationScope {
    @TaskLocal static var currentID: String?
}

/// One connector call that ended without a reply.
struct SteamConnectorFailure: Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        case cancelled
        case timedOut(seconds: Int)
        case interrupted
        /// `hostSignatureStatus` is this app's own static signature check at the moment of failure; 0 = valid.
        case invalid(hostSignatureStatus: OSStatus)
        case other

        var label: String {
            switch self {
            case .cancelled: "cancelled"
            case let .timedOut(seconds): "timedOut(\(seconds)s)"
            case .interrupted: "interrupted"
            case let .invalid(status): "invalid(hostSignatureStatus=\(status))"
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

    /// nil for `.cancelled`: the caller left, so there is nothing to tell the user.
    var userFacingReason: String? {
        switch kind {
        case .cancelled:
            nil
        case .interrupted:
            String(localized: "Loomscreen's Steam connector quit unexpectedly while handling the request (XPC error 4097). Try again. If it keeps happening, use Copy reports under Diagnostics and send the result to the developer.", bundle: .appLanguage, comment: "Steam connector failure when the XPC service process exited mid-request.")
        case let .invalid(status) where status != errSecSuccess:
            String(localized: "Loomscreen's Steam connector refused the connection because Loomscreen's own code signature failed verification (OSStatus \(status)). Download Loomscreen again and reinstall it.", bundle: .appLanguage, comment: "Steam connector failure when the app's own code signature is broken; %d is the Security framework status code.")
        case .invalid:
            String(localized: "Loomscreen's Steam connector could not be started, or macOS closed the connection (XPC error 4099). Quit Loomscreen and open it again.", bundle: .appLanguage, comment: "Steam connector failure when the XPC connection was invalidated while the app's signature is intact.")
        case let .timedOut(seconds):
            String(localized: "Loomscreen's Steam connector did not reply within \(seconds) seconds.", bundle: .appLanguage, comment: "Steam connector failure when no reply arrived in time; %lld is the number of seconds.")
        case .other:
            String(localized: "Loomscreen's Steam connector failed to communicate (\(errorDomain ?? "XPC") error \(errorCode ?? 0)).", bundle: .appLanguage, comment: "Steam connector failure for any other XPC error; %1$@ is the error domain, %2$lld the error code.")
        }
    }
}

@MainActor
enum SteamConnectorClient {
    private static let serviceName = "com.loomscreen.pro.SteamConnector"

    static func discoverAccounts() async -> [SteamAccountSummary] {
        guard let data = await call({ connector, reply in
            connector.discoverAccounts(with: reply)
        }) else { return [] }
        return (try? JSONDecoder().decode([SteamAccountSummary].self, from: data)) ?? []
    }

    static func probeCachedLogin(accountName: String) async -> SteamCachedLoginResult? {
        guard let data = await call({ connector, reply in
            connector.probeCachedLogin(accountName: accountName, with: reply)
        }) else { return nil }
        return try? JSONDecoder().decode(SteamCachedLoginResult.self, from: data)
    }

    static func inspectSteamCMDBinary(path: String) async -> SteamCMDBinaryInspection? {
        let data = await call { connector, reply in
            connector.inspectSteamCMDBinary(path: path, with: reply)
        }
        return data.flatMap { try? JSONDecoder().decode(SteamCMDBinaryInspection.self, from: $0) }
    }

    static func bindManualSteamCMDBinary(path: String) async -> SteamCMDManualBindResult? {
        let data = await call { connector, reply in
            connector.bindManualSteamCMDBinary(path: path, with: reply)
        }
        return data.flatMap { try? JSONDecoder().decode(SteamCMDManualBindResult.self, from: $0) }
    }

    @discardableResult
    static func clearManualSteamCMDBinary() async -> SteamCMDManualBindResult? {
        let data = await call { connector, reply in
            connector.clearManualSteamCMDBinary(with: reply)
        }
        return data.flatMap { try? JSONDecoder().decode(SteamCMDManualBindResult.self, from: $0) }
    }

    /// The Mach-O the connector would execute, resolved from its own candidate
    /// list. Takes no path: the app does not get to name what runs.
    static func locateSteamCMDBinary() async -> SteamCMDBinaryLocation? {
        let data = await call { connector, reply in
            connector.locateSteamCMDBinary(with: reply)
        }
        return data.flatMap { try? JSONDecoder().decode(SteamCMDBinaryLocation.self, from: $0) }
    }

    static func installManagedSteamCMD() async -> SteamCMDManagedInstallResult? {
        let data = await call { connector, reply in
            connector.installManagedSteamCMD(with: reply)
        }
        return data.flatMap { try? JSONDecoder().decode(SteamCMDManagedInstallResult.self, from: $0) }
    }

    /// nil means the connector was unreachable.
    static func signInSteamAccount(
        accountName: String,
        password: String,
        guardCode: String? = nil
    ) async -> SteamCMDLoginResult? {
        let request = SteamCMDLoginRequest(
            accountName: accountName, password: password, guardCode: guardCode
        )
        guard let payload = try? JSONEncoder().encode(request) else { return nil }
        let data = await call { connector, reply in
            connector.signInSteamAccount(payload, with: reply)
        }
        return data.flatMap { try? JSONDecoder().decode(SteamCMDLoginResult.self, from: $0) }
    }

    static func removeManagedSteamCMD() async -> SteamCMDManagedRemovalResult? {
        let data = await call { connector, reply in
            connector.removeManagedSteamCMD(with: reply)
        }
        return data.flatMap { try? JSONDecoder().decode(SteamCMDManagedRemovalResult.self, from: $0) }
    }

    /// nil means the connector was unreachable.
    static func removeAccountSession(accountName: String) async -> SteamAccountSessionRemovalResult? {
        let data = await call { connector, reply in
            connector.removeAccountSession(accountName: accountName, with: reply)
        }
        return data.flatMap { try? JSONDecoder().decode(SteamAccountSessionRemovalResult.self, from: $0) }
    }

    /// nil means the connector was unreachable.
    static func diagnoseSteamCMD(
        launchTimeout: TimeInterval = SteamCMDDiagnosisProbe.defaultLaunchTimeout
    ) async -> SteamCMDDiagnosis? {
        let request = SteamCMDDiagnosisRequest(launchTimeout: launchTimeout)
        guard let payload = try? JSONEncoder().encode(request) else { return nil }
        let data = await call { connector, reply in
            connector.diagnoseSteamCMD(payload, with: reply)
        }
        return data.flatMap { try? JSONDecoder().decode(SteamCMDDiagnosis.self, from: $0) }
    }

    static func runSteamCMDProbe(
        arguments: [String],
        timeout: TimeInterval
    ) async -> SteamCMDProbeRun? {
        let request = SteamCMDProbeRequest(arguments: arguments, timeout: timeout)
        guard let payload = try? JSONEncoder().encode(request) else { return nil }
        let data = await call { connector, reply in
            connector.runSteamCMDProbe(payload, with: reply)
        }
        return data.flatMap { try? JSONDecoder().decode(SteamCMDProbeRun.self, from: $0) }
    }

    // MARK: - Long operations

    static func installWallpaperEngineAssets(
        accountName: String,
        libraryPath: String,
        operationID: String,
        onProgress: @escaping @Sendable (SteamOperationProgress) -> Void
    ) async -> SteamEngineAssetsResult? {
        let data = await call(onProgress: onProgress) { connector, reply in
            connector.installWallpaperEngineAssets(
                accountName: accountName,
                libraryPath: libraryPath,
                operationID: operationID,
                with: reply
            )
        }
        return data.flatMap { try? JSONDecoder().decode(SteamEngineAssetsResult.self, from: $0) }
    }

    /// Cancel identity comes from SteamCMDOperationScope, not a parameter. Outside a scope the run still registers under an id nobody holds — uncancellable.
    static func downloadWorkshopItem(
        workshopID: String,
        accountName: String,
        libraryPath: String,
        onProgress: @escaping @Sendable (SteamOperationProgress) -> Void
    ) async -> SteamWorkshopDownloadResult? {
        let operationID = SteamCMDOperationScope.currentID ?? UUID().uuidString
        let data = await call(onProgress: onProgress) { connector, reply in
            connector.downloadWorkshopItem(
                workshopID: workshopID,
                accountName: accountName,
                libraryPath: libraryPath,
                operationID: operationID,
                with: reply
            )
        }
        return data.flatMap { try? JSONDecoder().decode(SteamWorkshopDownloadResult.self, from: $0) }
    }

    /// nil means the connector was unreachable.
    static func listSubscribedWorkshopItems(accountName: String) async -> SteamSubscribedItemsResult? {
        let data = await call { connector, reply in
            connector.listSubscribedWorkshopItems(accountName: accountName, with: reply)
        }
        return data.flatMap { try? JSONDecoder().decode(SteamSubscribedItemsResult.self, from: $0) }
    }

    static func deleteWorkshopItem(workshopID: String, libraryPath: String) async -> SteamDeleteResult? {
        let data = await call { connector, reply in
            connector.deleteWorkshopItem(workshopID: workshopID, libraryPath: libraryPath, with: reply)
        }
        return data.flatMap { try? JSONDecoder().decode(SteamDeleteResult.self, from: $0) }
    }

    /// true = something was signalled; false = a different operation (or none) holds the queue; nil = connector unreachable.
    @discardableResult
    static func cancelActiveSteamCMD(operationID: String) async -> Bool? {
        let data = await call { connector, reply in
            connector.cancelActiveSteamCMD(operationID: operationID, with: reply)
        }
        return data.flatMap { try? JSONDecoder().decode(Bool.self, from: $0) }
    }

    static func latestWallpaperEngineBuildID(operationID: String) async -> SteamEngineBuildLookup? {
        let data = await call { connector, reply in
            connector.latestWallpaperEngineBuildID(operationID: operationID, with: reply)
        }
        guard let data else { return nil }
        // A reply we cannot decode is still a reply. Returning nil here would make the caller report the connector did not respond.
        return (try? JSONDecoder().decode(SteamEngineBuildLookup.self, from: data))
            ?? SteamEngineBuildLookup(outcome: .unrecognized, buildID: nil)
    }

    /// nil means the connector was unreachable.
    static func recentCrashReports() async -> [SteamConnectorCrashSummary]? {
        let data = await call(timeout: 30) { connector, reply in
            connector.recentCrashReports(with: reply)
        }
        return data.flatMap { try? JSONDecoder().decode([SteamConnectorCrashSummary].self, from: $0) }
    }

    // MARK: - Failure record

    private struct CallFailure: Error {
        enum Cause {
            case cancelled
            case timedOut(Int)
            case transport
        }

        let cause: Cause
        /// nil when no XPC error was delivered: cancellation, the timer, or a proxy of the wrong type.
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

    nonisolated static var lastFailure: SteamConnectorFailure? {
        failures.withLock { $0.last }
    }

    /// What to tell the user after a call came back nil.
    nonisolated static var unreachableReason: String {
        lastFailure?.userFacingReason ?? String(
            localized: "Loomscreen's Steam connector did not respond.",
            bundle: .appLanguage, comment: "Steam sign-in diagnostic when the XPC connector could not be reached."
        )
    }

    private nonisolated static func recordFailure(_ failure: CallFailure, call: String) {
        let error = failure.error
        let kind: SteamConnectorFailure.Kind
        switch failure.cause {
        case .cancelled: kind = .cancelled
        case let .timedOut(seconds): kind = .timedOut(seconds: seconds)
        case .transport where error?.domain == NSCocoaErrorDomain && error?.code == NSXPCConnectionInterrupted:
            kind = .interrupted
        case .transport where error?.domain == NSCocoaErrorDomain && error?.code == NSXPCConnectionInvalid:
            var code: SecStaticCode?
            var status = SecStaticCodeCreateWithPath(Bundle.main.bundleURL as CFURL, [], &code)
            if status == errSecSuccess, let code {
                status = SecStaticCodeCheckValidity(code, [], nil)
            }
            kind = .invalid(hostSignatureStatus: status)
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
        guard let data = await call(timeout: 30, { connector, reply in
            connector.probeEnvironment(with: reply)
        }) else { return nil }
        return try? JSONDecoder().decode(SteamConnectorEnvironmentProbe.self, from: data)
    }

    /// Tests substitute an in-process anonymous listener for the XPC service.
    nonisolated(unsafe) static var connectionFactoryForTesting: (@Sendable () -> NSXPCConnection)?
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

    /// One-shot request; nil means connector unreachable (not a Steam "no"). Honours `Task` cancellation: the connection is invalidated, which is how the connector learns the caller is gone — a cancelled operation still waiting in its queue then never runs.
    private static func call(
        // Client timeout above connector's 900s so the service expires first.
        timeout: TimeInterval = 7200,
        onProgress: (@Sendable (SteamOperationProgress) -> Void)? = nil,
        caller: String = #function,
        _ body: @escaping @Sendable (any SteamConnectorProtocol, @escaping @Sendable (Data) -> Void) -> Void
    ) async -> Data? {
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
        let pending = OSAllocatedUnfairLock<CheckedContinuation<Data?, Never>?>(initialState: nil)
        let finish: @Sendable (Result<Data, CallFailure>) -> Void = { outcome in
            let continuation = pending.withLock { box -> CheckedContinuation<Data?, Never>? in
                defer { box = nil }
                return box
            }
            guard let continuation else { return }
            progressReceiver?.close()
            switch outcome {
            case let .success(data):
                continuation.resume(returning: data)
            case let .failure(failure):
                // Recorded before resuming so the caller's message describes this failure, not the previous one.
                recordFailure(failure, call: caller)
                continuation.resume(returning: nil)
            }
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
