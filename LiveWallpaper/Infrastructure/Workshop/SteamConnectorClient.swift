#if !LITE_BUILD
import Foundation
import LiveWallpaperCore
import os

enum SteamCMDOperationScope {
    @TaskLocal static var currentID: String?
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

    // MARK: - Transport

    private final class ProgressReceiver: NSObject, SteamConnectorProgressProtocol {
        private let handler: @Sendable (SteamOperationProgress) -> Void

        init(handler: @escaping @Sendable (SteamOperationProgress) -> Void) {
            self.handler = handler
        }

        func connectorDidReportProgress(_ payload: Data) {
            guard let progress = try? JSONDecoder().decode(SteamOperationProgress.self, from: payload) else { return }
            handler(progress)
        }
    }

    /// One-shot request; nil means connector unreachable (not a Steam "no").
    private static func call(
        // Client timeout above connector's 900s so the service expires first.
        timeout: TimeInterval = 7200,
        onProgress: (@Sendable (SteamOperationProgress) -> Void)? = nil,
        _ body: @escaping @Sendable (any SteamConnectorProtocol, @escaping @Sendable (Data) -> Void) -> Void
    ) async -> Data? {
        let connection = NSXPCConnection(serviceName: serviceName)
        connection.remoteObjectInterface = NSXPCInterface(with: (any SteamConnectorProtocol).self)
        if let onProgress {
            connection.exportedInterface = NSXPCInterface(with: (any SteamConnectorProgressProtocol).self)
            connection.exportedObject = ProgressReceiver(handler: onProgress)
        }
        connection.resume()
        defer { connection.invalidate() }

        // Both the reply and the error handler can fire; whichever lands first
        // owns the continuation.
        let settled = OSAllocatedUnfairLock(initialState: false)
        return await withCheckedContinuation { continuation in
            @Sendable func finish(_ value: Data?) {
                let alreadySettled = settled.withLock { done -> Bool in
                    if done { return true }
                    done = true
                    return false
                }
                guard !alreadySettled else { return }
                continuation.resume(returning: value)
            }

            let proxy = connection.remoteObjectProxyWithErrorHandler { error in
                Logger.warning(
                    "Steam connector unreachable: \(error.localizedDescription)",
                    category: .workshop
                )
                finish(nil)
            }
            guard let connector = proxy as? any SteamConnectorProtocol else {
                finish(nil)
                return
            }
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout) {
                finish(nil)
            }
            body(connector) { finish($0) }
        }
    }
}
#endif
