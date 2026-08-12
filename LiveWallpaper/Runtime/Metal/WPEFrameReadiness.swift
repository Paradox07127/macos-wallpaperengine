#if !LITE_BUILD
import Foundation

struct WPEFrameReadinessResult: Equatable, Sendable {
    let generation: Int
    let renderCompleted: Bool
    let presentCompleted: Bool
}

/// Load-scoped plan shared by frame production and present observation. Once a
/// generation is ready, steady-state frames no longer allocate producer
/// aggregates or schedule actor callbacks; an on-demand poster can still ask
/// for a present completion to own/release its source texture.
struct WPEFrameReadinessTrackingPlan: Equatable, Sendable {
    let tracksReadiness: Bool

    static func make(
        generation: Int,
        completedGeneration: Int?,
        hasReadinessConsumer: Bool
    ) -> WPEFrameReadinessTrackingPlan {
        WPEFrameReadinessTrackingPlan(
            tracksReadiness: hasReadinessConsumer && completedGeneration != generation
        )
    }

    func requiresPresentCompletion(hasPosterConsumer: Bool) -> Bool {
        tracksReadiness || hasPosterConsumer
    }
}

/// Injectable combination seam between the final texture's producer aggregate
/// and the subsequent present. Production may resolve before or after present;
/// a missing producer fails closed.
enum WPEFrameReadinessCoordinator {
    static func observe(
        generation: Int,
        frameProduction: WPEMetalFrameProductionCompletion?,
        presentCompleted: Bool,
        publish: @escaping @Sendable (WPEFrameReadinessResult) -> Void
    ) {
        guard let frameProduction else {
            publish(WPEFrameReadinessResult(
                generation: generation,
                renderCompleted: false,
                presentCompleted: presentCompleted
            ))
            return
        }
        frameProduction.observe { renderCompleted in
            publish(WPEFrameReadinessResult(
                generation: generation,
                renderCompleted: renderCompleted,
                presentCompleted: presentCompleted
            ))
        }
    }

    static func isCurrent(
        _ result: WPEFrameReadinessResult,
        didLoad: Bool,
        currentGeneration: Int,
        completedGeneration: Int?
    ) -> Bool {
        didLoad
            && result.generation == currentGeneration
            && completedGeneration != currentGeneration
    }
}

/// Calls the executor's source-release closure exactly once, even if a delayed
/// poster consumer invokes its callback more than once or abandons it.
final class WPEPresentSourceRelease: @unchecked Sendable { // `lock` protects the one-shot closure.
    private let lock = NSLock()
    private var action: (@Sendable () -> Void)?

    init(_ action: @escaping @Sendable () -> Void) {
        self.action = action
    }

    func release() {
        lock.lock()
        let action = self.action
        self.action = nil
        lock.unlock()
        action?()
    }

    deinit {
        release()
    }
}

enum WPEPresentSourceReleaseRouter {
    typealias Consumer = (@escaping @Sendable () -> Void) -> Void

    static func route(
        releaseSource: @escaping @Sendable () -> Void,
        consumer: Consumer? = nil
    ) {
        let release = WPEPresentSourceRelease(releaseSource)
        if let consumer {
            consumer { release.release() }
        } else {
            release.release()
        }
    }
}
#endif
