#if !LITE_BUILD
import Foundation
import LiveWallpaperCore
import os

/// XPC client for the unsandboxed Steam connector (real $HOME / STEAMROOT).
/// One short-lived connection per call.
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

    /// Connector-side SteamCMD hash + code signature (app never opens the binary).
    static func inspectSteamCMDBinary(path: String) async -> SteamCMDBinaryInspection? {
        let data = await call { connector, reply in
            connector.inspectSteamCMDBinary(path: path, with: reply)
        }
        return data.flatMap { try? JSONDecoder().decode(SteamCMDBinaryInspection.self, from: $0) }
    }

    /// The Mach-O the connector would execute, resolved from its own candidate
    /// list. Takes no path: the app does not get to name what runs.
    static func locateSteamCMDBinary() async -> SteamCMDBinaryLocation? {
        let data = await call { connector, reply in
            connector.locateSteamCMDBinary(with: reply)
        }
        return data.flatMap { try? JSONDecoder().decode(SteamCMDBinaryLocation.self, from: $0) }
    }

    /// Hands a verified bootstrap archive to the connector to unpack into a
    /// managed install. The app cannot unpack it itself: the sandbox stamps
    /// `com.apple.quarantine` on everything this process writes, and a
    /// quarantined bare CLI Mach-O cannot be spawned at all.
    static func installManagedSteamCMD(
        tarballPath: String
    ) async -> SteamCMDManagedInstallResult? {
        let data = await call { connector, reply in
            connector.installManagedSteamCMD(tarballPath: tarballPath, with: reply)
        }
        return data.flatMap { try? JSONDecoder().decode(SteamCMDManagedInstallResult.self, from: $0) }
    }

    /// Deletes the managed install. The app cannot do this itself — the payload
    /// is deliberately outside its container.
    static func removeManagedSteamCMD() async -> SteamCMDManagedRemovalResult? {
        let data = await call { connector, reply in
            connector.removeManagedSteamCMD(with: reply)
        }
        return data.flatMap { try? JSONDecoder().decode(SteamCMDManagedRemovalResult.self, from: $0) }
    }

    /// Whether SteamCMD works on this Mac, decided by the one process that can
    /// spawn it — resolution, signature, quarantine, and a real `steamcmd +quit`
    /// run. Slow by nature; the app renders the result rather than re-deriving
    /// any part of it. nil means the connector was unreachable.
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

    /// Runs one Doctor probe. Which binary it runs is the connector's call.
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

    /// Long-running app_update with progress.
    static func installWallpaperEngineAssets(
        accountName: String,
        onProgress: @escaping @Sendable (SteamOperationProgress) -> Void
    ) async -> SteamEngineAssetsResult? {
        let data = await call(onProgress: onProgress) { connector, reply in
            connector.installWallpaperEngineAssets(accountName: accountName, with: reply)
        }
        return data.flatMap { try? JSONDecoder().decode(SteamEngineAssetsResult.self, from: $0) }
    }

    static func downloadWorkshopItem(
        workshopID: String,
        accountName: String,
        onProgress: @escaping @Sendable (SteamOperationProgress) -> Void
    ) async -> SteamWorkshopDownloadResult? {
        let data = await call(onProgress: onProgress) { connector, reply in
            connector.downloadWorkshopItem(
                workshopID: workshopID,
                accountName: accountName,
                with: reply
            )
        }
        return data.flatMap { try? JSONDecoder().decode(SteamWorkshopDownloadResult.self, from: $0) }
    }

    /// Real delete of the user's Steam content. The app has no code path that
    /// can do this itself — by design.
    static func deleteWorkshopItem(workshopID: String) async -> SteamDeleteResult? {
        let data = await call { connector, reply in
            connector.deleteWorkshopItem(workshopID: workshopID, with: reply)
        }
        return data.flatMap { try? JSONDecoder().decode(SteamDeleteResult.self, from: $0) }
    }

    static func latestWallpaperEngineBuildID(accountName: String) async -> String? {
        let data = await call { connector, reply in
            connector.latestWallpaperEngineBuildID(accountName: accountName, with: reply)
        }
        return data.flatMap { try? JSONDecoder().decode(String?.self, from: $0) } ?? nil
    }

    // MARK: - Transport

    /// Progress on arbitrary queue (`@Sendable`; MainActor hop is caller's job).
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
            // Backstop if SteamCMD wedges without breaking the XPC connection.
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout) {
                finish(nil)
            }
            body(connector) { finish($0) }
        }
    }
}
#endif
