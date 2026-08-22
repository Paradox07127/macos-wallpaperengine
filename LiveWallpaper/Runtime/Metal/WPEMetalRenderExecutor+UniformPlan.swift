#if !LITE_BUILD
import CoreGraphics
import Foundation
import LiveWallpaperProWPE

/// Per-slot uniform SOURCE resolution, compiled once per (pass, layout).
/// Only the winner of the old candidate walk varies with the scene, and it is
/// fixed by the pass's key sets; values still come from live dictionaries so
/// animated/scripted overrides keep landing as before.
extension WPEMetalRenderExecutor {

    /// One probe, in the same order the interleaved candidate walk performed it.
    enum UniformResolutionStep: Equatable {
        /// Not terminal: the context is `.empty` outside `render`, so a miss
        /// must still fall through to the pass sources.
        case frameGlobal(String)
        /// Not terminal: a scripted key can vanish within a cache generation.
        case passValue(String)
        case passConstant(String)
    }

    struct UniformResolutionPlan {
        /// `g_TexelSize` is scene-level; falls through when scene size is degenerate.
        let isTexelSize: Bool
        /// `g_Texture<N>Resolution` → N. Falls through when slot N is unbound.
        let textureResolutionSlot: Int?
        let steps: [UniformResolutionStep]
        let defaultValue: WPESceneShaderConstantValue?
    }

    struct PassUniformPlans {
        let uniformCount: Int
        let constantsCount: Int
        /// `Array ==` short-circuits on shared storage (the hot-path case).
        let layout: [WPEUniformSlot]
        let plans: [UniformResolutionPlan]
    }

    func uniformPlans(
        for pass: WPEPreparedRenderPass,
        layout: [WPEUniformSlot]
    ) -> [UniformResolutionPlan] {
        if let cached = uniformPlansByPassID[pass.id],
           cached.uniformCount == pass.uniformValues.count,
           cached.constantsCount == pass.pass.constants.count,
           cached.layout == layout {
            return cached.plans
        }
        let keyIndex = uniformKeyIndex(for: pass)
        let plans = layout.map { compileUniformPlan(for: $0, pass: pass, keyIndex: keyIndex) }
        uniformPlanCompileCount += 1
        uniformPlansByPassID[pass.id] = PassUniformPlans(
            uniformCount: pass.uniformValues.count,
            constantsCount: pass.pass.constants.count,
            layout: layout,
            plans: plans
        )
        return plans
    }

    /// Mirrors the old walk. Within one candidate the frame context is probed
    /// first (it was inserted last, so it won); a later candidate never beats
    /// an earlier one. The whole probe order is emitted so a later miss still
    /// has the fallbacks the per-frame walk would have run.
    private func compileUniformPlan(
        for uniform: WPEUniformSlot,
        pass: WPEPreparedRenderPass,
        keyIndex: UniformKeyIndex
    ) -> UniformResolutionPlan {
        let candidates = memoizedUniformNameCandidates(for: uniform)
        var steps: [UniformResolutionStep] = []
        func append(_ step: UniformResolutionStep) {
            guard !steps.contains(step) else { return }
            steps.append(step)
        }

        for name in candidates.names {
            if WPEFrameUniformContext.canonicalNames.contains(name) {
                append(.frameGlobal(name))
            }
            if pass.uniformValues[name] != nil {
                append(.passValue(name))
            }
        }
        for lowered in candidates.lowercasedNames {
            if let canonical = WPEFrameUniformContext.canonicalNameByLowercased[lowered] {
                append(.frameGlobal(canonical))
            }
            if let canonical = keyIndex.uniformKeys[lowered] {
                append(.passValue(canonical))
            }
        }
        for name in candidates.names where pass.pass.constants[name] != nil {
            append(.passConstant(name))
        }
        for lowered in candidates.lowercasedNames {
            if let canonical = keyIndex.constantsKeys[lowered] {
                append(.passConstant(canonical))
            }
        }

        return UniformResolutionPlan(
            isTexelSize: uniform.name == Self.texelSizeUniformName,
            textureResolutionSlot: Self.textureResolutionSlotIndex(for: uniform.name),
            steps: steps,
            defaultValue: uniform.defaultValue
        )
    }

    func resolvedUniformValue(
        plan: UniformResolutionPlan,
        pass: WPEPreparedRenderPass,
        frame: WPEFrameUniformContext,
        texturesBySlot: WPEMetalTextureSlotTable?
    ) -> WPESceneShaderConstantValue? {
        // PIXEL size, not world size: g_TexelSize describes the FBO chain's head
        // resolution, and under render scaling the chain head is the scaled scene
        // output — a world-sized texel would narrow every blur kernel by the scale.
        if plan.isTexelSize,
           let value = Self.texelSizeValue(
               named: Self.texelSizeUniformName,
               sceneSize: currentScenePixelSize
           ) {
            return value
        }
        if let slot = plan.textureResolutionSlot,
           let texture = texturesBySlot?[slot] {
            return WPEMetalTextureMetadataRegistry.shared.resolution(for: texture).shaderValue
        }
        for step in plan.steps {
            switch step {
            case .frameGlobal(let name):
                if let value = frame.value(named: name, passID: pass.id) {
                    return value
                }
            case .passValue(let key):
                if let value = pass.uniformValues[key] {
                    return value
                }
            case .passConstant(let key):
                if let value = pass.pass.constants[key] {
                    return value
                }
            }
        }
        return plan.defaultValue
    }
}
#endif
