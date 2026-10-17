#if !LITE_BUILD
import AppKit
import AVFoundation
import LiveWallpaperCore
import LiveWallpaperProWPE
import Metal
import QuartzCore

@available(macOS 26.0, *)
@MainActor
enum SystemWallpaperScenePreparation {
    static func resolve(_ descriptor: SceneDescriptor, origin: WPEOrigin? = nil) throws -> SystemWallpaperSceneSource {
        let descriptor = descriptor.refreshingPresetSnapshot(in: SettingsManager.shared.loadGlobalSettings().scenePresets)
        let origin = origin ?? SettingsManager.shared.loadGlobalSettings().recentWPEImports
            .first { $0.origin.workshopID == descriptor.workshopID }?.origin
        guard let support = WPEPathSafety.defaultApplicationSupportRoot(fileManager: .default),
              WPEPathSafety.isSafeCacheRelativePath(descriptor.cacheRelativePath) else {
            throw WallpaperExportService.ServiceError.unsupportedContent
        }
        let cache = support.appendingPathComponent(descriptor.cacheRelativePath)
        guard let assets = AmbientWallpaperSessionBuilder().sceneAssets(
            descriptor: descriptor, origin: origin, cacheURL: cache,
            fileManager: .default, onOriginBookmarkRefresh: { _, _ in }
        ) else { throw WallpaperExportService.ServiceError.unsupportedContent }
        let mounts = WPEDependencyMountResolver().mounts(dependencyWorkshopIDs: descriptor.dependencyWorkshopIDs, origin: origin)
        return SystemWallpaperSceneSource(
            descriptor: descriptor,
            provider: assets.provider ?? WPEDirectorySceneAssetProvider(rootURL: cache),
            projectRoot: assets.projectRoot, mounts: mounts,
            engineRoot: WPEEngineAssetsLibrary.shared.resolveAuthorizedRoot()
        )
    }

    static func record(
        source: SystemWallpaperSceneSource, url: URL, size: CGSize, duration: TimeInterval, framesPerSecond: Int,
        progress: (Double) -> Void
    ) async throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw SystemWallpaperMovieWriter.Failure.bufferUnavailable
        }
        let layer = CAMetalLayer()
        layer.device = device
        layer.pixelFormat = .bgra8Unorm_srgb
        layer.drawableSize = size
        let actor = try await SystemWallpaperSceneRuntime.makeActor(source: source, layer: layer, size: size, hidingClockCalendar: true)
        let writer: SystemWallpaperMovieWriter
        do { writer = try SystemWallpaperMovieWriter(url: url, size: size, framesPerSecond: framesPerSecond, device: device) } catch {
            await actor.teardownRenderer()
            actor.requestStop()
            throw error
        }
        do {
            // Real-time pacing keeps authored timers and embedded AVPlayer video on the same clock.
            let clock = ContinuousClock()
            try await clock.sleep(for: .seconds(0.5))
            let start = clock.now
            let count = Int(duration * Double(framesPerSecond))
            await actor.setFrameRateCeiling(framesPerSecond)
            for frame in 0 ..< count {
                try await clock.sleep(until: start.advanced(by: .seconds(Double(frame) / Double(framesPerSecond))))
                let elapsed = start.duration(to: clock.now)
                let seconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
                guard seconds < duration else { break }
                try await writer.append(at: CMTime(seconds: seconds, preferredTimescale: 60000)) { texture in
                    try await actor.renderMovieFrame(into: .init(texture: texture))
                }
                progress(min(seconds / duration, 1))
            }
            try await writer.finish(at: CMTime(seconds: duration, preferredTimescale: 60000))
            progress(1)
            await actor.teardownRenderer()
            actor.requestStop()
        } catch {
            writer.cancel()
            await actor.teardownRenderer()
            actor.requestStop()
            throw error
        }
    }
}
#endif
