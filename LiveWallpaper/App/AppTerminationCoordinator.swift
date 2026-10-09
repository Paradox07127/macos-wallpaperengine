import Foundation
import LiveWallpaperCore

enum AppTerminationCoordinator {
    typealias AsyncStep = @Sendable () async -> Void

    static func shutdownForApplication() async {
        let saved = await run(
            stopMonitorProducers: { await Runtime.shared.shutdown() },
            flushSettings: { await SettingsManager.shared.flushPendingWrites() }
        )
        if !saved {
            Logger.error("Application is quitting with settings that could not be saved", category: .settings)
        }
    }

    @discardableResult
    static func run(
        stopMonitorProducers: AsyncStep,
        flushSettings: @Sendable () async -> Bool
    ) async -> Bool {
        await stopMonitorProducers()
        return await flushSettings()
    }
}
