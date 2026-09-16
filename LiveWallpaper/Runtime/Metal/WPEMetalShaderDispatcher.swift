#if !LITE_BUILD
import Foundation
import LiveWallpaperCore
import LiveWallpaperProWPE
import Metal
/// Puppet/model/text never reach here (executor encodes them). Absent compose slot 1 / image-4 mask / effect mask rebinds slot 0 (clears has-mask); godrays_combine slot 2 absent rebinds albedo and clears copy-background.
/// Buffers: fragment uniforms=0, object/shape-quad vertex uniforms=1, skew params=2.
struct WPEMetalShaderDispatcher {
    let executor: WPEMetalRenderExecutor
    func dispatch(
        pass: WPEPreparedRenderPass,
        layer: WPERenderLayer,
        destination: (id: WPEMetalTargetID, texture: MTLTexture),
        textures: [String: MTLTexture],
        frameState: WPEMetalFrameState,
        encoder: MTLRenderCommandEncoder,
        depthPixelFormat: MTLPixelFormat,
        fetchSceneColor: Bool = false
    ) throws {
        if pass.shader?.isBuiltin == false {
            try dispatchCustomShader(
                pass: pass,
                layer: layer,
                destination: destination,
                textures: textures,
                frameState: frameState,
                encoder: encoder,
                depthPixelFormat: depthPixelFormat
            )
            return
        }

        guard let kind = WPEBuiltinShaderKind(normalizing: pass.pass.shader) else {
            try dispatchCustomShader(
                pass: pass,
                layer: layer,
                destination: destination,
                textures: textures,
                frameState: frameState,
                encoder: encoder,
                depthPixelFormat: depthPixelFormat
            )
            return
        }
        switch kind {
        // Force-unwrap is pinned by the snapshot test on `WPEEffectDispatchDescriptor.table` (see `WPEMetalEffectDispatchTable.swift`).
        case .effectColorBalance, .effectBlur, .effectVignette, .effectWater,
             .effectOpacity, .effectScroll, .effectPulse, .effectIris,
             .effectWaterWaves, .effectSpin, .effectTint, .effectFoliageSway,
             .effectWaterRipple, .effectBlend, .effectWaterFlow,
             .effectColorGrading, .effectShimmer, .effectShake:
            try dispatchEffect(
                WPEEffectDispatchDescriptor.table[kind]!,
                pass: pass, layer: layer, destination: destination, textures: textures,
                frameState: frameState, encoder: encoder, depthPixelFormat: depthPixelFormat
            )
        case .solidColor:
            try dispatchSolid(
                fragmentName: "wpe_solidcolor_fragment",
                variant: .solidColor,
                pass: pass, layer: layer, destination: destination,
                frameState: frameState, encoder: encoder, depthPixelFormat: depthPixelFormat
            )
        case .solidLayer:
            try dispatchSolid(
                fragmentName: "wpe_solidlayer_fragment",
                variant: .solidLayer,
                pass: pass, layer: layer, destination: destination,
                frameState: frameState, encoder: encoder, depthPixelFormat: depthPixelFormat
            )
        case .copy:
            try dispatchCopy(
                pass: pass, layer: layer, destination: destination, textures: textures,
                frameState: frameState, encoder: encoder, depthPixelFormat: depthPixelFormat
            )
        case .blendComposite:
            try dispatchBlendComposite(
                pass: pass, layer: layer, destination: destination, textures: textures,
                frameState: frameState, encoder: encoder, depthPixelFormat: depthPixelFormat,
                fetchSceneColor: fetchSceneColor
            )
        case .compose:
            try dispatchCompose(
                pass: pass, layer: layer, destination: destination, textures: textures,
                frameState: frameState, encoder: encoder, depthPixelFormat: depthPixelFormat
            )
        case .genericImage2:
            try dispatchGenericImage2(
                pass: pass, layer: layer, destination: destination, textures: textures,
                frameState: frameState, encoder: encoder, depthPixelFormat: depthPixelFormat
            )
        case .genericImage4:
            try dispatchGenericImage4(
                pass: pass, layer: layer, destination: destination, textures: textures,
                frameState: frameState, encoder: encoder, depthPixelFormat: depthPixelFormat
            )
        case .genericParticle:
            try dispatchCustomShader(
                pass: pass, layer: layer, destination: destination, textures: textures,
                frameState: frameState, encoder: encoder, depthPixelFormat: depthPixelFormat
            )
        }

        #if DEBUG
        recordBuiltinTracePass(kind: kind, pass: pass, layer: layer, destination: destination,
                               textures: textures, frameState: frameState, fetchSceneColor: fetchSceneColor)
        #endif
    }

    func bindObjectQuadVertexUniforms(
        pass: WPEPreparedRenderPass,
        layer: WPERenderLayer,
        destination: (id: WPEMetalTargetID, texture: MTLTexture),
        frameState: WPEMetalFrameState,
        cameraParallax: WPECameraParallaxFrame,
        sourceTexture: MTLTexture,
        encoder: MTLRenderCommandEncoder
    ) {
        var quadUniforms = executor.objectQuadUniforms(
            for: layer,
            sceneSize: executor.objectQuadSceneSize(
                for: pass,
                layer: layer,
                destination: destination,
                frameState: frameState
            ),
            cameraParallax: cameraParallax,
            sourceTexture: sourceTexture,
            cameraUniforms: executor.objectQuadCameraUniforms(for: pass, layer: layer, frameState: frameState)
        )
        encoder.setVertexBytes(
            &quadUniforms,
            length: MemoryLayout<WPEObjectQuadUniforms>.stride,
            index: 1
        )
    }

    // MARK: - Compose family
    private func dispatchSolid(
        fragmentName: String,
        variant: WPEMetalRenderExecutor.PassPSOVariant,
        pass: WPEPreparedRenderPass,
        layer: WPERenderLayer,
        destination: (id: WPEMetalTargetID, texture: MTLTexture),
        frameState: WPEMetalFrameState,
        encoder: MTLRenderCommandEncoder,
        depthPixelFormat: MTLPixelFormat
    ) throws {
        let usesObjectQuad = executor.usesObjectQuadGeometry(for: pass, layer: layer, cameraParallax: frameState.cameraParallax)
        encoder.setRenderPipelineState(try executor.passPipelineState(
            passID: pass.pass.id,
            variant: variant,
            objectQuad: usesObjectQuad,
            vertexName: usesObjectQuad ? "wpe_object_quad_vertex" : "wpe_fullscreen_vertex",
            fragmentName: fragmentName,
            blendMode: pass.pass.blending,
            alphaWritePolicy: .resolve(targetID: destination.id, blendMode: pass.pass.blending),
            colorPixelFormat: destination.texture.pixelFormat,
            depthPixelFormat: depthPixelFormat
        ))
        var uniforms = WPESolidUniforms(color: WPEMetalShaderInputs.colorVector(for: pass))
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<WPESolidUniforms>.stride, index: 0)
        if usesObjectQuad {
            bindObjectQuadVertexUniforms(
                pass: pass, layer: layer, destination: destination, frameState: frameState,
                cameraParallax: frameState.cameraParallax,
                sourceTexture: destination.texture, encoder: encoder
            )
        }
    }

    /// Destination-reading blend (Overlay et al); slot 4 carries the scene snapshot (WPE `g_Texture4`). See `wpe_blend_composite_fragment`.
    private func dispatchBlendComposite(
        pass: WPEPreparedRenderPass,
        layer: WPERenderLayer,
        destination: (id: WPEMetalTargetID, texture: MTLTexture),
        textures: [String: MTLTexture],
        frameState: WPEMetalFrameState,
        encoder: MTLRenderCommandEncoder,
        depthPixelFormat: MTLPixelFormat,
        fetchSceneColor: Bool
    ) throws {
        let usesObjectQuad = executor.usesObjectQuadGeometry(for: pass, layer: layer, cameraParallax: frameState.cameraParallax)
        encoder.setRenderPipelineState(try executor.passPipelineState(
            passID: pass.pass.id,
            variant: fetchSceneColor ? .blendCompositeFramebufferFetch : .blendComposite,
            objectQuad: usesObjectQuad,
            vertexName: usesObjectQuad ? "wpe_object_quad_vertex" : "wpe_fullscreen_vertex",
            fragmentName: fetchSceneColor ? "wpe_blend_composite_fetch_fragment" : "wpe_blend_composite_fragment",
            blendMode: pass.pass.blending,
            alphaWritePolicy: .resolve(targetID: destination.id, blendMode: pass.pass.blending),
            colorPixelFormat: destination.texture.pixelFormat,
            depthPixelFormat: depthPixelFormat
        ))

        let layerReference = pass.textureBindings[0] ?? pass.pass.textures[0] ?? pass.pass.source
        let layerTexture = try WPEMetalShaderInputs.resolve(
            reference: layerReference,
            textures: textures,
            frameState: frameState,
            currentTargetID: destination.id
        )
        encoder.setFragmentTexture(layerTexture, index: 0)

        if !fetchSceneColor {
            guard let sceneReference = pass.textureBindings[4] ?? pass.pass.textures[4] else {
                throw WPEMetalRenderExecutorError.missingTexture(layerReference)
            }
            let sceneTexture = try WPEMetalShaderInputs.resolve(
                reference: sceneReference, textures: textures,
                frameState: frameState, currentTargetID: destination.id
            )
            encoder.setFragmentTexture(sceneTexture, index: 4)
        }

        var uniforms = WPEBlendCompositeUniforms(
            blendMode: Int32(WPEMetalShaderInputs.floatScalar(
                named: "g_BlendMode",
                in: pass,
                default: 0
            ))
        )
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<WPEBlendCompositeUniforms>.stride, index: 0)

        if usesObjectQuad {
            bindObjectQuadVertexUniforms(
                pass: pass, layer: layer, destination: destination, frameState: frameState,
                cameraParallax: frameState.cameraParallax,
                sourceTexture: layerTexture, encoder: encoder
            )
        }
    }

    private func dispatchCopy(
        pass: WPEPreparedRenderPass,
        layer: WPERenderLayer,
        destination: (id: WPEMetalTargetID, texture: MTLTexture),
        textures: [String: MTLTexture],
        frameState: WPEMetalFrameState,
        encoder: MTLRenderCommandEncoder,
        depthPixelFormat: MTLPixelFormat
    ) throws {
        let fragmentName = pass.pass.shader == "commands/copy"
            ? "wpe_copy_fragment"
            : "wpe_util_copy_fragment"
        let usesObjectQuad = executor.usesObjectQuadGeometry(for: pass, layer: layer, cameraParallax: frameState.cameraParallax)
        encoder.setRenderPipelineState(try executor.passPipelineState(
            passID: pass.pass.id,
            variant: .copy,
            objectQuad: usesObjectQuad,
            vertexName: usesObjectQuad ? "wpe_object_quad_vertex" : "wpe_fullscreen_vertex",
            fragmentName: fragmentName,
            blendMode: pass.pass.blending,
            alphaWritePolicy: .resolve(targetID: destination.id, blendMode: pass.pass.blending),
            colorPixelFormat: destination.texture.pixelFormat,
            depthPixelFormat: depthPixelFormat
        ))
        let reference = pass.textureBindings[0] ?? pass.pass.textures[0] ?? pass.pass.source
        let texture = try WPEMetalShaderInputs.resolve(
            reference: reference,
            textures: textures,
            frameState: frameState,
            currentTargetID: destination.id
        )
        encoder.setFragmentTexture(texture, index: 0)
        // wpe_copy_fragment samples 1:1 and takes no fragment uniform buffer.
        if usesObjectQuad {
            bindObjectQuadVertexUniforms(
                pass: pass, layer: layer, destination: destination, frameState: frameState,
                cameraParallax: frameState.cameraParallax,
                sourceTexture: texture, encoder: encoder
            )
        }
    }

    private func dispatchCompose(
        pass: WPEPreparedRenderPass,
        layer: WPERenderLayer,
        destination: (id: WPEMetalTargetID, texture: MTLTexture),
        textures: [String: MTLTexture],
        frameState: WPEMetalFrameState,
        encoder: MTLRenderCommandEncoder,
        depthPixelFormat: MTLPixelFormat
    ) throws {
        let firstReference = pass.textureBindings[0] ?? pass.pass.textures[0] ?? pass.pass.source
        let secondReference = pass.textureBindings[1] ?? pass.pass.textures[1] ?? firstReference
        let isSingleTextureComposeLayer = layer.isUtilityModelLayer
            && isLayerCompositeTarget(pass.pass.target)
            && (isSceneAliasReference(firstReference) || isGroupCompositeSourceReference(firstReference, layer: layer))
        let isLocalSceneCaptureComposeLayer = isSingleTextureComposeLayer
            && layer.groupCompositeSource == nil
            && isSceneAliasReference(firstReference)
            && executor.sceneCaptureUtilityOutputGeometry(for: layer) == .subregion
        if isLocalSceneCaptureComposeLayer {
            encoder.setRenderPipelineState(try executor.passPipelineState(
                passID: pass.pass.id,
                variant: .localSceneCapture,
                fragmentName: "wpe_local_scene_capture_fragment",
                blendMode: pass.pass.blending,
                alphaWritePolicy: .resolve(targetID: destination.id, blendMode: pass.pass.blending),
                colorPixelFormat: destination.texture.pixelFormat,
                depthPixelFormat: depthPixelFormat
            ))
            let firstTexture = try WPEMetalShaderInputs.resolve(
                reference: firstReference,
                textures: textures,
                frameState: frameState,
                currentTargetID: destination.id
            )
            encoder.setFragmentTexture(firstTexture, index: 0)
            var uniforms = executor.objectQuadUniforms(
                for: layer,
                sceneSize: frameState.sceneSize,
                cameraParallax: frameState.cameraParallax,
                sourceTexture: firstTexture,
                cameraUniforms: executor.objectQuadCameraUniforms(for: pass, layer: layer, frameState: frameState)
            )
            uniforms.uvSignAndPadding.z = clearAlphaValue(for: pass)
            encoder.setFragmentBytes(
                &uniforms,
                length: MemoryLayout<WPEObjectQuadUniforms>.stride,
                index: 0
            )
        } else if isSingleTextureComposeLayer {
            // WPE passthrough: fullscreen 1:1 screen-UV copy (+ CLEARALPHA), ignoring the layer transform (it positions downstream effects).
            encoder.setRenderPipelineState(try executor.passPipelineState(
                passID: pass.pass.id,
                variant: .composeLayer,
                fragmentName: "wpe_composelayer_fragment",
                blendMode: pass.pass.blending,
                alphaWritePolicy: .resolve(targetID: destination.id, blendMode: pass.pass.blending),
                colorPixelFormat: destination.texture.pixelFormat,
                depthPixelFormat: depthPixelFormat
            ))
            let firstTexture = try WPEMetalShaderInputs.resolve(
                reference: firstReference,
                textures: textures,
                frameState: frameState,
                currentTargetID: destination.id
            )
            encoder.setFragmentTexture(firstTexture, index: 0)
            var uniforms = WPEComposeLayerUniforms(
                flags: SIMD4<Float>(clearAlphaValue(for: pass), 0, 0, 0)
            )
            encoder.setFragmentBytes(
                &uniforms,
                length: MemoryLayout<WPEComposeLayerUniforms>.stride,
                index: 0
            )
        } else {
            let firstComposeSlot = 0
            let secondComposeSlot = 1
            let firstTexture = try WPEMetalShaderInputs.resolve(
                reference: firstReference,
                textures: textures,
                frameState: frameState,
                currentTargetID: destination.id
            )
            let secondTexture = try WPEMetalShaderInputs.resolve(
                reference: secondReference,
                textures: textures,
                frameState: frameState,
                currentTargetID: destination.id
            )
            let usesObjectQuad = executor.usesObjectQuadGeometry(for: pass, layer: layer, cameraParallax: frameState.cameraParallax)
            encoder.setRenderPipelineState(try executor.passPipelineState(
                passID: pass.pass.id,
                variant: .compose,
                objectQuad: usesObjectQuad,
                vertexName: usesObjectQuad ? "wpe_object_quad_vertex" : "wpe_fullscreen_vertex",
                fragmentName: "wpe_compose_fragment",
                blendMode: pass.pass.blending,
                alphaWritePolicy: .resolve(targetID: destination.id, blendMode: pass.pass.blending),
                colorPixelFormat: destination.texture.pixelFormat,
                depthPixelFormat: depthPixelFormat
            ))
            encoder.setFragmentTexture(firstTexture, index: firstComposeSlot)
            encoder.setFragmentTexture(secondTexture, index: secondComposeSlot)
            var uniforms = WPESolidUniforms(color: WPEMetalShaderInputs.colorVector(for: pass))
            encoder.setFragmentBytes(&uniforms, length: MemoryLayout<WPESolidUniforms>.stride, index: 0)
            if usesObjectQuad {
                bindObjectQuadVertexUniforms(
                    pass: pass, layer: layer, destination: destination, frameState: frameState,
                    cameraParallax: frameState.cameraParallax,
                    sourceTexture: firstTexture, encoder: encoder
                )
            }
        }
    }

    // MARK: - Image family

    /// Builtin image `$media*` substitution; do not route through `dispatchCustomShader` (would throw `unsupportedShader` and skip the composite write).
    private func mediaSubstituted(_ texture: MTLTexture, slot: Int, passID: String) -> MTLTexture {
        guard let store = executor.mediaTextureStore,
              let declarations = store.declarations(forPassID: passID) else { return texture }
        return store.substituting(texture, slot: slot, declarations: declarations) ?? texture
    }

    private func dispatchGenericImage2(
        pass: WPEPreparedRenderPass,
        layer: WPERenderLayer,
        destination: (id: WPEMetalTargetID, texture: MTLTexture),
        textures: [String: MTLTexture],
        frameState: WPEMetalFrameState,
        encoder: MTLRenderCommandEncoder,
        depthPixelFormat: MTLPixelFormat
    ) throws {
        let usesObjectQuad = executor.usesObjectQuadGeometry(for: pass, layer: layer, cameraParallax: frameState.cameraParallax)
        encoder.setRenderPipelineState(try executor.passPipelineState(
            passID: pass.pass.id,
            variant: .genericImage2,
            objectQuad: usesObjectQuad,
            vertexName: usesObjectQuad ? "wpe_object_quad_vertex" : "wpe_fullscreen_vertex",
            fragmentName: "wpe_genericimage2_fragment",
            blendMode: pass.pass.blending,
            alphaWritePolicy: .resolve(targetID: destination.id, blendMode: pass.pass.blending),
            colorPixelFormat: destination.texture.pixelFormat,
            depthPixelFormat: depthPixelFormat
        ))
        let reference = pass.textureBindings[0] ?? pass.pass.textures[0] ?? pass.pass.source
        let texture = mediaSubstituted(
            try WPEMetalShaderInputs.resolve(
                reference: reference,
                textures: textures,
                frameState: frameState,
                currentTargetID: destination.id
            ),
            slot: 0,
            passID: pass.pass.id
        )
        encoder.setFragmentTexture(texture, index: 0)
        var uniforms = executor.genericImageUniforms(
            for: pass,
            layer: layer,
            hasMask: false,
            sourceTexture: texture
        )
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<WPEGenericImageUniforms>.stride, index: 0)
        if usesObjectQuad {
            bindObjectQuadVertexUniforms(
                pass: pass, layer: layer, destination: destination, frameState: frameState,
                cameraParallax: frameState.cameraParallax,
                sourceTexture: texture, encoder: encoder
            )
        }
    }

    private func dispatchGenericImage4(
        pass: WPEPreparedRenderPass,
        layer: WPERenderLayer,
        destination: (id: WPEMetalTargetID, texture: MTLTexture),
        textures: [String: MTLTexture],
        frameState: WPEMetalFrameState,
        encoder: MTLRenderCommandEncoder,
        depthPixelFormat: MTLPixelFormat
    ) throws {
        let primarySlot = 0
        let maskSlot = 1
        let usesObjectQuad = executor.usesObjectQuadGeometry(for: pass, layer: layer, cameraParallax: frameState.cameraParallax)
        encoder.setRenderPipelineState(try executor.passPipelineState(
            passID: pass.pass.id,
            variant: .genericImage4,
            objectQuad: usesObjectQuad,
            vertexName: usesObjectQuad ? "wpe_object_quad_vertex" : "wpe_fullscreen_vertex",
            fragmentName: "wpe_genericimage4_fragment",
            blendMode: pass.pass.blending,
            alphaWritePolicy: .resolve(targetID: destination.id, blendMode: pass.pass.blending),
            colorPixelFormat: destination.texture.pixelFormat,
            depthPixelFormat: depthPixelFormat
        ))
        let primaryRef = pass.textureBindings[primarySlot] ?? pass.pass.textures[primarySlot] ?? pass.pass.source
        let primary = mediaSubstituted(
            try WPEMetalShaderInputs.resolve(
                reference: primaryRef,
                textures: textures,
                frameState: frameState,
                currentTargetID: destination.id
            ),
            slot: primarySlot,
            passID: pass.pass.id
        )
        WPESceneDebugArtifacts.shared.recordTextureBinding(
            passID: pass.pass.id,
            shader: pass.pass.shader,
            slot: primarySlot,
            reference: primaryRef,
            texture: primary,
            fallbackToPrimary: false
        )
        encoder.setFragmentTexture(primary, index: primarySlot)
        let maskRef = pass.textureBindings[maskSlot] ?? pass.pass.textures[maskSlot]
        let hasMask = maskRef != nil
        let mask: MTLTexture
        if let maskRef {
            mask = mediaSubstituted(
                try WPEMetalShaderInputs.resolve(
                    reference: maskRef,
                    textures: textures,
                    frameState: frameState,
                    currentTargetID: destination.id
                ),
                slot: maskSlot,
                passID: pass.pass.id
            )
            WPESceneDebugArtifacts.shared.recordTextureBinding(
                passID: pass.pass.id,
                shader: pass.pass.shader,
                slot: maskSlot,
                reference: maskRef,
                texture: mask,
                fallbackToPrimary: false
            )
        } else {
            mask = primary
            WPESceneDebugArtifacts.shared.recordTextureBinding(
                passID: pass.pass.id,
                shader: pass.pass.shader,
                slot: maskSlot,
                reference: nil,
                texture: mask,
                fallbackToPrimary: true
            )
        }
        encoder.setFragmentTexture(mask, index: maskSlot)
        var uniforms = executor.genericImageUniforms(
            for: pass,
            layer: layer,
            hasMask: hasMask,
            sourceTexture: primary,
            maskTexture: hasMask ? mask : nil
        )
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<WPEGenericImageUniforms>.stride, index: 0)
        if usesObjectQuad {
            bindObjectQuadVertexUniforms(
                pass: pass, layer: layer, destination: destination, frameState: frameState,
                cameraParallax: frameState.cameraParallax,
                sourceTexture: primary, encoder: encoder
            )
        }
    }

    // MARK: - Custom / transpiled fallback

    private func dispatchCustomShader(
        pass: WPEPreparedRenderPass,
        layer: WPERenderLayer,
        destination: (id: WPEMetalTargetID, texture: MTLTexture),
        textures: [String: MTLTexture],
        frameState: WPEMetalFrameState,
        encoder: MTLRenderCommandEncoder,
        depthPixelFormat: MTLPixelFormat
    ) throws {
        if WPEBuiltinShaderName.isGodraysCombine(pass.pass.shader) {
            try dispatchGodraysCombine(
                pass: pass,
                layer: layer,
                destination: destination,
                textures: textures,
                frameState: frameState,
                encoder: encoder,
                depthPixelFormat: depthPixelFormat
            )
            return
        }

        let result = try executor.compileCustomShader(for: pass)
        if WPESceneDebugArtifacts.shared.isEnabled {
            WPESceneDebugArtifacts.shared.recordNoteOnce(
                name: "msl-\(pass.pass.id)-\(pass.pass.shader).metal",
                contents: result.mslSource
            )
            var iface = "shader=\(pass.pass.shader) pass=\(pass.pass.id)\n"
            iface += "vertexFunction=\(result.vertexFunctionName)\n"
            iface += "fragmentFunction=\(result.fragmentFunctionName)\n"
            iface += "samplerNames=\(result.samplerNames)\n"
            iface += "uniformLayout (name | glslType | slot | slotCount | arrayLength | material):\n"
            for slot in result.uniformLayout {
                iface += "  \(slot.name) | \(slot.glslType) | \(slot.slot) | \(slot.slotCount)"
                    + " | \(slot.arrayLength.map(String.init) ?? "-") | \(slot.materialName ?? "-")\n"
            }
            WPESceneDebugArtifacts.shared.recordNoteOnce(
                name: "iface-\(pass.pass.id)-\(pass.pass.shader).txt",
                contents: iface
            )
        }
        let usesShapeQuad = executor.usesShapeQuadGeometry(for: pass, layer: layer, frameState: frameState)
        let usesObjectQuad = !usesShapeQuad
            && executor.usesObjectQuadGeometry(for: pass, layer: layer, cameraParallax: frameState.cameraParallax)
        if WPESceneDebugArtifacts.shared.isEnabled, Self.isWaveLikePass(pass) {
            let maskLive = Self.hasExplicitTextureSlot(1, in: pass)
            WPESceneDebugArtifacts.shared.appendLog(
                "🌊 [WPE.fx.vtx] \(pass.pass.shader) target=\(pass.pass.target) "
                    + "vertex=\(usesObjectQuad ? "builtin_object_quad" : "fullscreen+synthesized-varyings") "
                    + "maskSlot1=\(maskLive) MASK=\(pass.comboValues["MASK"] ?? 0)",
                level: .warning
            )
        }

        var primary: MTLTexture? = nil
        let resolvedTexturesBySlot = executor.customTextureSlotScratch
        resolvedTexturesBySlot.reset()
        // `$media*` resolved once per pass, not per slot: the store is nil for scenes with no `$media*` user texture, and its slot map is nil for every other pass.
        let mediaTextureStore = executor.mediaTextureStore
        let mediaSlots = mediaTextureStore?.declarations(forPassID: pass.pass.id)
        #if !LITE_BUILD && DEBUG
        var canonicalTextureBindings: [WPECanonicalTraceRecorder.TextureBindingInput] = []
        #endif
        // Bind exactly `result.textureSlotCount` (shader signature): fewer would sample an unbound texture.
        for slot in 0..<result.textureSlotCount {
            // Prefer `textureBindings` (normalized; rewrites effect-bind `previous` to the pass source). Raw `binds` still has literal `.previous`, which would resolve to the black bootstrap previous on a target with no history.
            let reference = pass.textureBindings[slot]
                ?? pass.pass.binds[slot]
                ?? pass.pass.textures[slot]
            var texture: MTLTexture?
            let samplingDescriptor: WPETexSpriteSamplingDescriptor?
            let resolvedReference: WPETextureReference?
            let fallbackToPrimary: Bool
            if let reference {
                // Auxiliary slot (slot > 0) miss rebinds primary rather than killing the scene; slot 0 stays fatal.
                do {
                    texture = try WPEMetalShaderInputs.resolve(
                        reference: reference,
                        textures: textures,
                        frameState: frameState,
                        currentTargetID: destination.id
                    )
                    resolvedReference = reference
                    samplingDescriptor = executor.textureSamplingDescriptor(for: reference)
                    fallbackToPrimary = false
                } catch where slot > 0 {
                    let key = "\(pass.pass.id)#\(slot)"
                    if executor.loggedUnresolvedTextureSlots.insert(key).inserted {
                        Logger.warning(
                            "WPE pass \(pass.pass.id) (\(pass.pass.shader)) slot \(slot) references"
                                + " \(reference), which does not resolve — binding the primary texture."
                                + " Wallpaper Engine tolerates a broken auxiliary slot; the scene still renders.",
                            category: .wpeRender
                        )
                    }
                    texture = primary
                    resolvedReference = nil
                    // Do not infer the missing auxiliary-slot transform from the primary texture just because the Metal slot rebinds it (WE fallback is undocumented).
                    samplingDescriptor = nil
                    fallbackToPrimary = true
                }
            } else if slot == 0 {
                texture = try WPEMetalShaderInputs.resolve(
                    reference: pass.pass.source,
                    textures: textures,
                    frameState: frameState,
                    currentTargetID: destination.id
                )
                resolvedReference = pass.pass.source
                samplingDescriptor = executor.textureSamplingDescriptor(for: pass.pass.source)
                fallbackToPrimary = false
            } else {
                texture = primary
                resolvedReference = nil
                samplingDescriptor = nil
                fallbackToPrimary = true
            }
            // Substitute after authored resolution: a nil store keeps the author's placeholder cover ("nothing is playing"), not a hole.
            if let mediaSlots, let mediaTextureStore {
                texture = mediaTextureStore.substituting(texture, slot: slot, declarations: mediaSlots)
            }
            if slot == 0, let texture { primary = texture }
            WPESceneDebugArtifacts.shared.recordTextureBinding(
                passID: pass.pass.id,
                shader: pass.pass.shader,
                slot: slot,
                reference: resolvedReference,
                texture: texture,
                fallbackToPrimary: fallbackToPrimary
            )
            // Per-slot sampler from TEXI flags (clamp/repeat, linear/nearest); time-scrolled tiling maps would freeze at the edge if clamped.
            let resolution = texture.map { WPEMetalTextureMetadataRegistry.shared.resolution(for: $0) }
            let sampler = executor.customShaderSamplerState(resolution: resolution)
            resolvedTexturesBySlot.set(
                texture: texture,
                samplingDescriptor: samplingDescriptor,
                sampler: sampler,
                resolution: resolution,
                at: slot
            )
            #if !LITE_BUILD && DEBUG
            canonicalTextureBindings.append(WPECanonicalTraceRecorder.TextureBindingInput(
                slot: slot,
                name: result.samplerNames.indices.contains(slot) ? result.samplerNames[slot] : nil,
                reference: resolvedReference,
                texture: texture,
                fallbackToPrimary: fallbackToPrimary,
                sampler: executor.customShaderSamplerDescription(resolution: resolution)
            ))
            #endif
        }

        resolvedTexturesBySlot.bindFragmentResources(to: encoder, count: result.textureSlotCount)
        let packedUniforms = try executor.packTranslatedUniformsForBinding(
            for: pass,
            layout: result.uniformLayout,
            texturesBySlot: resolvedTexturesBySlot
        )
        #if !LITE_BUILD && DEBUG
        WPECanonicalTraceRecorder.shared.recordCustomPass(
            pass: pass,
            destination: destination,
            result: result,
            textureBindings: canonicalTextureBindings,
            packedUniformSlots: packedUniforms.slotsForTracing(),
            usesObjectQuad: usesObjectQuad,
            nativeState: .scenePass(
                blendMode: pass.pass.blending,
                alphaWritePolicy: .resolve(targetID: destination.id, blendMode: pass.pass.blending),
                cullMode: pass.pass.cullMode,
                depthAttached: executor.depthCache.needsAttachment(for: pass),
                depthTest: pass.pass.depthTest,
                depthWrite: pass.pass.depthWrite,
                reversedZ: frameState.cameraUniforms.usesPerspectiveProjection
            )
        )
        #endif

        // `effects/skew` MODE=1 displaces quad geometry in the vertex stage; a plain object quad would drop the effect (transpiled fragment leaves UV untouched).
        let usesSkewVertex = usesObjectQuad && executor.isVertexSkewPass(pass)
        let vertexName: String?
        if usesShapeQuad {
            vertexName = "wpe_shape_quad_vertex"
        } else if usesSkewVertex {
            vertexName = "wpe_skew_object_quad_vertex"
        } else if usesObjectQuad {
            vertexName = "wpe_object_quad_vertex"
        } else {
            vertexName = nil
        }
        let pipelineState = try executor.translatedPipelineState(
            for: result,
            vertexName: vertexName,
            blendMode: pass.pass.blending,
            alphaWritePolicy: .resolve(targetID: destination.id, blendMode: pass.pass.blending),
            colorPixelFormat: destination.texture.pixelFormat,
            depthPixelFormat: depthPixelFormat
        )
        encoder.setRenderPipelineState(pipelineState)

        if !packedUniforms.isEmpty {
            executor.bindTranslatedUniformSlots(packedUniforms, to: encoder)
        }
        if usesShapeQuad {
            var shapeUniforms = executor.shapeQuadUniforms(
                for: layer,
                sceneSize: executor.objectQuadSceneSize(
                    for: pass,
                    layer: layer,
                    destination: destination,
                    frameState: frameState
                ),
                cameraParallax: frameState.cameraParallax
            )
            encoder.setVertexBytes(
                &shapeUniforms,
                length: MemoryLayout<WPEShapeQuadUniforms>.stride,
                index: 1
            )
        } else if usesObjectQuad {
            bindObjectQuadVertexUniforms(
                pass: pass, layer: layer, destination: destination, frameState: frameState,
                cameraParallax: frameState.cameraParallax,
                sourceTexture: primary ?? destination.texture, encoder: encoder
            )
            if usesSkewVertex {
                var skewParams = executor.vertexSkewParams(for: pass)
                encoder.setVertexBytes(
                    &skewParams,
                    length: MemoryLayout<WPESkewParams>.stride,
                    index: 2
                )
            }
        }
    }

    private func dispatchGodraysCombine(
        pass: WPEPreparedRenderPass,
        layer: WPERenderLayer,
        destination: (id: WPEMetalTargetID, texture: MTLTexture),
        textures: [String: MTLTexture],
        frameState: WPEMetalFrameState,
        encoder: MTLRenderCommandEncoder,
        depthPixelFormat: MTLPixelFormat
    ) throws {
        let usesObjectQuad = executor.usesObjectQuadGeometry(
            for: pass,
            layer: layer,
            cameraParallax: frameState.cameraParallax
        )
        encoder.setRenderPipelineState(try executor.passPipelineState(
            passID: pass.pass.id,
            variant: .godraysCombine,
            objectQuad: usesObjectQuad,
            vertexName: usesObjectQuad ? "wpe_object_quad_vertex" : "wpe_fullscreen_vertex",
            fragmentName: "wpe_effect_godrays_combine_fragment",
            blendMode: pass.pass.blending,
            alphaWritePolicy: .resolve(targetID: destination.id, blendMode: pass.pass.blending),
            colorPixelFormat: destination.texture.pixelFormat,
            depthPixelFormat: depthPixelFormat
        ))

        let raysSlot = 0
        let albedoSlot = 1
        let baseSlot = 2
        let raysReference = pass.textureBindings[raysSlot]
            ?? pass.pass.binds[raysSlot]
            ?? pass.pass.textures[raysSlot]
            ?? pass.pass.source
        let albedoReference = pass.textureBindings[albedoSlot]
            ?? pass.pass.binds[albedoSlot]
            ?? pass.pass.textures[albedoSlot]
            ?? pass.pass.source
        let baseReference = pass.textureBindings[baseSlot]
            ?? pass.pass.binds[baseSlot]
            ?? pass.pass.textures[baseSlot]
        let raysTexture = try WPEMetalShaderInputs.resolve(
            reference: raysReference,
            textures: textures,
            frameState: frameState,
            currentTargetID: destination.id
        )
        let albedoTexture = try WPEMetalShaderInputs.resolve(
            reference: albedoReference,
            textures: textures,
            frameState: frameState,
            currentTargetID: destination.id
        )
        let baseTexture = try baseReference.map {
            try WPEMetalShaderInputs.resolve(
                reference: $0,
                textures: textures,
                frameState: frameState,
                currentTargetID: destination.id
            )
        } ?? albedoTexture
        if WPESceneDebugArtifacts.shared.isEnabled {
            let destinationID = ObjectIdentifier(destination.texture)
            let raysID = ObjectIdentifier(raysTexture)
            let albedoID = ObjectIdentifier(albedoTexture)
            let baseID = ObjectIdentifier(baseTexture)
            WPESceneDebugArtifacts.shared.appendLog(
                "[godrays.combine] pass=\(pass.pass.id) "
                    + "dst=\(destination.texture.label ?? "-") \(destination.texture.width)x\(destination.texture.height) id=\(destinationID) "
                    + "rays=\(raysTexture.label ?? "-") \(raysTexture.width)x\(raysTexture.height) id=\(raysID) sameDst=\(raysTexture === destination.texture) "
                    + "albedo=\(albedoTexture.label ?? "-") \(albedoTexture.width)x\(albedoTexture.height) id=\(albedoID) sameDst=\(albedoTexture === destination.texture) "
                    + "base=\(baseTexture.label ?? "-") \(baseTexture.width)x\(baseTexture.height) id=\(baseID) sameDst=\(baseTexture === destination.texture)",
                level: .notice
            )
        }
        encoder.setFragmentTexture(raysTexture, index: raysSlot)
        encoder.setFragmentTexture(albedoTexture, index: albedoSlot)
        encoder.setFragmentTexture(baseTexture, index: baseSlot)

        // Slot 2 is COPYBG mixed under albedo (never rays-only). BLENDMODE default 9 = Add.
        var uniforms = WPEGodraysCombineUniforms(
            copyBackground: baseReference == nil ? 0 : 1,
            blendMode: Self.sanitizedGodraysBlendMode(pass.comboValues["BLENDMODE"])
        )
        encoder.setFragmentBytes(
            &uniforms,
            length: MemoryLayout<WPEGodraysCombineUniforms>.stride,
            index: 0
        )

        WPESceneDebugArtifacts.shared.recordTextureBinding(
            passID: pass.pass.id,
            shader: pass.pass.shader,
            slot: 0,
            reference: raysReference,
            texture: raysTexture,
            fallbackToPrimary: false
        )
        WPESceneDebugArtifacts.shared.recordTextureBinding(
            passID: pass.pass.id,
            shader: pass.pass.shader,
            slot: 1,
            reference: albedoReference,
            texture: albedoTexture,
            fallbackToPrimary: false
        )
        WPESceneDebugArtifacts.shared.recordTextureBinding(
            passID: pass.pass.id,
            shader: pass.pass.shader,
            slot: 2,
            reference: baseReference,
            texture: baseTexture,
            fallbackToPrimary: baseReference == nil
        )

        if usesObjectQuad {
            bindObjectQuadVertexUniforms(
                pass: pass, layer: layer, destination: destination, frameState: frameState,
                cameraParallax: frameState.cameraParallax,
                sourceTexture: albedoTexture, encoder: encoder
            )
        }
    }

    /// Authored combo is untrusted: a negative/huge value converted to `UInt32` would trap. Domain 0...32; else Add = 9.
    static func sanitizedGodraysBlendMode(_ authored: Int?) -> UInt32 {
        let value = authored ?? 9
        guard (0...32).contains(value) else { return 9 }
        return UInt32(value)
    }

    private static func isWaveLikePass(_ pass: WPEPreparedRenderPass) -> Bool {
        if WPEBuiltinShaderKind(normalizing: pass.pass.shader) == .effectWaterWaves { return true }
        let shader = pass.pass.shader.lowercased()
        return shader.contains("wave") || shader.contains("flutter")
    }

    private static func hasExplicitTextureSlot(_ slot: Int, in pass: WPEPreparedRenderPass) -> Bool {
        pass.textureBindings[slot] != nil
            || pass.pass.textures[slot] != nil
            || pass.pass.binds[slot] != nil
    }

    func isLayerCompositeTarget(_ target: WPERenderTarget) -> Bool {
        if case .layerComposite = target {
            return true
        }
        return false
    }

    func isSceneAliasReference(_ reference: WPETextureReference) -> Bool {
        guard case .fbo(let name) = reference else {
            return false
        }
        return WPETextureReference.isSceneAliasName(name)
    }

    func isGroupCompositeSourceReference(_ reference: WPETextureReference, layer: WPERenderLayer) -> Bool {
        guard case .fbo(let name) = reference else {
            return false
        }
        return name == layer.groupCompositeSource
    }

    private func clearAlphaValue(for pass: WPEPreparedRenderPass) -> Float {
        comboValueIfPresent(named: "CLEARALPHA", in: pass) == 1 ? 1 : 0
    }

    private func comboValueIfPresent(named name: String, in pass: WPEPreparedRenderPass) -> Int? {
        if let value = pass.comboValues[name] ?? pass.pass.combos[name] {
            return value
        }
        let uppercased = name.uppercased()
        for (key, value) in pass.comboValues where key.uppercased() == uppercased {
            return value
        }
        for (key, value) in pass.pass.combos where key.uppercased() == uppercased {
            return value
        }
        return nil
    }

}
#endif
