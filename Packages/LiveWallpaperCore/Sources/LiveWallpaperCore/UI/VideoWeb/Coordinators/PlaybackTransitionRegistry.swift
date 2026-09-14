import AppKit
import Combine

public final class AssetReadinessWork {
    public var frameRateSubscription: AnyCancellable?
    public var fallbackTask: Task<Void, Never>?

    public init() {}

    public func cancel() {
        frameRateSubscription?.cancel()
        frameRateSubscription = nil
        fallbackTask?.cancel()
        fallbackTask = nil
    }

    deinit {
        cancel()
    }
}

public final class RuntimePreparationWork {
    public var task: Task<Void, Never>?

    public init() {}

    public func cancel() {
        task?.cancel()
        task = nil
    }

    deinit {
        cancel()
    }
}

@MainActor
public final class PlaybackTransitionRegistry {
    private var generationByScreen: [CGDirectDisplayID: Int] = [:]
    private var assetReadinessByScreen: [CGDirectDisplayID: AssetReadinessWork] = [:]
    private var runtimePreparationByScreen: [CGDirectDisplayID: RuntimePreparationWork] = [:]
    /// Per-screen "is this URL playable" validation Task. Stored so `bumpTransition` can
    /// cancel it — a stale one holds the security scope and the `AVAsset` open.
    private var validationTaskByScreen: [CGDirectDisplayID: Task<Void, Never>] = [:]

    public init() {}

    @discardableResult
    public func bumpTransition(for screenID: CGDirectDisplayID) -> Int {
        validationTaskByScreen[screenID]?.cancel()
        validationTaskByScreen[screenID] = nil
        runtimePreparationByScreen[screenID]?.cancel()
        runtimePreparationByScreen[screenID] = nil
        let next = (generationByScreen[screenID] ?? 0) &+ 1
        generationByScreen[screenID] = next
        return next
    }

    public func isCurrentTransition(_ generation: Int, for screenID: CGDirectDisplayID) -> Bool {
        generationByScreen[screenID] == generation
    }

    public func cancelAssetReadiness(for screenID: CGDirectDisplayID) {
        assetReadinessByScreen[screenID]?.cancel()
        assetReadinessByScreen[screenID] = nil
    }

    @discardableResult
    public func setAssetReadiness(_ work: AssetReadinessWork, for screenID: CGDirectDisplayID) -> AssetReadinessWork {
        assetReadinessByScreen[screenID]?.cancel()
        assetReadinessByScreen[screenID] = work
        return work
    }

    /// Only removes the slot if the same work instance is still installed; a later transition may have replaced it.
    public func clearAssetReadinessIfMatch(_ work: AssetReadinessWork, for screenID: CGDirectDisplayID) {
        if assetReadinessByScreen[screenID] === work {
            assetReadinessByScreen[screenID] = nil
        }
    }

    @discardableResult
    public func setRuntimePreparation(
        _ work: RuntimePreparationWork,
        for screenID: CGDirectDisplayID
    ) -> RuntimePreparationWork {
        runtimePreparationByScreen[screenID]?.cancel()
        runtimePreparationByScreen[screenID] = work
        return work
    }

    public func clearRuntimePreparationIfMatch(
        _ work: RuntimePreparationWork,
        for screenID: CGDirectDisplayID
    ) {
        if runtimePreparationByScreen[screenID] === work {
            runtimePreparationByScreen[screenID] = nil
        }
    }

    /// Call this immediately after creating the Task so a rapid bump doesn't slip past it.
    public func setValidationTask(_ task: Task<Void, Never>, for screenID: CGDirectDisplayID) {
        validationTaskByScreen[screenID]?.cancel()
        validationTaskByScreen[screenID] = task
    }
}
