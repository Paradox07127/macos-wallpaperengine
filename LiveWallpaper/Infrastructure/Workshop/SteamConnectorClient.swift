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

    static func probeCachedLogin(
        accountName: String,
        steamCMDPath: String,
        expectedSHA256: String
    ) async -> SteamCachedLoginResult? {
        guard let data = await call({ connector, reply in
            connector.probeCachedLogin(
                accountName: accountName,
                steamCMDPath: steamCMDPath,
                expectedSHA256: expectedSHA256,
                with: reply
            )
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

    /// Resolves a SteamCMD path to the Mach-O we would execute. `pickedPath` nil
    /// means "try the three package-manager locations".
    static func locateSteamCMDBinary(pickedPath: String?) async -> SteamCMDBinaryLocation? {
        let data = await call { connector, reply in
            connector.locateSteamCMDBinary(pickedPath: pickedPath, with: reply)
        }
        return data.flatMap { try? JSONDecoder().decode(SteamCMDBinaryLocation.self, from: $0) }
    }

    /// Runs one Doctor probe. `expectedSHA256` is the digest the caller verified;
    /// the connector re-hashes before spawning and refuses on any change.
    static func runSteamCMDProbe(
        path: String,
        expectedSHA256: String,
        arguments: [String],
        timeout: TimeInterval
    ) async -> SteamCMDProbeRun? {
        let request = SteamCMDProbeRequest(
            path: path,
            expectedSHA256: expectedSHA256,
            arguments: arguments,
            timeout: timeout
        )
        guard let payload = try? JSONEncoder().encode(request) else { return nil }
        let data = await call { connector, reply in
            connector.runSteamCMDProbe(payload, with: reply)
        }
        return data.flatMap { try? JSONDecoder().decode(SteamCMDProbeRun.self, from: $0) }
    }

    // MARK: - Long operations

    /// Long-running app_update with progress; connector re-checks expectedSHA256.
    static func installWallpaperEngineAssets(
        accountName: String,
        steamCMDPath: String,
        expectedSHA256: String,
        onProgress: @escaping @Sendable (SteamOperationProgress) -> Void
    ) async -> SteamEngineAssetsResult? {
        let data = await call(onProgress: onProgress) { connector, reply in
            connector.installWallpaperEngineAssets(
                accountName: accountName,
                steamCMDPath: steamCMDPath,
                expectedSHA256: expectedSHA256,
                with: reply
            )
        }
        return data.flatMap { try? JSONDecoder().decode(SteamEngineAssetsResult.self, from: $0) }
    }

    static func downloadWorkshopItem(
        workshopID: String,
        accountName: String,
        steamCMDPath: String,
        expectedSHA256: String,
        onProgress: @escaping @Sendable (SteamOperationProgress) -> Void
    ) async -> SteamWorkshopDownloadResult? {
        let data = await call(onProgress: onProgress) { connector, reply in
            connector.downloadWorkshopItem(
                workshopID: workshopID,
                accountName: accountName,
                steamCMDPath: steamCMDPath,
                expectedSHA256: expectedSHA256,
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

    static func latestWallpaperEngineBuildID(
        accountName: String,
        steamCMDPath: String,
        expectedSHA256: String
    ) async -> String? {
        let data = await call { connector, reply in
            connector.latestWallpaperEngineBuildID(
                accountName: accountName,
                steamCMDPath: steamCMDPath,
                expectedSHA256: expectedSHA256,
                with: reply
            )
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
