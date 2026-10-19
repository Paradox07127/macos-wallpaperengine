#if !LITE_BUILD
import CoreGraphics
import Foundation
import LiveWallpaperCore
import Metal

struct WPEMetalFrameInFlightBudgetExhausted: Error {}

enum WPEMetalRenderExecutorError: Error, Equatable, LocalizedError, Sendable {
    case commandQueueUnavailable
    case libraryUnavailable
    case pipelineUnavailable(String)
    case pipelineStateBuildFailed(name: String, detail: String)
    case noRenderablePasses
    case commandBufferFailed

    var errorDescription: String? {
        switch self {
        case .commandQueueUnavailable:
            return String(
                localized: "error.render.executor.command_queue_unavailable",
                defaultValue: "Metal command queue is unavailable.",
                bundle: .appLanguage, comment: "Error shown when the Metal renderer cannot create or access a command queue."
            )
        case .libraryUnavailable:
            return String(
                localized: "error.render.executor.library_unavailable",
                defaultValue: "WPE Metal built-in shader library is unavailable.",
                bundle: .appLanguage, comment: "Error shown when the built-in Metal shader library is unavailable."
            )
        case let .pipelineUnavailable(name):
            return String(
                localized: "error.render.executor.pipeline_unavailable",
                defaultValue: "WPE Metal pipeline is unavailable for \(name).",
                bundle: .appLanguage, comment: "Error shown when the Metal renderer cannot create a render pipeline."
            )
        case let .pipelineStateBuildFailed(name, detail):
            return String(
                localized: "error.render.executor.pipeline_state_build_failed",
                defaultValue: "Metal pipeline build failed for '\(name)': \(detail)",
                bundle: .appLanguage, comment: "Error shown when Metal refuses to build a render pipeline state (typically a stage_in mismatch between the vertex output and the fragment input)."
            )
        case .noRenderablePasses:
            return String(
                localized: "error.render.executor.no_renderable_passes",
                defaultValue: "WPE Metal pipeline has no renderable passes.",
                bundle: .appLanguage, comment: "Error shown when the Metal render pipeline has no renderable passes."
            )
        case .commandBufferFailed:
            return String(
                localized: "error.render.executor.command_buffer_failed",
                defaultValue: "WPE Metal command buffer failed.",
                bundle: .appLanguage, comment: "Error shown when a Metal command buffer reports failure."
            )
        }
    }
}

enum WPEMetalTextureLimits {
    /// Mirrors Apple's Metal feature-set table for maximum 2D texture width/height, so invalid descriptors are rejected before Metal's Objective-C validation aborts the current test/app process.
    static func maximum2DTextureDimension(for device: MTLDevice) -> Int {
        // arm64-only distribution: every Mac GPU is Apple family with an
        // .apple7 (M1) floor at 16384; .apple10 raises the cap.
        device.supportsFamily(.apple10) ? 32768 : 16384
    }
}

struct WPESolidUniforms {
    var color: SIMD4<Float>
}

enum WPEPresentFitMode: Equatable {
    case stretch
    case contain
    case cover
    case center
}

extension WPEPresentFitMode {
    init(_ mode: VideoFitMode) {
        switch mode {
        case .stretch: self = .stretch
        case .aspectFit: self = .contain
        case .aspectFill: self = .cover
        case .center: self = .center
        }
    }
}

/// Layout MUST match `WPEPresentUniforms` in `WPEMetalBuiltins.metal`. `ndcScale` shrinks the quad for letterboxed `contain` or preserves source pixels for `center`; `uvScale`/`uvOffset` crop the source for `cover`. All-identity reproduces `stretch`.
struct WPEPresentUniforms {
    var ndcScale: SIMD2<Float>
    var uvScale: SIMD2<Float>
    var uvOffset: SIMD2<Float>
    var ndcOffset: SIMD2<Float> = .init(0, 0)

    /// Degenerate sizes fall back to identity (stretch).
    static func make(
        fitMode: WPEPresentFitMode,
        sourceWidth: Int,
        sourceHeight: Int,
        targetWidth: Int,
        targetHeight: Int
    ) -> WPEPresentUniforms {
        var u = WPEPresentUniforms(
            ndcScale: SIMD2<Float>(1, 1),
            uvScale: SIMD2<Float>(1, 1),
            uvOffset: SIMD2<Float>(0, 0)
        )
        guard sourceWidth > 0, sourceHeight > 0, targetWidth > 0, targetHeight > 0 else {
            return u
        }
        let srcAspect = Double(sourceWidth) / Double(sourceHeight)
        let dstAspect = Double(targetWidth) / Double(targetHeight)
        switch fitMode {
        case .stretch:
            break
        case .center:
            u.ndcScale = SIMD2<Float>(
                Float(Double(sourceWidth) / Double(targetWidth)),
                Float(Double(sourceHeight) / Double(targetHeight))
            )
        case .contain:
            // Shrink the quad on the over-long axis; the cleared margin shows
            // through as letterbox bars.
            if srcAspect > dstAspect {
                u.ndcScale.y = Float(dstAspect / srcAspect)
            } else if srcAspect < dstAspect {
                u.ndcScale.x = Float(srcAspect / dstAspect)
            }
        case .cover:
            // Keep the quad full-bleed; crop the source UV on the over-long
            // axis, centered.
            if srcAspect > dstAspect {
                let s = Float(dstAspect / srcAspect)
                u.uvScale.x = s
                u.uvOffset.x = (1 - s) / 2
            } else if srcAspect < dstAspect {
                let s = Float(srcAspect / dstAspect)
                u.uvScale.y = s
                u.uvOffset.y = (1 - s) / 2
            }
        }
        return u
    }

    /// Fits the scene once to the desktop union, then projects that quad into a
    /// display's local viewport. Desktop coordinates point up; texture UVs point down.
    func sliced(to configuration: VideoSpanRenderConfiguration) -> WPEPresentUniforms? {
        let canvas = configuration.canvasFrame
        let screen = configuration.screenFrame
        for rect in [canvas, screen] {
            guard [rect.minX, rect.minY, rect.width, rect.height].allSatisfy(\.isFinite),
                  rect.width > 0, rect.height > 0 else { return nil }
        }
        guard canvas.contains(screen) else { return nil }
        let scale = SIMD2<Float>(Float(canvas.width / screen.width), Float(canvas.height / screen.height))
        let offset = SIMD2<Float>(Float(2 * (canvas.midX - screen.midX) / screen.width),
                                  Float(2 * (canvas.midY - screen.midY) / screen.height))
        var result = self
        result.ndcScale *= scale
        result.ndcOffset = ndcOffset * scale + offset
        return result
    }

    /// Maps a pointer normalised to the drawable into the scene's own normalised space.
    ///
    /// Present crops (`cover`) or insets (`contain`/`center`) the scene whenever the two
    /// aspect ratios differ, so a pointer that skips this transform is off by up to half
    /// the cropped extent — zero at the centre, worst at the edges. It is the identity
    /// when the aspects match, which is why only non-16:9 displays saw it.
    ///
    /// Returns nil when the pointer sits on a letterbox margin, i.e. outside the scene.
    func scenePointer(fromDrawablePointer pointer: SIMD2<Double>) -> SIMD2<Double>? {
        var scene = SIMD2<Double>(0, 0)
        for axis in 0 ..< 2 {
            let ndc = Double(ndcScale[axis])
            guard ndc > 0 else { return nil }
            // Undo the quad placement first, then apply the source crop: the two are
            // applied in that order by the present shader.
            let offset = Double(ndcOffset[axis]) * (axis == 0 ? 1 : -1)
            let quad = (pointer[axis] - (1 - ndc + offset) / 2) / ndc
            scene[axis] = quad * Double(uvScale[axis]) + Double(uvOffset[axis])
        }
        guard (0 ... 1).contains(scene.x), (0 ... 1).contains(scene.y) else { return nil }
        return scene
    }

    /// Exact inverse of `scenePointer(fromDrawablePointer:)` with no range guard: scene points the present crops away land outside [0,1].
    func drawablePointer(fromScenePointer scene: SIMD2<Double>) -> SIMD2<Double> {
        var pointer = SIMD2<Double>(0, 0)
        for axis in 0 ..< 2 {
            let ndc = Double(ndcScale[axis])
            let offset = Double(ndcOffset[axis]) * (axis == 0 ? 1 : -1)
            let quad = (scene[axis] - Double(uvOffset[axis])) / Double(uvScale[axis])
            pointer[axis] = quad * ndc + (1 - ndc + offset) / 2
        }
        return pointer
    }
}

#endif
