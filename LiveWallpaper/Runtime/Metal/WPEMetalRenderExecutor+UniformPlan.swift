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
        /// Official half-pixel reciprocal, derived from the same render-pixel
        /// dimensions as `g_TexelSize`.
        let isTexelSizeHalf: Bool
        /// Official `(width, height, width / height)` render-pixel tuple.
        let isScreen: Bool
        /// `g_Texture<N>Resolution` → N. Falls through when slot N is unbound.
        let textureResolutionSlot: Int?
        /// Official TEXS globals exist only for sampler slots 0...7. They are
        /// terminal only when this exact binding carries a frame descriptor.
        let textureRotationSlot: Int?
        let textureTranslationSlot: Int?
        let steps: [UniformResolutionStep]
        let defaultValue: WPESceneShaderConstantValue?
    }

    struct PassUniformPlans {
        /// Which keys EXIST is what the steps are compiled from, so the key set
        /// is the cache identity — see `UniformKeyIndex`. A count compare kept a
        /// plan alive across a same-count scripted key substitution: it went on
        /// probing the key that vanished and never compiled a step for the one
        /// that appeared.
        let uniformKeySet: ShaderConstantKeys
        let constantKeySet: ShaderConstantKeys
        /// `Array ==` short-circuits on shared storage (the hot-path case).
        let layout: [WPEUniformSlot]
        let plans: [UniformResolutionPlan]
    }

    func uniformPlans(
        for pass: WPEPreparedRenderPass,
        layout: [WPEUniformSlot]
    ) -> [UniformResolutionPlan] {
        if let cached = uniformPlansByPassID[pass.id],
           cached.uniformKeySet == pass.uniformValues.keys,
           cached.constantKeySet == pass.pass.constants.keys,
           cached.layout == layout {
            return cached.plans
        }
        let keyIndex = uniformKeyIndex(for: pass)
        let plans = layout.map { compileUniformPlan(for: $0, pass: pass, keyIndex: keyIndex) }
        uniformPlanCompileCount += 1
        uniformPlansByPassID[pass.id] = PassUniformPlans(
            uniformKeySet: pass.uniformValues.keys,
            constantKeySet: pass.pass.constants.keys,
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
            isTexelSizeHalf: uniform.name == Self.texelSizeHalfUniformName,
            isScreen: uniform.name == Self.screenUniformName,
            textureResolutionSlot: Self.textureResolutionSlotIndex(for: uniform.name),
            textureRotationSlot: Self.textureRotationSlotIndex(for: uniform.name),
            textureTranslationSlot: Self.textureTranslationSlotIndex(for: uniform.name),
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
        if plan.isTexelSizeHalf,
           let value = Self.texelSizeHalfValue(
               named: Self.texelSizeHalfUniformName,
               sceneSize: currentScenePixelSize
           ) {
            return value
        }
        if plan.isScreen,
           let value = Self.screenValue(
               named: Self.screenUniformName,
               sceneSize: currentScenePixelSize
           ) {
            return value
        }
        if let slot = plan.textureResolutionSlot,
           let texture = texturesBySlot?[slot] {
            return WPEMetalTextureMetadataRegistry.shared.resolution(for: texture).shaderValue
        }
        if let slot = plan.textureRotationSlot,
           let descriptor = texturesBySlot?.samplingDescriptor(at: slot) {
            return .vector([
                Double(descriptor.rotation.x),
                Double(descriptor.rotation.y),
                Double(descriptor.rotation.z),
                Double(descriptor.rotation.w)
            ])
        }
        if let slot = plan.textureTranslationSlot,
           let descriptor = texturesBySlot?.samplingDescriptor(at: slot) {
            return .vector([
                Double(descriptor.translation.x),
                Double(descriptor.translation.y)
            ])
        }
        WPEFrameOccupancyMeter.count(.uniformSlotResolved)
        for step in plan.steps {
            WPEFrameOccupancyMeter.count(.uniformDictProbe)
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
