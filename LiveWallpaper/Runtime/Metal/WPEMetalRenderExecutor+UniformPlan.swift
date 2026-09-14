#if !LITE_BUILD
import CoreGraphics
import Foundation
import LiveWallpaperCore
import LiveWallpaperProWPE

extension WPEMetalRenderExecutor {

    enum UniformResolutionStep: Equatable {
        /// Not terminal: the context is `.empty` outside `render`, so a miss
        /// must still fall through to the pass sources.
        case frameGlobal(String)
        /// Not terminal: a scripted key can vanish within a cache generation.
        case passValue(String)
        case passConstant(String)
    }

    enum DirectUniformPacking: Equatable {
        case texelSize
        case texelSizeHalf
        case screen
        case textureResolution(Int)
        case textureRotation(Int)
        case textureTranslation(Int)
    }

    struct UniformResolutionPlan {
        let directPacking: DirectUniformPacking?
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
        /// Key set is the cache identity (see `UniformKeyIndex`). A count compare would keep a plan alive across a same-count scripted key substitution.
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

    /// Within one candidate, frame context is probed first (it was inserted last, so it won); a later candidate never beats an earlier one. The whole probe order is emitted so a later miss still has the fallbacks.
    private func compileUniformPlan(
        for uniform: WPEUniformSlot,
        pass: WPEPreparedRenderPass,
        keyIndex: UniformKeyIndex
    ) -> UniformResolutionPlan {
        // `require` does NOT gate runtime binding, so `uniform.requiredCombos` is not consulted. `require` decides only whether the editor exposes the field.
        let candidates = memoizedUniformNameCandidates(for: uniform)
        var steps: [UniformResolutionStep] = []
        func append(_ step: UniformResolutionStep) {
            guard !steps.contains(step) else { return }
            steps.append(step)
        }

        // Where a material-annotated uniform collides with a frame global, the authored value has to win; the frame global would shadow it (`g_Brightness` is both the pause dimmer and generic2/4 brightness).
        if let materialName = uniform.materialName, !materialName.isEmpty,
           WPEFrameUniformContext.canonicalNames.contains(uniform.name) {
            for name in candidates.names where pass.uniformValues[name] != nil {
                append(.passValue(name))
            }
            for name in candidates.names where pass.pass.constants[name] != nil {
                append(.passConstant(name))
            }
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
            directPacking: Self.directUniformPacking(for: uniform),
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

    private static func directUniformPacking(for uniform: WPEUniformSlot) -> DirectUniformPacking? {
        guard uniform.arrayLength == nil, uniform.slotCount == 1 else { return nil }
        switch uniform.glslType {
        case "vec2":
            if uniform.name == texelSizeUniformName {
                return .texelSize
            }
            if uniform.name == texelSizeHalfUniformName {
                return .texelSizeHalf
            }
            if let slot = textureTranslationSlotIndex(for: uniform.name) {
                return .textureTranslation(slot)
            }
        case "vec3":
            if uniform.name == screenUniformName {
                return .screen
            }
        case "vec4":
            if let slot = textureResolutionSlotIndex(for: uniform.name) {
                return .textureResolution(slot)
            }
            if let slot = textureRotationSlotIndex(for: uniform.name) {
                return .textureRotation(slot)
            }
        default:
            break
        }
        return nil
    }

    /// Preserve the legacy Double calculation/conversion and missing-source fallthrough.
    /// Texture metadata is the same draw-local snapshot used by the ordinary resolver.
    func directUniformVector(
        _ packing: DirectUniformPacking,
        texturesBySlot: WPEMetalTextureSlotTable?
    ) -> SIMD4<Float>? {
        switch packing {
        case .texelSize, .texelSizeHalf, .screen:
            let width = Double(currentScenePixelSize.width)
            let height = Double(currentScenePixelSize.height)
            guard width > 0, height > 0 else { return nil }
            switch packing {
            case .texelSize:
                return SIMD4<Float>(Float(1 / width), Float(1 / height), 0, 0)
            case .texelSizeHalf:
                return SIMD4<Float>(Float(0.5 / width), Float(0.5 / height), 0, 0)
            default:
                return SIMD4<Float>(Float(width), Float(height), Float(width / height), 0)
            }
        case let .textureResolution(slot):
            guard let texture = texturesBySlot?[slot] else { return nil }
            let resolution = texturesBySlot?.resolution(at: slot)
                ?? WPEMetalTextureMetadataRegistry.shared.resolution(for: texture)
            return SIMD4<Float>(
                Float(Double(resolution.textureWidth)), Float(Double(resolution.textureHeight)),
                Float(Double(resolution.imageWidth)), Float(Double(resolution.imageHeight))
            )
        case let .textureRotation(slot):
            guard let descriptor = texturesBySlot?.samplingDescriptor(at: slot) else { return nil }
            // Release may fold Float(Double(x)); preserve the legacy resolver's NaN quieting.
            guard !descriptor.rotation.x.isSignalingNaN, !descriptor.rotation.y.isSignalingNaN,
                  !descriptor.rotation.z.isSignalingNaN, !descriptor.rotation.w.isSignalingNaN else { return nil }
            return SIMD4<Float>(
                Float(Double(descriptor.rotation.x)), Float(Double(descriptor.rotation.y)),
                Float(Double(descriptor.rotation.z)), Float(Double(descriptor.rotation.w))
            )
        case let .textureTranslation(slot):
            guard let descriptor = texturesBySlot?.samplingDescriptor(at: slot) else { return nil }
            guard !descriptor.translation.x.isSignalingNaN,
                  !descriptor.translation.y.isSignalingNaN else { return nil }
            return SIMD4<Float>(
                Float(Double(descriptor.translation.x)), Float(Double(descriptor.translation.y)), 0, 0
            )
        }
    }

    func resolvedUniformValue(
        plan: UniformResolutionPlan,
        pass: WPEPreparedRenderPass,
        frame: WPEFrameUniformContext,
        texturesBySlot: WPEMetalTextureSlotTable?
    ) -> WPESceneShaderConstantValue? {
        // PIXEL size, not world size: `g_TexelSize` is the FBO chain head, which is the scaled scene output — a world-sized texel would narrow every blur kernel by the scale.
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
            let resolution = texturesBySlot?.resolution(at: slot)
                ?? WPEMetalTextureMetadataRegistry.shared.resolution(for: texture)
            return resolution.shaderValue
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
