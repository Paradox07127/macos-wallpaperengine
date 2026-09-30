#if !LITE_BUILD
import LiveWallpaperProWPE
import Metal

/// Load decisions use exact physical initialization, never a name or an allocation's
/// previous lifetime. These rules preserve the existing WPE render graph behavior.
struct WPEAttachmentLoadContract: Equatable, Sendable {
    enum Reason: String, Sendable {
        case uninitialized, targetFeedback, sceneAccumulation, groupAccumulation
        case blendDestination, scratchOverwrite, fullOverwrite, transientDepth, persistentDepth
    }

    let load: MTLLoadAction
    let store: MTLStoreAction
    let reason: Reason

    static func color(target: WPEMetalTargetID, initialized: Bool, readsCurrentTarget: Bool,
                      blendNeedsDestination: Bool) -> Self {
        guard initialized else { return Self(load: .clear, store: .store, reason: .uninitialized) }
        if readsCurrentTarget {
            return Self(load: .load, store: .store, reason: .targetFeedback)
        }
        if case .scene = target {
            return Self(load: .load, store: .store, reason: .sceneAccumulation)
        }
        if case let .named(name) = target, WPERenderTargetNames.LayerGroup.matches(name) {
            return Self(load: .load, store: .store, reason: .groupAccumulation)
        }
        return Self(load: blendNeedsDestination ? .load : .clear, store: .store,
                    reason: blendNeedsDestination ? .blendDestination : .scratchOverwrite)
    }

    static var fullOverwrite: Self {
        Self(load: .dontCare, store: .store, reason: .fullOverwrite)
    }

    static func depth(transient: Bool, initialized: Bool) -> Self {
        if transient {
            return Self(load: .clear, store: .dontCare, reason: .transientDepth)
        }
        return Self(load: initialized ? .load : .clear, store: .store,
                    reason: initialized ? .persistentDepth : .uninitialized)
    }
}
#endif
