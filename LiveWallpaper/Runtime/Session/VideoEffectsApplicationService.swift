import AVFoundation
import CoreGraphics
import LiveWallpaperCore

@MainActor
final class VideoEffectsApplicationService {
    typealias CompositionBuilder = @MainActor (
        _ asset: AVAsset,
        _ config: VideoEffectConfig,
        _ frameDuration: CMTime
    ) async throws -> AVVideoComposition
    typealias AssetProvider = @MainActor (WallpaperVideoPlayer) -> AVAsset?

    private let effectsManager = VideoEffectsManager()
    private let compositionBuilder: CompositionBuilder?
    private let assetProvider: AssetProvider
    private struct WorkIdentity: Equatable, Sendable {
        let rawValue = UUID()
    }
    private struct WorkKey: Hashable, Sendable {
        let screenID: CGDirectDisplayID
        let playerID: ObjectIdentifier

        init(screenID: CGDirectDisplayID, player: WallpaperVideoPlayer) {
            self.screenID = screenID
            self.playerID = ObjectIdentifier(player)
        }
    }
    private struct InflightWork {
        let identity: WorkIdentity
        let generation: UInt64
        let task: Task<Void, Never>
    }
    private final class PendingWork {
        weak var player: WallpaperVideoPlayer?
        let identity: WorkIdentity
        let generation: UInt64
        let config: ScreenConfiguration
        let screenRefreshRate: Int
        let noEffectsHandler: @MainActor () -> Void
        let completion: @MainActor (Bool) -> Void

        init(
            player: WallpaperVideoPlayer,
            identity: WorkIdentity,
            generation: UInt64,
            config: ScreenConfiguration,
            screenRefreshRate: Int,
            noEffectsHandler: @MainActor @escaping () -> Void,
            completion: @MainActor @escaping (Bool) -> Void
        ) {
            self.player = player
            self.identity = identity
            self.generation = generation
            self.config = config
            self.screenRefreshRate = screenRefreshRate
            self.noEffectsHandler = noEffectsHandler
            self.completion = completion
        }
    }
    private var inflightTasks: [WorkKey: InflightWork] = [:]
    private var pendingRequests: [WorkKey: PendingWork] = [:]
    private var generations: [WorkKey: UInt64] = [:]
    /// Last applied (effectConfig, frameRateLimit) hash; skip rebuild on duplicates (slider thrash).
    private struct AppliedFingerprint: Equatable {
        let effects: VideoEffectConfig
        let limit: FrameRateLimit
    }
    private var appliedFingerprints: [WorkKey: AppliedFingerprint] = [:]

    init(
        compositionBuilder: CompositionBuilder? = nil,
        assetProvider: @escaping AssetProvider = { $0.player?.currentItem?.asset }
    ) {
        self.compositionBuilder = compositionBuilder
        self.assetProvider = assetProvider
    }

    func hasInflightTask(for screenID: CGDirectDisplayID) -> Bool {
        inflightTasks.keys.contains { $0.screenID == screenID }
    }

    func hasInflightTask(
        for screenID: CGDirectDisplayID,
        player: WallpaperVideoPlayer
    ) -> Bool {
        inflightTasks[WorkKey(screenID: screenID, player: player)] != nil
    }

    #if DEBUG
    // Test-only introspection; no production reader.
    func hasPendingRequest(
        for screenID: CGDirectDisplayID,
        player: WallpaperVideoPlayer
    ) -> Bool {
        pendingRequests[WorkKey(screenID: screenID, player: player)] != nil
    }
    #endif

    func hasActiveWork(
        for screenID: CGDirectDisplayID,
        player: WallpaperVideoPlayer
    ) -> Bool {
        let key = WorkKey(screenID: screenID, player: player)
        return inflightTasks[key] != nil || pendingRequests[key] != nil
    }

    func workRevision(
        for screenID: CGDirectDisplayID,
        player: WallpaperVideoPlayer
    ) -> UInt64 {
        generations[WorkKey(screenID: screenID, player: player)] ?? 0
    }

    #if DEBUG
    // Test-only introspection; no production reader.
    func hasTrackedWorkKey(
        for screenID: CGDirectDisplayID,
        player: WallpaperVideoPlayer
    ) -> Bool {
        let key = WorkKey(screenID: screenID, player: player)
        return generations[key] != nil
            || inflightTasks[key] != nil
            || pendingRequests[key] != nil
            || appliedFingerprints[key] != nil
    }
    #endif

    func trackedWorkKeyCount(for screenID: CGDirectDisplayID) -> Int {
        trackedWorkKeys(for: screenID).count
    }

    func applyEffects(
        to player: WallpaperVideoPlayer,
        screenID: CGDirectDisplayID,
        config: ScreenConfiguration,
        screenRefreshRate: Int,
        noEffectsHandler: @MainActor @escaping () -> Void,
        completion: @MainActor @escaping (Bool) -> Void = { _ in }
    ) {
        startEffects(
            to: player,
            screenID: screenID,
            config: config,
            screenRefreshRate: screenRefreshRate,
            noEffectsHandler: noEffectsHandler,
            workIdentity: WorkIdentity(),
            completion: completion
        )
    }

    private func startEffects(
        to player: WallpaperVideoPlayer,
        screenID: CGDirectDisplayID,
        config: ScreenConfiguration,
        screenRefreshRate: Int,
        noEffectsHandler: @MainActor @escaping () -> Void,
        workIdentity: WorkIdentity,
        completion: @MainActor @escaping (Bool) -> Void
    ) {
        let key = WorkKey(screenID: screenID, player: player)
        let hasEffects = config.effectConfig.hasActiveEffect

        // Force SDR owns videoComposition; CIFilter must not overwrite it (gate before asset lookup).
        if player.isForceSDRActive {
            Logger.debug("Skip apply-effects: Force SDR owns videoComposition for screen \(screenID)", category: .videoPlayer)
            cancelWork(for: key)
            noEffectsHandler()
            completion(true)
            return
        }

        let fingerprint = AppliedFingerprint(
            effects: config.effectConfig,
            limit: config.frameRateLimit
        )

        if hasEffects,
           appliedFingerprints[key] == fingerprint,
           inflightTasks[key] == nil,
           pendingRequests[key] == nil,
           player.videoCompositionOwner == .effects,
           player.currentVideoComposition != nil {
            Logger.debug("Skip apply-effects: fingerprint unchanged for screen \(screenID)", category: .videoPlayer)
            completion(true)
            return
        }

        // Disabling effects is asset-independent. In particular, an
        // AVPlayerLooper nil-currentItem seam must still cancel the old build
        // and route to the plain-FPS fallback immediately.
        if !hasEffects {
            cancelWork(for: key)
            Logger.info("Applying effects for screen \(screenID): hasEffects=false", category: .videoPlayer)
            noEffectsHandler()
            completion(true)
            return
        }

        cancelWork(for: key)
        let generation = advanceGeneration(for: key)
        Logger.info("Applying effects for screen \(screenID): hasEffects=true", category: .videoPlayer)

        guard let asset = assetProvider(player) else {
            let pending = PendingWork(
                player: player,
                identity: workIdentity,
                generation: generation,
                config: config,
                screenRefreshRate: screenRefreshRate,
                noEffectsHandler: noEffectsHandler,
                completion: completion
            )
            pendingRequests[key] = pending
            player.onCurrentItemAvailable = { [weak self] resumedPlayer in
                self?.currentItemDidBecomeAvailable(
                    for: resumedPlayer,
                    screenID: screenID
                )
            }
            Logger.debug(
                "Deferring apply-effects until the next player item for screen \(screenID)",
                category: .videoPlayer
            )
            return
        }

        launchEffects(
            asset: asset,
            player: player,
            key: key,
            config: config,
            screenRefreshRate: screenRefreshRate,
            fingerprint: fingerprint,
            generation: generation,
            workIdentity: workIdentity,
            completion: completion
        )
    }

    func currentItemDidBecomeAvailable(
        for player: WallpaperVideoPlayer,
        screenID: CGDirectDisplayID
    ) {
        let key = WorkKey(screenID: screenID, player: player)
        guard let pending = pendingRequests[key],
              pending.player === player,
              generations[key] == pending.generation else { return }

        if player.isForceSDRActive {
            pendingRequests[key] = nil
            appliedFingerprints[key] = nil
            _ = advanceGeneration(for: key)
            pending.noEffectsHandler()
            pending.completion(true)
            return
        }

        guard let asset = assetProvider(player) else { return }
        pendingRequests[key] = nil
        let fingerprint = AppliedFingerprint(
            effects: pending.config.effectConfig,
            limit: pending.config.frameRateLimit
        )
        launchEffects(
            asset: asset,
            player: player,
            key: key,
            config: pending.config,
            screenRefreshRate: pending.screenRefreshRate,
            fingerprint: fingerprint,
            generation: pending.generation,
            workIdentity: pending.identity,
            completion: pending.completion
        )
    }

    private func launchEffects(
        asset: AVAsset,
        player: WallpaperVideoPlayer,
        key: WorkKey,
        config: ScreenConfiguration,
        screenRefreshRate: Int,
        fingerprint: AppliedFingerprint,
        generation: UInt64,
        workIdentity: WorkIdentity,
        completion: @MainActor @escaping (Bool) -> Void
    ) {
        effectsManager.updateConfig(config.effectConfig)

        let effectiveFPS = FrameRateLimit.resolveCompositionFPS(
            limit: config.frameRateLimit,
            videoFrameRate: player.videoFrameRate,
            screenRefreshRate: Double(screenRefreshRate)
        )
        let safeFPS = max(1.0, effectiveFPS)
        let frameDuration = CMTime(value: 1, timescale: CMTimeScale(safeFPS))

        let task = Task { [weak self, weak player] in
            do {
                guard let self else { return }
                let composition: AVVideoComposition
                if let compositionBuilder = self.compositionBuilder {
                    composition = try await compositionBuilder(asset, config.effectConfig, frameDuration)
                } else {
                    composition = try await self.effectsManager.buildComposition(
                        for: asset,
                        config: config.effectConfig,
                        frameDuration: frameDuration
                    )
                }
                try Task.checkCancellation()
                await MainActor.run { [weak self, weak player] in
                    guard let self,
                          self.generations[key] == generation,
                          self.inflightTasks[key]?.identity == workIdentity,
                          self.inflightTasks[key]?.generation == generation else {
                        completion(false)
                        return
                    }
                    self.inflightTasks[key] = nil
                    guard let player, !player.isForceSDRActive else {
                        completion(false)
                        return
                    }
                    player.setVideoComposition(composition, owner: .effects)
                    self.appliedFingerprints[key] = fingerprint
                    completion(true)
                }
            } catch is CancellationError {
                await MainActor.run {
                    completion(false)
                }
                return
            } catch {
                await MainActor.run { [weak self] in
                    guard let self,
                          self.generations[key] == generation,
                          self.inflightTasks[key]?.identity == workIdentity,
                          self.inflightTasks[key]?.generation == generation else {
                        completion(false)
                        return
                    }
                    Logger.error(
                        "Failed to apply video effects: \(error.localizedDescription)",
                        category: .videoPlayer
                    )
                    self.inflightTasks[key] = nil
                    completion(false)
                }
            }
        }
        inflightTasks[key] = InflightWork(
            identity: workIdentity,
            generation: generation,
            task: task
        )
    }

    func prepareEffects(
        to player: WallpaperVideoPlayer,
        screenID: CGDirectDisplayID,
        config: ScreenConfiguration,
        screenRefreshRate: Int,
        noEffectsHandler: @MainActor @escaping () -> Void
    ) async -> Bool {
        let gate = WallpaperPreparationContinuationGate<Bool>()
        let workIdentity = WorkIdentity()
        let key = WorkKey(screenID: screenID, player: player)
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                gate.install(continuation)
                startEffects(
                    to: player,
                    screenID: screenID,
                    config: config,
                    screenRefreshRate: screenRefreshRate,
                    noEffectsHandler: noEffectsHandler,
                    workIdentity: workIdentity
                ) { succeeded in
                    gate.resolve(succeeded)
                }
            }
        } onCancel: {
            Task { @MainActor [weak self, gate] in
                self?.cancelInflight(for: key, matching: workIdentity)
                gate.resolve(false)
            }
        }
    }

    func cancelInflight(for screenID: CGDirectDisplayID) {
        for key in trackedWorkKeys(for: screenID) {
            cancelWork(for: key)
        }
    }

    func cancelInflight(
        for screenID: CGDirectDisplayID,
        player: WallpaperVideoPlayer
    ) {
        cancelWork(for: WorkKey(screenID: screenID, player: player))
    }

    /// Retire player key (cancel then tombstone). WorkIdentity survives ObjectIdentifier reuse.
    func retireWork(
        for screenID: CGDirectDisplayID,
        player: WallpaperVideoPlayer
    ) {
        let key = WorkKey(screenID: screenID, player: player)
        cancelWork(for: key)
        generations.removeValue(forKey: key)
    }

    /// Terminal screen teardown. Unlike `cancelInflight`, this removes every
    /// historical key after invalidating its queued work.
    func retireAllWork(for screenID: CGDirectDisplayID) {
        for key in trackedWorkKeys(for: screenID) {
            cancelWork(for: key)
            generations.removeValue(forKey: key)
        }
    }

    func retireAllWork() {
        for key in trackedWorkKeys() {
            cancelWork(for: key)
            generations.removeValue(forKey: key)
        }
    }

    private func trackedWorkKeys(
        for screenID: CGDirectDisplayID? = nil
    ) -> Set<WorkKey> {
        let keys = Set(generations.keys)
            .union(inflightTasks.keys)
            .union(pendingRequests.keys)
            .union(appliedFingerprints.keys)
        guard let screenID else { return keys }
        return Set(keys.filter { $0.screenID == screenID })
    }

    @discardableResult
    private func advanceGeneration(for key: WorkKey) -> UInt64 {
        let next = (generations[key] ?? 0) &+ 1
        generations[key] = next
        return next
    }

    private func cancelWork(for key: WorkKey) {
        if let pending = pendingRequests.removeValue(forKey: key) {
            pending.completion(false)
        }
        inflightTasks.removeValue(forKey: key)?.task.cancel()
        appliedFingerprints[key] = nil
        // Bump token so a completion already past checkCancellation cannot install post-teardown.
        _ = advanceGeneration(for: key)
    }

    private func cancelInflight(
        for key: WorkKey,
        matching workIdentity: WorkIdentity
    ) {
        let matchesInflight = inflightTasks[key]?.identity == workIdentity
        let matchesPending = pendingRequests[key]?.identity == workIdentity
        guard matchesInflight || matchesPending else { return }
        cancelWork(for: key)
    }
}
