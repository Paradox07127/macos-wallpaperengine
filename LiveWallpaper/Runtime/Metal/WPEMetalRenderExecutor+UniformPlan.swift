#if !LITE_BUILD
import CoreGraphics
import Foundation
import LiveWallpaperProWPE

/// Per-slot uniform SOURCE resolution, compiled once per (pass, layout) instead
/// of re-derived per slot per pass per frame.
///
/// What it replaces: for every uniform slot the packer walked the slot's
/// candidate-name list (`u_Foo`, its `material` alias, the `u_`-stripped
/// spellings) and probed the frame context, `pass.uniformValues` and
/// `pass.pass.constants` — an exact round and then a lowercased round over all
/// of them. Only the WINNER of that walk varies with the scene, and it is fixed
/// by the pass's key SETS, which are load-stable; only the VALUES change per
/// frame. So the walk is compiled to an ordered step list and only the final
/// dictionary read stays on the hot path.
///
/// The plan is a name resolution, never a value one: nothing is inlined, so
/// animated values (re-resolved per frame by `addingMetalRuntimeUniforms`) and
/// scripted overrides keep landing exactly as before.
extension WPEMetalRenderExecutor {

    /// One probe, in the same order the interleaved candidate walk performed it.
    enum UniformResolutionStep: Equatable {
        /// `WPEFrameUniformContext.value(named:passID:)`. NOT terminal: the
        /// object dictionary is per-frame and the context is `.empty` outside a
        /// `render` call, so a frame-global name can legitimately miss and must
        /// still fall through to the pass sources behind it.
        case frameGlobal(String)
        /// `pass.uniformValues[key]`, for a key present when the plan was
        /// compiled. Normally hits; kept non-terminal because a scripted key can
        /// vanish within a cache generation.
        case passValue(String)
        /// `pass.pass.constants[key]`, same rule.
        case passConstant(String)
    }

    struct UniformResolutionPlan {
        /// `g_TexelSize` — scene-level, so still computed per frame from
        /// `currentSceneSize`, and still falls through to the steps when the
        /// scene size is degenerate.
        let isTexelSize: Bool
        /// `g_Texture<N>Resolution` → N. Falls through when slot N is unbound.
        let textureResolutionSlot: Int?
        let steps: [UniformResolutionStep]
        let defaultValue: WPESceneShaderConstantValue?
    }

    struct PassUniformPlans {
        /// Key-set validation, same shape as `UniformKeyIndex`: a scripted
        /// constant appearing (or the animated `g_Color` override landing) after
        /// the first tick changes the count and forces a recompile.
        let uniformCount: Int
        let constantsCount: Int
        /// A pass id alone does not name a layout — tests pack one pass under
        /// several. `Array ==` short-circuits on shared storage, which is the
        /// hot-path case (the layout comes from `compiledShaderResultByPassID`,
        /// so every frame passes the same array instance).
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

    /// Mirrors the old walk step for step. The interleaving matters: within one
    /// candidate the frame context is probed before the pass dictionary (the
    /// merge this descends from inserted frame values last, so they won for
    /// that name), but a LATER candidate never beats an earlier one.
    private func compileUniformPlan(
        for uniform: WPEUniformSlot,
        pass: WPEPreparedRenderPass,
        keyIndex: UniformKeyIndex
    ) -> UniformResolutionPlan {
        let candidates = memoizedUniformNameCandidates(for: uniform)
        var steps: [UniformResolutionStep] = []
        // Re-probing the same source can never change the outcome, so a step
        // already in the plan is dropped (the exact and lowercased rounds
        // resolve to the same canonical key for an all-lowercase name).
        func append(_ step: UniformResolutionStep) {
            guard !steps.contains(step) else { return }
            steps.append(step)
        }

        // Compilation does NOT stop at the first key that exists today: a step
        // only proves the key existed when the plan was built, and a scripted
        // key can disappear later within one cache generation (the key-count
        // validation misses a same-frame add+remove). Emitting the whole probe
        // order keeps the fallbacks that the old per-frame walk would have run.
        // Execution still returns on the first hit, so the hot path is unchanged
        // — only a miss walks further.
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
        // Constants are probed only after BOTH uniform rounds, and exact across
        // every candidate before any lowercased one.
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

    /// `frame` is threaded in rather than read off `self` so the per-pass
    /// context is loaded once instead of once per slot.
    func resolvedUniformValue(
        plan: UniformResolutionPlan,
        pass: WPEPreparedRenderPass,
        frame: WPEFrameUniformContext,
        texturesBySlot: WPEMetalTextureSlotTable?
    ) -> WPESceneShaderConstantValue? {
        if plan.isTexelSize,
           let value = Self.texelSizeValue(
               named: Self.texelSizeUniformName,
               sceneSize: currentSceneSize
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
