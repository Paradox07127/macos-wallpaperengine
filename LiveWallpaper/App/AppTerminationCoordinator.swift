import Foundation
import LiveWallpaperCore

enum AppTerminationCoordinator {
    typealias AsyncStep = @Sendable () async -> Void
    typealias BlockingStep = @Sendable () -> Void

    static func shutdownForApplication() async {
        let saved = await run(
            stopMonitorProducers: { await Runtime.shared.shutdown() },
            flushMonitorCursors: {
                await runBlockingOffMainActor {
                    SourceRegistration.flushCursorStoreForTermination()
                }
            },
            flushSettings: { await SettingsManager.shared.flushPendingWrites() }
        )
        if !saved {
            Logger.error("Application is quitting with settings that could not be saved", category: .settings)
        }
    }

    /// Cursor persistence is synchronous by design so termination can wait for the exact committed revision.
    static func runBlockingOffMainActor(_ operation: @escaping BlockingStep) async {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                operation()
                continuation.resume()
            }
        }
    }

    @discardableResult
    static func run(
        stopMonitorProducers: AsyncStep,
        flushMonitorCursors: AsyncStep,
        flushSettings: @Sendable () async -> Bool
    ) async -> Bool {
        await stopMonitorProducers()
        await flushMonitorCursors()
        return await flushSettings()
    }
}
